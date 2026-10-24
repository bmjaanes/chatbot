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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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
