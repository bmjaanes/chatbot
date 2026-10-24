import CoreLocation
import Foundation

/// Turns whatever Google Maps put on the clipboard ("Share → Copy") into a place.
enum GoogleMapsImporter {

    enum ImportError: LocalizedError {
        case noLink, notGoogleMaps, notFound

        var errorDescription: String? {
            switch self {
            case .noLink: "That doesn't contain a link. In Google Maps, open the place, tap Share, then Copy."
            case .notGoogleMaps: "That link isn't from Google Maps."
            case .notFound: "Couldn't find that place. Try searching for it instead."
            }
        }
    }

    static func importPlace(from sharedText: String, near location: CLLocation?) async throws -> PlaceCandidate {
        guard let original = GoogleMapsLinkParser.firstURL(in: sharedText) else { throw ImportError.noLink }
        guard GoogleMapsLinkParser.isGoogleMapsLink(original) else { throw ImportError.notGoogleMaps }

        let url = GoogleMapsLinkParser.isShortLink(original) ? try await expand(original) : original
        // Some links (e.g. "?cid=123") carry neither name nor coordinates; then the shared text's name is all we have.
        let info = GoogleMapsLinkParser.parse(url) ?? GoogleMapsPlaceInfo()

        let name = info.name ?? GoogleMapsLinkParser.nameHint(in: sharedText)

        if let lat = info.latitude, let lng = info.longitude {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let described = await PlaceFinder.describe(coordinate)
            return PlaceCandidate(
                name: name ?? described.name ?? "Pinned place",
                address: described.address,
                latitude: lat,
                longitude: lng,
                sourceURL: original)
        }

        // No coordinates in the link (e.g. "?cid=..." or "?q=Name, Address"): look it up by name.
        for query in [info.query, name].compactMap({ $0 }) {
            if var match = try await PlaceFinder.search(query, near: location).first {
                match.sourceURL = original
                return match
            }
        }
        throw ImportError.notFound
    }

    /// Follows the redirect from maps.app.goo.gl to the full google.com/maps URL.
    private static func expand(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.url ?? url
    }
}
