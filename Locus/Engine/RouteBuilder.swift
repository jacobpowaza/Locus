import CoreLocation
import Foundation
import MapKit

enum RouteBuilder {
    static func roadRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TravelMode
    ) async throws -> [CLLocationCoordinate2D] {
        let routes = try await routes(from: GeoPoint(start), to: GeoPoint(end), mode: mode)
        guard let route = routes.first else { throw RouteProviderError.noRoute }
        return sample(coordinates: route.points.map(\.coordinate), every: 12)
    }

    static func routes(
        from start: GeoPoint,
        to end: GeoPoint,
        mode: TravelMode = .drive,
        alternatives: Bool = false
    ) async throws -> [RouteResult] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = mode.mkTransportType
        request.requestsAlternateRoutes = alternatives
        let directions = MKDirections(request: request)
        let response = try await withTaskCancellationHandler {
            try await directions.calculate()
        } onCancel: {
            directions.cancel()
        }
        try Task.checkCancellation()
        let routes = response.routes.compactMap { route -> RouteResult? in
            guard route.polyline.pointCount > 1 else { return nil }
            let points = UnsafeBufferPointer(start: route.polyline.points(), count: route.polyline.pointCount)
                .map { GeoPoint($0.coordinate) }
            guard let road = try? Polyline(sanitizing: points),
                  Geo.distance(start, road.start) <= RunCompiler.maxSnapDistance,
                  Geo.distance(end, road.end) <= RunCompiler.maxSnapDistance else { return nil }
            return RouteResult(points: road.points, expectedTravelTime: route.expectedTravelTime,
                               speedLimits: nil, providerName: "Apple Maps", name: route.name.isEmpty ? nil : route.name)
        }
        guard !routes.isEmpty else { throw RouteProviderError.noRoute }
        return routes
    }

    static func sample(coordinates: [CLLocationCoordinate2D], every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        let coordinates = coordinates.filter { CLLocationCoordinate2DIsValid($0) }
        guard coordinates.count > 1, meters.isFinite, meters > 0 else { return coordinates }
        var sampled = [coordinates[0]]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let steps = max(1, Int(ceil(dist / meters)))
            for i in 1...steps {
                sampled.append(Geo.interpolate(GeoPoint(a), GeoPoint(b), Double(i) / Double(steps)).coordinate)
            }
        }
        return sampled
    }
}

enum GPXCodec {
    static func parse(_ url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var coords: [CLLocationCoordinate2D] = []
        let pattern = #"lat="([^"]+)"[^>]*lon="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let latR = Range(match.range(at: 1), in: text),
                  let lonR = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latR]),
                  let lon = Double(text[lonR]) else { return }
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        // Also support lon before lat
        if coords.isEmpty {
            let alt = #"lon="([^"]+)"[^>]*lat="([^"]+)""#
            let altRegex = try NSRegularExpression(pattern: alt)
            altRegex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let lonR = Range(match.range(at: 1), in: text),
                      let latR = Range(match.range(at: 2), in: text),
                      let lon = Double(text[lonR]),
                      let lat = Double(text[latR]) else { return }
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        coords = coords.filter { CLLocationCoordinate2DIsValid($0) }
        guard coords.count >= 2 else {
            throw NSError(domain: "Locus", code: 2, userInfo: [NSLocalizedDescriptionKey: "The GPX file needs at least two valid track points"])
        }
        return coords
    }

    static func export(_ coordinates: [CLLocationCoordinate2D], name: String = "Locus Route") -> String {
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Locus" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(name)</name>
            <trkseg>

        """
        for c in coordinates {
            body += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>\n", c.latitude, c.longitude)
        }
        body += """
            </trkseg>
          </trk>
        </gpx>
        """
        return body
    }
}
