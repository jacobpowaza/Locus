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
///
/// MapKit gives road geometry and an ETA but **no posted speed limits**, so
/// `speedLimits` is nil and drives use the labelled route-average fallback.
final class MapKitRouteProvider: RouteProvider {
    func route(from: GeoPoint, to: GeoPoint) async throws -> RouteResult {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch {
            throw RouteProviderError.unavailable(error.localizedDescription)
        }
        guard let route = response.routes.first else { throw RouteProviderError.noRoute }
        // Raw vertices; the core densifies for motion. 50 m keeps curves.
        let coords = RouteBuilder.sample(polyline: route.polyline, every: 50)
        return RouteResult(
            points: coords.map(GeoPoint.init),
            expectedTravelTime: route.expectedTravelTime,
            speedLimits: nil,
            providerName: "Apple Maps"
        )
    }
}

/// Sends executor output through the existing spoof session so status,
/// reconnection, resend and background keep-alive all keep working.
@MainActor
final class SpoofSessionSink: LocationSink {
    weak var session: SpoofSession?
    weak var pairing: PairingStore?

    init(session: SpoofSession, pairing: PairingStore) {
        self.session = session
        self.pairing = pairing
    }

    nonisolated func setSimulatedLocation(_ point: GeoPoint, speed: Double?, heading: Double?) -> Bool {
        MainActor.assumeIsolated {
            guard let session, let pairing else { return false }
            return session.automationSet(point.coordinate, pairing: pairing)
        }
    }

    nonisolated func stopSimulation() -> Bool {
        MainActor.assumeIsolated {
            guard let session, let pairing else { return false }
            return session.automationStop(pairing: pairing)
        }
    }
}

final class UserNotificationRunNotifier: RunNotifier {
    private let center = UNUserNotificationCenter.current()

    private func id(_ runID: UUID) -> String { "locus.run.reminder.\(runID.uuidString)" }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func scheduleStartReminder(runID: UUID, runName: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "\(runName) is waiting"
        content.body = "Locus wasn't running at the start time. Open Locus to start it."
        content.sound = .default
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: id(runID), content: content, trigger: trigger))
    }

    func cancelStartReminder(runID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [id(runID)])
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "locus.run.\(UUID().uuidString)", content: content, trigger: nil))
    }
}
