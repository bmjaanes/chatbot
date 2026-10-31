import MapKit
import UIKit
import XCTest
@testable import NextTime

/// Saved data from older versions, categories, and the small rules the UI relies on.
final class PlaceReminderTests: XCTestCase {

    func testReadsPlacesSavedByTheFirstVersion() throws {
        // Exactly what 1.0 (3) wrote: no ratings, dishes, photos, categories or edit times.
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","placeName":"Harbor Fish House","latitude":45.515,
          "longitude":-122.6745,"radius":150,"note":"Don't get the fish","isEnabled":true,"createdAt":700000000}]
        """
        let place = try XCTUnwrap(try JSONDecoder().decode([PlaceReminder].self, from: Data(json.utf8)).first)

        XCTAssertEqual(place.placeName, "Harbor Fish House")
        XCTAssertEqual(place.note, "Don't get the fish")
        XCTAssertNil(place.rating)
        XCTAssertEqual(place.dishes, [])
        XCTAssertEqual(place.photos, [])
        XCTAssertNil(place.category)
        XCTAssertEqual(place.updatedAt, place.createdAt, "older places count as last edited when created")
    }

    func testAnUnknownCategoryFromANewerVersionDoesNotLoseThePlace() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","placeName":"X","latitude":1,"longitude":1,"category":"spaceship"}
        """
        let place = try JSONDecoder().decode(PlaceReminder.self, from: Data(json.utf8))
        XCTAssertNil(place.category)
        XCTAssertEqual(place.radius, 150)
        XCTAssertTrue(place.isEnabled)
    }

    func testEverythingSurvivesSavingAndLoading() throws {
        var place = PlaceReminder(place: PlaceCandidate(name: "Luna", address: "Division St", latitude: 45.5, longitude: -122.6,
                                                        category: .food, suggestedRadius: nil))
        place.note = "Al pastor"
        place.rating = 5
        place.dishes = [DishNote(name: "Al pastor", verdict: .good)]
        place.photos = ["a.jpg"]

        let copy = try JSONDecoder().decode(PlaceReminder.self, from: JSONEncoder().encode(place))
        XCTAssertEqual(copy, place)
    }

    func testCitiesAndNeighborhoodsAreAreas() {
        var place = PlaceReminder(place: PlaceCandidate(name: "Chicago", latitude: 41.9, longitude: -87.6, suggestedRadius: 15_000))
        XCTAssertEqual(place.radius, 15_000)
        XCTAssertTrue(place.isArea)
        place.radius = PlaceCategory.areaRadius
        XCTAssertTrue(place.isArea, "a neighborhood")
        place.radius = 500
        XCTAssertFalse(place.isArea)
    }

    func testDishSummaryAndStars() {
        var place = PlaceReminder(place: PlaceCandidate(name: "X", latitude: 1, longitude: 1))
        XCTAssertNil(place.dishSummary)
        place.dishes = [DishNote(name: "Fish", verdict: .bad), DishNote(name: "Burger", verdict: .good)]
        XCTAssertEqual(place.dishSummary, "👎 Fish · 👍 Burger")

        XCTAssertEqual(StarRating.text(2), "★★☆☆☆")
        XCTAssertEqual(StarRating.text(9), "★★★★★")
        XCTAssertEqual(StarRating.text(-1), "☆☆☆☆☆")
    }

    func testCategoriesComeFromTheKindOfPlace() {
        XCTAssertEqual(PlaceCategory(MKPointOfInterestCategory.restaurant), .food)
        XCTAssertEqual(PlaceCategory(MKPointOfInterestCategory.cafe), .food)
        XCTAssertEqual(PlaceCategory(MKPointOfInterestCategory.store), .shopping)
        XCTAssertEqual(PlaceCategory(MKPointOfInterestCategory.museum), .todo)
        XCTAssertEqual(PlaceCategory(MKPointOfInterestCategory.library), .read)
        XCTAssertEqual(PlaceCategory(MKPointOfInterestCategory.movieTheater), .watch)
        XCTAssertNil(PlaceCategory(MKPointOfInterestCategory.hospital), "no guess when the kind doesn't fit")
        XCTAssertNil(PlaceCategory(nil as MKPointOfInterestCategory?))
    }

    func testEveryCategoryHasAnIconTitleAndExample() {
        for category in PlaceCategory.allCases {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.symbol.isEmpty)
            XCTAssertNotNil(UIImage(systemName: category.symbol), "\(category.symbol) should be a real SF Symbol")
            XCTAssertTrue(category.examplePrompt.hasPrefix("e.g. "))
        }
    }
}
