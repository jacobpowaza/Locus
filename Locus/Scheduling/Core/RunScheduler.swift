import Foundation

/// Pure schedule math: occurrences, due/missed decisions, overlap checks.
/// All functions take `now` explicitly so they're deterministic in tests.
enum RunScheduler {
    static func calendar(timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// First occurrence strictly after `date`.
    static func nextOccurrence(of schedule: RunSchedule, after date: Date, timeZone: TimeZone) -> Date? {
        switch schedule {
        case .manual:
            return nil
        case .once(let d):
            return d > date ? d : nil
        case .recurring(let time, let weekdays, _):
            let cal = calendar(timeZone: timeZone)
            var best: Date?
            for wd in weekdays where (1...7).contains(wd) {
                let comps = DateComponents(hour: time.hour, minute: time.minute, second: 0, weekday: wd)
                // .nextTime: on a spring-forward day a skipped 02:30 runs at 03:00.
                // .first: on a fall-back day a repeated 01:30 runs once (the first).
                if let next = cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) {
                    if best == nil || next < best! { best = next }
                }
            }
            return best
        }
    }

    /// Occurrences in (after, through], oldest first, at most `limit`.
    static func occurrences(of schedule: RunSchedule, after: Date, through: Date, timeZone: TimeZone, limit: Int = 200) -> [Date] {
        var out: [Date] = []
        var cursor = after
        while out.count < limit, let next = nextOccurrence(of: schedule, after: cursor, timeZone: timeZone), next <= through {
            out.append(next)
            cursor = next
        }
        return out
    }

    enum MissReason: Equatable {
        /// Locus wasn't running (or was busy) until too long after the start time.
        case tooLate(by: Double)
        /// Another run was active.
        case conflict(with: String)
    }

    enum Decision: Equatable {
        case start(runID: UUID, occurrence: Date, lateBy: Double)
        case missed(runID: UUID, occurrence: Date, reason: MissReason)

        var runID: UUID {
            switch self {
            case .start(let id, _, _), .missed(let id, _, _): return id
            }
        }

        var occurrence: Date {
            switch self {
            case .start(_, let d, _), .missed(_, let d, _): return d
            }
        }
    }

    /// Small allowance for timer jitter even when the late policy is "skip".
    static let jitterTolerance: Double = 5

    /// Decide what to do with every occurrence that has come due since each
    /// run's `lastHandledOccurrence`.
    static func evaluate(runs: [ScheduledRun], now: Date, activeRun: (id: UUID, name: String)?) -> [Decision] {
        var decisions: [Decision] = []
        var candidates: [(run: ScheduledRun, occ: Date, late: Double)] = []

        for run in runs where run.isEnabled && run.schedule.isAutomatic {
            let baseline = run.lastHandledOccurrence ?? run.createdAt.addingTimeInterval(-1)
            let due = occurrences(of: run.schedule, after: baseline, through: now, timeZone: run.timeZone)
            guard let latest = due.last else { continue }
            for occ in due.dropLast().suffix(20) {
                decisions.append(.missed(runID: run.id, occurrence: occ, reason: .tooLate(by: now.timeIntervalSince(occ))))
            }
            let late = now.timeIntervalSince(latest)
            if late <= max(run.latePolicy.maxDelay, jitterTolerance) {
                candidates.append((run, latest, late))
            } else {
                decisions.append(.missed(runID: run.id, occurrence: latest, reason: .tooLate(by: late)))
            }
        }

        candidates.sort { ($0.occ, $0.run.createdAt) < ($1.occ, $1.run.createdAt) }
        var busy = activeRun
        for c in candidates {
            if let busy {
                decisions.append(.missed(runID: c.run.id, occurrence: c.occ, reason: .conflict(with: busy.name)))
            } else {
                decisions.append(.start(runID: c.run.id, occurrence: c.occ, lateBy: c.late))
                busy = (c.run.id, c.run.name)
            }
        }
        return decisions
    }

    /// Earliest future occurrence among enabled runs.
    static func nextWake(runs: [ScheduledRun], now: Date) -> (runID: UUID, date: Date)? {
        var best: (UUID, Date)?
        for run in runs where run.isEnabled && run.schedule.isAutomatic {
            let after = max(now, run.lastHandledOccurrence ?? .distantPast)
            if let d = nextOccurrence(of: run.schedule, after: after, timeZone: run.timeZone),
               best == nil || d < best!.1 {
                best = (run.id, d)
            }
        }
        return best.map { (runID: $0.0, date: $0.1) }
    }

    struct Overlap: Equatable {
        var otherRunID: UUID
        var otherName: String
        var at: Date
    }

    /// Minimum window assumed for a run whose duration isn't known yet.
    static let unknownDuration: Double = 60

    /// Times in the next `horizon` seconds when `run` would be active at the
    /// same time as another enabled scheduled run. Only one run can drive the
    /// simulated location at once, so these are conflicts.
    static func overlaps(of run: ScheduledRun, with others: [ScheduledRun], now: Date, horizon: Double = 7 * 86400) -> [Overlap] {
        guard run.schedule.isAutomatic else { return [] }
        let end = now.addingTimeInterval(horizon)
        let mine = occurrences(of: run.schedule, after: now, through: end, timeZone: run.timeZone, limit: 60)
        let myLen = max(unknownDuration, run.estimatedDuration ?? 0)
        var out: [Overlap] = []
        for other in others where other.id != run.id && other.isEnabled && other.schedule.isAutomatic {
            let theirs = occurrences(of: other.schedule, after: now.addingTimeInterval(-86400), through: end, timeZone: other.timeZone, limit: 70)
            let theirLen = max(unknownDuration, other.estimatedDuration ?? 0)
            outer: for a in mine {
                for b in theirs where a < b.addingTimeInterval(theirLen) && b < a.addingTimeInterval(myLen) {
                    out.append(Overlap(otherRunID: other.id, otherName: other.name, at: max(a, b)))
                    break outer
                }
            }
        }
        return out.sorted { $0.at < $1.at }
    }
}
