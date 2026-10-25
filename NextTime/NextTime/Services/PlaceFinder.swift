import CoreLocation
import MapKit
import Observation

/// Place lookups backed by Apple Maps (free, no API key).
enum PlaceFinder {

    /// Restaurants, shops, etc. around a location, closest first.
    static func pointsOfInterest(near location: CLLocation, radius: CLLocationDistance = 300) async throws -> [PlaceCandidate] {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: radius)
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
            .sorted { distance($0, location) < distance($1, location) }
            .map { PlaceCandidate(mapItem: $0) }
    }

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

    private static func distance(_ item: MKMapItem, _ location: CLLocation) -> CLLocationDistance {
        let c = item.placemark.coordinate
        return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: location)
    }
}

extension PlaceCandidate {
    init(mapItem: MKMapItem, sourceURL: URL? = nil) {
        let placemark = mapItem.placemark
        self.init(
            name: mapItem.name ?? placemark.name ?? "Unnamed place",
            address: PlaceCandidate.address(from: placemark),
            latitude: placemark.coordinate.latitude,
            longitude: placemark.coordinate.longitude,
            sourceURL: sourceURL)
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
        completer.resultTypes = [.pointOfInterest, .address]
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
