import CoreLocation
import Foundation
import MapKit
import UserNotifications

// Glue between the platform-free Scheduled Runs core (Locus/Scheduling/Core)
// and the app's existing MapKit / SpoofSession / notification services.

extension GeoPoint {
    init(_ c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension PlaceRef {
    init(_ place: SavedPlace) {
        self.init(name: place.name, point: GeoPoint(latitude: place.latitude, longitude: place.longitude))
    }
}

/// Driving routes from Apple Maps (same MKDirections path RouteBuilder uses).
final class MapKitRouteProvider: RouteProvider {
    private let limits = PostedRoadLimits()

    func route(from: GeoPoint, to: GeoPoint) async throws -> RouteResult {
        guard let route = try await RouteBuilder.routes(from: from, to: to).first else {
            throw RouteProviderError.noRoute
        }
        return try await withPostedLimits(route)
    }

    func withPostedLimits(_ route: RouteResult) async throws -> RouteResult {
        guard route.speedLimits == nil else { return route }
        var enriched = route
        enriched.speedLimits = try await limits.lookup(for: route.points)
        return enriched
    }
}

/// Sends executor output through the existing spoof session so status,
/// reconnection, resend and background keep-alive all keep working.
@MainActor
final class SpoofSessionSink: LocationSink {
    private enum Command: Equatable { case set(GeoPoint), stop }
    private weak var session: SpoofSession?
    private weak var pairing: PairingStore?
    private var inFlight: Task<Void, Never>?
    private var completed: (Command, LocationDelivery)?
    var onReady: (() -> Void)?

    init(session: SpoofSession, pairing: PairingStore) {
        self.session = session
        self.pairing = pairing
    }

    nonisolated func deliver(_ point: GeoPoint, speed: Double?, heading: Double?) -> LocationDelivery {
        MainActor.assumeIsolated { submit(.set(point)) }
    }

    nonisolated func deliverStop() -> LocationDelivery {
        MainActor.assumeIsolated { submit(.stop) }
    }

    func invalidateCompletion() { completed = nil }

    func waitForDelivery() async { await inFlight?.value }

    private func submit(_ command: Command) -> LocationDelivery {
        guard let session, let pairing else { return .failed }
        if let result = completed {
            completed = nil
            if result.0 == command { return result.1 }
        }
        guard inFlight == nil, !session.isBusy else { return .pending }
        if case .set = command, !session.canRetryConnection() { return .failed }
        inFlight = Task {
            let ok: Bool
            switch command {
            case .set(let point): ok = await session.automationSet(point.coordinate, pairing: pairing)
            case .stop: ok = await session.automationStop(pairing: pairing)
            }
            inFlight = nil
            completed = (command, ok ? .applied : .failed)
            onReady?()
        }
        return .pending
    }
}

final class UserNotificationRunNotifier: RunNotifier {
    private let center = UNUserNotificationCenter.current()

    private func id(_ runID: UUID) -> String { "locus.run.reminder.\(runID.uuidString)" }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("[Locus][Notifications] Authorization: %@", error.localizedDescription) }
        }
    }

    func scheduleStartReminder(runID: UUID, runName: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "\(runName) is scheduled"
        content.body = "Open Locus to check this run or start it manually."
        content.userInfo = ["runID": runID.uuidString]
        content.sound = .default
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        add(UNNotificationRequest(identifier: id(runID), content: content, trigger: trigger))
    }

    func cancelStartReminder(runID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [id(runID)])
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        add(UNNotificationRequest(identifier: "locus.run.\(UUID().uuidString)", content: content, trigger: nil))
    }

    private func add(_ request: UNNotificationRequest) {
        center.add(request) { error in
            if let error { NSLog("[Locus][Notifications] Delivery request: %@", error.localizedDescription) }
        }
    }
}
