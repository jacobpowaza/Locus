import Foundation
import XCTest
@testable import LocusSchedulingCore

// MARK: - Geometry helpers

/// Point `east`/`north` metres from `origin` (flat-earth approximation, fine < 50 km).
func offset(_ origin: GeoPoint, east: Double = 0, north: Double = 0) -> GeoPoint {
    let dLat = north / Geo.earthRadius * 180 / .pi
    let dLon = east / (Geo.earthRadius * cos(origin.latitude * .pi / 180)) * 180 / .pi
    return GeoPoint(latitude: origin.latitude + dLat, longitude: origin.longitude + dLon)
}

let sf = GeoPoint(latitude: 37.7749, longitude: -122.4194)
let home = PlaceRef(name: "Home", point: sf)
let work = PlaceRef(name: "Work", point: offset(sf, east: 3000, north: 4000)) // 5 km away

func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    guard let d = f.date(from: iso) else { fatalError("bad date \(iso)") }
    return d
}

let newYork = TimeZone(identifier: "America/New_York")!

// MARK: - Fakes

final class FakeClock: RunClock {
    var now: Date
    var monotonic: Double = 1000
    init(_ now: Date) { self.now = now }

    /// Advance both clocks (normal passage of time).
    func advance(_ seconds: Double) {
        now = now.addingTimeInterval(seconds)
        monotonic += seconds
    }

    /// User changed the device clock: wall jumps, monotonic doesn't.
    func jumpWall(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
}

/// Routes as an L (east then north) via a corner, so turns are exercised.
/// ETA = distance / `averageSpeed` unless `eta` is nil.
final class FakeRouteProvider: RouteProvider {
    var calls = 0
    var failWith: Error?
    var averageSpeed: Double? = 15
    var speedLimits: [SpeedLimitSpan]?
    var override: ((GeoPoint, GeoPoint) -> [GeoPoint])?
    var straight = false

    func route(from: GeoPoint, to: GeoPoint) async throws -> RouteResult {
        calls += 1
        if let failWith { throw failWith }
        let pts: [GeoPoint]
        if let override {
            pts = override(from, to)
        } else if straight {
            pts = [from, to]
        } else {
            pts = [from, GeoPoint(latitude: from.latitude, longitude: to.longitude), to]
        }
        var length = 0.0
        for (a, b) in zip(pts, pts.dropFirst()) where a.isValid && b.isValid { length += Geo.distance(a, b) }
        return RouteResult(
            points: pts,
            expectedTravelTime: averageSpeed.map { length / $0 },
            speedLimits: speedLimits,
            providerName: "Fake"
        )
    }
}

final class RecordingSink: LocationSink {
    enum Call: Equatable {
        case set(GeoPoint)
        case stop
    }
    var calls: [Call] = []
    var speeds: [Double] = []
    var failing = false
    var pending = false

    var positions: [GeoPoint] {
        calls.compactMap { if case .set(let p) = $0 { return p } else { return nil } }
    }
    var last: GeoPoint? { positions.last }

    func deliver(_ point: GeoPoint, speed: Double?, heading: Double?) -> LocationDelivery {
        if pending { return .pending }
        if failing { return .failed }
        calls.append(.set(point))
        speeds.append(speed ?? 0)
        return .applied
    }

    func deliverStop() -> LocationDelivery {
        if pending { return .pending }
        if failing { return .failed }
        calls.append(.stop)
        return .applied
    }
}

final class FakeNotifier: RunNotifier {
    var reminders: [UUID: Date] = [:]
    var posted: [(title: String, body: String)] = []

    func scheduleStartReminder(runID: UUID, runName: String, at date: Date) { reminders[runID] = date }
    func cancelStartReminder(runID: UUID) { reminders[runID] = nil }
    func post(title: String, body: String) { posted.append((title, body)) }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("locus-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func XCTAssertNear(_ a: Double, _ b: Double, _ tol: Double, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssert(abs(a - b) <= tol, "\(a) is not within \(tol) of \(b). \(msg)", file: file, line: line)
}

func XCTAssertNear(_ a: GeoPoint?, _ b: GeoPoint, meters: Double, file: StaticString = #filePath, line: UInt = #line) {
    guard let a else { return XCTFail("nil point", file: file, line: line) }
    let d = Geo.distance(a, b)
    XCTAssert(d <= meters, "points are \(d) m apart (> \(meters))", file: file, line: line)
}
