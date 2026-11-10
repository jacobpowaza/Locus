import Foundation

/// Where executed positions go. The app implements this on top of
/// SpoofSession / LocationEngine; tests record calls.
protocol LocationSink: AnyObject {
    /// Speed and heading are informational. The DVT service accepts coordinates.
    func deliver(_ point: GeoPoint, speed: Double?, heading: Double?) -> LocationDelivery
    func deliverStop() -> LocationDelivery
}

enum LocationDelivery {
    case applied, pending, failed
}

enum ExecutionStatus: String, Codable, Equatable {
    case running, paused, completed, failed, cancelled

    var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
}

struct ExecutionLogEntry: Codable, Equatable, Hashable {
    enum Level: String, Codable { case info, warning, error }
    var date: Date
    var level: Level
    var message: String
}

/// Everything needed to resume a run after an app restart. Persisted as the
/// active-run checkpoint.
struct ExecutionState: Codable, Equatable {
    var recordID: UUID
    var runID: UUID
    var runName: String
    var trigger: RunTrigger
    var occurrence: Date?
    var plan: RunPlan
    var index: Int = 0
    var elapsedInSegment: Double = 0
    var status: ExecutionStatus = .running
    var pauseReason: String?
    var failure: String?
    var speedPolicy: SpeedPolicy
    var startedAt: Date
    var endedAt: Date?
    /// Running time excluding pauses.
    var activeElapsed: Double = 0
    /// Wall time of the last advance — used to catch up after a restart.
    var lastWall: Date
    /// Distance from drives already finished (or cut by pause/speed change).
    var distanceBanked: Double = 0
    /// Last segment whose start was logged (avoids duplicate log lines on resume).
    var announcedIndex: Int = -1
    var log: [ExecutionLogEntry] = []
    var startConfirmed: Bool? = nil
    var lastStartedStep: Int? = nil
    var stopPending: Bool? = nil

    static let maxLogEntries = 500
}

enum RunTrigger: String, Codable, Equatable {
    case manual, scheduled
}

/// Read-only view for the UI.
struct ExecutionSnapshot: Equatable {
    var status: ExecutionStatus
    var pauseReason: String?
    var segment: PlanSegment?
    var segmentIndex: Int
    var segmentCount: Int
    /// Simulated position (nil = not spoofing).
    var position: GeoPoint?
    var speed: Double
    var heading: Double?
    var referenceSpeed: Double?
    var referenceSource: SpeedReferenceSource?
    var speedPolicy: SpeedPolicy
    var legDistanceRemaining: Double?
    var legArrival: Date?
    var holdEnds: Date?
    var runEnd: Date
    var activeElapsed: Double
    var distanceDriven: Double
    var distanceRemaining: Double
    var projected: [ProjectedSegment]
    var connectionProblem: Bool
    /// Standing at a red light or stop sign right now.
    var stoppedFor: DriveStop.Kind? = nil
    var isClearingLocation = false
}

/// Steps a compiled plan forward in time and pushes positions to a sink.
///
/// Time handling:
/// - Waits and drives advance on a monotonic clock (unaffected by the user
///   changing the device clock or by DST).
/// - Start At waits for wall-clock time.
/// - After a restart, progress is caught up from the last checkpoint's wall
///   time, then the run is paused so the user decides to continue.
final class RunExecutor {
    private static let driveCadence = 1.0
    private(set) var state: ExecutionState
    weak var sink: LocationSink?

    private enum Sent: Equatable { case unknown, stopped, at(GeoPoint) }
    private var sent: Sent = .unknown
    private var lastMonotonic: Double?
    private var sinkFailingSince: Date?
    private var pendingSince: Date?
    private var awaitingDelivery = false
    private var pendingDriveAdvance: Double?
    private var pendingDriveSubmission: Double?
    private var queuedSpeed: SpeedPolicy?
    private(set) var stopRequested = false
    private var skipRequested = false

    /// Pause the run if the sink keeps failing this long.
    var sinkFailureGrace: Double = 30
    /// Treat a tick gap this long as a suspension. Must
    /// exceed the longest planned tick (15 s during waits, see nextWakeDelay)
    /// so ordinary ticks aren't reported as suspensions.
    var suspensionThreshold: Double = 20
    /// Mirrors every log line (the app forwards these to the system log).
    var logObserver: ((ExecutionLogEntry) -> Void)?
    enum StepEvent: String { case started, completed, interrupted }
    var stepObserver: ((StepEvent, PlanSegment) -> Void)?

    init(state: ExecutionState, sink: LocationSink?) {
        self.state = state
        self.sink = sink
    }

