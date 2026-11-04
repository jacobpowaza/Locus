import XCTest
@testable import LocusSchedulingCore

final class ExecutorTests: XCTestCase {
    private var clock: FakeClock!
    private var sink: RecordingSink!

    override func setUp() {
        clock = FakeClock(date("2026-11-04T15:00:00Z"))
        sink = RecordingSink()
    }

    private func compile(_ actions: [RunActionKind], schedule: RunSchedule = .manual) async throws -> (ScheduledRun, RunPlan) {
        let run = ScheduledRun(name: "Exec", actions: actions.map { RunAction($0) }, schedule: schedule)
        let r = try await RunCompiler(routeProvider: FakeRouteProvider()).compile(run, anchorDate: clock.now, startDate: clock.now, currentLocation: nil)
        return (run, r.plan)
    }

    private func start(_ run: ScheduledRun, _ plan: RunPlan) -> RunExecutor {
        RunExecutor.start(plan: plan, run: run, trigger: .manual, occurrence: nil, wallNow: clock.now, monotonic: clock.monotonic, sink: sink)
    }

    private func tick(_ ex: RunExecutor, seconds: Double, step: Double = 1) {
        var t = 0.0
        while t < seconds {
            clock.advance(step)
            ex.advance(wallNow: clock.now, monotonic: clock.monotonic)
            t += step
        }
    }

    func testFullRunOrderAndCompletion() async throws {
        let (run, plan) = try await compile([.setLocation(home), .wait(seconds: 60), .driveTo(work, speed: .constant(20)), .wait(seconds: 30), .stopSpoofing])
        let ex = start(run, plan)
        XCTAssertEqual(sink.calls.first, .set(home.point))
        tick(ex, seconds: 59)
        XCTAssertEqual(sink.positions.count, 1, "no resends while holding")
        XCTAssertEqual(ex.state.index, 1)

        guard case .drive(let leg) = plan.segments[2].kind else { return XCTFail() }
        tick(ex, seconds: 1 + leg.profile.duration + 31)
        XCTAssertEqual(ex.state.status, .completed)
        XCTAssertEqual(sink.calls.last, .stop)
        XCTAssertNear(sink.positions.last, work.point, meters: 1)

        // Simulated distance accounted.
        XCTAssertNear(ex.state.distanceBanked, leg.profile.distance, 1)
        XCTAssertNear(ex.state.activeElapsed, 60 + leg.profile.duration + 30, 1.5)
        XCTAssertTrue(ex.state.log.contains { $0.message.contains("Arrived at Work") })
        XCTAssertTrue(ex.state.log.contains { $0.message == "Run completed." })
    }

    func testDriveEmitsSmoothlySpacedPositions() async throws {
        let (run, plan) = try await compile([.setLocation(home), .driveTo(work, speed: .constant(20))])
        let ex = start(run, plan)
        guard case .drive(let leg) = plan.segments[1].kind else { return XCTFail() }
        tick(ex, seconds: leg.profile.duration + 2)
        let pts = sink.positions
        XCTAssertGreaterThan(pts.count, Int(leg.profile.duration) - 2)
        for (a, b) in zip(pts, pts.dropFirst()) {
            XCTAssertLessThanOrEqual(Geo.distance(a, b), 20.5, "1 s ticks at ≤ 20 m/s")
        }
        XCTAssertEqual(ex.state.status, .completed)
        XCTAssertEqual(sink.speeds.max() ?? 0, 20, accuracy: 0.01)
    }

