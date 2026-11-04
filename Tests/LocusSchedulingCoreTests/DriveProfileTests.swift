import XCTest
@testable import LocusSchedulingCore

final class DriveProfileTests: XCTestCase {
    private func straight(_ meters: Double) throws -> Polyline {
        try Polyline(sanitizing: [sf, offset(sf, east: meters)])
    }

    private func ref(_ v: Double, source: SpeedReferenceSource = .routeAverage) -> SpeedReference {
        SpeedReference(spans: [], fallback: v, fallbackSource: source)
    }

    /// Samples the profile every `dt` seconds.
    private func samples(_ p: DriveProfile, dt: Double = 0.5) -> [DriveState] {
        stride(from: 0.0, through: p.duration, by: dt).map { p.state(at: $0) } + [p.state(at: p.duration)]
    }

    func testConstantSpeedWithSmoothingMatchesKinematics() throws {
        let p = DriveProfile(route: try straight(1000), reference: ref(13), policy: .constant(20))
        // accel 0→20 @2 m/s² = 10 s / 100 m; brake 20→0 @2.5 m/s² = 8 s / 80 m; cruise 820 m @20 = 41 s.
        XCTAssertNear(p.duration, 59, 0.5)
        XCTAssertNear(p.distance, 1000, 0.5)
        XCTAssertNear(p.maxSpeed, 20, 1e-6)
        let mid = p.state(at: 30)
        XCTAssertNear(mid.speed, 20, 0.01)
    }

    func testStartsAndEndsStoppedAndNeverExceedsTarget() throws {
        let p = DriveProfile(route: try straight(1000), reference: ref(13), policy: .constant(20))
        XCTAssertEqual(p.state(at: 0).speed, 0)
        XCTAssertEqual(p.state(at: p.duration).speed, 0)
        XCTAssertNear(p.state(at: p.duration).position, offset(sf, east: 1000), meters: 0.5)
        var lastD = -1.0
        for s in samples(p) {
            XCTAssertLessThanOrEqual(s.speed, 20 + 1e-6)
            XCTAssertGreaterThanOrEqual(s.distanceTravelled, lastD - 1e-9, "position must never move backwards")
            lastD = s.distanceTravelled
            XCTAssertNear(s.distanceTravelled + s.distanceRemaining, p.distance, 0.01)
        }
    }

    func testAccelerationIsBounded() throws {
        let motion = MotionSettings.standard
        let p = DriveProfile(route: try straight(2000), reference: ref(13), policy: .constant(30), motion: motion)
        let dt = 0.25
        let ss = samples(p, dt: dt)
        for (a, b) in zip(ss, ss.dropFirst()) {
            let accel = (b.speed - a.speed) / dt
            XCTAssertLessThanOrEqual(accel, motion.acceleration + 0.05)
            XCTAssertGreaterThanOrEqual(accel, -motion.deceleration - 0.05)
        }
    }

    func testNoSmoothingIsCloseToDistanceOverSpeed() throws {
        var m = MotionSettings.standard
        m.smoothing = false
        let p = DriveProfile(route: try straight(1000), reference: ref(13), policy: .constant(20), motion: m)
        // Only the first and last 10 m node segments ramp; ≈ 50 s + 1 s.
        XCTAssertNear(p.duration, 51, 0.6)
        XCTAssertEqual(p.state(at: p.duration).speed, 0, "still stops at the destination")
    }

    func testETARecalculatesWhenSpeedChanges() throws {
        let line = try straight(5000)
        let slow = DriveProfile(route: line, reference: ref(13), policy: .constant(10))
        let fast = DriveProfile(route: line, reference: ref(13), policy: .constant(20))
        XCTAssertLessThan(fast.duration, slow.duration * 0.55)
        let above = DriveProfile(route: line, reference: ref(13), policy: .aboveLimit(SpeedUnit.mph.toMetersPerSecond(5)))
        let follow = DriveProfile(route: line, reference: ref(13), policy: .followLimit)
        let below = DriveProfile(route: line, reference: ref(13), policy: .belowLimit(SpeedUnit.mph.toMetersPerSecond(5)))
        XCTAssertLessThan(above.duration, follow.duration)
        XCTAssertLessThan(follow.duration, below.duration)
    }

    func testFollowLimitTracksPostedLimitSpans() throws {
        let reference = SpeedReference(
            spans: [
                SpeedLimitSpan(fromDistance: 0, toDistance: 1000, limit: 10),
                SpeedLimitSpan(fromDistance: 1000, toDistance: 3000, limit: 25),
            ],
            fallback: 13, fallbackSource: .routeAverage
        )
        let p = DriveProfile(route: try straight(3000), reference: reference, policy: .followLimit)
        XCTAssertEqual(p.referenceSource, .postedLimits)
        let inSlowZone = samples(p).first { $0.distanceTravelled > 500 }!
        XCTAssertNear(inSlowZone.speed, 10, 0.01)
        XCTAssertEqual(inSlowZone.referenceSpeed, 10)
        let inFastZone = samples(p).first { $0.distanceTravelled > 2000 }!
        XCTAssertNear(inFastZone.speed, 25, 0.01)
        // Speed-up happens after the boundary, never before it.
        for s in samples(p) where s.distanceTravelled < 995 {
            XCTAssertLessThanOrEqual(s.speed, 10 + 1e-6)
        }
    }

