import XCTest
@testable import LocusSchedulingCore

final class SchedulerTests: XCTestCase {
    private func daily(_ h: Int, _ m: Int, days: Set<Int> = RunSchedule.everyDay, tz: String = "America/New_York") -> RunSchedule {
        .recurring(TimeOfDay(hour: h, minute: m), weekdays: days, timeZoneID: tz)
    }

    private func run(_ name: String, _ schedule: RunSchedule, created: Date, duration: Double? = nil, late: Double = 15 * 60) -> ScheduledRun {
        ScheduledRun(name: name, actions: [RunAction(.setLocation(home))], schedule: schedule,
                     latePolicy: LatePolicy(maxDelay: late), createdAt: created, estimatedDuration: duration)
    }

    func testManualHasNoOccurrences() {
        XCTAssertNil(RunScheduler.nextOccurrence(of: .manual, after: Date(), timeZone: newYork))
    }

    func testOnce() {
        let d = date("2026-11-05T15:00:00Z")
        XCTAssertEqual(RunScheduler.nextOccurrence(of: .once(d), after: d.addingTimeInterval(-1), timeZone: newYork), d)
        XCTAssertNil(RunScheduler.nextOccurrence(of: .once(d), after: d, timeZone: newYork))
    }

    func testDailyInTimeZone() {
        // 2026-11-04 is a Wednesday. 10:00 EST = 15:00Z.
        let s = daily(10, 0)
        XCTAssertEqual(RunScheduler.nextOccurrence(of: s, after: date("2026-11-04T14:00:00Z"), timeZone: newYork), date("2026-11-04T15:00:00Z"))
        XCTAssertEqual(RunScheduler.nextOccurrence(of: s, after: date("2026-11-04T15:00:00Z"), timeZone: newYork), date("2026-11-05T15:00:00Z"))
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(RunScheduler.nextOccurrence(of: daily(10, 0, tz: "Asia/Tokyo"), after: date("2026-11-04T14:00:00Z"), timeZone: tokyo),
                       date("2026-11-05T01:00:00Z"))
    }

    func testWeekdaysSkipWeekend() {
        // Friday 2026-11-06 after 10:00 → Monday 2026-11-09.
        let s = daily(10, 0, days: RunSchedule.weekdaysOnly)
        XCTAssertEqual(RunScheduler.nextOccurrence(of: s, after: date("2026-11-06T16:00:00Z"), timeZone: newYork), date("2026-11-09T15:00:00Z"))
    }

    func testDailyAcrossSpringForward() {
        // 02:30 doesn't exist on 2026-03-08 in New York → runs at 03:00 EDT that day.
        let s = daily(2, 30)
        let occ = RunScheduler.occurrences(of: s, after: date("2026-03-07T00:00:00Z"), through: date("2026-03-10T00:00:00Z"), timeZone: newYork)
        XCTAssertEqual(occ, [
            date("2026-03-07T07:30:00Z"), // 02:30 EST
            date("2026-03-08T07:00:00Z"), // 03:00 EDT (skipped hour)
            date("2026-03-09T06:30:00Z"), // 02:30 EDT
        ])
    }

    func testDailyAcrossFallBackRunsOnce() {
        let s = daily(1, 30)
        let occ = RunScheduler.occurrences(of: s, after: date("2026-10-31T00:00:00Z"), through: date("2026-11-03T00:00:00Z"), timeZone: newYork)
        XCTAssertEqual(occ, [
            date("2026-10-31T05:30:00Z"), // 01:30 EDT
            date("2026-11-01T05:30:00Z"), // first 01:30 (EDT) only
            date("2026-11-02T06:30:00Z"), // 01:30 EST
        ])
    }

    func testLocalTimeStaysFixedAcrossDST() {
        // A 10:00 run is 14:00Z in summer and 15:00Z in winter.
        let s = daily(10, 0)
        XCTAssertEqual(RunScheduler.nextOccurrence(of: s, after: date("2026-10-31T00:00:00Z"), timeZone: newYork), date("2026-10-31T14:00:00Z"))
        XCTAssertEqual(RunScheduler.nextOccurrence(of: s, after: date("2026-11-02T00:00:00Z"), timeZone: newYork), date("2026-11-02T15:00:00Z"))
    }

    func testEvaluateStartsDueRun() {
        let r = run("A", daily(10, 0), created: date("2026-11-01T00:00:00Z"))
        var handled = r
        handled.lastHandledOccurrence = date("2026-11-04T00:00:00Z")
        let d = RunScheduler.evaluate(runs: [handled], now: date("2026-11-04T15:00:02Z"), activeRun: nil)
        XCTAssertEqual(d, [.start(runID: r.id, occurrence: date("2026-11-04T15:00:00Z"), lateBy: 2)])
        XCTAssertTrue(RunScheduler.evaluate(runs: [handled], now: date("2026-11-04T14:59:59Z"), activeRun: nil).isEmpty)
    }

