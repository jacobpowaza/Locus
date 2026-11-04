import Foundation

// Platform-independent geometry for Scheduled Runs.
//
// Deliberately does not use CoreLocation so it compiles and is testable on
// Linux. The app converts to/from CLLocationCoordinate2D at the edges
// (see ScheduledRunsBridge.swift).

/// A WGS-84 coordinate.
struct GeoPoint: Codable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Finite and inside the valid lat/lon range.
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

enum Geo {
    static let earthRadius = 6_371_008.8 // mean radius, metres

    /// Great-circle distance in metres (haversine).
    static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from true north in [0, 360).
    static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Linear interpolation in lat/lon. Accurate for the short (≤ tens of
    /// metres) segments produced by `Polyline.densified`.
    static func interpolate(_ a: GeoPoint, _ b: GeoPoint, _ t: Double) -> GeoPoint {
        var dLon = b.longitude - a.longitude
        // Take the short way across the antimeridian.
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        var lon = a.longitude + dLon * t
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        return GeoPoint(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: lon)
    }

    /// Smallest absolute difference between two headings, degrees in [0, 180].
    static func headingDelta(_ h1: Double, _ h2: Double) -> Double {
        let d = abs(h1 - h2).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}

enum PolylineError: Error, Equatable, LocalizedError {
    case tooFewPoints
    case zeroLength

    var errorDescription: String? {
        switch self {
        case .tooFewPoints: return "The route has fewer than two valid points."
        case .zeroLength: return "The route has no length — start and destination are the same place."
        }
    }
}

/// An ordered path with cumulative distances, used for distance ↔ position lookups.
struct Polyline: Codable, Equatable {
    private(set) var points: [GeoPoint]
    /// cumulative[i] = distance in metres from points[0] to points[i].
    private(set) var cumulative: [Double]

    var length: Double { cumulative.last ?? 0 }
    var start: GeoPoint { points[0] }
    var end: GeoPoint { points[points.count - 1] }

    /// Builds a polyline after dropping invalid coordinates (NaN, out of range)
    /// and consecutive duplicates. Throws if fewer than two distinct points remain.
    init(sanitizing raw: [GeoPoint], duplicateTolerance: Double = 0.05) throws {
        var clean: [GeoPoint] = []
        clean.reserveCapacity(raw.count)
        for p in raw where p.isValid {
            if let last = clean.last, Geo.distance(last, p) <= duplicateTolerance { continue }
            clean.append(p)
        }
        guard clean.count >= 2 else {
            // Several valid points that all collapse to one place = zero length.
            let validCount = raw.lazy.filter(\.isValid).count
            throw validCount >= 2 ? PolylineError.zeroLength : PolylineError.tooFewPoints
        }
        self.points = clean
        var cum = [0.0]
        cum.reserveCapacity(clean.count)
        for i in 1..<clean.count {
            cum.append(cum[i - 1] + Geo.distance(clean[i - 1], clean[i]))
        }
        self.cumulative = cum
    }

    /// Re-samples so no segment is longer than `maxSpacing` metres. Original
    /// vertices are preserved so turns stay sharp.
    func densified(maxSpacing: Double) -> Polyline {
        guard maxSpacing > 0 else { return self }
        var out: [GeoPoint] = [points[0]]
        for i in 1..<points.count {
            let segLen = cumulative[i] - cumulative[i - 1]
            let n = max(1, Int((segLen / maxSpacing).rounded(.up)))
            for k in 1...n {
                out.append(Geo.interpolate(points[i - 1], points[i], Double(k) / Double(n)))
            }
        }
        // Points came from a valid polyline, so this cannot throw.
        return (try? Polyline(sanitizing: out, duplicateTolerance: 0)) ?? self
    }

    /// Index i such that cumulative[i] <= distance < cumulative[i+1] (clamped).
    func segmentIndex(atDistance distance: Double) -> Int {
        if distance <= 0 { return 0 }
        if distance >= length { return points.count - 2 }
        var lo = 0
        var hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= distance { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Position at `distance` metres along the line (clamped to the ends).
    func point(atDistance distance: Double) -> GeoPoint {
        if distance <= 0 { return start }
        if distance >= length { return end }
        let i = segmentIndex(atDistance: distance)
        let segLen = cumulative[i + 1] - cumulative[i]
        let t = segLen > 0 ? (distance - cumulative[i]) / segLen : 0
        return Geo.interpolate(points[i], points[i + 1], t)
    }

    /// Heading of travel at `distance` metres along the line.
    func heading(atDistance distance: Double) -> Double {
        let i = segmentIndex(atDistance: distance)
        return Geo.bearing(points[i], points[i + 1])
    }

    /// The part of the line from `distance` metres to the end, or nil if
    /// less than ~1 m remains.
    func suffix(fromDistance distance: Double) -> Polyline? {
        guard distance < length - 1 else { return nil }
        let d = max(0, distance)
        let i = segmentIndex(atDistance: d)
        var pts = [point(atDistance: d)]
        pts.append(contentsOf: points[(i + 1)...])
        return try? Polyline(sanitizing: pts)
    }
}
