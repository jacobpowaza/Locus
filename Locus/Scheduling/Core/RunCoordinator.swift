import Foundation

/// Wall + monotonic time source (injectable for tests).
protocol RunClock: AnyObject {
    var now: Date { get }
    /// Seconds on a clock that never jumps (includes device sleep on Darwin).
    var monotonic: Double { get }
}

final class SystemRunClock: RunClock {
    private let origin = ContinuousClock.now
    var now: Date { Date() }
    var monotonic: Double {
        let d = ContinuousClock.now - origin
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Local notifications. The app implements this with UNUserNotificationCenter.
protocol RunNotifier: AnyObject {
    /// "Run X couldn't start — open Locus" at `date`. Replaces any pending
    /// reminder for the same run. Fires only if Locus doesn't start the run
    /// first (it cancels/reschedules the reminder when it does).
    func scheduleStartReminder(runID: UUID, runName: String, at date: Date)
    func cancelStartReminder(runID: UUID)
    func post(title: String, body: String)
}

struct RunPreview {
    var startDate: Date
    var issues: [RunIssue]
    var plan: RunPlan?
    var projected: [ProjectedSegment]
    var estimatedDuration: Double?
    var error: String?
    var errorActionID: UUID?
    var overlaps: [RunScheduler.Overlap]

    var canRun: Bool { plan != nil && error == nil }
}

/// Orchestrates Scheduled Runs: persistence, schedule evaluation, compile,
/// execution, restart recovery, history, and reminders.
///
/// Platform-free so the full lifecycle is integration-tested with fake
/// clock / routing / location sink. `ScheduledRunsController` (app) wraps it
/// for SwiftUI and drives `tick()` from a timer.
@MainActor
final class RunCoordinator {
    private(set) var runs: [ScheduledRun] = []
    private(set) var history: [RunRecord] = []
    private(set) var executor: RunExecutor?
    /// Run being compiled (routing) before it starts.
    private(set) var startingRunID: UUID?
    /// Most recently finished record, for a "Run complete" card.
    private(set) var lastFinished: RunRecord?

    var onChange: (@MainActor () -> Void)?
    /// Receives every run log line (app → system log for diagnostics).
    var logObserver: ((ExecutionLogEntry) -> Void)?
    /// What Locus is spoofing right now (for runs that don't begin with Set Location).
    var currentLocation: @MainActor () -> GeoPoint? = { nil }

    let store: ScheduledRunStore
    let routeProvider: RouteProvider
    let clock: RunClock
    weak var sink: LocationSink?
    weak var notifier: RunNotifier?
    var manualActivity: (() -> String?)?
    private let manualActivityID = UUID()
    private var notifiedStartID: UUID?

    /// How long after a missed start the reminder notification fires.
    static let reminderDelay: Double = 60
    private var lastCheckpointWall: Date = .distantPast
    private var lastCheckpointKey: String = ""

    init(store: ScheduledRunStore, routeProvider: RouteProvider, clock: RunClock, sink: LocationSink?, notifier: RunNotifier?) {
        self.store = store
        self.routeProvider = routeProvider
        self.clock = clock
        self.sink = sink
        self.notifier = notifier
    }

    var storageProblems: [String] { store.problems }

    // MARK: - Lifecycle

    /// Load persisted state and recover an interrupted run.
    func load() {
        runs = store.loadRuns()
        history = store.loadHistory()
        if let state = store.loadCheckpoint() {
            let ex = RunExecutor(state: state, sink: sink)
            ex.logObserver = logObserver
            if state.startConfirmed == true { notifiedStartID = state.recordID }
            ex.recoverAfterRestart(wallNow: clock.now, monotonic: clock.monotonic)
            if ex.state.status.isFinished {
                finish(ex)
            } else {
                executor = ex
                checkpoint(force: true)
            }
        }
        refreshReminders()
        changed()
    }

    // MARK: - Editing

    func run(id: UUID) -> ScheduledRun? { runs.first { $0.id == id } }

    func upsert(_ run: ScheduledRun) {
        var r = run
        let now = clock.now
        r.updatedAt = now
        if let i = runs.firstIndex(where: { $0.id == run.id }) {
            // Changing the schedule shouldn't immediately fire occurrences
            // that already passed under the new settings.
            if runs[i].schedule != r.schedule || (!runs[i].isEnabled && r.isEnabled) {
                r.lastHandledOccurrence = now
            }
            runs[i] = r
        } else {
            r.lastHandledOccurrence = r.lastHandledOccurrence ?? now
            runs.append(r)
        }
        persistRuns()
        refreshReminders()
        changed()
    }

    func delete(id: UUID) {
        if executor?.state.runID == id {
            cancel(stopSpoofing: false)
        }
        runs.removeAll { $0.id == id }
        notifier?.cancelStartReminder(runID: id)
        persistRuns()
        changed()
    }

    @discardableResult
    func duplicate(id: UUID) -> ScheduledRun? {
        guard let original = run(id: id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " Copy"
        copy.actions = original.actions.map { $0.duplicated() }
        if let preferredRoutes = original.preferredRoutes {
            copy.preferredRoutes = Dictionary(uniqueKeysWithValues: zip(original.actions, copy.actions).compactMap { old, new in
                preferredRoutes[old.id].map { (new.id, $0) }
            })
        }
        copy.isEnabled = false
        copy.createdAt = clock.now
        copy.lastHandledOccurrence = clock.now
        upsert(copy)
        return copy
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard var r = run(id: id) else { return }
        r.isEnabled = enabled
        upsert(r)
    }

    func clearHistory() {
        history.removeAll()
        lastFinished = nil
        store.saveHistory(history)
        changed()
    }

    // MARK: - Preview

    /// Validates, routes, and times a run without executing it.
    func preview(_ run: ScheduledRun) async -> RunPreview {
        let now = clock.now
        let start: Date
        switch run.schedule {
        case .manual: start = now
        case .once(let d): start = max(d, now)
        case .recurring:
            start = RunScheduler.nextOccurrence(of: run.schedule, after: now, timeZone: run.timeZone) ?? now
        }
        func overlapIssues(_ overlaps: [RunScheduler.Overlap]) -> [RunIssue] {
            overlaps.prefix(3).map {
                .warning("Overlaps \"\($0.otherName)\" around \(DurationText.clock($0.at, timeZone: run.timeZone)). Only one run can control the location at a time; the later one will be skipped.")
            }
        }
        let issues = RunValidator.validate(run, now: now)
        guard !issues.hasErrors else {
            let overlaps = RunScheduler.overlaps(of: run, with: runs, now: now)
            return RunPreview(startDate: start, issues: issues + overlapIssues(overlaps), plan: nil, projected: [], estimatedDuration: nil, error: nil, errorActionID: nil, overlaps: overlaps)
        }
        let compiler = RunCompiler(routeProvider: routeProvider)
        do {
            let result = try await compiler.compile(run, anchorDate: start, startDate: start, currentLocation: currentLocation())
            // Overlaps need this run's real duration, so check after compiling.
            var timed = run
            timed.estimatedDuration = result.estimatedDuration
            let overlaps = RunScheduler.overlaps(of: timed, with: runs, now: now)
            if let i = runs.firstIndex(where: { $0.id == run.id }) {
                runs[i].estimatedDuration = result.estimatedDuration
                persistRuns()
            }
            return RunPreview(
                startDate: start,
                issues: Self.dedupe(result.issues + overlapIssues(overlaps)),
                plan: result.plan,
                projected: result.plan.project(now: start),
                estimatedDuration: result.estimatedDuration,
                error: nil,
                errorActionID: nil,
                overlaps: overlaps
            )
        } catch {
            let ce = error as? CompileError
            let overlaps = RunScheduler.overlaps(of: run, with: runs, now: now)
            return RunPreview(
                startDate: start,
                issues: issues + overlapIssues(overlaps),
                plan: nil,
                projected: [],
                estimatedDuration: nil,
                error: ce?.errorDescription ?? error.localizedDescription,
                errorActionID: ce?.actionID,
                overlaps: overlaps
            )
        }
    }

    private static func dedupe(_ issues: [RunIssue]) -> [RunIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Execution

    var isBusy: Bool { (executor.map { !$0.state.status.isFinished } ?? false) || startingRunID != nil }

    /// Start a run immediately. Returns an error message on failure.
    @discardableResult
    func startNow(runID: UUID) async -> String? {
        guard let run = run(id: runID) else { return "This run no longer exists." }
        if let active = executor, !active.state.status.isFinished {
            return "\"\(active.state.runName)\" is already running. Cancel it first."
        }
        if startingRunID != nil { return "Another run is starting." }
        return await begin(run, trigger: .manual, occurrence: nil)
    }

    /// Start a one-off run that isn't saved in the runs list (e.g. a drive
    /// started from the map). It still shows in history.
    @discardableResult
    func startOneOff(_ run: ScheduledRun) async -> String? {
        if let active = executor, !active.state.status.isFinished {
            return "\"\(active.state.runName)\" is already running. End it first."
        }
        if startingRunID != nil { return "Another run is starting." }
        return await begin(run, trigger: .manual, occurrence: nil)
    }

    private func begin(_ run: ScheduledRun, trigger: RunTrigger, occurrence: Date?) async -> String? {
        if let manual = manualActivity?() { return "Finish \(manual.lowercased()) before starting a run." }
        startingRunID = run.id
        changed()
        defer {
            startingRunID = nil
            changed()
        }
        let now = clock.now
        let anchor = occurrence ?? now
        let compiler = RunCompiler(routeProvider: routeProvider)
        do {
            let result = try await compiler.compile(run, anchorDate: anchor, startDate: clock.now, currentLocation: currentLocation())
            let ex = RunExecutor.start(
                plan: result.plan,
                run: run,
                trigger: trigger,
                occurrence: occurrence,
                wallNow: clock.now,
                monotonic: clock.monotonic,
                sink: sink,
                logObserver: logObserver
            )
            for issue in result.issues where issue.severity == .warning {
                ex.noteWarning(issue.message, wallNow: clock.now)
            }
            if let i = runs.firstIndex(where: { $0.id == run.id }) {
                runs[i].estimatedDuration = result.estimatedDuration
                persistRuns()
            }
            executor = ex
            notifyStart(ex)
            if ex.state.status.isFinished {
                finish(ex)
            } else {
                checkpoint(force: true)
            }
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            let record = RunRecord(
                runID: run.id, runName: run.name, trigger: trigger, occurrence: occurrence,
                outcome: .failed, startedAt: now, endedAt: clock.now, message: message,
                log: [ExecutionLogEntry(date: clock.now, level: .error, message: message)]
            )
            appendHistory(record)
            if trigger == .scheduled {
                notifier?.post(title: "\(run.name) couldn't start", body: message)
            }
            return message
        }
    }

    /// Advance the active run and start any runs that have come due.
    /// Call from a timer; `nextWakeDelay` says when.
    func tick() async {
        let now = clock.now
        if let ex = executor {
            ex.advance(wallNow: now, monotonic: clock.monotonic)
            notifyStart(ex)
            if ex.state.status.isFinished {
                finish(ex)
            } else {
                checkpoint(force: false)
            }
        }
        await evaluateSchedules()
        changed()
    }

    private func evaluateSchedules() async {
        guard startingRunID == nil else { return }
        let now = clock.now
        let active = executor.flatMap { $0.state.status.isFinished ? nil : (id: $0.state.runID, name: $0.state.runName) }
            ?? manualActivity?().map { (id: manualActivityID, name: $0) }
        let decisions = RunScheduler.evaluate(runs: runs, now: now, activeRun: active)
        guard !decisions.isEmpty else { return }

        var toStart: (ScheduledRun, Date)?
        for d in decisions {
            guard let i = runs.firstIndex(where: { $0.id == d.runID }) else { continue }
            runs[i].lastHandledOccurrence = max(runs[i].lastHandledOccurrence ?? .distantPast, d.occurrence)
            switch d {
            case .start(_, let occ, _):
                toStart = (runs[i], occ)
            case .missed(_, let occ, let reason):
                let message: String
                switch reason {
                case .tooLate(let by):
                    message = "Locus wasn't running at the start time (\(DurationText.short(by)) ago), beyond the \(DurationText.short(runs[i].latePolicy.maxDelay)) late-start window."
                case .conflict(let other):
                    message = "Skipped because \"\(other)\" was running."
                }
                notifier?.post(title: "\(runs[i].name) missed", body: message)
                appendHistory(RunRecord(
                    runID: runs[i].id, runName: runs[i].name, trigger: .scheduled, occurrence: occ,
                    outcome: .missed, startedAt: nil, endedAt: now, message: message
                ))
            }
        }
        persistRuns()
        refreshReminders()
        if let (run, occ) = toStart {
            _ = await begin(run, trigger: .scheduled, occurrence: occ)
            refreshReminders()
        }
    }

    private func notifyStart(_ ex: RunExecutor) {
        guard ex.state.trigger == .scheduled, ex.state.startConfirmed == true, notifiedStartID != ex.state.recordID else { return }
        notifiedStartID = ex.state.recordID
        notifier?.post(title: "\(ex.state.runName) started", body: "Open Locus to follow the run.")
    }

    private func finish(_ ex: RunExecutor) {
        let record = RunRecord(finished: ex.state, endedAt: clock.now)
        appendHistory(record)
        lastFinished = record
        executor = nil
        store.saveCheckpoint(nil)
        if ex.state.trigger == .scheduled, record.outcome == .failed || record.outcome == .completed {
            notifier?.post(title: "\(record.runName) \(record.outcome == .completed ? "completed" : "failed")",
                           body: record.message ?? "Open Locus to see the run history.")
        }
    }

    func dismissLastFinished() {
        lastFinished = nil
        changed()
    }

    // MARK: - Controls

    func pause(reason: String? = nil) {
        executor?.pause(reason: reason, wallNow: clock.now)
        checkpoint(force: true)
        changed()
    }

    func resume() {
        executor?.resume(wallNow: clock.now, monotonic: clock.monotonic)
        if let ex = executor, ex.state.status.isFinished { finish(ex) } else { checkpoint(force: true) }
        changed()
    }

    func skip() {
        executor?.skip(wallNow: clock.now, monotonic: clock.monotonic)
        if let ex = executor, ex.state.status.isFinished { finish(ex) } else { checkpoint(force: true) }
        changed()
    }

    func cancel(stopSpoofing: Bool) {
        guard let ex = executor else { return }
        ex.cancel(stopSpoofing: stopSpoofing, wallNow: clock.now)
        if ex.state.status.isFinished { finish(ex) } else { checkpoint(force: true) }
        changed()
    }

    func changeSpeed(_ policy: SpeedPolicy) {
        executor?.changeSpeed(to: policy, wallNow: clock.now)
        checkpoint(force: true)
        changed()
    }

    /// The user moved the location by hand (teleport, joystick, stop…).
    func manualOverride(_ what: String) {
        guard let ex = executor, ex.state.status == .running else { return }
        pause(reason: "You took manual control (\(what)). Resume to continue the run.")
    }

    /// Wall clock / time zone changed (UIApplication.significantTimeChange).
    func handleClockChange() {
        executor?.noteWarning("Device time or time zone changed; Wait Until times use the new clock.", wallNow: clock.now)
        refreshReminders()
        changed()
    }

    /// Spoofing session reconnected; re-send the current position.
    func invalidateConfirmedOutput() {
        executor?.invalidateSentPosition()
    }

    func snapshot() -> ExecutionSnapshot? { executor?.snapshot(wallNow: clock.now) }

    /// Seconds until `tick()` is next needed.
    func nextWakeDelay() -> Double {
        let now = clock.now
        var delay = executor?.nextWakeDelay(wallNow: now) ?? 60
        if let next = RunScheduler.nextWake(runs: runs, now: now) {
            delay = min(delay, max(0.25, next.date.timeIntervalSince(now)))
        }
        return max(0.25, min(delay, 60))
    }

    // MARK: - Reminders

    /// Schedule one "couldn't start" reminder per enabled run at its next
    /// occurrence + `reminderDelay`. When Locus is alive it starts the run
    /// and reschedules, so the reminder only shows when Locus wasn't running.
    func refreshReminders() {
        guard let notifier else { return }
        let now = clock.now
        for run in runs {
            guard run.isEnabled, run.schedule.isAutomatic,
                  let next = RunScheduler.nextOccurrence(
                    of: run.schedule,
                    after: max(now.addingTimeInterval(-Self.reminderDelay), run.lastHandledOccurrence ?? .distantPast),
                    timeZone: run.timeZone
                  ) else {
                notifier.cancelStartReminder(runID: run.id)
                continue
            }
            notifier.scheduleStartReminder(runID: run.id, runName: run.name, at: next.addingTimeInterval(Self.reminderDelay))
        }
    }

    // MARK: - Diagnostics

    func diagnosticsReport(platformNotes: [String]) -> String {
        let f = ISO8601DateFormatter()
        let now = clock.now
        var lines = ["Locus Scheduled Runs diagnostics — \(f.string(from: now))", ""]
        lines.append("Runs (\(runs.count)):")
        for r in runs {
            let next = RunScheduler.nextOccurrence(of: r.schedule, after: now, timeZone: r.timeZone).map { f.string(from: $0) } ?? "—"
            lines.append("  • \(r.name) enabled=\(r.isEnabled) steps=\(r.actions.count) next=\(next) tz=\(r.timeZone.identifier)")
        }
        if let s = snapshot(), let ex = executor {
            lines.append("")
            lines.append("Active: \(ex.state.runName) status=\(s.status.rawValue) step=\(s.segmentIndex + 1)/\(s.segmentCount) reason=\(s.pauseReason ?? "-")")
        }
        if !store.problems.isEmpty {
            lines.append("")
            lines.append("Storage problems:")
            lines.append(contentsOf: store.problems.map { "  ! \($0)" })
        }
        if !platformNotes.isEmpty {
            lines.append("")
            lines.append("Platform:")
            lines.append(contentsOf: platformNotes.map { "  \($0)" })
        }
        lines.append("")
        lines.append("History (latest \(min(10, history.count))):")
        for r in history.prefix(10) {
            lines.append("")
            lines.append(r.diagnosticsText())
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence helpers

    private func appendHistory(_ record: RunRecord) {
        history.insert(record, at: 0)
        if history.count > ScheduledRunStore.maxHistory { history.removeLast(history.count - ScheduledRunStore.maxHistory) }
        store.saveHistory(history)
    }

    private func persistRuns() { store.saveRuns(runs) }

    private func checkpoint(force: Bool) {
        guard let ex = executor else { return }
        let key = "\(ex.state.index)|\(ex.state.status.rawValue)"
        let now = clock.now
        if force || key != lastCheckpointKey || now.timeIntervalSince(lastCheckpointWall) >= 15 {
            store.saveCheckpoint(ex.state)
            lastCheckpointKey = key
            lastCheckpointWall = now
        }
    }

    private func changed() { onChange?() }
}

extension RunExecutor {
    /// Adds a warning line to the run log (compile warnings, clock changes).
    func noteWarning(_ message: String, wallNow: Date) {
        appendLog(.warning, message, wallNow)
    }
}
