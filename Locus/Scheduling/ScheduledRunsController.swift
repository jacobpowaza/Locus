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
    /// The Scheduled Runs sheet is showing (it shows its own error alert).
    @Published var isPresentingRunsUI = false

    /// MPH / km/h preference (defaults from the device region).
    @Published var unit: SpeedUnit {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: Self.unitKey) }
    }
    private static let unitKey = "locus.speedUnit"

    /// Speed and traffic choices for drives started from the map.
    @Published var drivePrefs: DrivePreferences {
        didSet {
            if let data = try? JSONEncoder().encode(drivePrefs) {
                UserDefaults.standard.set(data, forKey: Self.drivePrefsKey)
            }
        }
    }
    private static let drivePrefsKey = "locus.drivePrefs"

    private let coordinator: RunCoordinator
    private let routeProvider: CachingRouteProvider
    private var lastDrive: ScheduledRun?
    var savedRoutes: [ScheduledRun] { runs.filter { $0.isSavedRoute == true } }
    var automations: [ScheduledRun] { runs.filter { $0.isSavedRoute != true && $0.isTemplate != true } }
    var templates: [ScheduledRun] { runs.filter { $0.isTemplate == true } }
    private let notifier = UserNotificationRunNotifier()
    private var sink: SpoofSessionSink?
    private weak var session: SpoofSession?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var attached = false
    private var sessionStatusCancellable: AnyCancellable?
    private var shownStorageProblems = Set<String>()

    /// Plain-language limits shown in the UI and the diagnostics export.
    static let platformNotes: [String] = [
        "Runs execute inside Locus. Locus pushes coordinates to iOS through the developer location-simulation service; nothing runs on Apple's side.",
        "In the foreground, steps run on time.",
        "In the background, runs continue while iOS keeps Locus alive (it holds a background location session while spoofing). This is best effort: iOS may still suspend or end the app.",
        "If Locus is force-quit, crashes, or was ended by iOS, nothing can start or continue a run. With notifications enabled, a reminder can open Locus. The run starts late if it is still within the late-start window, or appears as missed.",
        "If Locus restarts during a run, it restores the last confirmed checkpoint and waits for you to resume.",
        "iOS only receives coordinates from Locus. Apps compute speed and heading themselves from successive positions, so the speed shown here is Locus's simulated speed, not a value iOS reports.",
        "Drives use OpenStreetMap limits where the road matches. Speed offsets apply only to those limits.",
    ]

    init() {
        unit = UserDefaults.standard.string(forKey: Self.unitKey).flatMap(SpeedUnit.init(rawValue:))
            ?? SpeedUnit.defaultFor(regionCode: Locale.current.region?.identifier)
        drivePrefs = UserDefaults.standard.data(forKey: Self.drivePrefsKey)
            .flatMap { try? JSONDecoder().decode(DrivePreferences.self, from: $0) } ?? DrivePreferences()
        let store = ScheduledRunStore(directory: ScheduledRunStore.defaultDirectory())
        let routes = CachingRouteProvider(base: MapKitRouteProvider(), cache: RouteCache(fileURL: store.routeCacheURL))
        routeProvider = routes
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
        sink.onReady = { [weak self] in Task { await self?.tickNow() } }
        coordinator.manualActivity = { [weak session] in session?.manualActivity }
        session.runOwnsLocation = { [weak self] in self?.isBusy == true }
        session.canTakeManualControl = { [weak self] in
            self?.startingRunID == nil && self?.coordinator.executor?.stopRequested != true
        }
        coordinator.currentLocation = { [weak session] in
            guard let session, session.isSpoofing, let sim = session.simulated else { return nil }
            return GeoPoint(sim)
        }
        coordinator.defaultDriveOrigin = { [weak session] in
            session?.realCoordinate.map(GeoPoint.init)
        }
        session.onManualControl = { [weak self] what in
            self?.sink?.invalidateCompletion()
            self?.coordinator.manualOverride(what)
        }
        // When the spoof session reconnects, resend the run's position.
        sessionStatusCancellable = session.$status
            .removeDuplicates()
            .sink { [weak self] status in
                if status.isDropped { self?.coordinator.invalidateConfirmedOutput() }
            }
        coordinator.load()
        observe()
        #if DEBUG
        // Test hook (scripts/ios-sim-smoke.sh): open the Scheduled Runs sheet.
        if ProcessInfo.processInfo.arguments.contains("-LocusShowRuns") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotificationCenter.default.post(name: .locusOpenScheduledRuns, object: nil)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-LocusDemoRun") {
            startDemoRun(near: session.simulated ?? session.realCoordinate)
            return
        }
        #endif
        Task { await tickNow() }
    }

    #if DEBUG
    /// Debug/test hook (launch argument `-LocusDemoRun`): creates and starts a
    /// short run — set location, 10 s wait, ~1 km drive at 20 mph, 10 min wait — and opens
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
                RunAction(.setSpeed(.constant(SpeedUnit.mph.toMetersPerSecond(20)))),
                RunAction(.driveTo(b, speed: nil)),
                // Long enough that the smoke test's restart always lands mid-run,
                // even on slow CI simulators.
                RunAction(.wait(seconds: 600)),
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
        let newProblems = coordinator.storageProblems.filter { shownStorageProblems.insert($0).inserted }
        if !newProblems.isEmpty { errorMessage = newProblems.joined(separator: "\n") }
        func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<ScheduledRunsController, T>, _ value: T) {
            if self[keyPath: kp] != value { self[keyPath: kp] = value }
        }
        set(\.runs, coordinator.runs)
        set(\.history, coordinator.history)
        set(\.startingRunID, coordinator.startingRunID)
        if let finished = coordinator.lastFinished, finished.id != lastFinished?.id, finished.outcome == .completed,
           let drive = lastDrive, drive.id == finished.runID, case .driveTo(let destination, _)? = drive.actions.last?.kind {
            session?.pushNamedRecent(name: destination.name, coordinate: destination.point.coordinate)
        }
        set(\.lastFinished, coordinator.lastFinished)
        set(\.activeRunName, coordinator.executor?.state.runName)
        set(\.activeRunID, coordinator.executor?.state.runID)
        set(\.activePlan, coordinator.executor?.state.plan)
        set(\.snapshot, coordinator.snapshot())
    }

    // MARK: - Editing

    @discardableResult
    func save(_ run: ScheduledRun) -> Bool {
        guard coordinator.upsert(run) else { return false }
        if run.schedule.isAutomatic && run.isEnabled { notifier.requestAuthorization() }
        scheduleTimer()
        return true
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

    /// The active run is a drive started from the map, not a saved run.
    var isOneOffActive: Bool {
        guard let id = activeRunID else { return false }
        return !runs.contains { $0.id == id }
    }

    func start(_ id: UUID) {
        Task {
            if let message = await coordinator.startNow(runID: id) {
                errorMessage = message
            }
            scheduleTimer()
        }
    }

    func routeOptions(from: GeoPoint, to: GeoPoint) async throws -> [RouteResult] {
        do {
            let options = try await RouteBuilder.routes(from: from, to: to, alternatives: true)
            if let first = options.first { routeProvider.cache.store(first, from: from, to: to) }
            return options
        } catch {
            try Task.checkCancellation()
            if var cached = routeProvider.cache.lookup(from: from, to: to) {
                cached.fromCache = true
                return [cached]
            }
            throw error
        }
    }

    var isBusy: Bool { coordinator.isBusy }
    var canReplayDrive: Bool { lastDrive?.id == lastFinished?.runID && lastDrive != nil }

    func startDrive(_ route: ScheduledRun) {
        var run = route
        run.id = UUID()
        lastDrive = run
        startOneOff(run)
    }

    func replayDrive() {
        if let lastDrive { startDrive(lastDrive) }
    }

    func restartDrive() {
        guard isOneOffActive, let lastDrive, lastDrive.id == activeRunID else { return }
        guard session?.isBusy == false else { return }
        coordinator.cancel(stopSpoofing: false)
        sink?.invalidateCompletion()
        startDrive(lastDrive)
    }

    var driveEndDestination: PlaceRef? {
        if isOneOffActive, let activePlan {
            if let lastDrive, lastDrive.id == activeRunID,
               case .driveTo(let destination, _)? = lastDrive.actions.last?.kind { return destination }
            for segment in activePlan.segments.reversed() {
                if case .drive(let leg) = segment.kind { return leg.destination }
            }
        }
        if case .drive(let leg)? = snapshot?.segment?.kind { return leg.destination }
        return nil
    }

    func endDrive(at destination: PlaceRef, driving: Bool, replacing id: UUID) async -> String? {
        guard let active = liveSnapshot(), activeRunID == id, driveEndDestination != nil,
              startingRunID == nil, !active.isClearingLocation else { return "This drive has already changed." }
        coordinator.pause()
        defer { scheduleTimer() }

        if driving { await sink?.waitForDelivery() }
        let origin = session?.simulated.map(GeoPoint.init)
        let isReturnDrive = driving && origin.map { Geo.distance($0, destination.point) >= RunCompiler.arrivalTolerance } == true
        var motion = drivePrefs.motion
        var speed = active.speedPolicy
        if case .drive(let leg)? = active.segment?.kind {
            motion = leg.profile.motion
            speed = leg.profile.policy
        }
        let run: ScheduledRun
        if isReturnDrive, let origin {
            run = ScheduledRun(name: "Drive to \(destination.name)",
                               actions: [
                                   RunAction(.setLocation(PlaceRef(name: "Return start", point: origin))),
                                   RunAction(.driveTo(destination, speed: nil)),
                               ],
                               defaultSpeed: speed, motion: motion)
        } else {
            run = ScheduledRun(name: "Arrive at \(destination.name)", actions: [RunAction(.setLocation(destination))])
        }
        if driving && origin == nil {
            if active.status == .running, activeRunID == id { coordinator.resume() }
            return "Locus needs a confirmed simulated location to drive back."
        }
        if let message = await coordinator.replaceDrive(run, replacing: id) {
            if active.status == .running, activeRunID == id, coordinator.executor?.stopRequested == false {
                coordinator.resume()
            }
            return message
        }
        if isReturnDrive { lastDrive = run }
        return nil
    }

    func startOneOff(_ run: ScheduledRun) {
        Task {
            if let message = await coordinator.startOneOff(run) {
                errorMessage = message
            } else {
                NotificationCenter.default.post(name: .locusOpenActiveRun, object: nil)
            }
            scheduleTimer()
        }
    }

    /// Ends any run and returns the iPhone to its real location.
    func turnOffLocus(session: SpoofSession, pairing: PairingStore) {
        if isActive {
            coordinator.cancel(stopSpoofing: true)
            scheduleTimer()
        } else if startingRunID == nil, session.needsClear || session.isSpoofing {
            Task { await session.stop(pairing: pairing) }
        }
    }

    func pause() { coordinator.pause(); scheduleTimer() }
    func resume() {
        if session?.joystickActive == true || session?.followingRouteTo != nil {
            errorMessage = "Turn off manual movement before resuming the run."
            return
        }
        coordinator.resume()
        scheduleTimer()
    }
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
        if let s = session {
            notes.append("Connection: \(s.status.label) · path: \(s.networkDescription)")
            notes.append("Core Location fix: \(s.coreLocationFixSummary)")
            if let detail = s.connectionDetail { notes.append("Last failure: \(detail)") }
        }
        notes.append(TunnelConfig.embeddedProvider ? "Packet tunnel provider is bundled; inspect signature for entitlement." : "No embedded packet tunnel provider. Uses an external helper.")
        #if targetEnvironment(simulator)
        notes.append("Running in the iOS Simulator: location spoofing is stubbed (no device tunnel).")
        #endif
        return notes
    }
}

/// Remembered choices for map drives.
struct DrivePreferences: Codable, Equatable {
    var speed: SpeedPolicy = .followLimit
    var realism: DriveRealism = .off
    var settings: MotionSettings? = nil

    var motion: MotionSettings {
        var motion = settings ?? .standard
        motion.realism = realism
        return motion
    }
}
