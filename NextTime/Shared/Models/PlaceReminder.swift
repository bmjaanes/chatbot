import CoreLocation
import Foundation

/// A note to yourself that pops up the next time you arrive at a place.
struct PlaceReminder: Identifiable, Codable, Hashable {
    var id = UUID()
    var placeName: String
    var address: String?
    var latitude: Double
    var longitude: Double
    /// How close (in meters) you need to get before the reminder fires.
    var radius: Double = 150
    var note: String = ""
    var isEnabled = true
    /// The Google Maps link the place was imported from, if any.
    var sourceURL: URL?
    var createdAt = Date()
    /// 1 to 5 stars, or nil when not rated yet.
    var rating: Int?
    /// What you had, and whether to get it again.
    var dishes: [DishNote] = []
    /// File names of photos kept by `PhotoStore`.
    var photos: [String] = []

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case id, placeName, address, latitude, longitude, radius, note, isEnabled, sourceURL, createdAt
        case rating, dishes, photos
    }

    /// One line for notifications and lists: "👍 Burger · 👎 Fish".
    var dishSummary: String? {
        guard !dishes.isEmpty else { return nil }
        return dishes.map { "\($0.verdict.emoji) \($0.name)" }.joined(separator: " · ")
    }

    init(place: PlaceCandidate) {
        placeName = place.name
        address = place.address
        latitude = place.latitude
        longitude = place.longitude
        sourceURL = place.sourceURL
    }

    /// Opens the place in the Google Maps app, falling back to the Google Maps website.
    var googleMapsURLs: (app: URL, web: URL) {
        let coords = "\(latitude),\(longitude)"
        let query = [placeName, address].compactMap { $0 }.joined(separator: ", ")

        var app = URLComponents(string: "comgooglemaps://")!
        app.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "center", value: coords),
        ]

        var web = URLComponents(string: "https://www.google.com/maps/search/")!
        web.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: query.isEmpty ? coords : query),
        ]
        return (sourceURL ?? app.url!, web.url!)
    }
}

/// A place the user picked, before it becomes a reminder.
struct PlaceCandidate: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var sourceURL: URL?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension PlaceReminder {
    /// Decodes reminders saved by older versions, which lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        placeName = try c.decode(String.self, forKey: .placeName)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 150
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        dishes = try c.decodeIfPresent([DishNote].self, forKey: .dishes) ?? []
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
    }
}

/// Something you had at a place, and whether it was worth getting again.
struct DishNote: Identifiable, Codable, Hashable {
    enum Verdict: String, Codable {
        case good, bad

        var emoji: String { self == .good ? "👍" : "👎" }
    }

    var id = UUID()
    var name: String
    var verdict: Verdict
}

enum StarRating {
    /// "★★★☆☆"
    static func text(_ rating: Int) -> String {
        let filled = min(max(rating, 0), 5)
        return String(repeating: "★", count: filled) + String(repeating: "☆", count: 5 - filled)
    }
}
