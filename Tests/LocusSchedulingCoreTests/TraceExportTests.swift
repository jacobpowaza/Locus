import XCTest
@testable import LocusSchedulingCore

/// Writes a 1 Hz trace of a full scheduled commute (through the coordinator,
/// executor and sink) as CSV when LOCUS_TRACE_DIR is set, for plotting /
/// eyeballing realism. Always asserts basic physical sanity.
@MainActor
final class TraceExportTests: XCTestCase {
    func testCommuteTrace() async throws {
        let clock = FakeClock(date("2026-11-04T14:59:59Z"))
        let routes = FakeRouteProvider()
        // A route with a 90° corner and a gentle bend.
        routes.override = { a, b in
            let c1 = offset(a, east: 1500)
            let c2 = offset(c1, east: 400, north: 300)
            return [a, c1, c2, offset(c2, north: 1500), b]
        }
        routes.speedLimits = [
            SpeedLimitSpan(fromDistance: 0, toDistance: 1500, limit: SpeedUnit.mph.toMetersPerSecond(25)),
            SpeedLimitSpan(fromDistance: 1500, toDistance: 20_000, limit: SpeedUnit.mph.toMetersPerSecond(45)),
        ]
        let sink = RecordingSink()
        let dir = tempDirectory()
        let c = RunCoordinator(store: ScheduledRunStore(directory: dir), routeProvider: routes, clock: clock, sink: sink, notifier: nil)
        c.load()
        let dest = PlaceRef(name: "Work", point: offset(sf, east: 1900, north: 1800))
        let run = ScheduledRun(name: "Trace", actions: [
            RunAction(.setLocation(home)),
            RunAction(.wait(seconds: 30)),
            RunAction(.setSpeed(.aboveLimit(SpeedUnit.mph.toMetersPerSecond(5)))),
            RunAction(.driveTo(dest, speed: nil)),
        ], schedule: .recurring(TimeOfDay(hour: 10, minute: 0), weekdays: RunSchedule.everyDay, timeZoneID: "America/New_York"),
           createdAt: clock.now.addingTimeInterval(-60))
        c.upsert(run)

        var rows = ["t,lat,lon,speed_mps,ref_mps,segment"]
        var t0: Date?
        for _ in 0..<2000 {
            clock.advance(1)
            await c.tick()
            guard let s = c.snapshot() else { if t0 != nil { break } else { continue } }
            if t0 == nil { t0 = clock.now }
            if let p = s.position {
                rows.append(String(format: "%.0f,%.7f,%.7f,%.3f,%.3f,%d",
                                   clock.now.timeIntervalSince(t0!), p.latitude, p.longitude, s.speed, s.referenceSpeed ?? 0, s.segmentIndex))
            }
            XCTAssertLessThanOrEqual(s.speed, SpeedUnit.mph.toMetersPerSecond(50) + 0.01, "never above 45+5 mph")
        }
        XCTAssertEqual(c.history.first?.outcome, .completed)
        XCTAssertNear(sink.last, dest.point, meters: 1)
        if let out = ProcessInfo.processInfo.environment["LOCUS_TRACE_DIR"] {
            try rows.joined(separator: "\n").write(toFile: out + "/commute-trace.csv", atomically: true, encoding: .utf8)
        }
    }
}
