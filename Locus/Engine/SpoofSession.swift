import CoreLocation
import Foundation
import MapKit
import Network
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .connecting: return "Connecting"
        case .active: return "Active"
        case .reconnecting: return "Reconnecting"
        case .dropped: return "Connection Failed"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = UserDefaults.standard.integer(forKey: "locus.mapStyle") {
        didSet { UserDefaults.standard.set(mapStyleIndex, forKey: "locus.mapStyle") }
    }
    @Published var lastError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var realCoordinate: CLLocationCoordinate2D?
    @Published private(set) var networkDescription = "Checking"
    @Published private(set) var connectionDetail: String?
    private(set) var needsClear = UserDefaults.standard.bool(forKey: "locus.simulationNeedsClear") {
        didSet {
            if oldValue != needsClear { UserDefaults.standard.set(needsClear, forKey: "locus.simulationNeedsClear") }
        }
    }
    private let pathMonitor = NWPathMonitor()
    private var cellularOnly = false
    private var retryAfter: Date = .distantPast
    var runOwnsLocation: (() -> Bool)?
    var canTakeManualControl: (() -> Bool)?
    var manualActivity: String? {
        if joystickActive { return "Joystick" }
        if followingRouteTo != nil { return "Manual route" }
        if isBusy { return "Location update" }
        return nil
    }
    @Published var joystickActive = false
    /// Friendly name of where we're simulating (search result, favorite…).
    @Published var simulatedName: String?
    /// Walking a route started from the map.
    @Published private(set) var followingRouteTo: String?

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []
    @Published private(set) var shortcuts: [PlaceShortcut: SavedPlace] = [:]

    private var resendTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()

    /// Called when the user moves/stops the location by hand, so an active
    /// Scheduled Run can pause instead of fighting the user.
    var onManualControl: (@MainActor (String) -> Void)?

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"

    init() {
        if needsClear { status = .dropped("Previous simulation may still be active.") }
        locationKeeper.acceptsActualFixes = !needsClear
        locationKeeper.onActualLocation = { [weak self] in self?.realCoordinate = $0 }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            let cellular = path.usesInterfaceType(.cellular)
            let text = wifi ? "Wi‑Fi" : (cellular ? "Cellular" : (path.status == .satisfied ? "Other" : "Unavailable"))
            Task { @MainActor in
                self?.cellularOnly = cellular && !wifi
                self?.networkDescription = text
                self?.retryAfter = .distantPast
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.chrismack.locus.path"))
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
        for shortcut in PlaceShortcut.allCases {
            shortcuts[shortcut] = SavedPlace.load(key: shortcut.key).first
                ?? favorites.first { $0.name.caseInsensitiveCompare(shortcut.rawValue) == .orderedSame }
        }
    }

    func setShortcut(_ shortcut: PlaceShortcut, place: MapPlace) {
        let value = SavedPlace(name: place.name, latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        shortcuts[shortcut] = value
        SavedPlace.save([value], key: shortcut.key)
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D, name: String? = nil, pairing: PairingStore) async -> Bool {
        guard canControlManually(), checkPairing(pairing) else { return false }
        onManualControl?("teleport")
        cancelRoute()
        if joystickActive { stopJoystick() }
        pin = coordinate
        guard await apply(coordinate, pairing: pairing, markRecent: name == nil) else { return false }
        simulatedName = name
        if let name { pushNamedRecent(name: name, coordinate: coordinate) }
        return true
    }

    private func canControlManually() -> Bool {
        if isBusy || canTakeManualControl?() == false {
            lastError = "A location update is in progress. Try again in a moment."
            return false
        }
        return true
    }

    private func checkPairing(_ pairing: PairingStore, showError: Bool = true) -> Bool {
        #if !targetEnvironment(simulator)
        guard pairing.hasPairingFile else {
            if showError { lastError = Self.notPairedMessage }
            return false
        }
        #endif
        return true
    }

    static let notPairedMessage = "Locus isn't connected to this iPhone yet. Open Settings › Connection to finish setup."

    private func cancelRoute() {
        routeTask?.cancel()
        routeTask = nil
        followingRouteTo = nil
    }

    @discardableResult
    func stop(pairing: PairingStore) async -> Bool {
        onManualControl?("stop")
        return await performStop(pairing: pairing)
    }

    private func performStop(pairing: PairingStore) async -> Bool {
        guard !isBusy else { return false }
        cancelRoute()
        stopJoystick()
        stopResend()
        guard needsClear || simulated != nil else {
            status = .idle
            return true
        }
        isBusy = true
        let result = await LocationEngine.clear(pairingPath: pairing.pairingPath, deviceIP: TunnelConfig.targetIP)
        isBusy = false
        endBackground()
        locationKeeper.start()
        switch result {
        case .success:
            simulated = nil
            simulatedName = nil
            needsClear = false
            status = .idle
            connectionDetail = nil
            locationKeeper.acceptsActualFixes = true
            return true
        case .failure(let error):
            let message = "Couldn’t confirm the location was restored. \(connectionMessage(error))"
            connectionDetail = "\(error)"
            lastError = message
            status = .dropped(message)
            return false
        }
    }

    // MARK: - Automated Runs

    func automationSet(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore) async -> Bool {
        guard !isBusy, checkPairing(pairing, showError: false) else { return false }
        return await apply(coordinate, pairing: pairing, markRecent: false, surfaceErrors: false, drive: true)
    }

    func automationStop(pairing: PairingStore) async -> Bool { await performStop(pairing: pairing) }

    func startLocationUpdates() { locationKeeper.start(inBackground: isSpoofing) }

    func startJoystick(pairing: PairingStore) {
        guard canControlManually(), checkPairing(pairing) else { return }
        onManualControl?("joystick")
        cancelRoute()
        simulatedName = nil
        let start = simulated ?? pin ?? realCoordinate
        guard let start else {
            lastError = "Locus can’t find your location yet. Choose a starting point on the map."
            return
        }
        joystickActive = true
        Task {
            if simulated == nil, !(await apply(start, pairing: pairing, markRecent: false)) {
                stopJoystick()
                return
            }
            guard joystickActive else { return }
            joystickTimer?.invalidate()
            joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.tickJoystick(pairing: pairing) }
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    func followRoute(
        _ coordinates: [CLLocationCoordinate2D],
        mode: TravelMode? = nil,
        destinationName: String? = nil,
        pairing: PairingStore
    ) {
        guard canControlManually(), checkPairing(pairing), coordinates.count >= 2 else { return }
        onManualControl?("route")
        routeTask?.cancel()
        stopJoystick()
        simulatedName = nil
        followingRouteTo = destinationName ?? "your destination"
        let mode = mode ?? travelMode
        routeTask = Task { [weak self] in
            guard let self else { return }
            var previous = coordinates[0]
            guard await self.apply(previous, pairing: pairing, markRecent: true) else {
                if !Task.isCancelled { self.followingRouteTo = nil; self.routeTask = nil }
                return
            }
            for next in coordinates.dropFirst() {
                if Task.isCancelled { break }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                var speed = mode.baseSpeed * Double.random(in: 0.88...1.12)
                speed = max(0.8, speed)
                let stepMeters: CLLocationDistance = min(12, max(4, speed * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                for i in 1...steps {
                    if Task.isCancelled { break }
                    let t = Double(i) / Double(steps)
                    let coord = CLLocationCoordinate2D(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    )
                    let delay = stepMeters / speed
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    guard await self.apply(coord, pairing: pairing, markRecent: false) else {
                        if !Task.isCancelled { self.followingRouteTo = nil; self.routeTask = nil }
                        return
                    }
                }
                previous = next
            }
            if !Task.isCancelled {
                self.followingRouteTo = nil
                self.simulatedName = destinationName
                self.routeTask = nil
            }
        }
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    @discardableResult
    private func apply(
        _ coordinate: CLLocationCoordinate2D,
        pairing: PairingStore,
        markRecent: Bool,
        surfaceErrors: Bool = true,
        drive: Bool = false,
        resend: Bool = false
    ) async -> Bool {
        guard !isBusy else { return false }
        let previous = status
        if status == .idle { status = .connecting }
        else if status.isDropped { status = .reconnecting }
        isBusy = true
        locationKeeper.acceptsActualFixes = false
        let result = await LocationEngine.set(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            pairingPath: pairing.pairingPath,
            deviceIP: TunnelConfig.targetIP
        )
        isBusy = false
        switch result {
        case .success:
            simulated = coordinate
            needsClear = true
            if !drive && !resend { pin = coordinate }
            if drive && !resend { simulatedName = nil }
            status = .active
            connectionDetail = nil
            lastError = nil
            retryAfter = .distantPast
            beginBackground()
            locationKeeper.start(inBackground: true)
            startResend(pairing: pairing)
            if markRecent { pushRecent(coordinate) }
            return true
        case .failure(let error):
            let message = connectionMessage(error)
            connectionDetail = "\(error) on \(networkDescription)"
            if surfaceErrors { lastError = message }
            if simulated != nil && previous == .active { postDropNotification(message) }
            status = .dropped(message)
            locationKeeper.acceptsActualFixes = !needsClear
            retryAfter = Date().addingTimeInterval(2)
            return false
        }
    }

    private func connectionMessage(_ error: LocationEngineError) -> String {
        if case .tunnelCreate = error {
            if cellularOnly {
                return "Couldn’t start a connection over cellular. Join Wi‑Fi, connect the helper in Settings, and try again."
            }
            return "Couldn’t reach this iPhone’s location service. Check the connection in Settings and try again."
        }
        return error.localizedDescription
    }

    func canRetryConnection() -> Bool { Date() >= retryAfter }

    private func tickJoystick(pairing: PairingStore) async {
        guard joystickActive, !isBusy, canRetryConnection(), let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let speed = travelMode.baseSpeed * min(1.0, magnitude) * Double.random(in: 0.9...1.1)
        let meters = speed * 0.25
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        await apply(next, pairing: pairing, markRecent: false)
    }

    private func startResend(pairing: PairingStore) {
        stopResend()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBusy, self.canRetryConnection(), let point = self.simulated else { return }
                // The executor owns reconnect and position delivery during a run.
                guard self.runOwnsLocation?() != true || self.status == .active else { return }
                await self.apply(point, pairing: pairing, markRecent: false, surfaceErrors: false, resend: true)
            }
        }
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}
