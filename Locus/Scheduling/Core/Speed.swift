import Foundation

/// Display unit for speeds and distances.
enum SpeedUnit: String, Codable, CaseIterable, Identifiable {
    case mph, kmh

    var id: String { rawValue }
    var label: String { self == .mph ? "mph" : "km/h" }
    var distanceLabel: String { self == .mph ? "mi" : "km" }

    /// Metres per second in one unit of this speed.
    var metersPerSecondPerUnit: Double { self == .mph ? 0.44704 : 1 / 3.6 }
    /// Metres in one display distance unit.
    var metersPerDistanceUnit: Double { self == .mph ? 1609.344 : 1000 }

    func fromMetersPerSecond(_ mps: Double) -> Double { mps / metersPerSecondPerUnit }
    func toMetersPerSecond(_ value: Double) -> Double { value * metersPerSecondPerUnit }

    /// Default unit for a locale-ish hint ("US", "GB", "LR", "MM" drive in miles).
    static func defaultFor(regionCode: String?) -> SpeedUnit {
        switch regionCode?.uppercased() {
        case "US", "GB", "LR", "MM", "PR", "VI", "GU", "AS", "MP": return .mph
        default: return .kmh
        }
    }
}

/// How fast a simulated drive moves, relative to the road.
enum SpeedPolicy: Codable, Equatable, Hashable {
    /// Match the road's reference speed (posted limit when known, otherwise the
    /// labelled fallback — see `SpeedReferenceSource`).
    case followLimit
    /// Fixed speed, metres per second.
    case constant(Double)
    /// Reference speed plus an offset, metres per second.
    case aboveLimit(Double)
    /// Reference speed minus an offset, metres per second.
    case belowLimit(Double)

    static let minimumSpeed = 0.5   // m/s — slower than this is effectively stopped
    static let maximumSpeed = 70.0  // m/s ≈ 157 mph — hard ceiling for sanity

    /// Target speed given the road's reference speed.
    func target(reference: Double) -> Double {
        let raw: Double
        switch self {
        case .followLimit: raw = reference
        case .constant(let v): raw = v
        case .aboveLimit(let o): raw = reference + o
        case .belowLimit(let o): raw = reference - o
        }
        return min(Self.maximumSpeed, max(Self.minimumSpeed, raw))
    }

    /// True when the policy depends on the road's reference speed.
    var usesReference: Bool {
        if case .constant = self { return false }
        return true
    }

    func summary(unit: SpeedUnit) -> String {
        func fmt(_ mps: Double) -> String {
            "\(Int(unit.fromMetersPerSecond(mps).rounded())) \(unit.label)"
        }
        switch self {
        case .followLimit: return "Follow speed limit"
        case .constant(let v): return "Constant \(fmt(v))"
        case .aboveLimit(let o): return "\(fmt(o)) above limit"
        case .belowLimit(let o): return "\(fmt(o)) below limit"
        }
    }

    /// Returns a human-readable problem, or nil when valid.
    var validationProblem: String? {
        switch self {
        case .followLimit: return nil
        case .constant(let v):
            if !v.isFinite || v < Self.minimumSpeed { return "Speed must be greater than zero." }
            if v > Self.maximumSpeed { return "Speed is unrealistically high." }
        case .aboveLimit(let o), .belowLimit(let o):
            if !o.isFinite || o < 0 { return "Offset can't be negative." }
            if o > 40 { return "Offset is unrealistically large." }
        }
        return nil
    }
}

/// Motion realism knobs shared by every drive in a run.
struct MotionSettings: Codable, Equatable, Hashable {
    /// Accelerate/decelerate gradually instead of jumping between speeds.
    var smoothing: Bool = true
    /// m/s² — typical relaxed car acceleration.
    var acceleration: Double = 2.0
    /// m/s² — comfortable braking.
    var deceleration: Double = 2.5
    /// m/s² — lateral acceleration allowed in turns; limits corner speed.
    var lateralAcceleration: Double = 3.0
    /// Slowest speed a corner forces, m/s.
    var minimumCornerSpeed: Double = 3.0
    /// Slow for turns at all.
    var slowForTurns: Bool = true

