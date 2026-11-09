import XCTest
@testable import LocusSchedulingCore

/// End-to-end Scheduled Runs lifecycle through `RunCoordinator`, with a real
/// on-disk store and fake clock / routing / location sink / notifications.
@MainActor
final class CoordinatorIntegrationTests: XCTestCase {
    private var dir: URL!
    private var clock: FakeClock!
    private var routes: FakeRouteProvider!
    private var sink: RecordingSink!
    private var notifier: FakeNotifier!

    override func setUp() async throws {
        dir = tempDirectory()
        clock = FakeClock(date("2026-11-04T14:58:00Z")) // 09:58 EST, Wednesday
        routes = FakeRouteProvider()
        sink = RecordingSink()
        notifier = FakeNotifier()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeCoordinator() -> RunCoordinator {
        let c = RunCoordinator(store: ScheduledRunStore(directory: dir), routeProvider: routes, clock: clock, sink: sink, notifier: notifier)
        c.load()
        return c
    }

    private func commute(at h: Int = 10, _ m: Int = 0) -> ScheduledRun {
        var r = ScheduledRun.commuteTemplate(home: home, work: work, now: clock.now)
        r.actions.removeAll { if case .startAt = $0.kind { return true } else { return false } }
        // 10:00 Set Home · wait 15 min · drive to Work (speed-limit aware) · stay.
        r.schedule = .recurring(TimeOfDay(hour: h, minute: m), weekdays: RunSchedule.everyDay, timeZoneID: "America/New_York")
        return r
    }

    /// Ticks like the app timer: at the coordinator's requested cadence.
    private func run(_ c: RunCoordinator, for seconds: Double) async {
        var elapsed = 0.0
        while elapsed < seconds {
            let step = min(c.nextWakeDelay(), seconds - elapsed)
            clock.advance(step)
            elapsed += step
            await c.tick()
        }
    }

    func testOneOffDriveRunsWithoutBeingSavedAndStopsAtLights() async throws {
        let c = makeCoordinator()
        var drive = ScheduledRun(name: "Drive to Work", actions: [
            RunAction(.setLocation(home)),
            RunAction(.driveTo(work, speed: nil)),
        ])
        drive.motion.realism = DriveRealism(redLights: true, maxRedLightWait: 30, stopSigns: true, varySpeed: true)

        let error = await c.startOneOff(drive)
        XCTAssertNil(error)
        XCTAssertTrue(c.runs.isEmpty, "one-off drives aren't added to the runs list")
        XCTAssertNotNil(c.executor)

        // A second one can't start on top of it.
        let second = await c.startOneOff(drive)
        XCTAssertNotNil(second)

        // Somewhere along the way the car stands still at a light or sign.
        var sawStop = false
        for _ in 0..<4000 {
            await run(c, for: 1)
            if c.snapshot()?.stoppedFor != nil {
                sawStop = true
                XCTAssertEqual(c.snapshot()?.speed, 0)
            }
            if c.executor == nil || c.executor?.state.status.isFinished == true { break }
        }
        XCTAssertTrue(sawStop)
        XCTAssertEqual(c.history.first?.outcome, .completed)
        XCTAssertEqual(c.history.first?.runName, "Drive to Work")
    }

    func testScheduledRunFullLifecycle() async throws {
        let c = makeCoordinator()
        let r = commute()
        c.upsert(r)

        // Reminder armed for 10:01 (fires only if Locus isn't running then).
        XCTAssertEqual(notifier.reminders[r.id], date("2026-11-04T15:01:00Z"))

        await run(c, for: 119) // to 09:59:59
        XCTAssertNil(c.executor)

        await run(c, for: 1) // 10:00:00
        let ex = try XCTUnwrap(c.executor)
        XCTAssertEqual(ex.state.trigger, .scheduled)
        XCTAssertEqual(ex.state.occurrence, date("2026-11-04T15:00:00Z"))
        XCTAssertEqual(sink.calls.first, .set(home.point))
        XCTAssertEqual(notifier.reminders[r.id], date("2026-11-05T15:01:00Z"), "rescheduled to tomorrow")

        // Checkpoint exists while active.
        XCTAssertNotNil(ScheduledRunStore(directory: dir).loadCheckpoint())

        await run(c, for: 15 * 60 + 1)
        let s = try XCTUnwrap(c.snapshot())
        XCTAssertEqual(s.segment.map { if case .drive = $0.kind { return true } else { return false } }, true)
        XCTAssertGreaterThan(s.speed, 0)
        XCTAssertEqual(s.referenceSource, .routeAverage)

        await run(c, for: 3600)
        XCTAssertNil(c.executor)
        let rec = try XCTUnwrap(c.history.first)
        XCTAssertEqual(rec.outcome, .completed)
        XCTAssertNear(rec.distance, 7000, 40)
        XCTAssertNear(sink.last, work.point, meters: 1)
        XCTAssertFalse(sink.calls.contains(.stop), "arrives and stays at Work")
        XCTAssertNil(ScheduledRunStore(directory: dir).loadCheckpoint(), "checkpoint cleared")
        XCTAssertEqual(c.lastFinished?.id, rec.id)

        // Persisted.
        let c2 = makeCoordinator()
        XCTAssertEqual(c2.history.first?.id, rec.id)
        XCTAssertEqual(c2.runs.first?.lastHandledOccurrence, date("2026-11-04T15:00:00Z"))

        // Doesn't run the same occurrence twice.
        await c2.tick()
        XCTAssertNil(c2.executor)
    }

    func testAppRestartMidRunRecoversPausedThenCompletes() async throws {
        let c = makeCoordinator()
        let r = commute()
        c.upsert(r)
        await run(c, for: 120 + 15 * 60 + 60) // a minute into the drive
        let before = try XCTUnwrap(c.snapshot())
        XCTAssertEqual(before.status, .running)

        // Kill the process; relaunch 2 minutes later.
        clock.advance(120)
        sink = RecordingSink()
        let c2 = makeCoordinator()
        let s = try XCTUnwrap(c2.snapshot())
        XCTAssertEqual(s.status, .paused)
        XCTAssertTrue(s.pauseReason?.contains("closed") == true)
        XCTAssertLessThanOrEqual(s.distanceDriven, before.distanceDriven, "resume from confirmed progress")
        XCTAssertTrue(sink.calls.isEmpty)

        c2.resume()
        XCTAssertEqual(sink.calls.count, 1)
        await run(c2, for: 3600)
        XCTAssertEqual(c2.history.first?.outcome, .completed)
        XCTAssertTrue(c2.history.first!.log.contains { $0.message.contains("Recovered") })
    }

    func testMissedWhileAppWasClosedIsRecorded() async throws {
        let c = makeCoordinator()
        var r = commute()
        r.latePolicy.maxDelay = 5 * 60
        c.upsert(r)

        // Locus not running at 10:00; opened at 10:30.
        clock.advance(32 * 60)
        let c2 = makeCoordinator()
        await c2.tick()
        XCTAssertNil(c2.executor)
        let rec = try XCTUnwrap(c2.history.first)
        XCTAssertEqual(rec.outcome, .missed)
        XCTAssertTrue(rec.message!.contains("wasn't running"))
        XCTAssertEqual(notifier.reminders[r.id], date("2026-11-05T15:01:00Z"))
    }

    func testLateStartWithinWindowRunsAndLogsLateness() async throws {
        let c = makeCoordinator()
        c.upsert(commute())
        clock.advance(10 * 60) // opened at 10:08
        let c2 = makeCoordinator()
        await c2.tick()
        XCTAssertNotNil(c2.executor)
        XCTAssertEqual(c2.executor?.state.occurrence, date("2026-11-04T15:00:00Z"))
    }

    func testConflictingRunIsSkippedAndUserNotified() async throws {
        let c = makeCoordinator()
        let a = commute()
        var b = commute(at: 10, 5)
        b.name = "Errand"
        c.upsert(a)
        c.upsert(b)

        let preview = await c.preview(a)
        XCTAssertTrue(preview.issues.contains { $0.message.contains("Overlaps \"Errand\"") }, "\(preview.issues)")

        await run(c, for: 8 * 60)
        XCTAssertEqual(c.executor?.state.runID, a.id)
        let skipped = try XCTUnwrap(c.history.first { $0.runID == b.id })
        XCTAssertEqual(skipped.outcome, .missed)
        XCTAssertTrue(skipped.message!.contains("Morning Commute"))
        XCTAssertTrue(notifier.posted.contains { $0.title.contains("Errand") })
    }

    func testRouteFailureRecordsFailedRunAndNotifies() async throws {
        routes.failWith = RouteProviderError.unavailable("No network.")
        let c = makeCoordinator()
        c.upsert(commute())
        await run(c, for: 125)
        XCTAssertNil(c.executor)
        let rec = try XCTUnwrap(c.history.first)
        XCTAssertEqual(rec.outcome, .failed)
        XCTAssertTrue(rec.message!.contains("No network"))
        XCTAssertTrue(notifier.posted.contains { $0.title.contains("couldn't start") })
    }

    func testManualStartPreviewAndControls() async throws {
        let c = makeCoordinator()
        var r = commute()
        r.schedule = .manual
        c.upsert(r)
        let preview = await c.preview(r)
        XCTAssertTrue(preview.canRun)
        XCTAssertNotNil(preview.estimatedDuration)
        XCTAssertEqual(c.run(id: r.id)?.estimatedDuration, preview.estimatedDuration, "cached for overlap checks")

        let err = await c.startNow(runID: r.id)
        XCTAssertNil(err)
        let again = await c.startNow(runID: r.id)
        XCTAssertNotNil(again, "only one run at a time")

        c.manualOverride("teleport")
        XCTAssertEqual(c.snapshot()?.status, .paused)
        c.resume()
        c.skip() // skip wait
        c.changeSpeed(.constant(30))
        await run(c, for: 60)
        XCTAssertGreaterThan(c.snapshot()!.speed, 10)
        c.cancel(stopSpoofing: true)
        XCTAssertEqual(c.history.first?.outcome, .cancelled)
        XCTAssertEqual(sink.calls.last, .stop)
    }

    func testCorruptStoreIsSetAsideNotLost() async throws {
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("runs.json"))
        let c = makeCoordinator()
        XCTAssertTrue(c.runs.isEmpty)
        XCTAssertFalse(c.storageProblems.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("runs.json.corrupt-") })
        c.upsert(commute())
        XCTAssertEqual(makeCoordinator().runs.count, 1)
    }

    func testEditingScheduleDoesNotFirePastOccurrences() async throws {
        clock = FakeClock(date("2026-11-04T15:05:00Z")) // 10:05
        let c = makeCoordinator()
        c.upsert(commute(at: 10, 0)) // already 5 min past, within late window
        await c.tick()
        XCTAssertNil(c.executor, "creating a run doesn't retro-fire today's 10:00")
    }

    func testDuplicateAndDelete() async throws {
        let c = makeCoordinator()
        let r = commute()
        c.upsert(r)
        let copy = try XCTUnwrap(c.duplicate(id: r.id))
        XCTAssertFalse(copy.isEnabled)
        XCTAssertNotEqual(copy.actions.first?.id, r.actions.first?.id)
        c.delete(id: r.id)
        XCTAssertEqual(c.runs.map(\.id), [copy.id])
        XCTAssertNil(notifier.reminders[r.id])
    }

    func testOnceScheduleRunsOnceOnly() async throws {
        let c = makeCoordinator()
        var r = commute()
        r.schedule = .once(date("2026-11-04T15:00:00Z"))
        c.upsert(r)
        await run(c, for: 120)
        XCTAssertNotNil(c.executor)
        c.cancel(stopSpoofing: false)
        clock.advance(86400)
        await c.tick()
        XCTAssertNil(c.executor)
        XCTAssertNil(notifier.reminders[r.id])
    }

    func testDiagnosticsReportContainsHistoryAndNotes() async throws {
        let c = makeCoordinator()
        c.upsert(commute())
        await run(c, for: 130)
        let report = c.diagnosticsReport(platformNotes: ["Background: best effort"])
        XCTAssertTrue(report.contains("Morning Commute"))
        XCTAssertTrue(report.contains("Active:"))
        XCTAssertTrue(report.contains("Background: best effort"))
    }
}
