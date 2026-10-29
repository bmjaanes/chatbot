import Foundation

/// A place sent to a friend: everything but photos, packed into a link.
///
/// The data rides in the link's fragment (after "#"), so it is never sent to a server.
/// The web app reads and writes the same format (docs/index.html and docs/share.html).
struct SharedPlace: Codable, Equatable {
    var v = 1
    /// Name
    var n: String
    /// Address
    var a: String?
    /// Latitude and longitude
    var la: Double
    var lo: Double
    /// Rating, 1-5
    var r: Int?
    /// Note
    var t: String?
    /// Dishes, "+Name" to get again or "-Name" to skip
    var d: [String]?
    /// Category (PlaceCategory raw value)
    var c: String?
    /// Reminder radius in meters, sent only for cities and neighborhoods
    var m: Double?

    static let webPage = URL(string: "https://bmjaanes.github.io/chatbot/share.html")!

    init(_ reminder: PlaceReminder) {
        n = reminder.placeName
        a = reminder.address
        la = (reminder.latitude * 1e6).rounded() / 1e6
        lo = (reminder.longitude * 1e6).rounded() / 1e6
        r = reminder.rating
        t = reminder.note.isEmpty ? nil : reminder.note
        d = reminder.dishes.isEmpty ? nil : reminder.dishes.map { ($0.verdict == .good ? "+" : "-") + $0.name }
        c = reminder.category?.rawValue
        m = reminder.isArea ? reminder.radius : nil
    }

    /// The link to send: a web page that shows the place and offers to open it in the app.
    var link: URL {
        var components = URLComponents(url: Self.webPage, resolvingAgainstBaseURL: false)!
        components.fragment = "p=" + encoded
        return components.url!
    }

    /// "Harbor Fish House ★★☆☆☆ · 👍 Smash burger · 👎 Fish & chips"
    var summary: String {
        var parts = [n + (r.map { " " + StarRating.text($0) } ?? "")]
        if let t { parts.append(t) }
        if let d { parts.append(d.map { ($0.hasPrefix("-") ? "👎 " : "👍 ") + $0.dropFirst() }.joined(separator: " · ")) }
        return parts.joined(separator: "\n")
    }

    /// A new place for the friend's own list, prefilled with what was shared.
    func reminder() -> PlaceReminder {
        var reminder = PlaceReminder(place: PlaceCandidate(name: n, address: a, latitude: la, longitude: lo))
        reminder.rating = r
        reminder.category = c.flatMap(PlaceCategory.init(rawValue:))
        if let m, (100...50_000).contains(m) { reminder.radius = m }
        reminder.note = t ?? ""
        reminder.dishes = (d ?? []).compactMap { item in
            guard let first = item.first, first == "+" || first == "-", item.count > 1 else { return nil }
            return DishNote(name: String(item.dropFirst()), verdict: first == "+" ? .good : .bad)
        }
        return reminder
    }

    // MARK: - Encoding

    private var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reads a shared place from a link: the web page link, or nexttime://import#p=… from that page.
    init?(url: URL) {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              fragment.hasPrefix("p=") else { return nil }
        var base64 = String(fragment.dropFirst(2))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let place = try? JSONDecoder().decode(SharedPlace.self, from: data),
              !place.n.trimmingCharacters(in: .whitespaces).isEmpty,
              (-90...90).contains(place.la), (-180...180).contains(place.lo) else { return nil }
        self = place
    }
}
