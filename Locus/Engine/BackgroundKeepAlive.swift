import CoreLocation
import Foundation

final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var lastKnownCoordinate: CLLocationCoordinate2D?
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

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard acceptsActualFixes, let fix = locations.last,
              fix.sourceInformation?.isSimulatedBySoftware != true,
              fix.horizontalAccuracy >= 0, abs(fix.timestamp.timeIntervalSinceNow) < 30,
              CLLocationCoordinate2DIsValid(fix.coordinate) else { return }
        lastKnownCoordinate = fix.coordinate
        onActualLocation?(fix.coordinate)
    }
}