    func testPauseFreezesAndResumeRestartsFromStandstill() async throws {
        let (run, plan) = try await compile([.setLocation(home), .driveTo(work, speed: .constant(20))])
        let ex = start(run, plan)
        tick(ex, seconds: 60)
        let before = ex.snapshot(wallNow: clock.now)
        XCTAssertGreaterThan(before.speed, 5)
        ex.pause(wallNow: clock.now)
        let frozen = ex.desiredPosition?.point
        tick(ex, seconds: 120)
        XCTAssertEqual(ex.desiredPosition?.point, frozen)
        XCTAssertEqual(ex.snapshot(wallNow: clock.now).speed, 0)
        XCTAssertEqual(ex.state.status, .paused)

        ex.resume(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertEqual(ex.state.status, .running)
        tick(ex, seconds: 1)
        let after = ex.snapshot(wallNow: clock.now)
        XCTAssertLessThan(after.speed, 3, "accelerates again from a stop")
        XCTAssertNear(after.distanceDriven, before.distanceDriven, 5)
        tick(ex, seconds: 1000)
        XCTAssertEqual(ex.state.status, .completed)
        XCTAssertNear(ex.state.distanceBanked, plan.totalDriveDistance, 2)
    }

    func testSkipDriveJumpsToDestination() async throws {
        let (run, plan) = try await compile([.setLocation(home), .driveTo(work, speed: nil), .wait(seconds: 600)])
        let ex = start(run, plan)
        tick(ex, seconds: 10)
        ex.skip(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertNear(sink.last, work.point, meters: 1)
        XCTAssertEqual(ex.state.index, 2)
        ex.skip(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertEqual(ex.state.status, .completed)
    }

    func testCancelOptionallyStopsSpoofing() async throws {
        let (run, plan) = try await compile([.setLocation(home), .wait(seconds: 600)])
        let a = start(run, plan)
        a.cancel(stopSpoofing: false, wallNow: clock.now)
        XCTAssertEqual(a.state.status, .cancelled)
        XCTAssertFalse(sink.calls.contains(.stop))
        let b = start(run, plan)
        b.cancel(stopSpoofing: true, wallNow: clock.now)
        XCTAssertEqual(sink.calls.last, .stop)
    }

    func testLiveSpeedChangeUpdatesETA() async throws {
        let (run, plan) = try await compile([.setLocation(home), .driveTo(work, speed: nil), .driveTo(home, speed: .constant(5)), .driveTo(work, speed: nil)])
        let ex = start(run, plan)
        tick(ex, seconds: 30)
        let eta1 = ex.snapshot(wallNow: clock.now).runEnd
        ex.changeSpeed(to: .constant(30), wallNow: clock.now)
        let eta2 = ex.snapshot(wallNow: clock.now).runEnd
        XCTAssertLessThan(eta2, eta1.addingTimeInterval(-60))
        // Custom-speed leg untouched.
        guard case .drive(let custom) = ex.state.plan.segments[2].kind,
              case .drive(let last) = ex.state.plan.segments[3].kind else { return XCTFail() }
        XCTAssertNear(custom.profile.maxSpeed, 5, 0.01)
        XCTAssertNear(last.profile.maxSpeed, 30, 0.01)
        // Continuity: no jump at the moment of change.
        let p1 = sink.last!
        tick(ex, seconds: 1)
        XCTAssertLessThan(Geo.distance(p1, sink.last!), 25)
    }

    func testStartAtWaitsForWallClockAndHonoursClockChanges() async throws {
        // 10:00 EST now; wait until 10:30.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let target = clock.now.addingTimeInterval(1800)
        let comps = cal.dateComponents([.hour, .minute], from: target)
        let (run, plan) = try await compile([.setLocation(home), .startAt(TimeOfDay(hour: comps.hour!, minute: comps.minute!), dayOffset: 0), .setLocation(work)])
        let ex = start(run, plan)
        tick(ex, seconds: 600, step: 15)
        XCTAssertEqual(ex.state.index, 1)
        // User sets the clock forward 25 minutes: Start At uses the wall clock.
        clock.jumpWall(1500)
        ex.advance(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertEqual(ex.state.status, .completed)
        XCTAssertNear(sink.last, work.point, meters: 0.1)
    }

    func testWaitUsesMonotonicTimeNotWallClock() async throws {
        let (run, plan) = try await compile([.setLocation(home), .wait(seconds: 600), .setLocation(work)])
        let ex = start(run, plan)
        clock.jumpWall(3600) // clock change, no real time passed
        ex.advance(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertEqual(ex.state.index, 1, "a wall-clock jump must not finish a Wait")
        tick(ex, seconds: 600)
        XCTAssertEqual(ex.state.status, .completed)
    }

    func testCatchUpAfterSuspension() async throws {
        let (run, plan) = try await compile([.setLocation(home), .driveTo(work, speed: .constant(20))])
        let ex = start(run, plan)
        tick(ex, seconds: 10)
        // App suspended 100 s (monotonic includes sleep).
        clock.advance(100)
        ex.advance(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertTrue(ex.state.log.contains { $0.message.contains("Caught up") })
        XCTAssertNear(ex.state.elapsedInSegment, 110, 0.01)
    }

    func testNormalWaitTicksAreNotReportedAsSuspension() async throws {
        let (run, plan) = try await compile([.setLocation(home), .wait(seconds: 600)])
        let ex = start(run, plan)
        // During waits the app ticks at most every 15 s (nextWakeDelay).
        XCTAssertLessThanOrEqual(ex.nextWakeDelay(wallNow: clock.now), 15)
        tick(ex, seconds: 60, step: 15.5)
        XCTAssertFalse(ex.state.log.contains { $0.message.contains("Caught up") })
    }

    func testSinkFailurePausesAfterGraceAndRecovers() async throws {
        let (run, plan) = try await compile([.setLocation(home), .driveTo(work, speed: nil)])
        let ex = start(run, plan)
        sink.failing = true
        tick(ex, seconds: 10)
        XCTAssertEqual(ex.state.status, .running)
        XCTAssertTrue(ex.snapshot(wallNow: clock.now).connectionProblem)
        tick(ex, seconds: 25)
        XCTAssertEqual(ex.state.status, .paused)
        XCTAssertTrue(ex.state.pauseReason?.contains("LocalDevVPN") == true)
        sink.failing = false
        ex.resume(wallNow: clock.now, monotonic: clock.monotonic)
        tick(ex, seconds: 2)
        XCTAssertFalse(ex.snapshot(wallNow: clock.now).connectionProblem)
    }

    func testRecoveryAfterRestartCatchesUpAndPauses() async throws {
        let (run, plan) = try await compile([.setLocation(home), .driveTo(work, speed: .constant(20)), .wait(seconds: 3600)])
        let ex = start(run, plan)
        tick(ex, seconds: 30)
        // Persist checkpoint, "kill" the app, relaunch 120 s later.
        let data = try JSONEncoder().encode(ex.state)
        let restored = try JSONDecoder().decode(ExecutionState.self, from: data)
        XCTAssertEqual(restored, ex.state)
        clock.advance(120)
        let fresh = RecordingSink()
        let ex2 = RunExecutor(state: restored, sink: fresh)
        ex2.recoverAfterRestart(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertEqual(ex2.state.status, .paused)
        XCTAssertNear(ex2.state.elapsedInSegment, 150, 0.01)
        XCTAssertTrue(fresh.calls.isEmpty, "doesn't spoof until the user resumes")
        ex2.resume(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertEqual(fresh.calls.count, 1)
    }

    func testRecoveryWhenRunFinishedWhileClosed() async throws {
        let (run, plan) = try await compile([.setLocation(home), .wait(seconds: 60)])
        let ex = start(run, plan)
        clock.advance(3600)
        let ex2 = RunExecutor(state: ex.state, sink: sink)
        ex2.recoverAfterRestart(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertEqual(ex2.state.status, .completed)
    }

    func testRecoveryWithClockMovedBackwardsDoesNotRewind() async throws {
        let (run, plan) = try await compile([.setLocation(home), .wait(seconds: 600)])
        let ex = start(run, plan)
        tick(ex, seconds: 100)
        clock.jumpWall(-7200)
        let ex2 = RunExecutor(state: ex.state, sink: sink)
        ex2.recoverAfterRestart(wallNow: clock.now, monotonic: clock.monotonic)
        XCTAssertNear(ex2.state.elapsedInSegment, 100, 0.01)
    }

    func testSnapshotFigures() async throws {
        let (run, plan) = try await compile([.setLocation(home), .driveTo(work, speed: .constant(20)), .wait(seconds: 300)])
        let ex = start(run, plan)
        tick(ex, seconds: 100)
        let s = ex.snapshot(wallNow: clock.now)
        XCTAssertEqual(s.status, .running)
        XCTAssertEqual(s.segmentIndex, 1)
        XCTAssertNear(s.speed, 20, 0.5)
        XCTAssertEqual(s.referenceSource, .routeAverage)
        XCTAssertNotNil(s.legArrival)
        XCTAssertNear(s.distanceDriven + s.distanceRemaining, plan.totalDriveDistance, 1)
        XCTAssertNear(s.runEnd.timeIntervalSince(s.legArrival!), 300, 0.5)
        XCTAssertNear(s.activeElapsed, 100, 0.5)
    }

    func testWakeDelays() async throws {
        let (run, plan) = try await compile([.setLocation(home), .wait(seconds: 100), .driveTo(work, speed: nil)])
        let ex = start(run, plan)
        XCTAssertEqual(ex.nextWakeDelay(wallNow: clock.now), 15)
        tick(ex, seconds: 95)
        XCTAssertNear(ex.nextWakeDelay(wallNow: clock.now), 5, 0.01)
        tick(ex, seconds: 6)
        XCTAssertEqual(ex.nextWakeDelay(wallNow: clock.now), 1)
        ex.pause(wallNow: clock.now)
        XCTAssertEqual(ex.nextWakeDelay(wallNow: clock.now), 30)
    }

    func testLogIsCapped() async throws {
        let (run, plan) = try await compile([.setLocation(home), .setLocation(work), .repeatPrevious(count: 2, times: 100)])
        let ex = start(run, plan)
        XCTAssertEqual(ex.state.status, .completed)
        XCTAssertLessThanOrEqual(ex.state.log.count, ExecutionState.maxLogEntries)
    }
}
