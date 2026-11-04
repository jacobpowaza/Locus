import Foundation

/// Where executed positions go. The app implements this on top of
/// SpoofSession / LocationEngine; tests record calls.
protocol LocationSink: AnyObject {
    /// Set the simulated location. `speed`/`heading` are informational: the
    /// DVT location-simulation service only accepts a coordinate, so iOS
    /// derives speed/course itself from successive fixes.
    func setSimulatedLocation(_ point: GeoPoint, speed: Double?, heading: Double?) -> Bool
    /// End simulation; the device returns to real GPS.
    func stopSimulation() -> Bool
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
    private(set) var state: ExecutionState
    weak var sink: LocationSink?

    private enum Sent: Equatable { case unknown, stopped, at(GeoPoint) }
    private var sent: Sent = .unknown
    private var lastMonotonic: Double?
    private var sinkFailingSince: Date?

    /// Pause the run if the sink keeps failing this long.
    var sinkFailureGrace: Double = 30
    /// Log a catch-up message when a single tick jumps more than this. Must
    /// exceed the longest planned tick (15 s during waits, see nextWakeDelay)
    /// so ordinary ticks aren't reported as suspensions.
    var catchUpLogThreshold: Double = 20
    /// Mirrors every log line (the app forwards these to the system log).
    var logObserver: ((ExecutionLogEntry) -> Void)?

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
        logObserver: ((ExecutionLogEntry) -> Void)? = nil
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
        ex.lastMonotonic = monotonic
        ex.log(.info, "Started \(trigger == .scheduled ? "scheduled" : "manual") run with \(plan.segments.count) steps.", wallNow)
        ex.advance(wallNow: wallNow, monotonic: monotonic)
        return ex
    }

    // MARK: - Ticking

    /// Normal tick.
    func advance(wallNow: Date, monotonic: Double) {
        let dt = max(0, monotonic - (lastMonotonic ?? monotonic))
        lastMonotonic = monotonic
        guard state.status == .running else {
            state.lastWall = wallNow
            return
        }
        if dt > catchUpLogThreshold {
            log(.info, "Caught up \(DurationText.short(dt)) after Locus was suspended.", wallNow)
        }
        step(dt: dt, wallNow: wallNow)
        state.lastWall = wallNow
        emit(wallNow: wallNow)
    }

    /// After an app restart: replay elapsed wall time without touching the
    /// sink, then pause so the user can review before spoofing resumes.
    func recoverAfterRestart(wallNow: Date, monotonic: Double) {
        lastMonotonic = monotonic
        sent = .unknown
        guard state.status == .running || state.status == .paused else { return }
        let wasRunning = state.status == .running
        let gap = wallNow.timeIntervalSince(state.lastWall)
        if wasRunning {
            // A negative gap means the clock moved backwards; don't rewind.
            step(dt: max(0, gap), wallNow: wallNow)
        }
        state.lastWall = wallNow
        if !state.status.isFinished {
            state.status = .paused
            state.pauseReason = "Locus was closed while this run was \(wasRunning ? "running" : "paused")."
            log(.warning, wasRunning
                ? "Recovered after Locus restarted (\(DurationText.short(max(0, gap))) later). Moved to where the schedule is now and paused."
                : "Recovered paused run after Locus restarted.", wallNow)
        } else {
            log(.info, "Run finished while Locus was closed.", wallNow)
        }
    }

    private func step(dt: Double, wallNow: Date) {
        var remaining = dt
        let segs = state.plan.segments
        while state.index < segs.count, state.status == .running {
            let seg = state.plan.segments[state.index]
            switch seg.kind {
            case .teleport(let place):
                log(.info, "Set location to \(place.name).", wallNow.addingTimeInterval(-remaining))
                enterNext()
            case .setSpeed(let policy):
                state.speedPolicy = policy
                log(.info, "Speed: \(policy.summary(unit: .mph)).", wallNow.addingTimeInterval(-remaining))
                enterNext()
            case .stop:
                log(.info, "Turned off Locus.", wallNow.addingTimeInterval(-remaining))
                enterNext()
            case .hold(let seconds):
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
                if state.announcedIndex != state.index {
                    state.announcedIndex = state.index
                    log(.info, "Driving to \(leg.destination.name) — \(Self.km(leg.profile.distance)), about \(DurationText.short(leg.profile.duration)).", wallNow.addingTimeInterval(-remaining))
                }
                let left = leg.profile.duration - state.elapsedInSegment
                if remaining >= left {
                    remaining -= max(0, left)
                    state.activeElapsed += max(0, left)
                    state.distanceBanked += leg.profile.distance
                    log(.info, "Arrived at \(leg.destination.name).", wallNow.addingTimeInterval(-remaining))
                    enterNext()
                } else {
                    state.elapsedInSegment += remaining
                    state.activeElapsed += remaining
                    remaining = 0
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

    private func enterNext() {
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

    private func emit(wallNow: Date) {
        guard let sink else { return }
        let ok: Bool
        if let d = desiredPosition {
            if case .at(let p) = sent, p == d.point { return }
            ok = sink.setSimulatedLocation(d.point, speed: d.speed, heading: d.heading)
            if ok { sent = .at(d.point) }
        } else {
            if sent == .stopped || sent == .unknown { return }
            ok = sink.stopSimulation()
            if ok { sent = .stopped }
        }
        if ok {
            if sinkFailingSince != nil {
                log(.info, "Spoofing connection restored.", wallNow)
            }
            sinkFailingSince = nil
        } else if let since = sinkFailingSince {
            if wallNow.timeIntervalSince(since) >= sinkFailureGrace {
                pause(reason: "Lost the connection. Check LocalDevVPN, then resume.", wallNow: wallNow)
                sinkFailingSince = nil
            }
        } else {
            sinkFailingSince = wallNow
            log(.warning, "Couldn't update the simulated location; retrying.", wallNow)
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
        log(reason == nil ? .info : .warning, reason.map { "Paused: \($0)" } ?? "Paused.", wallNow)
        // Stand still where we are.
        if let d = desiredPosition, let sink {
            if sink.setSimulatedLocation(d.point, speed: 0, heading: d.heading) { sent = .at(d.point) }
        }
    }

    func resume(wallNow: Date, monotonic: Double) {
        guard state.status == .paused else { return }
        // A paused car restarts from standstill: re-solve the rest of the leg.
        if state.index < state.plan.segments.count,
           case .drive(var leg) = state.plan.segments[state.index].kind,
           state.elapsedInSegment > 0 {
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
        log(.info, "Resumed.", wallNow)
        step(dt: 0, wallNow: wallNow)
        state.lastWall = wallNow
        emit(wallNow: wallNow)
    }

    /// Finish the current step immediately (a drive jumps to its destination).
    func skip(wallNow: Date, monotonic: Double) {
        guard !state.status.isFinished, state.index < state.plan.segments.count else { return }
        let seg = state.plan.segments[state.index]
        if case .drive(let leg) = seg.kind {
            state.distanceBanked += leg.profile.distance
            log(.info, "Skipped drive — jumped to \(leg.destination.name).", wallNow)
        } else {
            log(.info, "Skipped: \(seg.summary).", wallNow)
        }
        enterNext()
        lastMonotonic = monotonic
        if state.status == .running {
            step(dt: 0, wallNow: wallNow)
            emit(wallNow: wallNow)
        } else if let d = desiredPosition, let sink, sink.setSimulatedLocation(d.point, speed: 0, heading: d.heading) {
            sent = .at(d.point)
        }
        state.lastWall = wallNow
    }

    func cancel(stopSpoofing: Bool, wallNow: Date) {
        guard !state.status.isFinished else { return }
        state.status = .cancelled
        state.endedAt = wallNow
        state.pauseReason = nil
        log(.info, stopSpoofing ? "Ended and returned to the real location." : "Ended. Staying at the current simulated location.", wallNow)
        if stopSpoofing, let sink, sink.stopSimulation() { sent = .stopped }
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
    func nextWakeDelay(wallNow: Date) -> Double {
        guard state.status == .running, state.index < state.plan.segments.count else { return 30 }
        switch state.plan.segments[state.index].kind {
        case .drive: return 1
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
            speed: paused ? 0 : (d?.speed ?? 0),
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
            connectionProblem: sinkFailingSince != nil,
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
