import XCTest
@testable import LocusSchedulingCore

final class ValidatorTests: XCTestCase {
    private func run(_ kinds: [RunActionKind], schedule: RunSchedule = .manual) -> ScheduledRun {
        ScheduledRun(name: "T", actions: kinds.map { RunAction($0) }, schedule: schedule)
    }

    func testEmptyRunIsAnError() {
        XCTAssertTrue(RunValidator.validate(run([])).hasErrors)
    }

    func testCommuteTemplateIsValid() {
        let r = ScheduledRun.commuteTemplate(home: home, work: work)
        let issues = RunValidator.validate(r)
        XCTAssertFalse(issues.hasErrors, "\(issues)")
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }

    func testWaitBounds() {
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .wait(seconds: 0)])).hasErrors)
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .wait(seconds: -3)])).hasErrors)
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .wait(seconds: 8.0 * 86400)])).hasErrors)
        XCTAssertFalse(RunValidator.validate(run([.setLocation(home), .wait(seconds: 60)])).hasErrors)
    }

    func testInvalidPlace() {
        let bad = PlaceRef(name: "?", point: GeoPoint(latitude: .nan, longitude: 0))
        XCTAssertTrue(RunValidator.validate(run([.setLocation(bad)])).hasErrors)
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .driveTo(bad, speed: nil)])).hasErrors)
    }

    func testStartAtMustNotGoBackwards() {
        let r = run([
            .startAt(TimeOfDay(hour: 10, minute: 30), dayOffset: 0),
            .setLocation(home),
            .startAt(TimeOfDay(hour: 10, minute: 15), dayOffset: 0),
        ])
        let issues = RunValidator.validate(r)
        XCTAssertTrue(issues.hasErrors)
        XCTAssertEqual(issues.first { $0.severity == .error }?.actionID, r.actions[2].id)

        // Next day is fine.
        let ok = run([
            .startAt(TimeOfDay(hour: 22, minute: 0), dayOffset: 0),
            .setLocation(home),
            .startAt(TimeOfDay(hour: 6, minute: 0), dayOffset: 1),
        ])
        XCTAssertFalse(RunValidator.validate(ok).hasErrors)
    }

    func testDriveWithoutKnownStartWarns() {
        let r = run([.driveTo(work, speed: nil)])
        let issues = RunValidator.validate(r)
        XCTAssertFalse(issues.hasErrors)
        XCTAssertEqual(issues.filter { $0.severity == .warning }.count, 1)
    }

    func testDriveAfterStopIsAnError() {
        let r = run([.setLocation(home), .stopSpoofing, .driveTo(work, speed: nil)])
        let issues = RunValidator.validate(r)
        XCTAssertTrue(issues.hasErrors)
        XCTAssertEqual(issues.first?.actionID, r.actions[2].id)
        XCTAssertFalse(RunValidator.validate(run([.setLocation(home), .stopSpoofing, .setLocation(home), .driveTo(work, speed: nil)])).hasErrors)
    }

    func testRepeatRules() {
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .repeatPrevious(count: 2, times: 1)])).hasErrors)
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .repeatPrevious(count: 0, times: 1)])).hasErrors)
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .repeatPrevious(count: 1, times: 0)])).hasErrors)
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .repeatPrevious(count: 1, times: 101)])).hasErrors)
        XCTAssertTrue(RunValidator.validate(run([
            .setLocation(home), .repeatPrevious(count: 1, times: 1), .repeatPrevious(count: 2, times: 1),
        ])).hasErrors, "nested repeat")
        let withStart = RunValidator.validate(run([
            .setLocation(home), .startAt(TimeOfDay(hour: 9, minute: 0), dayOffset: 0), .repeatPrevious(count: 2, times: 2),
        ]))
        XCTAssertFalse(withStart.hasErrors)
        XCTAssertTrue(withStart.contains { $0.severity == .warning })
    }

    func testExpansionLimit() {
        let r = run([
            .setLocation(home), .wait(seconds: 1), .setLocation(work), .wait(seconds: 1), .setLocation(home), .wait(seconds: 1),
            .repeatPrevious(count: 6, times: 100),
        ])
        XCTAssertTrue(RunValidator.validate(r).hasErrors)
    }

    func testScheduleValidation() {
        let now = date("2026-11-04T12:00:00Z")
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home)], schedule: .recurring(TimeOfDay(hour: 9, minute: 0), weekdays: [], timeZoneID: nil))).hasErrors)
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home)], schedule: .recurring(TimeOfDay(hour: 9, minute: 0), weekdays: [1], timeZoneID: "Mars/Olympus"))).hasErrors)
        let past = RunValidator.validate(run([.setLocation(home)], schedule: .once(now.addingTimeInterval(-60))), now: now)
        XCTAssertFalse(past.hasErrors)
        XCTAssertTrue(past.contains { $0.severity == .warning })
    }

    func testSpeedValidation() {
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .setSpeed(.constant(0))])).hasErrors)
        XCTAssertTrue(RunValidator.validate(run([.setLocation(home), .driveTo(work, speed: .constant(-1))])).hasErrors)
        var r = run([.setLocation(home)])
        r.defaultSpeed = .aboveLimit(-2)
        XCTAssertTrue(RunValidator.validate(r).hasErrors)
    }
}

