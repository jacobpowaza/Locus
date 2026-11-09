import XCTest
@testable import LocusSchedulingCore

final class SpeedTests: XCTestCase {
    func testUnitConversions() {
        XCTAssertNear(SpeedUnit.mph.toMetersPerSecond(35), 15.6464, 1e-4)
        XCTAssertNear(SpeedUnit.kmh.toMetersPerSecond(36), 10, 1e-9)
        XCTAssertNear(SpeedUnit.mph.fromMetersPerSecond(SpeedUnit.mph.toMetersPerSecond(55)), 55, 1e-9)
        XCTAssertEqual(SpeedUnit.defaultFor(regionCode: "US"), .mph)
        XCTAssertEqual(SpeedUnit.defaultFor(regionCode: "gb"), .mph)
        XCTAssertEqual(SpeedUnit.defaultFor(regionCode: "DE"), .kmh)
        XCTAssertEqual(SpeedUnit.defaultFor(regionCode: nil), .kmh)
    }

    func testPolicyTargets() {
        let five = SpeedUnit.mph.toMetersPerSecond(5)
        XCTAssertEqual(SpeedPolicy.followLimit.target(reference: 20), 20)
        XCTAssertEqual(SpeedPolicy.constant(15).target(reference: 30), 15)
        XCTAssertNear(SpeedPolicy.aboveLimit(five).target(reference: 20), 20 + five, 1e-9)
        XCTAssertNear(SpeedPolicy.belowLimit(five).target(reference: 20), 20 - five, 1e-9)
        // Clamped: never negative / stopped, never absurd.
        XCTAssertEqual(SpeedPolicy.belowLimit(30).target(reference: 10), SpeedPolicy.minimumSpeed)
        XCTAssertEqual(SpeedPolicy.constant(500).target(reference: 10), SpeedPolicy.maximumSpeed)
    }

    func testPolicyValidation() {
        XCTAssertNil(SpeedPolicy.followLimit.validationProblem)
        XCTAssertNil(SpeedPolicy.constant(15).validationProblem)
        XCTAssertNotNil(SpeedPolicy.constant(0).validationProblem)
        XCTAssertNotNil(SpeedPolicy.constant(.nan).validationProblem)
        XCTAssertNotNil(SpeedPolicy.constant(100).validationProblem)
        XCTAssertNotNil(SpeedPolicy.aboveLimit(-1).validationProblem)
        XCTAssertNotNil(SpeedPolicy.belowLimit(50).validationProblem)
    }

    func testReferencePrefersRouteAverageWhenNoLimits() {
        let ref = SpeedReference.make(spans: nil, routeDistance: 6000, expectedTravelTime: 600, travelModeDefault: 13.4)
        XCTAssertEqual(ref.fallbackSource, .routeAverage)
        XCTAssertEqual(ref.speed(atDistance: 100).value, 10)
        XCTAssertEqual(ref.overallSource(routeLength: 6000), .routeAverage)
        XCTAssertTrue(ref.overallSource(routeLength: 6000).isFallback)
    }

    func testReferenceFallsBackToModeDefaultWithoutData() {
        for eta in [nil, 0, -5, .nan, 1e-6] as [Double?] {
            let ref = SpeedReference.make(spans: [], routeDistance: 6000, expectedTravelTime: eta, travelModeDefault: 13.4)
            XCTAssertEqual(ref.fallbackSource, .travelModeDefault, "eta \(String(describing: eta))")
            XCTAssertEqual(ref.speed(atDistance: 0).value, 13.4)
        }
    }

    func testPostedLimitsWinWhereTheyExist() {
        let spans = [
            SpeedLimitSpan(fromDistance: 0, toDistance: 500, limit: 11),
            SpeedLimitSpan(fromDistance: 500, toDistance: 1000, limit: 25),
            SpeedLimitSpan(fromDistance: 10, toDistance: 5, limit: 99), // malformed, dropped
            SpeedLimitSpan(fromDistance: 0, toDistance: 5, limit: .nan), // malformed, dropped
        ]
        let ref = SpeedReference.make(spans: spans, routeDistance: 1000, expectedTravelTime: 100, travelModeDefault: 13.4)
        XCTAssertEqual(ref.spans.count, 2)
        XCTAssertEqual(ref.speed(atDistance: 100).value, 11)
        XCTAssertEqual(ref.speed(atDistance: 100).source, .postedLimits)
        XCTAssertEqual(ref.speed(atDistance: 700).value, 25)
        XCTAssertEqual(ref.speed(atDistance: 1500).source, .routeAverage)
        XCTAssertEqual(ref.overallSource(routeLength: 1000), .postedLimits)
        XCTAssertEqual(ref.overallSource(routeLength: 2000), .routeAverage) // only 50% covered
    }

    func testPercentageOffsetScalesWithReferenceSpeed() {
        let policy = SpeedPolicy.aboveLimitPercent(25)
        XCTAssertEqual(policy.target(reference: 12), 15)
        XCTAssertEqual(policy.target(reference: 20), 25)
        XCTAssertNil(policy.validationProblem)
        XCTAssertNotNil(SpeedPolicy.aboveLimitPercent(-1).validationProblem)
        XCTAssertNotNil(SpeedPolicy.aboveLimitPercent(101).validationProblem)
    }

    func testShiftedReference() {
        let ref = SpeedReference(spans: [SpeedLimitSpan(fromDistance: 100, toDistance: 300, limit: 9)], fallback: 13, fallbackSource: .routeAverage)
        let s = ref.shifted(by: 200)
        XCTAssertEqual(s.spans, [SpeedLimitSpan(fromDistance: 0, toDistance: 100, limit: 9)])
        XCTAssertEqual(ref.shifted(by: 400).spans, [])
    }

    func testFallbackSourcesAreLabelledAsEstimates() {
        XCTAssertFalse(SpeedReferenceSource.postedLimits.label.contains("Estimated"))
        XCTAssertTrue(SpeedReferenceSource.routeAverage.label.contains("Estimated"))
        XCTAssertTrue(SpeedReferenceSource.travelModeDefault.label.contains("Estimated"))
        XCTAssertTrue(SpeedReferenceSource.routeAverage.explanation.contains("not the signed limit"))
    }
}
