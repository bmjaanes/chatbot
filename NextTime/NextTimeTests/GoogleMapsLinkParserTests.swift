import XCTest
@testable import NextTime

/// Reading the links Google Maps shares. The web app has its own copy of these rules (tests/web).
final class GoogleMapsLinkParserTests: XCTestCase {

    private func parse(_ link: String) -> GoogleMapsPlaceInfo? {
        GoogleMapsLinkParser.parse(URL(string: link)!)
    }

    func testPlaceLinkUsesTheExactPinNotTheMapCenter() throws {
        let info = try XCTUnwrap(parse("https://www.google.com/maps/place/Joe's+Fish+Shack/@45.5231,-122.6765,17z/data=!3m1!4b1!4m6!3m5!1s0x1:0x1!8m2!3d45.5229!4d-122.6762"))
        XCTAssertEqual(info.name, "Joe's Fish Shack")
        XCTAssertEqual(info.latitude, 45.5229)
        XCTAssertEqual(info.longitude, -122.6762)
    }

    func testPlaceLinkWithOnlyTheMapCenterUsesIt() throws {
        let info = try XCTUnwrap(parse("https://www.google.com/maps/place/Somewhere/@45.5231,-122.6765,17z"))
        XCTAssertEqual(info.latitude, 45.5231)
        XCTAssertEqual(info.longitude, -122.6765)
    }

    func testQueryWithCoordinates() throws {
        let info = try XCTUnwrap(parse("https://maps.google.com/?q=45.5229,-122.6762"))
        XCTAssertEqual(info.latitude, 45.5229)
        XCTAssertEqual(info.longitude, -122.6762)
        XCTAssertNil(info.query)
    }

    func testQueryWithANameAndAddress() throws {
        let info = try XCTUnwrap(parse("https://maps.google.com/?q=Joe%27s+Fish+Shack,+12+Main+St&ftid=0x1:0x1"))
        XCTAssertEqual(info.query, "Joe's Fish Shack, 12 Main St")
        XCTAssertFalse(info.hasCoordinate)
    }

    func testSearchLinks() throws {
        XCTAssertEqual(parse("https://www.google.com/maps/search/?api=1&query=Caf%C3%A9+Lux")?.query, "Café Lux")
        let byPath = try XCTUnwrap(parse("https://www.google.com/maps/search/45.52,+-122.67?entry=tts"))
        XCTAssertEqual(byPath.latitude, 45.52)
        XCTAssertEqual(byPath.longitude, -122.67)
    }

    func testGoogleMapsAppLink() throws {
        let info = try XCTUnwrap(parse("comgooglemaps://?q=Pizza&center=40.7,-74.0"))
        XCTAssertEqual(info.query, "Pizza")
        XCTAssertEqual(info.latitude, 40.7)
    }

    func testCookieConsentPageIsUnwrapped() throws {
        let inner = "https://www.google.com/maps/place/Harbor/@1,1,17z/data=!3d45.5!4d-122.6"
        let wrapped = "https://consent.google.com/ml?continue=" + inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let info = try XCTUnwrap(parse(wrapped))
        XCTAssertEqual(info.name, "Harbor")
        XCTAssertEqual(info.latitude, 45.5)
    }

    func testLinksWithoutAPlaceGiveNothing() {
        XCTAssertNil(parse("https://maps.google.com/?cid=1234567890"), "the app falls back to the shared place name")
        XCTAssertNil(parse("https://example.com/maps/place/Nope"))
    }

    func testImpossibleCoordinatesAreIgnored() throws {
        let info = parse("https://maps.google.com/?q=123.4,567.8")
        XCTAssertFalse(info?.hasCoordinate ?? false)
    }

    func testFindsTheLinkInSharedText() {
        let text = "Harbor Fish House\n1120 SW Front Ave, Portland\nhttps://maps.app.goo.gl/AbC123"
        XCTAssertEqual(GoogleMapsLinkParser.firstURL(in: text)?.absoluteString, "https://maps.app.goo.gl/AbC123")
        XCTAssertEqual(GoogleMapsLinkParser.nameHint(in: text), "Harbor Fish House")
        XCTAssertNil(GoogleMapsLinkParser.firstURL(in: "no link here"))
    }

    func testShortLinksAreRecognized() {
        XCTAssertTrue(GoogleMapsLinkParser.isShortLink(URL(string: "https://maps.app.goo.gl/AbC123")!))
        XCTAssertTrue(GoogleMapsLinkParser.isGoogleMapsLink(URL(string: "https://maps.app.goo.gl/AbC123")!))
        XCTAssertFalse(GoogleMapsLinkParser.isShortLink(URL(string: "https://www.google.com/maps/place/X")!))
        XCTAssertFalse(GoogleMapsLinkParser.isGoogleMapsLink(URL(string: "https://www.google.com/search?q=x")!))
    }
}
