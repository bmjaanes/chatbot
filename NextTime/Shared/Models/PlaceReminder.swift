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
    /// When this place was last edited on any device; the newer edit wins when iCloud syncs two devices.
    var updatedAt = Date()
    /// 1 to 5 stars, or nil when not rated yet.
    var rating: Int?
    /// What you had, and whether to get it again.
    var dishes: [DishNote] = []
    /// File names of photos kept by `PhotoStore`.
    var photos: [String] = []
    /// Optional kind of place, shown as its icon. Filled in automatically when the place type is known.
    var category: PlaceCategory?

    /// A city or neighborhood rather than one spot: "You're in Chicago" instead of "Back at…".
    var isArea: Bool { radius >= PlaceCategory.areaRadius }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case id, placeName, address, latitude, longitude, radius, note, isEnabled, sourceURL, createdAt, updatedAt
        case rating, dishes, photos, category
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
        category = place.category
        if let radius = place.suggestedRadius { self.radius = radius }
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
    var category: PlaceCategory?
    /// Set for cities and neighborhoods, which need a much bigger reminder area than a shop.
    var suggestedRadius: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// What kind of place a note is for. Optional; only changes the icon, the filter and the example text.
enum PlaceCategory: String, Codable, CaseIterable, Identifiable {
    case food, shopping, todo, read, watch, other

    var id: Self { self }

    /// Reminder areas this big or bigger count as a whole city or neighborhood.
    static let areaRadius: Double = 2_000

    var title: String {
        switch self {
        case .food: "Food & Drink"
        case .shopping: "Shopping"
        case .todo: "Things to Do"
        case .read: "Read"
        case .watch: "Watch"
        case .other: "Other"
        }
    }

    /// SF Symbol for lists and menus.
    var symbol: String {
        switch self {
        case .food: "fork.knife"
        case .shopping: "bag"
        case .todo: "ticket"
        case .read: "book"
        case .watch: "tv"
        case .other: "mappin"
        }
    }

    /// Example for the note field, so people see what each kind is good for.
    var examplePrompt: String {
        switch self {
        case .food: "e.g. Don't get the fish. The burger was great."
        case .shopping: "e.g. Ask for the 3/8\" brass fittings. Aisle 7."
        case .todo: "e.g. Architecture boat tour. Deep dish at Lou Malnati's."
        case .read: "e.g. Borrow Project Hail Mary."
        case .watch: "e.g. Download the new season of Severance before the flight."
        case .other: "e.g. Parking is cheaper on the second level."
        }
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
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        dishes = try c.decodeIfPresent([DishNote].self, forKey: .dishes) ?? []
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
        category = try? c.decodeIfPresent(PlaceCategory.self, forKey: .category)
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
