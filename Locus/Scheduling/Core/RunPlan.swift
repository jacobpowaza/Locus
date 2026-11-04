import Foundation

/// One drive leg inside a compiled plan.
struct DriveLeg: Codable, Equatable {
    var destination: PlaceRef
    var profile: DriveProfile
    /// Drive To had its own speed ("Custom Speed"); live speed changes skip it.
    var hasCustomSpeed: Bool
    /// The live routing request failed and a previously saved route was used.
    var routeFromCache: Bool
    var providerName: String
}

/// A concrete, timed step. Repeats are already unrolled and routes fetched.
struct PlanSegment: Codable, Equatable, Identifiable {
    enum Kind: Codable, Equatable {
        case teleport(PlaceRef)
        case hold(seconds: Double)
        case waitUntil(Date)
        case drive(DriveLeg)
        case setSpeed(SpeedPolicy)
        case stop
    }

    var id: Int
    var actionID: UUID
    /// 0 = first pass, ≥1 = Repeat iteration.
    var iteration: Int
    var kind: Kind
    /// Simulated location while this segment is active (drive: its start).
    /// Nil = not spoofing.
    var location: GeoPoint?

    /// Seconds this segment takes on its own (waitUntil depends on the clock → 0).
    var fixedDuration: Double {
        switch kind {
        case .hold(let s): return s
        case .drive(let leg): return leg.profile.duration
        case .teleport, .waitUntil, .setSpeed, .stop: return 0
        }
    }

    var isInstant: Bool {
        switch kind {
        case .teleport, .setSpeed, .stop: return true
        case .hold, .waitUntil, .drive: return false
        }
    }

    var summary: String {
        switch kind {
        case .teleport(let p): return "Teleport to \(p.name)"
        case .hold(let s): return "Wait \(DurationText.short(s))"
        case .waitUntil(let d): return "Wait until \(DurationText.clock(d))"
        case .drive(let leg): return "Drive to \(leg.destination.name)"
        case .setSpeed(let p): return "Change speed: \(p.summary(unit: .mph))"
        case .stop: return "Turn off Locus"
        }
    }
}

struct ProjectedSegment: Equatable {
    var segmentID: Int
    var start: Date
    var end: Date
    /// waitUntil whose time had already passed when reached.
    var lateBy: Double
}

struct RunPlan: Codable, Equatable {
    var segments: [PlanSegment]
    /// Day/time Start At steps are resolved against (scheduled occurrence).
    var anchorDate: Date
    /// When the plan was compiled to start.
    var startDate: Date
    var timeZoneID: String

    var totalDriveDistance: Double {
        segments.reduce(0) { sum, s in
            if case .drive(let leg) = s.kind { return sum + leg.profile.distance }
            return sum
        }
    }

    var finalLocation: GeoPoint? {
        guard let last = segments.last else { return nil }
        if case .drive(let leg) = last.kind { return leg.profile.polyline.end }
        if case .teleport(let p) = last.kind { return p.point }
        if case .stop = last.kind { return nil }
        return last.location
    }

    /// Projected start/end for segments `fromIndex...`, given the current
    /// segment has been running for `elapsedInCurrent` seconds at `now`.
    func project(fromIndex: Int = 0, elapsedInCurrent: Double = 0, now: Date) -> [ProjectedSegment] {
        guard fromIndex < segments.count else { return [] }
        var out: [ProjectedSegment] = []
        out.reserveCapacity(segments.count - fromIndex)
        var cursor = now
        for i in fromIndex..<segments.count {
            let seg = segments[i]
            let elapsed = i == fromIndex ? elapsedInCurrent : 0
            let start = i == fromIndex ? now.addingTimeInterval(-elapsed) : cursor
            var late = 0.0
            let end: Date
            if case .waitUntil(let target) = seg.kind {
                if target < cursor { late = cursor.timeIntervalSince(target) }
                end = max(cursor, target)
            } else {
                end = cursor.addingTimeInterval(max(0, seg.fixedDuration - elapsed))
            }
            out.append(ProjectedSegment(segmentID: seg.id, start: start, end: end, lateBy: late))
            cursor = end
        }
        return out
    }

    func projectedEnd(fromIndex: Int = 0, elapsedInCurrent: Double = 0, now: Date) -> Date {
        project(fromIndex: fromIndex, elapsedInCurrent: elapsedInCurrent, now: now).last?.end ?? now
    }
}

enum DurationText {
    /// "1 h 5 min", "12 min", "45 s"
    static func short(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60
        let rem = m % 60
        if h < 48 { return rem == 0 ? "\(h) h" : "\(h) h \(rem) min" }
        return "\(h / 24) d \(h % 24) h"
    }

    /// "10:30" in the process time zone — only for log/plain-text summaries;
    /// the UI uses locale-aware formatting.
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
