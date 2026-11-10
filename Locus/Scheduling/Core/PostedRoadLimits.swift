import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Map-matches an Apple Maps route against Valhalla's OpenStreetMap graph.
/// Only the posted-limit attribute is used. Routing and playback geometry stay with MapKit.
actor PostedRoadLimits {
    private var cache: [[GeoPoint]: [SpeedLimitSpan]] = [:]
    private var nextRequest = ContinuousClock.now

    func lookup(for points: [GeoPoint]) async throws -> [SpeedLimitSpan]? {
        if let cached = cache[points] { return cached }
        guard let line = try? Polyline(sanitizing: points) else { return [] }
        let count = max(2, Int(ceil(line.length / 20)))
        // Keep the payload bounded on long trips. The demo server also has
        // its own limits and can refuse a request.
        guard count <= 8_000 else { return [] }
        let distances = (0...count).map { line.length * Double($0) / Double(count) }
        let trace = distances.map { d in
            let point = line.point(atDistance: d)
            return ["lat": point.latitude, "lon": point.longitude]
        }

        let clock = ContinuousClock()
        let start = max(clock.now, nextRequest)
        nextRequest = start.advanced(by: .seconds(1))
        try await clock.sleep(until: start)
        try Task.checkCancellation()
        if let cached = cache[points] { return cached }

        var request = URLRequest(url: URL(string: "https://valhalla1.openstreetmap.de/trace_attributes")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.chrismack.locus", forHTTPHeaderField: "X-Client-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "shape": trace,
            "costing": "auto",
            "units": "kilometers",
            "shape_match": "map_snap",
            "filters": ["action": "include", "attributes": [
                "edge.speed_limit", "matched.edge_index", "matched.distance_from_trace_point",
                "matched.begin_route_discontinuity", "matched.end_route_discontinuity",
            ]],
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let limits = try Self.spans(from: data, distances: distances)
            if cache.count >= 24 { cache.removeAll() }
            cache[points] = limits
            return limits
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private struct Response: Decodable {
        struct Edge: Decodable {
            let limit: Double?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // An absent field is unknown. Valhalla sends "unlimited" as text.
                let speed = try? container.decode(Double.self, forKey: .speedLimit)
                limit = speed.flatMap { (1...200).contains($0) ? SpeedUnit.kmh.toMetersPerSecond($0) : nil }
            }

            private enum CodingKeys: String, CodingKey { case speedLimit }
        }

        struct Match: Decodable {
            var edgeIndex: Int?
            var distanceFromTracePoint: Double?
            var beginRouteDiscontinuity: Bool?
            var endRouteDiscontinuity: Bool?

            var trustedEdge: Int? {
                guard let distanceFromTracePoint, (0...18).contains(distanceFromTracePoint) else { return nil }
                return edgeIndex
            }
        }

        var edges: [Edge]
        var matchedPoints: [Match]
    }

    static func spans(from data: Data, distances: [Double]) throws -> [SpeedLimitSpan] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(Response.self, from: data)
        guard result.matchedPoints.count == distances.count, distances.count >= 2 else { return [] }

        var spans: [SpeedLimitSpan] = []
        func append(_ limit: Double?, from: Double, to: Double) {
            guard let limit, to > from else { return }
            if let last = spans.indices.last, spans[last].limit == limit, spans[last].toDistance == from {
                spans[last].toDistance = to
            } else {
                spans.append(SpeedLimitSpan(fromDistance: from, toDistance: to, limit: limit))
            }
        }

        for i in 1..<distances.count {
            let a = result.matchedPoints[i - 1]
            let b = result.matchedPoints[i]
            guard a.beginRouteDiscontinuity != true, b.endRouteDiscontinuity != true,
                  let first = a.trustedEdge, let last = b.trustedEdge, first <= last,
                  result.edges.indices.contains(first), result.edges.indices.contains(last) else { continue }
            let limit = result.edges[first].limit
            if result.edges[first...last].allSatisfy({ $0.limit == limit }) {
                append(limit, from: distances[i - 1], to: distances[i])
            } else if last == first + 1, limit != nil, result.edges[last].limit != nil {
                // Adjacent trace samples straddle the change. Their midpoint
                // locates it within half a sample interval of the route.
                let mid = (distances[i - 1] + distances[i]) / 2
                append(limit, from: distances[i - 1], to: mid)
                append(result.edges[last].limit, from: mid, to: distances[i])
            }
        }
        return spans
    }
}
