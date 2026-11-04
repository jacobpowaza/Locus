import Combine
import CoreLocation
import Foundation
import SwiftUI
import UIKit

/// SwiftUI-facing owner of the Scheduled Runs engine.
///
/// Wraps `RunCoordinator` (platform-free, unit-tested) and drives its `tick()`
/// from a main-run-loop timer at the cadence the engine asks for: ~1 s while a
/// drive is moving, ≤ 15 s while holding, ≤ 60 s while idle.
@MainActor
final class ScheduledRunsController: ObservableObject {
    @Published private(set) var runs: [ScheduledRun] = []
    @Published private(set) var history: [RunRecord] = []
    @Published private(set) var snapshot: ExecutionSnapshot?
    @Published private(set) var activePlan: RunPlan?
    @Published private(set) var activeRunName: String?
    @Published private(set) var activeRunID: UUID?
    @Published private(set) var startingRunID: UUID?
    @Published private(set) var lastFinished: RunRecord?
    @Published var errorMessage: String?

    /// MPH / km/h preference (defaults from the device region).
    @Published var unit: SpeedUnit {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: Self.unitKey) }
    }
    private static let unitKey = "locus.speedUnit"

    private let coordinator: RunCoordinator
    private let notifier = UserNotificationRunNotifier()
    private var sink: SpoofSessionSink?
    private weak var session: SpoofSession?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var attached = false
    private var sessionStatusCancellable: AnyCancellable?

    /// Plain-language limits shown in the UI and the diagnostics export.
    static let platformNotes: [String] = [
        "Runs execute inside Locus. Locus pushes coordinates to iOS through the developer location-simulation service; nothing runs on Apple's side.",
        "In the foreground, steps run on time.",
        "In the background, runs continue while iOS keeps Locus alive (it holds a background location session while spoofing). This is best effort: iOS may still suspend or end the app.",
        "If Locus is force-quit, crashes, or was ended by iOS, nothing can start or continue a run. You'll get a notification about a minute after the start time; open Locus and it starts late if within the run's late-start window.",
        "If Locus restarts during a run, the run resumes paused at the position the schedule says it should be.",
        "iOS only receives coordinates from Locus. Apps compute speed and heading themselves from successive positions, so the speed shown here is Locus's simulated speed, not a value iOS reports.",
        "Apple Maps doesn't provide posted speed limits. \"Follow speed limit\" uses Apple's estimated route-average speed and is labelled \"Estimated\".",
    ]

    init() {
        unit = UserDefaults.standard.string(forKey: Self.unitKey).flatMap(SpeedUnit.init(rawValue:))
            ?? SpeedUnit.defaultFor(regionCode: Locale.current.region?.identifier)
        let store = ScheduledRunStore(directory: ScheduledRunStore.defaultDirectory())
        let routes = CachingRouteProvider(base: MapKitRouteProvider(), cache: RouteCache(fileURL: store.routeCacheURL))
        coordinator = RunCoordinator(store: store, routeProvider: routes, clock: SystemRunClock(), sink: nil, notifier: notifier)
        coordinator.onChange = { [weak self] in self?.publish() }
        coordinator.logObserver = { entry in
            NSLog("[Locus][Run][%@] %@", entry.level.rawValue, entry.message)
        }
    }

    /// Connect to the app's spoof session. Safe to call more than once.
    func attach(session: SpoofSession, pairing: PairingStore) {
        guard !attached else { return }
        attached = true
        self.session = session
        let sink = SpoofSessionSink(session: session, pairing: pairing)
        self.sink = sink
        coordinator.sink = sink
        coordinator.currentLocation = { [weak session] in
            guard let session, session.isSpoofing, let sim = session.simulated else { return nil }
            return GeoPoint(sim)
        }
        session.onManualControl = { [weak self] what in
            self?.coordinator.manualOverride(what)
        }
        // When the spoof session reconnects, resend the run's position.
        sessionStatusCancellable = session.$status
            .removeDuplicates()
            .sink { [weak self] status in
                if case .active = status { self?.coordinator.spoofingReconnected() }
            }
        coordinator.load()
        observe()
        if !coordinator.storageProblems.isEmpty {
            errorMessage = coordinator.storageProblems.joined(separator: "\n")
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-LocusDemoRun") {
            startDemoRun(near: session.simulated ?? session.realCoordinate)
            return
        }
        #endif
        Task { await tickNow() }
    }

    #if DEBUG
    /// Debug/test hook (launch argument `-LocusDemoRun`): creates and starts a
    /// short run — set location, 10 s wait, ~1 km drive, 10 s wait — and opens
    /// the live dashboard. Used by scripts/ios-sim-smoke.sh.
    private func startDemoRun(near coordinate: CLLocationCoordinate2D?) {
        let origin = coordinate.map(GeoPoint.init) ?? GeoPoint(latitude: 37.3349, longitude: -122.0090)
        let a = PlaceRef(name: "Demo Start", point: origin)
        let b = PlaceRef(name: "Demo End", point: GeoPoint(latitude: origin.latitude + 0.006, longitude: origin.longitude + 0.004))
        let run = ScheduledRun(
            name: "Demo Run",
            actions: [
                RunAction(.setLocation(a)),
                RunAction(.wait(seconds: 10)),
                RunAction(.setSpeed(.constant(SpeedUnit.mph.toMetersPerSecond(45)))),
                RunAction(.driveTo(b, speed: nil)),
                RunAction(.wait(seconds: 10)),
            ],
            tint: 1
        )
        coordinator.upsert(run)
        Task {
            if let message = await coordinator.startNow(runID: run.id) {
                NSLog("[Locus][Run][error] demo failed to start: %@", message)
            }
            NotificationCenter.default.post(name: .locusOpenActiveRun, object: nil)
            await tickNow()
        }
    }
    #endif

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.handleClockChange()
                await self?.tickNow()
            }
        })
        observers.append(nc.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.handleClockChange()
                await self?.tickNow()
            }
        })
    }

    func sceneBecameActive() {
        Task { await tickNow() }
    }

    // MARK: - Timer

    private func tickNow() async {
        await coordinator.tick()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let delay = coordinator.nextWakeDelay()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.tickNow() }
        }
        t.tolerance = min(0.2, delay * 0.1)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Copies engine state into @Published properties, assigning only what
    /// changed so a 1 Hz tick doesn't redraw route polylines every second.
    private func publish() {
        func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<ScheduledRunsController, T>, _ value: T) {
            if self[keyPath: kp] != value { self[keyPath: kp] = value }
        }
        set(\.runs, coordinator.runs)
        set(\.history, coordinator.history)
        set(\.startingRunID, coordinator.startingRunID)
        set(\.lastFinished, coordinator.lastFinished)
        set(\.activeRunName, coordinator.executor?.state.runName)
        set(\.activeRunID, coordinator.executor?.state.runID)
        set(\.activePlan, coordinator.executor?.state.plan)
        set(\.snapshot, coordinator.snapshot())
    }

    // MARK: - Editing

    func save(_ run: ScheduledRun) {
        coordinator.upsert(run)
        if run.schedule.isAutomatic && run.isEnabled { notifier.requestAuthorization() }
        scheduleTimer()
    }

    func delete(_ id: UUID) { coordinator.delete(id: id) }
    func duplicate(_ id: UUID) { coordinator.duplicate(id: id) }
    func setEnabled(_ enabled: Bool, id: UUID) {
        coordinator.setEnabled(enabled, id: id)
        if enabled { notifier.requestAuthorization() }
        scheduleTimer()
    }
    func clearHistory() { coordinator.clearHistory() }
    func run(id: UUID) -> ScheduledRun? { coordinator.run(id: id) }

    func preview(_ run: ScheduledRun) async -> RunPreview {
        await coordinator.preview(run)
    }

    func nextOccurrence(of run: ScheduledRun) -> Date? {
        guard run.isEnabled else { return nil }
        let after = max(Date(), run.lastHandledOccurrence ?? .distantPast)
        return RunScheduler.nextOccurrence(of: run.schedule, after: after, timeZone: run.timeZone)
    }

    // MARK: - Execution

    var isActive: Bool { snapshot.map { !$0.status.isFinished } ?? false }

    func start(_ id: UUID) {
        Task {
            if let message = await coordinator.startNow(runID: id) {
                errorMessage = message
            }
            scheduleTimer()
        }
    }

    func pause() { coordinator.pause(); scheduleTimer() }
    func resume() { coordinator.resume(); scheduleTimer() }
    func skip() { coordinator.skip(); scheduleTimer() }
    func cancel(stopSpoofing: Bool) { coordinator.cancel(stopSpoofing: stopSpoofing); scheduleTimer() }
    func changeSpeed(_ policy: SpeedPolicy) { coordinator.changeSpeed(policy); scheduleTimer() }
    func dismissLastFinished() { coordinator.dismissLastFinished() }

    /// Fresh snapshot for TimelineView-driven UI between engine ticks.
    func liveSnapshot() -> ExecutionSnapshot? { coordinator.snapshot() }

    func diagnosticsReport() -> String {
        coordinator.diagnosticsReport(platformNotes: Self.platformNotes + deviceNotes())
    }

    private func deviceNotes() -> [String] {
        let device = UIDevice.current
        var notes = ["Device: \(device.model) iOS \(device.systemVersion)"]
        notes.append("Background refresh: \(UIApplication.shared.backgroundRefreshStatus == .available ? "available" : "restricted/denied")")
        notes.append("Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")")
        if let s = session { notes.append("Spoof status: \(s.status.label)") }
        #if targetEnvironment(simulator)
        notes.append("Running in the iOS Simulator: location spoofing is stubbed (no device tunnel).")
        #endif
        return notes
    }
}