    static func start(
        plan: RunPlan,
        run: ScheduledRun,
        trigger: RunTrigger,
        occurrence: Date?,
        wallNow: Date,
        monotonic: Double,
        sink: LocationSink?,
        logObserver: ((ExecutionLogEntry) -> Void)? = nil,
        stepObserver: ((StepEvent, PlanSegment) -> Void)? = nil
    ) -> RunExecutor {
        let state = ExecutionState(
            recordID: UUID(),
            runID: run.id,
            runName: run.name,
            trigger: trigger,
            occurrence: occurrence,
            plan: plan,
            speedPolicy: run.defaultSpeed,
            startedAt: wallNow,
            lastWall: wallNow
        )
        let ex = RunExecutor(state: state, sink: sink)
        ex.logObserver = logObserver
        ex.stepObserver = stepObserver
        ex.lastMonotonic = monotonic
        ex.advance(wallNow: wallNow, monotonic: monotonic)
        return ex
    }

    // MARK: - Ticking

    /// Normal tick.
    func advance(wallNow: Date, monotonic: Double) {
        let dt = max(0, monotonic - (lastMonotonic ?? monotonic))
        lastMonotonic = monotonic
        defer { state.lastWall = wallNow }
        if stopRequested {
            cancel(stopSpoofing: true, wallNow: wallNow)
            return
        }
        if skipRequested {
            skip(wallNow: wallNow, monotonic: monotonic)
            return
        }
        guard state.status == .running else { return }
        if dt > suspensionThreshold {
            log(.warning, "Locus was suspended. Playback continues from the last confirmed position.", wallNow)
        }
        let interrupted = dt > suspensionThreshold || sinkFailingSince != nil
        if interrupted { pendingDriveSubmission = nil }
        let index = state.index
        let hadPendingDrive = pendingDriveAdvance != nil
        step(dt: interrupted ? 0 : dt, wallNow: wallNow)
        if awaitingDelivery, pendingDriveAdvance != nil {
            if !hadPendingDrive { pendingDriveSubmission = monotonic }
        } else {
            // A prompt acknowledgment should not add a second wait to every
            // moving fix. Use the send time as the origin for the next frame.
            if let submission = pendingDriveSubmission, state.index == index,
               pendingDriveAdvance == nil, monotonic - submission < Self.driveCadence {
                lastMonotonic = submission
            }
            pendingDriveSubmission = nil
        }
        if let policy = queuedSpeed, pendingDriveAdvance == nil {
            queuedSpeed = nil
            changeSpeed(to: policy, wallNow: wallNow)
        }
    }

    /// A checkpoint represents confirmed output. Preserve it and wait for
    /// the user to resume before applying any further location actions.
    func recoverAfterRestart(wallNow: Date, monotonic: Double) {
        lastMonotonic = monotonic
        sent = .unknown
        guard state.status == .running || state.status == .paused else { return }
        state.lastWall = wallNow
        state.status = .paused
        state.pauseReason = state.stopPending == true
            ? "Locus closed before clearing the simulated location. Resume to retry clearing."
            : "Locus was closed. Resume from the last saved step."
        log(.warning, "Recovered after Locus restarted. Paused at the last checkpoint.", wallNow)
    }

