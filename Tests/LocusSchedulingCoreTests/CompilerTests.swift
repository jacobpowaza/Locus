import XCTest
@testable import LocusSchedulingCore

final class CompilerTests: XCTestCase {
    private func ny(_ run: ScheduledRun) -> ScheduledRun {
        var r = run
        r.schedule = .recurring(TimeOfDay(hour: 10, minute: 0), weekdays: RunSchedule.everyDay, timeZoneID: "America/New_York")
        return r
    }

    func testCommuteExampleTimeline() async throws {
        // 10:00 Set Home · wait 15 min · 10:30 drive to Work · arrive & stay.
        let routes = FakeRouteProvider()
        let run = ny(ScheduledRun.commuteTemplate(home: home, work: work))
        let anchor = date("2026-11-05T15:00:00Z") // 10:00 EST
        let result = try await RunCompiler(routeProvider: routes).compile(run, anchorDate: anchor, startDate: anchor, currentLocation: nil)
        let plan = result.plan
        XCTAssertEqual(plan.segments.count, 6)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")

        let p = plan.project(now: anchor)
        // Start At 10:00 → immediate; Set Home; wait until 10:15.
        XCTAssertEqual(p[0].end, anchor)
        XCTAssertEqual(p[2].end, anchor.addingTimeInterval(15 * 60))
        // Start At 10:30.
        XCTAssertEqual(p[3].end, date("2026-11-05T15:30:00Z"))
        // Drive begins 10:30 and arrives after the profile duration.
        guard case .drive(let leg) = plan.segments[5].kind else { return XCTFail("expected drive") }
        XCTAssertEqual(p[5].start, date("2026-11-05T15:30:00Z"))
        XCTAssertEqual(p[5].end, date("2026-11-05T15:30:00Z").addingTimeInterval(leg.profile.duration))
        XCTAssertEqual(leg.profile.referenceSource, .routeAverage, "MapKit-like provider has no posted limits → labelled fallback")
        XCTAssertNear(leg.profile.distance, 7000, 30) // L-shaped: 3 km east + 4 km north
        XCTAssertNear(plan.finalLocation!, work.point, meters: 1)
        XCTAssertNear(result.estimatedDuration, 30 * 60 + leg.profile.duration, 1)
    }

