import XCTest
@testable import NextTime

/// The "Share with a Friend" link format, which the web app (docs/) reads and writes too.
final class SharedPlaceTests: XCTestCase {

    /// Links the web tests (tests/web) check as well, so both sides stay in step.
    private func fixture(_ key: String) throws -> (link: URL, expected: [String: Any]) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "shared-places", withExtension: "json"),
                                "shared-places.json should be in the test bundle")
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entry = try XCTUnwrap(all[key] as? [String: Any])
        return (try XCTUnwrap(URL(string: try XCTUnwrap(entry["link"] as? String))),
                try XCTUnwrap(entry["expected"] as? [String: Any]))
    }

    func testReadsTheSharedCafeLink() throws {
        let (link, e) = try fixture("cafe")
        let reminder = try XCTUnwrap(SharedPlace(url: link)).reminder()

        XCTAssertEqual(reminder.placeName, e["name"] as? String)
        XCTAssertEqual(reminder.address, e["address"] as? String)
        XCTAssertEqual(reminder.latitude, e["latitude"] as? Double)
        XCTAssertEqual(reminder.longitude, e["longitude"] as? Double)
        XCTAssertEqual(reminder.rating, e["rating"] as? Int)
        XCTAssertEqual(reminder.note, e["note"] as? String)
        XCTAssertEqual(reminder.category?.rawValue, e["category"] as? String)
        XCTAssertEqual(reminder.radius, 150, "a single spot keeps the normal reminder area")
        let dishes = try XCTUnwrap(e["dishes"] as? [[String: Any]])
        XCTAssertEqual(reminder.dishes.map(\.name), dishes.compactMap { $0["name"] as? String })
        XCTAssertEqual(reminder.dishes.map { $0.verdict == .good }, dishes.compactMap { $0["good"] as? Bool })
    }

    func testReadsTheSharedCityLink() throws {
        let (link, e) = try fixture("city")
        let reminder = try XCTUnwrap(SharedPlace(url: link)).reminder()

        XCTAssertEqual(reminder.placeName, "Chicago")
        XCTAssertEqual(reminder.category, .todo)
        XCTAssertEqual(reminder.radius, e["radius"] as? Double)
        XCTAssertTrue(reminder.isArea)
        XCTAssertNil(reminder.rating)
    }

    func testTheShareLinkOpensInTheAppToo() throws {
        let (link, _) = try fixture("cafe")
        let fragment = try XCTUnwrap(link.fragment)
        let appLink = try XCTUnwrap(URL(string: "nexttime://import#" + fragment))
        XCTAssertEqual(SharedPlace(url: appLink), SharedPlace(url: link))
    }

    func testRoundTripKeepsEverythingButPhotos() throws {
        var original = PlaceReminder(place: PlaceCandidate(name: "Café Lux 🍷", address: "Montréal", latitude: 45.5016889, longitude: -73.5672561))
        original.rating = 4
        original.note = "Ask for Élodie's table.\nCash only."
        original.dishes = [DishNote(name: "Croque-monsieur", verdict: .good), DishNote(name: "Crème brûlée", verdict: .bad)]
        original.category = .food
        original.photos = ["private.jpg"]

        let link = SharedPlace(original).link
        XCTAssertEqual(link.host, "bmjaanes.github.io")
        XCTAssertNil(link.query, "place details must stay in the fragment, which browsers never send to a server")
        let copy = try XCTUnwrap(SharedPlace(url: link)).reminder()

        XCTAssertEqual(copy.placeName, original.placeName)
        XCTAssertEqual(copy.address, original.address)
        XCTAssertEqual(copy.latitude, 45.501689, accuracy: 1e-9) // rounded to about 10 cm
        XCTAssertEqual(copy.rating, 4)
        XCTAssertEqual(copy.note, original.note)
        XCTAssertEqual(copy.dishes.map(\.name), ["Croque-monsieur", "Crème brûlée"])
        XCTAssertEqual(copy.dishes.map(\.verdict), [.good, .bad])
        XCTAssertEqual(copy.category, .food)
        XCTAssertEqual(copy.photos, [], "photos are never shared")
        XCTAssertNotEqual(copy.id, original.id, "the friend gets their own copy")
    }

    func testOnlyCitiesAndNeighborhoodsShareTheirSize() {
        var shop = PlaceReminder(place: PlaceCandidate(name: "Shop", latitude: 1, longitude: 1))
        shop.radius = 250
        XCTAssertNil(SharedPlace(shop).m)

        var city = shop
        city.radius = 15_000
        XCTAssertEqual(SharedPlace(city).m, 15_000)
    }

    func testSummaryForTheMessage() {
        var place = PlaceReminder(place: PlaceCandidate(name: "Harbor Fish House", latitude: 1, longitude: 1))
        place.rating = 2
        place.note = "Ask for a booth."
        place.dishes = [DishNote(name: "Fish & chips", verdict: .bad), DishNote(name: "Smash burger", verdict: .good)]

        XCTAssertEqual(SharedPlace(place).summary,
                       "Harbor Fish House ★★☆☆☆\nAsk for a booth.\n👎 Fish & chips · 👍 Smash burger")
    }

    func testBrokenLinksAreIgnored() {
        let broken = [
            "https://bmjaanes.github.io/chatbot/share.html",
            "https://bmjaanes.github.io/chatbot/share.html#p=",
            "https://bmjaanes.github.io/chatbot/share.html#p=abc",
            "https://bmjaanes.github.io/chatbot/share.html#p=e30", // {} with no name
            "nexttime://import",
        ]
        for link in broken {
            XCTAssertNil(SharedPlace(url: URL(string: link)!), link)
        }
    }

    func testOutOfRangeValuesAreRejectedOrIgnored() throws {
        func link(_ json: String) -> URL {
            let b64 = Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return URL(string: "nexttime://import#p=" + b64)!
        }
        XCTAssertNil(SharedPlace(url: link(#"{"v":1,"n":"X","la":95,"lo":0}"#)), "latitude beyond the pole")
        let huge = try XCTUnwrap(SharedPlace(url: link(#"{"v":1,"n":"X","la":1,"lo":1,"m":9999999,"c":"spaceship"}"#)))
        XCTAssertEqual(huge.reminder().radius, 150, "an absurd area falls back to the default")
        XCTAssertNil(huge.reminder().category, "an unknown category is ignored")
    }
}