    private func step(dt: Double, wallNow: Date) {
        var remaining = awaitingDelivery || sinkFailingSince != nil ? 0 : dt
        let segs = state.plan.segments
        while state.index < segs.count, state.status == .running {
            let seg = state.plan.segments[state.index]
            switch seg.kind {
            case .teleport(let place):
                guard send(.at(place.point), speed: 0, wallNow: wallNow) else { return }
                confirmStart(wallNow)
                log(.info, "Set location to \(place.name).", wallNow.addingTimeInterval(-remaining))
                enterNext()
            case .setSpeed(let policy):
                confirmStart(wallNow)
                state.speedPolicy = policy
                log(.info, "Speed: \(policy.summary(unit: .mph)).", wallNow.addingTimeInterval(-remaining))
                enterNext()
            case .stop:
                guard send(.stopped, wallNow: wallNow) else { return }
                confirmStart(wallNow)
                log(.info, "Turned off Locus.", wallNow.addingTimeInterval(-remaining))
                enterNext()
            case .hold(let seconds):
                if let point = seg.location, !send(.at(point), speed: 0, wallNow: wallNow) { return }
                confirmStart(wallNow)
                let left = seconds - state.elapsedInSegment
                if remaining >= left {
                    remaining -= max(0, left)
                    state.activeElapsed += max(0, left)
                    enterNext()
                } else {
                    state.elapsedInSegment += remaining
                    state.activeElapsed += remaining
                    remaining = 0
                    return
                }
            case .waitUntil(let target):
                if let point = seg.location, !send(.at(point), speed: 0, wallNow: wallNow) { return }
                confirmStart(wallNow)
                let entry = wallNow.addingTimeInterval(-remaining)
                if target <= entry {
                    let late = entry.timeIntervalSince(target)
                    if late > 60, state.elapsedInSegment == 0 {
                        log(.warning, "Wait Until \(DurationText.clock(target, timeZone: tz)) began \(DurationText.short(late)) late.", entry)
                    }
                    enterNext()
                } else if target <= wallNow {
                    let waited = target.timeIntervalSince(entry)
                    state.activeElapsed += waited
                    remaining = wallNow.timeIntervalSince(target)
                    enterNext()
                } else {
                    state.elapsedInSegment += remaining
                    state.activeElapsed += remaining
                    remaining = 0
                    return
                }
            case .drive(let leg):
                let left = max(0, leg.profile.duration - state.elapsedInSegment)
                let increment = pendingDriveAdvance ?? min(remaining, left)
                let next = leg.profile.state(at: state.elapsedInSegment + increment)
                let point = increment >= left ? leg.destination.point : next.position
                guard send(.at(point), speed: next.speed, heading: next.heading, wallNow: wallNow) else {
                    pendingDriveAdvance = increment
                    return
                }
                pendingDriveAdvance = nil
                confirmStart(wallNow)
                if state.announcedIndex != state.index {
                    state.announcedIndex = state.index
                    log(.info, "Driving to \(leg.destination.name) — \(Self.km(leg.profile.distance)), about \(DurationText.short(leg.profile.duration)).", wallNow)
                }
                state.elapsedInSegment += increment
                state.activeElapsed += increment
                if increment >= left {
                    remaining = max(0, remaining - increment)
                    state.distanceBanked += leg.profile.distance
                    log(.info, "Arrived at \(leg.destination.name).", wallNow)
                    enterNext()
                } else {
                    return
                }
            }
        }
        if state.index >= segs.count, state.status == .running {
            state.status = .completed
            state.endedAt = wallNow.addingTimeInterval(-remaining)
            log(.info, "Run completed.", state.endedAt ?? wallNow)
        }
    }

    private func confirmStart(_ now: Date) {
        if state.startConfirmed != true {
            state.startConfirmed = true
            log(.info, "Started \(state.trigger == .scheduled ? "scheduled" : "manual") run with \(state.plan.segments.count) steps.", now)
        }
        if state.lastStartedStep != state.index {
            state.lastStartedStep = state.index
            stepObserver?(.started, state.plan.segments[state.index])
        }
    }

    private func enterNext(completed: Bool = true) {
        if completed { stepObserver?(.completed, state.plan.segments[state.index]) }
        state.index += 1
        state.elapsedInSegment = 0
    }

    private var tz: TimeZone { TimeZone(identifier: state.plan.timeZoneID) ?? .current }

    // MARK: - Output

    /// Where the simulated location should be right now (nil = not spoofing).
    var desiredPosition: (point: GeoPoint, speed: Double, heading: Double?)? {
        let segs = state.plan.segments
        if state.index >= segs.count {
            return state.plan.finalLocation.map { ($0, 0, nil) }
        }
        let seg = segs[state.index]
        switch seg.kind {
        case .drive(let leg):
            let s = leg.profile.state(at: state.elapsedInSegment)
            return (s.position, state.status == .running ? s.speed : 0, s.heading)
        case .teleport(let p):
            return (p.point, 0, nil)
        case .stop:
            return nil
        case .hold, .waitUntil, .setSpeed:
            return seg.location.map { ($0, 0, nil) }
        }
    }

    @discardableResult
    private func send(_ target: Sent, speed: Double? = nil, heading: Double? = nil, wallNow: Date) -> Bool {
        if sent == target && !awaitingDelivery && sinkFailingSince == nil { return true }
        guard let sink else { return true }
        let result: LocationDelivery
        switch target {
        case .at(let point): result = sink.deliver(point, speed: speed, heading: heading)
        case .stopped: result = sink.deliverStop()
        case .unknown: return true
        }
        awaitingDelivery = result == .pending
        if result != .pending { pendingSince = nil }
        switch result {
        case .applied:
            sent = target
            if sinkFailingSince != nil { log(.info, "Simulation connection restored.", wallNow) }
            sinkFailingSince = nil
            return true
        case .pending:
            if pendingSince == nil { pendingSince = wallNow }
            return false
        case .failed:
            if let since = sinkFailingSince {
                if wallNow.timeIntervalSince(since) >= sinkFailureGrace {
                    if state.plan.segments.indices.contains(state.index) {
                        stepObserver?(.interrupted, state.plan.segments[state.index])
                    }
                    if stopRequested {
                        stopRequested = false
                        state.stopPending = nil
                        fail("Couldn’t confirm that the simulated location was cleared.", wallNow: wallNow)
                    } else {
                        skipRequested = false
                        pause(reason: "Connection lost. Check Settings, then resume.", wallNow: wallNow)
                    }
                }
            } else {
                sinkFailingSince = wallNow
                log(.warning, "Couldn’t update the simulated location. Retrying.", wallNow)
            }
            return false
        }
    }