    func testDriveOverrunningNextStartAtIsReported() async throws {
        let routes = FakeRouteProvider()
        routes.averageSpeed = 5 // slow
        let run = ny(ScheduledRun(name: "Overrun", actions: [
            RunAction(.setLocation(home)),
            RunAction(.setSpeed(.constant(5))),
            RunAction(.driveTo(work, speed: nil)), // 7 km @ 5 m/s ≈ 23+ min
            RunAction(.startAt(TimeOfDay(hour: 10, minute: 15), dayOffset: 0)),
        ]))
        let anchor = date("2026-11-05T15:00:00Z")
        let result = try await RunCompiler(routeProvider: routes).compile(run, anchorDate: anchor, startDate: anchor, currentLocation: nil)
        let warning = result.issues.first { $0.actionID == run.actions[3].id }
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.severity, .warning)
        XCTAssertTrue(warning!.message.contains("late"))
        let p = result.plan.project(now: anchor)
        XCTAssertGreaterThan(p[3].lateBy, 60)
    }

    func testStartAtAlreadyPassedForManualRun() async throws {
        let run = ScheduledRun(name: "Late", actions: [
            RunAction(.startAt(TimeOfDay(hour: 8, minute: 0), dayOffset: 0)),
            RunAction(.setLocation(home)),
        ])
        let now = date("2026-11-05T17:00:00Z")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let result = try await RunCompiler(routeProvider: FakeRouteProvider()).compile(run, anchorDate: now, startDate: now, currentLocation: nil)
        let target = RunCompiler.resolve(TimeOfDay(hour: 8, minute: 0), dayOffset: 0, anchor: now, calendar: cal)
        if target < now {
            XCTAssertTrue(result.issues.contains { $0.message.contains("already passed") })
        }
    }

    func testRouteFailureIsActionable() async {
        let routes = FakeRouteProvider()
        routes.failWith = RouteProviderError.unavailable("The Internet connection appears to be offline.")
        let run = ScheduledRun(name: "R", actions: [RunAction(.setLocation(home)), RunAction(.driveTo(work, speed: nil))])
        do {
            _ = try await RunCompiler(routeProvider: routes).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
            XCTFail("expected failure")
        } catch let e as CompileError {
            XCTAssertEqual(e.actionID, run.actions[1].id)
            XCTAssertTrue(e.localizedDescription.contains("Work"))
            XCTAssertTrue(e.localizedDescription.contains("offline"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMalformedRoutesAreRejected() async {
        let cases: [(String, (GeoPoint, GeoPoint) -> [GeoPoint])] = [
            ("empty", { _, _ in [] }),
            ("nan", { _, _ in [GeoPoint(latitude: .nan, longitude: .nan), GeoPoint(latitude: .nan, longitude: 3)] }),
            ("single", { a, _ in [a] }),
            ("wrong place", { a, _ in [a, offset(a, east: -50_000)] }),
        ]
        for (name, make) in cases {
            let routes = FakeRouteProvider()
            routes.override = make
            let run = ScheduledRun(name: name, actions: [RunAction(.setLocation(home)), RunAction(.driveTo(work, speed: nil))])
            do {
                _ = try await RunCompiler(routeProvider: routes).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
                XCTFail("\(name): expected malformed route error")
            } catch let e as CompileError {
                guard case .malformedRoute = e else { return XCTFail("\(name): \(e)") }
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
    }

    func testRouteWithSomeBadPointsIsCleanedNotRejected() async throws {
        let routes = FakeRouteProvider()
        routes.override = { a, b in [a, GeoPoint(latitude: .nan, longitude: 0), a, Geo.interpolate(a, b, 0.5), b] }
        let run = ScheduledRun(name: "C", actions: [RunAction(.setLocation(home)), RunAction(.driveTo(work, speed: nil))])
        let result = try await RunCompiler(routeProvider: routes).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
        guard case .drive(let leg) = result.plan.segments[1].kind else { return XCTFail() }
        XCTAssertNear(leg.profile.distance, 5000, 5)
    }

    func testMissingETAFallsBackToDefaultDrivingSpeed() async throws {
        let routes = FakeRouteProvider()
        routes.averageSpeed = nil
        let run = ScheduledRun(name: "D", actions: [RunAction(.setLocation(home)), RunAction(.driveTo(work, speed: nil))])
        let result = try await RunCompiler(routeProvider: routes).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
        guard case .drive(let leg) = result.plan.segments[1].kind else { return XCTFail() }
        XCTAssertEqual(leg.profile.referenceSource, .travelModeDefault)
        XCTAssertNear(leg.profile.maxSpeed, TravelDefaults.driveSpeed, 0.01)
    }

    func testPostedLimitsFromProviderAreUsed() async throws {
        let routes = FakeRouteProvider()
        routes.straight = true
        routes.speedLimits = [SpeedLimitSpan(fromDistance: 0, toDistance: 6000, limit: 22)]
        let run = ScheduledRun(name: "L", actions: [RunAction(.setLocation(home)), RunAction(.driveTo(work, speed: nil))])
        let result = try await RunCompiler(routeProvider: routes).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
        guard case .drive(let leg) = result.plan.segments[1].kind else { return XCTFail() }
        XCTAssertEqual(leg.profile.referenceSource, .postedLimits)
        XCTAssertNear(leg.profile.maxSpeed, 22, 0.01)
    }

    func testCustomSpeedOverridesRunSpeedForOneLeg() async throws {
        let run = ScheduledRun(name: "S", actions: [
            RunAction(.setLocation(home)),
            RunAction(.setSpeed(.constant(10))),
            RunAction(.driveTo(work, speed: .constant(25))),
            RunAction(.driveTo(home, speed: nil)),
        ])
        let result = try await RunCompiler(routeProvider: FakeRouteProvider()).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
        guard case .drive(let custom) = result.plan.segments[2].kind,
              case .drive(let inherited) = result.plan.segments[3].kind else { return XCTFail() }
        XCTAssertTrue(custom.hasCustomSpeed)
        XCTAssertNear(custom.profile.maxSpeed, 25, 0.01)
        XCTAssertFalse(inherited.hasCustomSpeed)
        XCTAssertNear(inherited.profile.maxSpeed, 10, 0.01)
    }

    func testNoStartLocation() async {
        let run = ScheduledRun(name: "N", actions: [RunAction(.driveTo(work, speed: nil))])
        do {
            _ = try await RunCompiler(routeProvider: FakeRouteProvider()).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
            XCTFail()
        } catch let e as CompileError {
            XCTAssertEqual(e, .noStartLocation(actionID: run.actions[0].id))
        } catch { XCTFail("\(error)") }
    }

    func testUsesCurrentSpoofLocationWhenNoSetLocation() async throws {
        let run = ScheduledRun(name: "N", actions: [RunAction(.driveTo(work, speed: nil))])
        let result = try await RunCompiler(routeProvider: FakeRouteProvider()).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: home.point)
        guard case .drive(let leg) = result.plan.segments[0].kind else { return XCTFail() }
        XCTAssertNear(leg.profile.polyline.start, home.point, meters: 0.1)
    }

    func testRepeatsReuseRoutesAndAlternate() async throws {
        let routes = FakeRouteProvider()
        let run = ScheduledRun(name: "Loop", actions: [
            RunAction(.setLocation(home)),
            RunAction(.driveTo(work, speed: nil)),
            RunAction(.driveTo(home, speed: nil)),
            RunAction(.repeatPrevious(count: 2, times: 4)),
        ])
        let result = try await RunCompiler(routeProvider: routes).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
        XCTAssertEqual(result.plan.segments.count, 1 + 2 * 5)
        XCTAssertEqual(routes.calls, 2, "identical legs are routed once")
        XCTAssertNear(result.plan.totalDriveDistance, 10 * 7000, 300)
    }

    func testDriveToCurrentPlaceIsSkippedWithWarning() async throws {
        let run = ScheduledRun(name: "Same", actions: [RunAction(.setLocation(home)), RunAction(.driveTo(home, speed: nil))])
        let result = try await RunCompiler(routeProvider: FakeRouteProvider()).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
        XCTAssertEqual(result.plan.segments.count, 1)
        XCTAssertTrue(result.issues.contains { $0.message.contains("Already at") })
    }

    func testInvalidRunThrowsValidationIssues() async {
        let run = ScheduledRun(name: "Bad", actions: [])
        do {
            _ = try await RunCompiler(routeProvider: FakeRouteProvider()).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
            XCTFail()
        } catch let e as CompileError {
            guard case .invalid(let issues) = e else { return XCTFail() }
            XCTAssertTrue(issues.hasErrors)
        } catch { XCTFail() }
    }

    func testOfflineFallsBackToCachedRoute() async throws {
        let base = FakeRouteProvider()
        let dir = tempDirectory()
        let cache = RouteCache(fileURL: dir.appendingPathComponent("routes.json"))
        let provider = CachingRouteProvider(base: base, cache: cache)
        let run = ScheduledRun(name: "Cache", actions: [RunAction(.setLocation(home)), RunAction(.driveTo(work, speed: nil))])

        let online = try await RunCompiler(routeProvider: provider).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
        XCTAssertFalse(online.issues.contains { $0.message.contains("saved") })

        base.failWith = RouteProviderError.unavailable("offline")
        // Fresh cache object reading the persisted file = survives app restart.
        let reloaded = CachingRouteProvider(base: base, cache: RouteCache(fileURL: dir.appendingPathComponent("routes.json")))
        let offline = try await RunCompiler(routeProvider: reloaded).compile(run, anchorDate: Date(), startDate: Date(), currentLocation: nil)
        XCTAssertTrue(offline.issues.contains { $0.message.contains("saved") })
        guard case .drive(let leg) = offline.plan.segments[1].kind else { return XCTFail() }
        XCTAssertTrue(leg.routeFromCache)
    }

    // MARK: Start At time resolution

    func testResolveStartAtInTimeZone() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let anchor = date("2026-11-05T01:00:00Z") // 10:00 JST on Nov 5
        let t = RunCompiler.resolve(TimeOfDay(hour: 10, minute: 30), dayOffset: 0, anchor: anchor, calendar: cal)
        XCTAssertEqual(t, date("2026-11-05T01:30:00Z"))
        let next = RunCompiler.resolve(TimeOfDay(hour: 6, minute: 0), dayOffset: 1, anchor: anchor, calendar: cal)
        XCTAssertEqual(next, date("2026-11-05T21:00:00Z"))
    }

    func testResolveStartAtOnSpringForwardDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = newYork
        // 2026-03-08: clocks jump 02:00 → 03:00 EST→EDT; 02:30 doesn't exist.
        let anchor = date("2026-03-08T06:00:00Z") // 01:00 EST
        let t = RunCompiler.resolve(TimeOfDay(hour: 2, minute: 30), dayOffset: 0, anchor: anchor, calendar: cal)
        XCTAssertEqual(t, date("2026-03-08T07:00:00Z"), "falls forward to 03:00 EDT")
    }

    func testResolveStartAtOnFallBackDayUsesFirstOccurrence() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = newYork
        // 2026-11-01: 01:00–02:00 happens twice (EDT then EST).
        let anchor = date("2026-11-01T04:30:00Z") // 00:30 EDT
        let t = RunCompiler.resolve(TimeOfDay(hour: 1, minute: 30), dayOffset: 0, anchor: anchor, calendar: cal)
        XCTAssertEqual(t, date("2026-11-01T05:30:00Z"), "01:30 EDT, not 01:30 EST")
    }
}
