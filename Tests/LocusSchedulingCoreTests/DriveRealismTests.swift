import XCTest
@testable import LocusSchedulingCore

final class DriveRealismTests: XCTestCase {
    private func straight(_ meters: Double) throws -> Polyline {
        try Polyline(sanitizing: [sf, offset(sf, east: meters)])
    }

    /// East, then a right-angle turn north at `corner` metres.
    private func elbow(_ corner: Double, _ leg2: Double) throws -> Polyline {
        let c = offset(sf, east: corner)
        return try Polyline(sanitizing: [sf, c, offset(c, north: leg2)])
    }

    private func ref(_ v: Double) -> SpeedReference {
        SpeedReference(spans: [], fallback: v, fallbackSource: .routeAverage)
    }

    func testStopAddsItsDwellAndStandsStill() throws {
        let line = try straight(1000)
        let plain = DriveProfile(route: line, reference: ref(13), policy: .constant(15))
        let stop = DriveStop(distance: 500, dwell: 60, kind: .redLight)
        let p = DriveProfile(route: line, reference: ref(13), policy: .constant(15), stops: [stop])

        // Braking to zero and pulling away costs extra time on top of the dwell.
        XCTAssertGreaterThan(p.duration, plain.duration + 60)
        XCTAssertLessThan(p.duration, plain.duration + 60 + 20)
        XCTAssertNear(p.totalStopTime, 60, 1e-9)

        // Find the moment the car is at the light and check it stays there.
        let ss = stride(from: 0.0, through: p.duration, by: 0.5).map { p.state(at: $0) }
        let atLight = ss.filter { $0.stoppedFor == .redLight }
        XCTAssertFalse(atLight.isEmpty)
        XCTAssertNear(Double(atLight.count) * 0.5, 60, 1.0)
        for s in atLight {
            XCTAssertEqual(s.speed, 0)
            XCTAssertNear(s.distanceTravelled, 500, 6)
        }
        // Never moves backwards, ends at the destination stopped.
        var last = -1.0
        for s in ss {
            XCTAssertGreaterThanOrEqual(s.distanceTravelled, last - 1e-9)
            last = s.distanceTravelled
        }
        XCTAssertEqual(p.state(at: p.duration).speed, 0)
        XCTAssertNil(p.state(at: p.duration).stoppedFor)
    }

    func testNoRealismLeavesProfileUnchanged() throws {
        let line = try straight(800)
        let a = DriveProfile(route: line, reference: ref(13), policy: .followLimit)
        let b = DriveProfile(route: line, reference: ref(13), policy: .followLimit, stops: [], speedKnots: [])
        XCTAssertEqual(a, b)
        XCTAssertNil(a.stops)
    }

    func testStopsAtEndpointsAreIgnored() throws {
        let line = try straight(500)
        let p = DriveProfile(route: line, reference: ref(13), policy: .constant(15), stops: [
            DriveStop(distance: 0, dwell: 30, kind: .redLight),
            DriveStop(distance: 500, dwell: 30, kind: .redLight),
        ])
        XCTAssertNil(p.stops)
    }