    /// Re-send the current position even if unchanged (after reconnects).
    func invalidateSentPosition() { sent = .unknown }

    // MARK: - Controls

    func pause(reason: String? = nil, wallNow: Date) {
        guard state.status == .running else { return }
        state.status = .paused
        state.pauseReason = reason
        state.lastWall = wallNow
        pendingDriveSubmission = nil
        log(reason == nil ? .info : .warning, reason.map { "Paused: \($0)" } ?? "Paused.", wallNow)

    }

    func resume(wallNow: Date, monotonic: Double) {
        guard state.status == .paused else { return }
        if state.stopPending == true {
            sinkFailingSince = nil
            cancel(stopSpoofing: true, wallNow: wallNow)
            return
        }
        // A paused car restarts from standstill: re-solve the rest of the leg.
        if state.index < state.plan.segments.count,
           case .drive(var leg) = state.plan.segments[state.index].kind,
           state.elapsedInSegment > 0, pendingDriveAdvance == nil {
            let travelled = leg.profile.state(at: state.elapsedInSegment).distanceTravelled
            if let rest = leg.profile.remainder(from: state.elapsedInSegment, initialSpeed: 0) {
                state.distanceBanked += travelled
                leg.profile = rest
                state.plan.segments[state.index].kind = .drive(leg)
                state.elapsedInSegment = 0
            }
        }
        state.status = .running
        state.pauseReason = nil
        lastMonotonic = monotonic
        sent = .unknown
        sinkFailingSince = nil
        log(.info, "Resumed.", wallNow)
        step(dt: 0, wallNow: wallNow)
        state.lastWall = wallNow
    }

    /// Explicitly skipping a drive applies its endpoint before advancing.
    func skip(wallNow: Date, monotonic: Double) {
        guard !state.status.isFinished, state.index < state.plan.segments.count else { return }
        let seg = state.plan.segments[state.index]
        skipRequested = true
        if case .drive(let leg) = seg.kind {
            guard send(.at(leg.destination.point), speed: 0, wallNow: wallNow) else { return }
            state.distanceBanked += leg.profile.distance
        }
        skipRequested = false
        pendingDriveAdvance = nil
        pendingDriveSubmission = nil
        log(.info, "Skipped: \(seg.summary).", wallNow)
        enterNext(completed: false)
        lastMonotonic = monotonic
        if state.status == .running { step(dt: 0, wallNow: wallNow) }
        state.lastWall = wallNow
    }

    func cancel(stopSpoofing: Bool, wallNow: Date) {
        guard !state.status.isFinished else { return }
        stopRequested = stopSpoofing
        state.stopPending = stopSpoofing ? true : nil
        if stopSpoofing && !send(.stopped, wallNow: wallNow) { return }
        stopRequested = false
        state.stopPending = nil
        state.status = .cancelled
        state.endedAt = wallNow
        state.pauseReason = nil
        log(.info, stopSpoofing ? "Ended and cleared the simulated location." : "Ended at the last confirmed location.", wallNow)
    }

    func fail(_ message: String, wallNow: Date) {
        guard !state.status.isFinished else { return }
        state.status = .failed
        state.failure = message
        state.endedAt = wallNow
        log(.error, message, wallNow)
    }