    func testEvaluateStartsLateWithinWindowAndMissesBeyond() {
        var r = run("A", daily(10, 0), created: date("2026-11-01T00:00:00Z"), late: 600)
        r.lastHandledOccurrence = date("2026-11-04T00:00:00Z")
        let within = RunScheduler.evaluate(runs: [r], now: date("2026-11-04T15:09:00Z"), activeRun: nil)
        guard case .start(_, _, let late) = within.first else { return XCTFail("\(within)") }
        XCTAssertEqual(late, 540)

        let beyond = RunScheduler.evaluate(runs: [r], now: date("2026-11-04T15:11:00Z"), activeRun: nil)
        guard case .missed(_, _, .tooLate) = beyond.first else { return XCTFail("\(beyond)") }

        var skip = r
        skip.latePolicy.maxDelay = 0
        let strict = RunScheduler.evaluate(runs: [skip], now: date("2026-11-04T15:00:30Z"), activeRun: nil)
        guard case .missed = strict.first else { return XCTFail("\(strict)") }
    }

    func testEvaluateReportsEveryMissedDayAfterLongOutage() {
        var r = run("A", daily(10, 0), created: date("2026-11-01T00:00:00Z"))
        r.lastHandledOccurrence = date("2026-11-01T15:00:00Z")
        let d = RunScheduler.evaluate(runs: [r], now: date("2026-11-04T15:05:00Z"), activeRun: nil)
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual(d.filter { if case .missed = $0 { return true } else { return false } }.count, 2)
        XCTAssertEqual(d.last, .start(runID: r.id, occurrence: date("2026-11-04T15:00:00Z"), lateBy: 300))
    }

    func testDisabledAndManualRunsAreIgnored() {
        var off = run("off", daily(10, 0), created: date("2026-11-01T00:00:00Z"))
        off.isEnabled = false
        let manual = run("m", .manual, created: date("2026-11-01T00:00:00Z"))
        XCTAssertTrue(RunScheduler.evaluate(runs: [off, manual], now: date("2026-11-04T15:00:00Z"), activeRun: nil).isEmpty)
    }

    func testConflicts() {
        var a = run("A", daily(10, 0), created: date("2026-11-01T00:00:00Z"))
        var b = run("B", daily(10, 0), created: date("2026-11-02T00:00:00Z"))
        a.lastHandledOccurrence = date("2026-11-04T00:00:00Z")
        b.lastHandledOccurrence = date("2026-11-04T00:00:00Z")
        let now = date("2026-11-04T15:00:00Z")
        let d = RunScheduler.evaluate(runs: [b, a], now: now, activeRun: nil)
        XCTAssertTrue(d.contains(.start(runID: a.id, occurrence: now, lateBy: 0)), "earlier-created run wins ties")
        XCTAssertTrue(d.contains(.missed(runID: b.id, occurrence: now, reason: .conflict(with: "A"))))

        let busy = RunScheduler.evaluate(runs: [a], now: now, activeRun: (UUID(), "Manual"))
        XCTAssertEqual(busy, [.missed(runID: a.id, occurrence: now, reason: .conflict(with: "Manual"))])
    }

    func testNextWake() {
        var a = run("A", daily(10, 0), created: date("2026-11-01T00:00:00Z"))
        a.lastHandledOccurrence = date("2026-11-04T15:00:00Z")
        let b = run("B", .once(date("2026-11-04T18:00:00Z")), created: date("2026-11-01T00:00:00Z"))
        let w = RunScheduler.nextWake(runs: [a, b], now: date("2026-11-04T15:00:01Z"))
        XCTAssertEqual(w?.runID, b.id)
        XCTAssertEqual(w?.date, date("2026-11-04T18:00:00Z"))
    }

    func testOverlapDetection() {
        let now = date("2026-11-04T12:00:00Z")
        let a = run("Commute", daily(10, 0), created: now, duration: 40 * 60)
        let b = run("Errand", daily(10, 30), created: now, duration: 10 * 60)
        let c = run("Evening", daily(18, 0), created: now, duration: 30 * 60)
        let overlaps = RunScheduler.overlaps(of: a, with: [a, b, c], now: now)
        XCTAssertEqual(overlaps.map(\.otherName), ["Errand"])
        XCTAssertEqual(overlaps.first?.at, date("2026-11-04T15:30:00Z"), "10:30 EST today, while Commute (10:00–10:40) runs")

        var shortA = a
        shortA.estimatedDuration = 20 * 60
        XCTAssertTrue(RunScheduler.overlaps(of: shortA, with: [b, c], now: now).isEmpty)

        var disabled = b
        disabled.isEnabled = false
        XCTAssertTrue(RunScheduler.overlaps(of: a, with: [disabled], now: now).isEmpty)
    }
}