    func testRemainderKeepsStopsAhead() throws {
        let line = try straight(2000)
        let p = DriveProfile(route: line, reference: ref(13), policy: .constant(15), stops: [
            DriveStop(distance: 400, dwell: 20, kind: .stopSign),
            DriveStop(distance: 1500, dwell: 45, kind: .redLight),
        ])
        // Somewhere past the first stop.
        let t = stride(from: 0.0, through: p.duration, by: 0.5).first { p.state(at: $0).distanceTravelled > 700 }!
        let rest = try XCTUnwrap(p.remainder(from: t))
        let stops = try XCTUnwrap(rest.stops)
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops[0].kind, .redLight)
        XCTAssertNear(stops[0].distance, 1500 - p.state(at: t).distanceTravelled, 0.01)
    }

    func testWithPolicyKeepsStops() throws {
        let p = DriveProfile(route: try straight(1000), reference: ref(13), policy: .constant(10), stops: [
            DriveStop(distance: 500, dwell: 30, kind: .redLight),
        ])
        let q = p.withPolicy(.constant(20))
        XCTAssertEqual(q.stops, p.stops)
        XCTAssertLessThan(q.duration, p.duration)
    }

    func testSpeedDriftStaysNearTarget() throws {
        var rng = SeededGenerator(seed: 7)
        let line = try straight(3000)
        let knots = DriveRealismPlanner.speedKnots(along: line.length, using: &rng)
        XCTAssertGreaterThan(knots.count, 2)
        var noTurns = MotionSettings.standard
        noTurns.slowForTurns = false
        let p = DriveProfile(route: line, reference: ref(13), policy: .constant(20), motion: noTurns, speedKnots: knots)
        XCTAssertLessThanOrEqual(p.maxSpeed, 20 * 1.08 + 1e-6)
        let speeds = stride(from: 20.0, to: p.duration - 20, by: 2).map { p.state(at: $0).speed }
        XCTAssertGreaterThan((speeds.max() ?? 0) - (speeds.min() ?? 0), 0.3, "speed should actually vary")
        XCTAssertGreaterThan(speeds.min() ?? 0, 20 * 0.92 - 0.5)
    }

    func testPlannerIsDeterministicForTheSameSeed() throws {
        let line = try straight(5000)
        let id = UUID()
        var a = SeededGenerator(uuid: id)
        var b = SeededGenerator(uuid: id)
        let s1 = DriveRealismPlanner.stops(along: line, reference: ref(11), realism: .natural, using: &a)
        let s2 = DriveRealismPlanner.stops(along: line, reference: ref(11), realism: .natural, using: &b)
        XCTAssertEqual(s1, s2)
    }

    func testPlannerRespectsTogglesAndLimits() throws {
        let line = try straight(20_000)
        var rng = SeededGenerator(seed: 42)
        var realism = DriveRealism.off
        XCTAssertTrue(DriveRealismPlanner.stops(along: line, reference: ref(11), realism: realism, using: &rng).isEmpty)

        realism.redLights = true
        realism.maxRedLightWait = 60
        let lights = DriveRealismPlanner.stops(along: line, reference: ref(11), realism: realism, using: &rng)
        XCTAssertFalse(lights.isEmpty)
        for s in lights {
            XCTAssertEqual(s.kind, .redLight)
            XCTAssertLessThanOrEqual(s.dwell, 60)
            XCTAssertGreaterThanOrEqual(s.dwell, realism.minRedLightWait - 1)
        }
        for (x, y) in zip(lights, lights.dropFirst()) {
            XCTAssertGreaterThanOrEqual(y.distance - x.distance, DriveRealismPlanner.minimumGap)
        }

        // Highways have no lights between turns.
        let highway = DriveRealismPlanner.stops(along: line, reference: ref(30), realism: realism, using: &rng)
        XCTAssertTrue(highway.isEmpty)
    }

    func testTurnsAreDetected() throws {
        let line = try elbow(600, 600)
        let turns = DriveRealismPlanner.turnDistances(line)
        XCTAssertEqual(turns.count, 1)
        XCTAssertNear(turns[0], 600, 12)
        XCTAssertTrue(DriveRealismPlanner.turnDistances(try straight(1000)).isEmpty)
    }

    func testOldMotionSettingsStillDecode() throws {
        let json = #"{"smoothing":true,"acceleration":2,"deceleration":2.5,"lateralAcceleration":3,"minimumCornerSpeed":3,"slowForTurns":true}"#
        let m = try JSONDecoder().decode(MotionSettings.self, from: Data(json.utf8))
        XCTAssertNil(m.realism)
        XCTAssertEqual(m, MotionSettings.standard)
    }

    func testCompiledRunWithRealismIncludesStopsAndMatchesPreview() async throws {
        let routes = FakeRouteProvider()
        routes.averageSpeed = 11
        var run = ScheduledRun(name: "Errand", actions: [
            RunAction(.setLocation(home)),
            RunAction(.driveTo(work, speed: nil)),
        ])
        run.motion.realism = DriveRealism(redLights: true, maxRedLightWait: 60, stopSigns: true, varySpeed: true)
        let compiler = RunCompiler(routeProvider: routes)
        let start = date("2026-03-02T10:00:00Z")
        let a = try await compiler.compile(run, anchorDate: start, startDate: start, currentLocation: nil)
        let b = try await compiler.compile(run, anchorDate: start, startDate: start, currentLocation: nil)
        XCTAssertEqual(a.estimatedDuration, b.estimatedDuration, accuracy: 1e-6)

        guard case .drive(let leg) = a.plan.segments[1].kind else { return XCTFail("expected a drive") }
        XCTAssertGreaterThan(leg.profile.totalStopTime, 0, "a 7 km city drive should hit at least one stop")
    }
}
