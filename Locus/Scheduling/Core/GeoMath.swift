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

/// Place input that can be interpreted locally before sending a text search to MapKit.
enum DestinationQuery: Equatable {
    case coordinates(GeoPoint, name: String?)
    case text(String)
    case applePlaceID(String, fallback: GeoPoint?)
    case shortGoogleLink(URL)
    case unsupportedLink

    init(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let point = Self.coordinatePair(value) {
            self = .coordinates(point, name: nil)
            return
        }
        guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased() else {
            self = .text(value)
            return
        }
        let parameters = url.queryItems ?? []
        func parameter(_ key: String) -> String? { parameters.first { $0.name == key }?.value }
        let host = url.host?.lowercased() ?? ""
        if scheme == "geo", let point = Self.coordinatePair(url.path) {
            self = .coordinates(point, name: nil)
            return
        }
        guard ["https", "http", "maps"].contains(scheme) else {
            self = .unsupportedLink
            return
        }
        if host == "maps.apple.com" || (scheme == "maps" && host.isEmpty) {
            let fallback = (parameter("coordinate") ?? parameter("ll")).flatMap(Self.coordinatePair)
            if let id = parameter("place-id"), !id.isEmpty {
                self = .applePlaceID(id, fallback: fallback)
            } else if let query = parameter("destination") ?? parameter("daddr") ?? parameter("query") ?? parameter("q") {
                if let point = Self.coordinatePair(query) {
                    self = .coordinates(point, name: nil)
                } else if let fallback, parameter("q") != nil, parameter("address") == nil, parameter("daddr") == nil {
                    self = .coordinates(fallback, name: query)
                } else {
                    self = .text(query)
                }
            } else if let address = parameter("address") {
                self = .text(address)
            } else if let fallback {
                self = .coordinates(fallback, name: parameter("name"))
            } else {
                self = .unsupportedLink
            }
        } else if host == "maps.app.goo.gl" || (host == "goo.gl" && url.path.hasPrefix("/maps/")) {
            self = url.url.map(Self.shortGoogleLink) ?? .unsupportedLink
        } else if Self.isGoogleMapsURL(url) {
            if let query = parameter("destination") ?? parameter("query") ?? parameter("q") {
                self = Self.coordinatePair(query).map { .coordinates($0, name: nil) } ?? .text(query)
            } else if let match = url.path.range(of: #"!3d[-+]?\d+(?:\.\d+)?!4d[-+]?\d+(?:\.\d+)?"#, options: .regularExpression),
                      let point = Self.coordinatePair(String(url.path[match]).dropFirst(3).replacingOccurrences(of: "!4d", with: ",")) {
                self = .coordinates(point, name: nil)
            } else if let range = url.path.range(of: "/place/"),
                      let name = url.path[range.upperBound...].split(separator: "/").first {
                self = .text(name.replacingOccurrences(of: "+", with: " "))
            } else if let range = url.path.range(of: "/@"),
                      let point = Self.coordinatePair(url.path[range.upperBound...].split(separator: ",").prefix(2).joined(separator: ",")) {
                self = .coordinates(point, name: nil)
            } else {
                self = .unsupportedLink
            }
        } else {
            self = .unsupportedLink
        }
    }

    static func isGoogleMapsURL(_ url: URLComponents) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "maps.google.com" ||
            (["google.com", "www.google.com"].contains(host) && (url.path == "/maps" || url.path.hasPrefix("/maps/")))
    }

    private static func coordinatePair(_ value: String) -> GeoPoint? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let point = GeoPoint(latitude: lat, longitude: lon)
        return point.isValid ? point : nil
    }
}
