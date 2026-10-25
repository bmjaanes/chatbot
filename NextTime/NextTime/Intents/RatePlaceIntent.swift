import AppIntents
import CoreLocation

enum StarRatingOption: Int, AppEnum {
    case one = 1, two, three, four, five

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Rating"
    static let caseDisplayRepresentations: [StarRatingOption: DisplayRepresentation] = [
        .one: DisplayRepresentation(title: "1 star", synonyms: ["one star"]),
        .two: DisplayRepresentation(title: "2 stars", synonyms: ["two stars"]),
        .three: DisplayRepresentation(title: "3 stars", synonyms: ["three stars"]),
        .four: DisplayRepresentation(title: "4 stars", synonyms: ["four stars"]),
        .five: DisplayRepresentation(title: "5 stars", synonyms: ["five stars"]),
    ]
}

/// "Hey Siri, rate this place 4 stars in Next Time."
struct RatePlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Rate This Place"
    static let description = IntentDescription(
        "Gives the place you're at a 1 to 5 star rating. It's saved if it isn't already.")

    @Parameter(title: "Rating", requestValueDialog: IntentDialog("How many stars, 1 to 5?"))
    var rating: StarRatingOption

    static var parameterSummary: some ParameterSummary {
        Summary("Rate this place \(\.$rating)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let locationService = LocationService()
        guard locationService.isAuthorized else {
            return .result(dialog: "Open Next Time and allow location access first, then try again.")
        }
        guard let here = await locationService.currentLocation() else {
            return .result(dialog: "I couldn't tell where you are right now. Try again in a moment.")
        }

        let store = ReminderStore.shared
        let stars = rating.rawValue
        let label = stars == 1 ? "1 star" : "\(stars) stars"
        if var existing = store.reminders.first(where: {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: here) <= 40
        }) {
            existing.rating = stars
            store.save(existing)
            return .result(dialog: "Gave \(existing.placeName) \(label).")
        }

        var reminder = PlaceReminder(place: await PlaceFinder.placeAt(here))
        reminder.rating = stars
        store.save(reminder)
        return .result(dialog: "Saved \(reminder.placeName) with \(label).")
    }
}
