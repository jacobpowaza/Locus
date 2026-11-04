import XCTest
@testable import LocusSchedulingCore

final class GeoMathTests: XCTestCase {
    func testDistanceOfOneDegreeLatitude() {
        let d = Geo.distance(GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 1, longitude: 0))
        XCTAssertNear(d, 111_195, 50)
    }

    func testOffsetHelperRoundTrips() {
        XCTAssertNear(Geo.distance(sf, offset(sf, east: 3000, north: 4000)), 5000, 5)
    }

    func testBearingCardinals() {
        XCTAssertNear(Geo.bearing(sf, offset(sf, north: 100)), 0, 0.1)
        XCTAssertNear(Geo.bearing(sf, offset(sf, east: 100)), 90, 0.1)
        XCTAssertNear(Geo.bearing(sf, offset(sf, north: -100)), 180, 0.1)
        XCTAssertNear(Geo.bearing(sf, offset(sf, east: -100)), 270, 0.1)
    }

    func testHeadingDeltaWraps() {
        XCTAssertEqual(Geo.headingDelta(350, 10), 20)
        XCTAssertEqual(Geo.headingDelta(90, 270), 180)
    }

    func testInterpolationCrossesAntimeridianTheShortWay() {
        let a = GeoPoint(latitude: 0, longitude: 179.9)
        let b = GeoPoint(latitude: 0, longitude: -179.9)
        let mid = Geo.interpolate(a, b, 0.5)
        XCTAssertNear(abs(mid.longitude), 180, 1e-9)
    }

    func testSanitizeDropsInvalidAndDuplicatePoints() throws {
        let raw = [
            sf,
            sf, // duplicate
            GeoPoint(latitude: .nan, longitude: 0),
            GeoPoint(latitude: 95, longitude: 0), // out of range
            GeoPoint(latitude: 0, longitude: .infinity),
            offset(sf, east: 100),
        ]
        let line = try Polyline(sanitizing: raw)
        XCTAssertEqual(line.points.count, 2)
        XCTAssertNear(line.length, 100, 0.5)
    }

    func testSanitizeErrors() {
        XCTAssertThrowsError(try Polyline(sanitizing: [])) { XCTAssertEqual($0 as? PolylineError, .tooFewPoints) }
        XCTAssertThrowsError(try Polyline(sanitizing: [sf])) { XCTAssertEqual($0 as? PolylineError, .tooFewPoints) }
        XCTAssertThrowsError(try Polyline(sanitizing: [sf, GeoPoint(latitude: .nan, longitude: 1)])) {
            XCTAssertEqual($0 as? PolylineError, .tooFewPoints)
        }
        XCTAssertThrowsError(try Polyline(sanitizing: [sf, sf, sf])) { XCTAssertEqual($0 as? PolylineError, .zeroLength) }
    }

    func testPointAtDistanceAndClamping() throws {
        let line = try Polyline(sanitizing: [sf, offset(sf, east: 100), offset(sf, east: 100, north: 100)])
        XCTAssertNear(line.length, 200, 0.5)
        XCTAssertNear(line.point(atDistance: -5), sf, meters: 0.01)
        XCTAssertNear(line.point(atDistance: 50), offset(sf, east: 50), meters: 0.5)
        XCTAssertNear(line.point(atDistance: 150), offset(sf, east: 100, north: 50), meters: 0.5)
        XCTAssertNear(line.point(atDistance: 999), line.end, meters: 0.01)
        XCTAssertNear(line.heading(atDistance: 50), 90, 0.5)
        XCTAssertNear(line.heading(atDistance: 150), 0, 0.5)
    }

    func testDensifyKeepsLengthAndVertices() throws {
        let line = try Polyline(sanitizing: [sf, offset(sf, east: 95), offset(sf, east: 95, north: 33)])
        let dense = line.densified(maxSpacing: 10)
        XCTAssertNear(dense.length, line.length, 0.01)
        XCTAssertTrue(dense.points.contains(line.points[1]))
        for (a, b) in zip(dense.points, dense.points.dropFirst()) {
            XCTAssertLessThanOrEqual(Geo.distance(a, b), 10.001)
        }
    }

    func testSuffix() throws {
        let line = try Polyline(sanitizing: [sf, offset(sf, east: 100), offset(sf, east: 100, north: 100)])
        let rest = try XCTUnwrap(line.suffix(fromDistance: 50))
        XCTAssertNear(rest.length, 150, 0.5)
        XCTAssertNear(rest.start, offset(sf, east: 50), meters: 0.5)
        XCTAssertNil(line.suffix(fromDistance: 199.5))
    }
}
