import CoreLocation
import Foundation

final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var lastKnownCoordinate: CLLocationCoordinate2D?
    private var latestFix: CLLocation?
    var onActualLocation: ((CLLocationCoordinate2D) -> Void)?
    var acceptsActualFixes = true
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }

    func start(inBackground: Bool = false) {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = inBackground
        manager.desiredAccuracy = inBackground ? kCLLocationAccuracyThreeKilometers : kCLLocationAccuracyHundredMeters
        guard !running else { return }
        manager.startUpdatingLocation()
        running = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        running = false
    }

    var fixSummary: String {
        guard let fix = latestFix, abs(fix.timestamp.timeIntervalSinceNow) < 10 else { return "No recent fix" }
        let speed = fix.speed >= 0 ? String(format: "%.1f m/s", fix.speed) : "speed unavailable"
        let course = fix.course >= 0 ? String(format: "%.0f°", fix.course) : "course unavailable"
        let source = fix.sourceInformation.map { $0.isSimulatedBySoftware ? "simulated" : "unflagged" } ?? "source unknown"
        return "\(speed) · \(course) · \(source)"
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last,
              fix.horizontalAccuracy >= 0, abs(fix.timestamp.timeIntervalSinceNow) < 30,
              CLLocationCoordinate2DIsValid(fix.coordinate) else { return }
        latestFix = fix
        guard acceptsActualFixes, fix.sourceInformation?.isSimulatedBySoftware != true else { return }
        lastKnownCoordinate = fix.coordinate
        onActualLocation?(fix.coordinate)
    }
}
