import CoreLocation
import Foundation

struct SavedPlace: Identifiable, Codable, Equatable {
    var id: String { "\(latitude),\(longitude)" }
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func load(key: String) -> [SavedPlace] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedPlace].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ places: [SavedPlace], key: String) {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}


enum PlaceShortcut: String, CaseIterable, Identifiable {
    case home = "Home", work = "Work"

    var id: String { rawValue }
    var key: String { "locus.shortcut.\(rawValue.lowercased())" }
    var symbol: String { self == .home ? "house.fill" : "briefcase.fill" }
}