    func testAboveAndBelowLimitOffsets() throws {
        let five = SpeedUnit.mph.toMetersPerSecond(5)
        let reference = SpeedReference(spans: [SpeedLimitSpan(fromDistance: 0, toDistance: 3000, limit: 20)], fallback: 13, fallbackSource: .routeAverage)
        let above = DriveProfile(route: try straight(3000), reference: reference, policy: .aboveLimit(five))
        let below = DriveProfile(route: try straight(3000), reference: reference, policy: .belowLimit(five))
        XCTAssertNear(above.maxSpeed, 20 + five, 1e-6)
        XCTAssertNear(below.maxSpeed, 20 - five, 1e-6)
    }

    func testSlowsForSharpTurn() throws {
        let corner = offset(sf, east: 500)
        let line = try Polyline(sanitizing: [sf, corner, offset(corner, north: 500)])
        let p = DriveProfile(route: line, reference: ref(13), policy: .constant(20))
        let nearCorner = samples(p, dt: 0.1).min { abs($0.distanceTravelled - 500) < abs($1.distanceTravelled - 500) }!
        XCTAssertLessThan(nearCorner.speed, 6, "a 90° corner should be taken slowly")
        XCTAssertGreaterThanOrEqual(nearCorner.speed, MotionSettings.standard.minimumCornerSpeed - 0.5)

        var noTurns = MotionSettings.standard
        noTurns.slowForTurns = false
        let q = DriveProfile(route: line, reference: ref(13), policy: .constant(20), motion: noTurns)
        XCTAssertLessThan(q.duration, p.duration)
        let qCorner = samples(q, dt: 0.1).min { abs($0.distanceTravelled - 500) < abs($1.distanceTravelled - 500) }!
        XCTAssertNear(qCorner.speed, 20, 0.5)
    }

    func testGentleCurveIsNotSlowedMuch() throws {
        // 2 km arc of radius ~1.3 km built from 100 m chords.
        var pts: [GeoPoint] = []
        let r = 1300.0
        for k in 0...20 {
            let a = Double(k) / 20 * (2000 / r)
            pts.append(offset(sf, east: r * sin(a), north: r * (1 - cos(a))))
        }
        let p = DriveProfile(route: try Polyline(sanitizing: pts), reference: ref(13), policy: .constant(20))
        let mid = p.state(at: p.duration / 2)
        XCTAssertGreaterThan(mid.speed, 19)
    }

    func testHeadingFollowsRoute() throws {
        let p = DriveProfile(route: try straight(500), reference: ref(13), policy: .constant(10))
        XCTAssertNear(p.state(at: p.duration / 2).heading, 90, 1)
    }

    func testRemainderStartsFromGivenSpeedAndCoversRest() throws {
        let p = DriveProfile(route: try straight(2000), reference: ref(13), policy: .constant(20))
        let t = p.duration / 2
        let s = p.state(at: t)
        let rest = try XCTUnwrap(p.remainder(from: t, initialSpeed: 0))
        XCTAssertEqual(rest.state(at: 0).speed, 0)
        XCTAssertNear(rest.distance, s.distanceRemaining, 1)
        XCTAssertNear(rest.state(at: 0).position, s.position, meters: 0.5)
        XCTAssertNear(rest.state(at: rest.duration).position, offset(sf, east: 2000), meters: 0.5)

        let carry = try XCTUnwrap(p.remainder(from: t))
        XCTAssertNear(carry.state(at: 0).speed, s.speed, 1e-6)
        XCTAssertLessThan(carry.duration, rest.duration)

        XCTAssertNil(p.remainder(from: p.duration))
    }

    func testCodableRoundTrip() throws {
        let p = DriveProfile(route: try straight(800), reference: ref(13), policy: .aboveLimit(2))
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(DriveProfile.self, from: data)
        XCTAssertEqual(back, p)
    }

    func testVeryShortRouteIsStable() throws {
        let p = DriveProfile(route: try straight(3), reference: ref(13), policy: .constant(20))
        XCTAssertGreaterThan(p.duration, 0)
        XCTAssertTrue(p.duration.isFinite)
        XCTAssertNear(p.state(at: p.duration).position, offset(sf, east: 3), meters: 0.1)
    }

    func testSampleStateIsFiniteEverywhere() throws {
        let p = DriveProfile(route: try straight(1500), reference: ref(13), policy: .followLimit)
        for s in samples(p, dt: 0.37) {
            XCTAssertTrue(s.speed.isFinite && s.position.isValid && s.heading.isFinite)
        }
        _ = p.state(at: -10)
        _ = p.state(at: .greatestFiniteMagnitude)
    }
}