    static let standard = MotionSettings()
}

/// Where a drive's reference ("limit") speed comes from. Shown to the user so
/// a fallback is never presented as a real posted limit.
enum SpeedReferenceSource: String, Codable, Equatable {
    /// Per-road posted limits supplied by the route provider.
    case postedLimits
    /// No posted limits available; uses the routing service's estimated
    /// average speed for the whole route (distance ÷ expected travel time).
    case routeAverage
    /// No limits and no route estimate; uses the travel mode's default speed.
    case travelModeDefault

    var isFallback: Bool { self != .postedLimits }

    var label: String {
        switch self {
        case .postedLimits: return "Posted speed limits"
        case .routeAverage: return "Estimated — route average"
        case .travelModeDefault: return "Estimated — default driving speed"
        }
    }

    var explanation: String {
        switch self {
        case .postedLimits:
            return "Speeds follow posted limits from the routing data."
        case .routeAverage:
            return "Apple Maps doesn't provide posted speed limits. \"Limit\" here means Apple's estimated average speed for this route — not the signed limit."
        case .travelModeDefault:
            return "No speed-limit or travel-time data for this route. \"Limit\" here is a default driving speed, not the signed limit."
        }
    }
}

/// A run of road with a known posted limit, in distance along the route.
struct SpeedLimitSpan: Codable, Equatable, Hashable {
    var fromDistance: Double
    var toDistance: Double
    /// m/s
    var limit: Double
}

/// Reference speed along a route: posted limits where known, otherwise one
/// clearly-labelled fallback value.
struct SpeedReference: Codable, Equatable {
    /// Sorted, non-overlapping spans; may be empty.
    var spans: [SpeedLimitSpan]
    /// Used wherever no span covers a distance.
    var fallback: Double
    var fallbackSource: SpeedReferenceSource

    /// Source for the route as a whole (posted only if spans cover ≥ 90%).
    func overallSource(routeLength: Double) -> SpeedReferenceSource {
        guard routeLength > 0, !spans.isEmpty else { return fallbackSource }
        let covered = spans.reduce(0) { $0 + max(0, min($1.toDistance, routeLength) - max($1.fromDistance, 0)) }
        return covered / routeLength >= 0.9 ? .postedLimits : fallbackSource
    }

    func speed(atDistance d: Double) -> (value: Double, source: SpeedReferenceSource) {
        // Spans are few; linear scan is fine and allocation-free.
        for span in spans where d >= span.fromDistance && d < span.toDistance {
            return (span.limit, .postedLimits)
        }
        return (fallback, fallbackSource)
    }

    /// Same reference re-based so distance 0 is `offset` metres into the original.
    func shifted(by offset: Double) -> SpeedReference {
        var copy = self
        copy.spans = spans.compactMap { s in
            let from = s.fromDistance - offset
            let to = s.toDistance - offset
            guard to > 0 else { return nil }
            return SpeedLimitSpan(fromDistance: max(0, from), toDistance: to, limit: s.limit)
        }
        return copy
    }

    /// Builds the reference for a route, picking the best available fallback.
    static func make(
        spans: [SpeedLimitSpan]?,
        routeDistance: Double,
        expectedTravelTime: Double?,
        travelModeDefault: Double
    ) -> SpeedReference {
        let validSpans = (spans ?? [])
            .filter { $0.limit.isFinite && $0.limit > 0 && $0.toDistance > $0.fromDistance }
            .sorted { $0.fromDistance < $1.fromDistance }
        if let eta = expectedTravelTime, eta.isFinite, eta > 0, routeDistance > 0 {
            let avg = routeDistance / eta
            if avg.isFinite, avg >= 1, avg <= SpeedPolicy.maximumSpeed {
                return SpeedReference(spans: validSpans, fallback: avg, fallbackSource: .routeAverage)
            }
        }
        return SpeedReference(spans: validSpans, fallback: travelModeDefault, fallbackSource: .travelModeDefault)
    }
}

enum TravelDefaults {
    /// Matches TravelMode.drive.baseSpeed in the app (≈ 30 mph).
    static let driveSpeed = 13.4
}