final class ExpanderTests: XCTestCase {
    func testRepeatUnrollsPrecedingBlock() throws {
        let a = RunAction(.setLocation(home))
        let b = RunAction(.wait(seconds: 5))
        let r = RunAction(.repeatPrevious(count: 2, times: 3))
        let out = try RunExpander.expand([a, b, r])
        XCTAssertEqual(out.map(\.action.id), [a.id, b.id, a.id, b.id, a.id, b.id, a.id, b.id])
        XCTAssertEqual(out.map(\.iteration), [0, 0, 1, 1, 2, 2, 3, 3])
    }

    func testRepeatOnlyCoversItsCount() throws {
        let a = RunAction(.setLocation(home))
        let b = RunAction(.wait(seconds: 5))
        let c = RunAction(.repeatPrevious(count: 1, times: 2))
        let d = RunAction(.stopSpoofing)
        let out = try RunExpander.expand([a, b, c, d])
        XCTAssertEqual(out.map(\.action.id), [a.id, b.id, b.id, b.id, d.id])
    }

    func testInvalidRepeatThrows() {
        XCTAssertThrowsError(try RunExpander.expand([RunAction(.repeatPrevious(count: 1, times: 1))]))
    }
}

final class EditingTests: XCTestCase {
    private func ids(_ r: ScheduledRun) -> [UUID] { r.actions.map(\.id) }

    func testInsertDeleteDuplicate() {
        var r = ScheduledRun(name: "E")
        let a = RunAction(.setLocation(home))
        let b = RunAction(.wait(seconds: 60))
        r.insertAction(a)
        r.insertAction(b)
        r.insertAction(RunAction(.stopSpoofing), at: 99)
        XCTAssertEqual(r.actions.count, 3)

        let copy = r.duplicateAction(id: a.id)
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, a.id)
        XCTAssertEqual(r.actions[1].kind, a.kind, "duplicate goes right after the original")
        XCTAssertNil(r.duplicateAction(id: UUID()))

        r.deleteAction(id: a.id)
        XCTAssertEqual(r.actions.count, 3)
        XCTAssertFalse(ids(r).contains(a.id))
    }

    func testMoveMatchesSwiftUIOnMoveSemantics() {
        let acts = (0..<5).map { RunAction(.wait(seconds: Double($0 + 1))) }
        var r = ScheduledRun(name: "M", actions: acts)
        // Drag item 0 to the end.
        r.moveActions(fromOffsets: IndexSet(integer: 0), toOffset: 5)
        XCTAssertEqual(ids(r), [acts[1], acts[2], acts[3], acts[4], acts[0]].map(\.id))
        // Drag item 4 (acts[0]) to the top.
        r.moveActions(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        XCTAssertEqual(ids(r), acts.map(\.id))
        // Move two items down past one.
        r.moveActions(fromOffsets: IndexSet([0, 1]), toOffset: 3)
        XCTAssertEqual(ids(r), [acts[2], acts[0], acts[1], acts[3], acts[4]].map(\.id))
    }

    func testRunCodableRoundTrip() throws {
        var r = ScheduledRun.commuteTemplate(home: home, work: work)
        r.schedule = .recurring(TimeOfDay(hour: 7, minute: 45), weekdays: RunSchedule.weekdaysOnly, timeZoneID: "Europe/Warsaw")
        r.actions.append(RunAction(.repeatPrevious(count: 1, times: 2)))
        r.actions.append(RunAction(.driveTo(home, speed: .belowLimit(2))))
        r.actions.append(RunAction(.stopSpoofing))
        let data = try JSONEncoder().encode([r])
        let back = try JSONDecoder().decode([ScheduledRun].self, from: data)
        XCTAssertEqual(back, [r])
        XCTAssertEqual(back[0].timeZone.identifier, "Europe/Warsaw")
    }
}
