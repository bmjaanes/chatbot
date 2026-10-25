import Foundation

/// What we could learn about a place from a Google Maps link.
struct GoogleMapsPlaceInfo: Equatable {
    var name: String?
    var latitude: Double?
    var longitude: Double?
    /// A free-text search ("Joe's Fish Shack, 12 Main St") when the link has no coordinates.
    var query: String?

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    mutating func setCoordinate(_ pair: (Double, Double)) {
        latitude = pair.0
        longitude = pair.1
    }
}

/// Pulls place names and coordinates out of the links Google Maps shares.
///
/// Handles the common shapes:
///   https://maps.app.goo.gl/AbC123                       (short link; expand it first)
///   https://www.google.com/maps/place/Joe's/@37.77,-122.41,17z/data=...!3d37.7749!4d-122.4194
///   https://maps.google.com/?q=37.7749,-122.4194
///   https://maps.google.com/?q=Joe's+Fish+Shack,+12+Main+St&ftid=...
///   https://www.google.com/maps/search/?api=1&query=...
///   comgooglemaps://?q=...&center=37.77,-122.41
enum GoogleMapsLinkParser {

    /// Finds the first http(s) or comgooglemaps link in some shared text.
    static func firstURL(in text: String) -> URL? {
        let pattern = #"(https?|comgooglemaps)://[^\s<>"]+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    /// Short links have to be followed (an HTTP redirect) before they can be parsed.
    static func isShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "maps.app.goo.gl" || host == "goo.gl" || host == "g.co"
    }

    static func isGoogleMapsLink(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "comgooglemaps" { return true }
        guard let host = url.host?.lowercased() else { return false }
        if isShortLink(url) { return true }
        let isGoogleHost = host.hasPrefix("google.") || host.contains(".google.")
        return isGoogleHost && (host.hasPrefix("maps.") || url.path.hasPrefix("/maps"))
    }

    /// When Google Maps shares a place it often sends the name on the first line and the link after it.
    static func nameHint(in sharedText: String) -> String? {
        sharedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.contains("://") }
    }

    static func parse(_ url: URL) -> GoogleMapsPlaceInfo? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let value = items.first(where: { $0.name == name })?.value, !value.isEmpty else { return nil }
            return value
        }

        // EU users can land on a cookie consent page that wraps the real link.
        if url.host?.lowercased().hasPrefix("consent.") == true,
           let inner = value("continue").flatMap(URL.init(string:)) {
            return parse(inner)
        }

        guard isGoogleMapsLink(url) else { return nil }

        var info = GoogleMapsPlaceInfo()
        let path = url.path

        // /maps/place/<Name>/... and /maps/search/<query>/...
        let segments = path.split(separator: "/").map(String.init)
        if let i = segments.firstIndex(of: "place"), i + 1 < segments.count,
           !segments[i + 1].hasPrefix("@") {
            info.name = decode(segments[i + 1])
        }
        if let i = segments.firstIndex(of: "search"), i + 1 < segments.count,
           !segments[i + 1].hasPrefix("@") {
            let text = decode(segments[i + 1])
            if let c = coordinatePair(text) { info.setCoordinate(c) } else { info.query = text }
        }

        // The exact pin: "!3d<lat>!4d<lng>" inside the data= blob. The last pair is the place itself.
        let full = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        if !info.hasCoordinate, let c = lastMatch(#"!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)"#, in: full) {
            info.setCoordinate(c)
        }

        // Query parameters: q=, query=, ll=, destination=, daddr=, center=.
        for key in ["q", "query", "destination", "daddr", "ll", "center"] {
            guard let raw = value(key) else { continue }
            let text = raw.replacingOccurrences(of: "+", with: " ")
            if let c = coordinatePair(text) {
                if !info.hasCoordinate { info.setCoordinate(c) }
            } else if info.query == nil, key != "ll", key != "center" {
                info.query = text
            }
        }

        // Last resort: "@<lat>,<lng>,<zoom>z" is where the map was centered.
        if !info.hasCoordinate, let c = lastMatch(#"@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)"#, in: path) {
            info.setCoordinate(c)
        }

        if info.name == nil, info.query == nil, !info.hasCoordinate { return nil }
        return info
    }

    // MARK: - Helpers

    private static func decode(_ segment: String) -> String {
        let spaced = segment.replacingOccurrences(of: "+", with: " ")
        return (spaced.removingPercentEncoding ?? spaced).trimmingCharacters(in: .whitespaces)
    }

    private static func coordinatePair(_ text: String) -> (Double, Double)? {
        let pattern = #"^\s*(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*$"#
        return lastMatch(pattern, in: text)
    }

    private static func lastMatch(_ pattern: String, in text: String) -> (Double, Double)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let latRange = Range(match.range(at: 1), in: text),
              let lngRange = Range(match.range(at: 2), in: text),
              let lat = Double(text[latRange]), let lng = Double(text[lngRange]),
              (-90...90).contains(lat), (-180...180).contains(lng)
        else { return nil }
        return (lat, lng)
    }
}
