import CoreLocation
import MapKit
import SwiftUI

/// A place shown in the place card: a search result, a favorite, a recent,
/// or a pin dropped on the map.
struct MapPlace: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D
    var category: MKPointOfInterestCategory?
    var website: URL? = nil
    var kind: Kind = .search

    enum Kind { case search, favorite, recent, droppedPin }

    static func == (a: MapPlace, b: MapPlace) -> Bool {
        a.id == b.id && a.name == b.name && a.subtitle == b.subtitle
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
    }

    var placeRef: PlaceRef { PlaceRef(name: name, point: GeoPoint(coordinate)) }

    init(name: String, subtitle: String, coordinate: CLLocationCoordinate2D, category: MKPointOfInterestCategory? = nil, kind: Kind = .search) {
        self.name = name
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.category = category
        self.kind = kind
    }

    init(saved: SavedPlace, kind: Kind) {
        self.init(name: saved.name, subtitle: kind == .favorite ? "Favorite" : "Recent", coordinate: saved.coordinate, kind: kind)
    }

    static func droppedPin(at coordinate: CLLocationCoordinate2D) -> MapPlace {
        MapPlace(name: "Dropped Pin", subtitle: "Finding address…", coordinate: coordinate, kind: .droppedPin)
    }
}

/// Round coloured icon for a place, like Apple Maps' result glyphs.
struct PlaceIcon: View {
    var category: MKPointOfInterestCategory?
    var kind: MapPlace.Kind = .search
    var size: CGFloat = 40

    var body: some View {
        let style = Self.style(category: category, kind: kind)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(style.color.gradient))
            .accessibilityHidden(true)
    }

    static func style(category: MKPointOfInterestCategory?, kind: MapPlace.Kind) -> (symbol: String, color: Color) {
        switch kind {
        case .favorite: return ("star.fill", Color(red: 1.0, green: 0.75, blue: 0.2))
        case .recent: return ("clock.fill", Color(white: 0.45))
        case .droppedPin: return ("mappin", Color(red: 0.95, green: 0.27, blue: 0.27))
        case .search: break
        }
        guard let category else { return ("mappin", Color(red: 0.95, green: 0.27, blue: 0.27)) }
        switch category {
        case .cafe, .bakery: return ("cup.and.saucer.fill", .orange)
        case .restaurant, .foodMarket: return ("fork.knife", .orange)
        case .nightlife, .brewery, .winery: return ("wineglass.fill", .pink)
        case .store: return ("bag.fill", .yellow)
        case .park, .nationalPark, .campground, .beach: return ("tree.fill", .green)
        case .school, .university, .library: return ("graduationcap.fill", .brown)
        case .hospital, .pharmacy: return ("cross.fill", .red)
        case .gasStation, .evCharger: return ("fuelpump.fill", .blue)
        case .parking: return ("parkingsign", .blue)
        case .hotel: return ("bed.double.fill", .indigo)
        case .airport: return ("airplane", .blue)
        case .publicTransport: return ("tram.fill", .blue)
        case .fitnessCenter, .stadium: return ("figure.run", .green)
        case .museum, .theater, .movieTheater: return ("building.columns.fill", .teal)
        case .bank, .atm: return ("dollarsign", .green)
        default: return ("mappin", Color(red: 0.95, green: 0.27, blue: 0.27))
        }
    }
}

@MainActor
final class PlaceSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    /// A query is out and no answer has come back yet.
    @Published private(set) var isLoading = false
    private let completer = MKLocalSearchCompleter()

    var query: String = "" {
        didSet {
            results = []
            completer.cancel()
            if case .text(let text) = DestinationQuery(query), !text.isEmpty {
                isLoading = true
                completer.queryFragment = text
            } else {
                isLoading = false
                completer.queryFragment = ""
            }
        }
    }

    /// Bias results toward where the user is (or is simulating).
    var near: CLLocationCoordinate2D? {
        didSet {
            if let near {
                completer.region = MKCoordinateRegion(center: near, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
            }
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let fragment = completer.queryFragment
        let items = completer.results
        Task { @MainActor in
            guard !fragment.isEmpty, case .text(let text) = DestinationQuery(self.query), text == fragment else { return }
            self.results = items
            self.isLoading = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.results = []
            self.isLoading = false
        }
    }

    /// Looks up a suggestion's coordinate and details.
    static func resolve(_ completion: MKLocalSearchCompletion) async -> MapPlace? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return place(item, fallbackName: completion.title, subtitle: completion.subtitle)
    }

    /// Runs the typed text as a full search (Return key) and takes the best hit.
    static func search(_ input: String, near: CLLocationCoordinate2D?) async throws -> MapPlace? {
        var query = DestinationQuery(input)
        if case .shortGoogleLink(let url) = query {
            let delegate = MapsRedirectDelegate()
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.httpMethod = "HEAD"
            let (_, response) = try await session.data(for: request)
            query = response.url.map { DestinationQuery($0.absoluteString) } ?? .unsupportedLink
        }
        switch query {
        case .coordinates(let point, let name):
            return MapPlace(name: name ?? "Dropped Pin", subtitle: String(format: "%.5f, %.5f", point.latitude, point.longitude),
                            coordinate: point.coordinate, kind: .droppedPin)
        case .applePlaceID(let id, let fallback):
            if let identifier = MKMapItem.Identifier(rawValue: id),
               let item = try? await MKMapItemRequest(mapItemIdentifier: identifier).mapItem {
                return place(item, fallbackName: "Apple Maps Place")
            }
            if let fallback { return MapPlace.droppedPin(at: fallback.coordinate) }
            throw SearchError.unavailableLink
        case .text(let text):
            return try await textSearch(text, near: near)
        case .unsupportedLink, .shortGoogleLink:
            throw SearchError.unavailableLink
        }
    }

    private static func textSearch(_ text: String, near: CLLocationCoordinate2D?) async throws -> MapPlace? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let near {
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler { try await search.start() } onCancel: { search.cancel() }
        return response.mapItems.first.map { place($0, fallbackName: text) }
    }

    private static func place(_ item: MKMapItem, fallbackName: String, subtitle: String? = nil) -> MapPlace {
        var place = MapPlace(name: item.name ?? fallbackName, subtitle: subtitle ?? item.placemark.title ?? "",
                             coordinate: item.placemark.coordinate, category: item.pointOfInterestCategory)
        if let url = item.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { place.website = url }
        return place
    }

    private enum SearchError: LocalizedError {
        case unavailableLink
        var errorDescription: String? { "This link doesn’t identify a place. Try the address or latitude and longitude." }
    }

    /// Street address for a dropped pin.
    static func address(for coordinate: CLLocationCoordinate2D) async -> (name: String, subtitle: String)? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let city = [mark.locality, mark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        let name = street.isEmpty ? (mark.name ?? city) : street
        return (name.isEmpty ? "Dropped Pin" : name, city)
    }
}


// Short links are expanded over HTTPS and redirects stay inside Google Maps.
private final class MapsRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              DestinationQuery.isGoogleMapsURL(components) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
