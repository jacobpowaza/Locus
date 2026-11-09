import Foundation

/// "Drive like a person" options: red lights, stop signs and a speed that
/// wanders a little instead of sitting exactly on the target.
///
/// Locus has no data about where real signals and signs are (MapKit doesn't
/// expose them), so stops are placed at the route's turns and at plausible
/// intersection spacing on slower roads. The UI says so.
struct DriveRealism: Codable, Equatable, Hashable {
    /// Sometimes stop at a red light.
    var redLights: Bool = false
    /// Longest a single red light can hold the car, seconds.
    var maxRedLightWait: Double = 90
    /// Come to a brief full stop at many turns.
    var stopSigns: Bool = false
    /// Drift a few percent above and below the target speed.
    var varySpeed: Bool = false

    static let off = DriveRealism()
    /// What a new drive starts with.
    static let natural = DriveRealism(redLights: true, maxRedLightWait: 90, stopSigns: true, varySpeed: true)

    var isOff: Bool { !redLights && !stopSigns && !varySpeed }

    /// Shortest red light, seconds.
    var minRedLightWait: Double { min(maxRedLightWait, max(8, maxRedLightWait * 0.2)) }

    static let redLightChoices: [Double] = [30, 60, 90, 180]
}

/// A planned full stop along a drive.
struct DriveStop: Codable, Equatable, Hashable {
    enum Kind: String, Codable, Equatable, Hashable {
        case redLight, stopSign
    }

    /// Metres from the start of the drive.
    var distance: Double
    /// Seconds stood still.
    var dwell: Double
    var kind: Kind
}

/// A speed multiplier at a point along the route; values in between are
/// interpolated linearly.
struct SpeedKnot: Codable, Equatable, Hashable {
    var distance: Double
    var factor: Double
}

/// Small, fast, seedable generator so a drive's stops are the same in the
/// editor preview and in the actual run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    init(uuid: UUID, salt: UInt64 = 0) {
        let u = uuid.uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        self.init(seed: h ^ (salt &* 0xBF58_476D_1CE4_E5B9))
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Places stops and speed drift along a route.
enum DriveRealismPlanner {
    /// Turns sharper than this (degrees) count as intersections.
    static let turnThreshold = 50.0
    /// No stops this close to the start or the destination.
    static let edgeClearance = 40.0
    /// Two stops are never closer than this.
    static let minimumGap = 80.0
    /// Roads faster than this (m/s, ≈ 45 mph) are treated as highways with
    /// no lights or signs between turns.
    static let highwaySpeed = 20.0
    /// Below this (m/s, ≈ 27 mph) a road is residential: stop signs on straights.
    static let residentialSpeed = 12.0

    static func stops<G: RandomNumberGenerator>(
        along line: Polyline,
        reference: SpeedReference,
        realism: DriveRealism,
        using rng: inout G
    ) -> [DriveStop] {
        guard realism.redLights || realism.stopSigns else { return [] }
        let length = line.length
        guard length > edgeClearance * 2 + 10 else { return [] }

        // Intersections: real turns first, then plausible cross streets on
        // slower roads between them.
        var candidates: [(distance: Double, isTurn: Bool)] = turnDistances(line).map { ($0, true) }
        var d = edgeClearance + Double.random(in: 150...450, using: &rng)
        while d < length - edgeClearance {
            candidates.append((d, false))
            d += Double.random(in: 250...700, using: &rng)
        }
        candidates.sort { $0.distance < $1.distance }

        var out: [DriveStop] = []
        for c in candidates {
            guard c.distance > edgeClearance, c.distance < length - edgeClearance else { continue }
            if let last = out.last, c.distance - last.distance < minimumGap { continue }
            let roadSpeed = reference.speed(atDistance: c.distance).value
            let highway = roadSpeed > highwaySpeed
            if !c.isTurn && highway { continue }

            // One roll decides what this intersection is.
            let roll = Double.random(in: 0..<1, using: &rng)
            let redChance = c.isTurn ? 0.40 : 0.30
            let signChance: Double
            if c.isTurn {
                signChance = highway ? 0 : 0.45
            } else {
                signChance = roadSpeed <= residentialSpeed ? 0.30 : 0
            }

            if realism.redLights && roll < redChance {
                let wait = Double.random(in: realism.minRedLightWait...max(realism.minRedLightWait, realism.maxRedLightWait), using: &rng)
                out.append(DriveStop(distance: c.distance, dwell: wait.rounded(), kind: .redLight))
            } else if realism.stopSigns && roll >= redChance && roll < redChance + signChance {
                let wait = Double.random(in: 2...4, using: &rng)
                out.append(DriveStop(distance: c.distance, dwell: wait.rounded(), kind: .stopSign))
            }
        }
        return out
    }

    /// Slow drift: a new factor every few hundred metres, ±~8 %.
    static func speedKnots<G: RandomNumberGenerator>(along length: Double, using rng: inout G) -> [SpeedKnot] {
        guard length > 0 else { return [] }
        var knots: [SpeedKnot] = []
        var d = 0.0
        while d < length {
            knots.append(SpeedKnot(distance: d, factor: Double.random(in: 0.92...1.08, using: &rng)))
            d += Double.random(in: 250...600, using: &rng)
        }
        knots.append(SpeedKnot(distance: length, factor: Double.random(in: 0.92...1.08, using: &rng)))
        return knots
    }

    static func factor(_ knots: [SpeedKnot], atDistance d: Double) -> Double {
        guard let first = knots.first else { return 1 }
        if d <= first.distance { return first.factor }
        var lo = 0
        var hi = knots.count - 1
        if d >= knots[hi].distance { return knots[hi].factor }
        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2
            if d < knots[mid].distance { hi = mid } else { lo = mid }
        }
        let a = knots[lo], b = knots[hi]
        let span = b.distance - a.distance
        let t = span > 0 ? (d - a.distance) / span : 0
        return a.factor + (b.factor - a.factor) * t
    }

    /// Distances along the line where the heading changes by more than
    /// `turnThreshold`, measured across a ~20 m window so road curves made of
    /// many small bends don't count.
    static func turnDistances(_ line: Polyline) -> [Double] {
        let dense = line.densified(maxSpacing: 10)
        let pts = dense.points
        let n = pts.count
        guard n >= 5 else { return [] }
        var turns: [(distance: Double, delta: Double)] = []
        for i in 2..<(n - 2) {
            let h1 = Geo.bearing(pts[i - 2], pts[i])
            let h2 = Geo.bearing(pts[i], pts[i + 2])
            let delta = Geo.headingDelta(h1, h2)
            guard delta >= turnThreshold else { continue }
            let d = dense.cumulative[i]
            // Merge neighbours of the same turn; keep the sharpest node.
            if let last = turns.last, d - last.distance < 30 {
                if delta > last.delta { turns[turns.count - 1] = (d, delta) }
            } else {
                turns.append((d, delta))
            }
        }
        return turns.map(\.distance)
    }
}

extension Array where Element == DriveStop {
    var totalDwell: Double { reduce(0) { $0 + $1.dwell } }
}