    /// Live speed change: applies to the current drive and later drives that
    /// inherit the run's speed (until the next Set Speed step). Drives with
    /// their own Custom Speed are left alone.
    func changeSpeed(to policy: SpeedPolicy, wallNow: Date) {
        guard !state.status.isFinished else { return }
        if pendingDriveAdvance != nil {
            queuedSpeed = policy
            return
        }
        state.speedPolicy = policy
        var i = state.index
        while i < state.plan.segments.count {
            let seg = state.plan.segments[i]
            if i > state.index, case .setSpeed = seg.kind { break }
            if case .drive(var leg) = seg.kind, !leg.hasCustomSpeed {
                if i == state.index, state.elapsedInSegment > 0 {
                    let now = leg.profile.state(at: state.elapsedInSegment)
                    let initial = state.status == .running ? now.speed : 0
                    if let rest = leg.profile.remainder(from: state.elapsedInSegment, policy: policy, initialSpeed: initial) {
                        state.distanceBanked += now.distanceTravelled
                        leg.profile = rest
                        state.elapsedInSegment = 0
                    }
                } else {
                    leg.profile = leg.profile.withPolicy(policy)
                }
                state.plan.segments[i].kind = .drive(leg)
            }
            i += 1
        }
        log(.info, "Speed changed to \(policy.summary(unit: .mph)); ETA updated.", wallNow)
    }

    // MARK: - Reading

    /// Seconds until the executor next needs a tick.
    func nextWakeDelay(wallNow: Date, monotonic: Double) -> Double {
        if awaitingDelivery { return 0.25 }
        if stopRequested || skipRequested || (state.status == .running && sinkFailingSince != nil) { return 2 }
        guard state.status == .running, state.index < state.plan.segments.count else { return 30 }
        switch state.plan.segments[state.index].kind {
        case .drive:
            let elapsed = max(0, monotonic - (lastMonotonic ?? monotonic))
            return max(0.25, Self.driveCadence - elapsed)
        case .hold(let s): return min(15, max(0.25, s - state.elapsedInSegment))
        case .waitUntil(let t): return min(15, max(0.25, t.timeIntervalSince(wallNow)))
        default: return 0.25
        }
    }

    func snapshot(wallNow: Date) -> ExecutionSnapshot {
        let segs = state.plan.segments
        let seg = state.index < segs.count ? segs[state.index] : nil
        let d = desiredPosition
        var ref: Double?
        var refSource: SpeedReferenceSource?
        var legRemaining: Double?
        var legArrival: Date?
        var holdEnds: Date?
        var currentLegDriven = 0.0
        var currentLegLeft = 0.0
        var stoppedFor: DriveStop.Kind?

        let projected = state.status.isFinished
            ? []
            : state.plan.project(fromIndex: min(state.index, max(0, segs.count - 1)), elapsedInCurrent: state.elapsedInSegment, now: wallNow)

        if let seg {
            switch seg.kind {
            case .drive(let leg):
                let s = leg.profile.state(at: state.elapsedInSegment)
                ref = s.referenceSpeed
                refSource = s.referenceSource
                legRemaining = s.distanceRemaining
                currentLegDriven = s.distanceTravelled
                currentLegLeft = s.distanceRemaining
                stoppedFor = s.stoppedFor
                legArrival = projected.first?.end
            case .hold, .waitUntil:
                holdEnds = projected.first?.end
            default:
                break
            }
        }
        var later = 0.0
        if state.index + 1 < segs.count {
            for s in segs[(state.index + 1)...] {
                if case .drive(let leg) = s.kind { later += leg.profile.distance }
            }
        }
        let paused = state.status != .running
        return ExecutionSnapshot(
            status: state.status,
            pauseReason: state.pauseReason,
            segment: seg,
            segmentIndex: state.index,
            segmentCount: segs.count,
            position: d?.point,
            speed: paused || stopRequested || sinkFailingSince != nil ? 0 : (d?.speed ?? 0),
            heading: d?.heading,
            referenceSpeed: ref,
            referenceSource: refSource,
            speedPolicy: state.speedPolicy,
            legDistanceRemaining: legRemaining,
            legArrival: legArrival,
            holdEnds: holdEnds,
            runEnd: state.endedAt ?? projected.last?.end ?? wallNow,
            activeElapsed: state.activeElapsed,
            distanceDriven: state.distanceBanked + currentLegDriven,
            distanceRemaining: currentLegLeft + later,
            projected: projected,
            connectionProblem: sinkFailingSince != nil || (pendingSince.map { wallNow.timeIntervalSince($0) > 2 } ?? false),
            stoppedFor: state.status == .running ? stoppedFor : nil
        )
    }

    // MARK: - Logging

    func appendLog(_ level: ExecutionLogEntry.Level, _ message: String, _ date: Date) {
        log(level, message, date)
    }

    private func log(_ level: ExecutionLogEntry.Level, _ message: String, _ date: Date) {
        let entry = ExecutionLogEntry(date: date, level: level, message: message)
        logObserver?(entry)
        state.log.append(entry)
        if state.log.count > ExecutionState.maxLogEntries {
            state.log.removeFirst(state.log.count - ExecutionState.maxLogEntries)
        }
    }

    static func km(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters.rounded())) m"
    }
}
