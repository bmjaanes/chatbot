import CoreLocation
import MapKit
import Observation

/// Place lookups backed by Apple Maps (free, no API key).
enum PlaceFinder {

    /// Restaurants, shops, etc. around a location, closest first.
    static func pointsOfInterest(near location: CLLocation, radius: CLLocationDistance = 300) async throws -> [PlaceCandidate] {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: worthRemembering)
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
            .sorted { distance($0, location) < distance($1, location) }
            .map { PlaceCandidate(mapItem: $0) }
    }

    /// Places people go back to. Leaves out restrooms, fountains, transit stops, offices and the like.
    private static let worthRemembering: [MKPointOfInterestCategory] = [
        .restaurant, .cafe, .bakery, .brewery, .winery, .nightlife, .foodMarket, .store,
        .hotel, .museum, .theater, .movieTheater, .fitnessCenter, .park, .beach,
        .amusementPark, .zoo, .aquarium, .library, .stadium, .pharmacy,
    ]

    /// Free-text search ("Joe's Fish Shack Portland"), biased toward a location when given.
    static func search(_ query: String, near location: CLLocation?) async throws -> [PlaceCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let location {
            request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        return try await MKLocalSearch(request: request).start().mapItems.map { PlaceCandidate(mapItem: $0) }
    }

    static func resolve(_ completion: MKLocalSearchCompletion) async throws -> PlaceCandidate? {
        let request = MKLocalSearch.Request(completion: completion)
        return try await MKLocalSearch(request: request).start().mapItems.first.map { PlaceCandidate(mapItem: $0) }
    }

    /// A human-readable name and address for a bare coordinate.
    static func describe(_ coordinate: CLLocationCoordinate2D) async -> (name: String?, address: String?) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return (nil, nil)
        }
        return (placemark.name, PlaceCandidate.address(from: placemark))
    }

    /// The business you're most likely at (within `radius`), or the street address if there isn't one.
    static func placeAt(_ location: CLLocation, radius: CLLocationDistance = 60) async -> PlaceCandidate {
        if let nearest = try? await pointsOfInterest(near: location, radius: radius).first,
           CLLocation(latitude: nearest.latitude, longitude: nearest.longitude).distance(from: location) <= radius {
            return nearest
        }
        let described = await describe(location.coordinate)
        return PlaceCandidate(
            name: described.name ?? "Saved spot",
            address: described.address,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude)
    }

    private static func distance(_ item: MKMapItem, _ location: CLLocation) -> CLLocationDistance {
        let c = item.placemark.coordinate
        return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: location)
    }
}

extension PlaceCandidate {
    init(mapItem: MKMapItem, sourceURL: URL? = nil) {
        let placemark = mapItem.placemark
        let area = PlaceCandidate.areaRadius(for: mapItem)
        self.init(
            name: mapItem.name ?? placemark.name ?? "Unnamed place",
            address: area == nil ? PlaceCandidate.address(from: placemark) : placemark.administrativeArea,
            latitude: placemark.coordinate.latitude,
            longitude: placemark.coordinate.longitude,
            sourceURL: sourceURL,
            category: area == nil ? PlaceCategory(mapItem.pointOfInterestCategory) : .todo,
            suggestedRadius: area)
    }

    /// A whole city or neighborhood (no street, no business) gets a reminder area to match.
    private static func areaRadius(for item: MKMapItem) -> Double? {
        let p = item.placemark
        guard item.pointOfInterestCategory == nil, p.thoroughfare == nil, p.subThoroughfare == nil else { return nil }
        if p.locality != nil, p.subLocality == nil, item.name == p.locality { return 15_000 } // city
        if p.subLocality != nil || p.locality != nil { return 2_000 } // neighborhood or district
        return nil
    }

    static func address(from placemark: CLPlacemark) -> String? {
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street, placemark.locality].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Search-as-you-type suggestions.
@MainActor
@Observable
final class PlaceSearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address] // .address includes cities
    }

    func update(query: String, near location: CLLocation?) {
        if let location {
            completer.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
        } else {
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

extension PlaceCategory {
    /// Picks a category from Apple Maps' place type, so most places never need one chosen by hand.
    init?(_ poi: MKPointOfInterestCategory?) {
        guard let poi else { return nil }
        switch poi {
        case .restaurant, .cafe, .bakery, .brewery, .winery, .nightlife, .foodMarket: self = .food
        case .store, .pharmacy: self = .shopping
        case .museum, .theater, .park, .beach, .nationalPark, .amusementPark, .zoo, .aquarium, .stadium,
             .fitnessCenter, .marina: self = .todo
        case .library: self = .read
        case .movieTheater: self = .watch
        default: return nil
        }
    }
}
