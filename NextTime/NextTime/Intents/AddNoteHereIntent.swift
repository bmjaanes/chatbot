import AppIntents
import CoreLocation

/// "Hey Siri, add a Next Time note" → "What do you want to remember?" → saved for the place you're at.
struct AddNoteHereIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Note Here"
    static let description = IntentDescription(
        "Saves a note for the place you're at right now. You'll be reminded the next time you come back.")

    @Parameter(
        title: "Note",
        requestValueDialog: IntentDialog("What do you want to remember for next time?"))
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Remember \(\.$note) for this place")
    }

    /// How far away a business can be and still count as "here".
    private static let placeSearchRadius: CLLocationDistance = 60
    /// A saved place this close is treated as the same place, and the note is added to it.
    private static let samePlaceDistance: CLLocationDistance = 40

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw $note.needsValueError() }

        // Siri can't show the location permission prompt, so it has to be granted in the app first.
        let locationService = LocationService()
        guard locationService.isAuthorized else {
            return .result(dialog: "Open Next Time and allow location access first, then try again.")
        }
        guard let here = await locationService.currentLocation() else {
            return .result(dialog: "I couldn't tell where you are right now. Try again in a moment.")
        }

        let store = ReminderStore.shared
        if var existing = store.reminders.first(where: {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: here) <= Self.samePlaceDistance
        }) {
            existing.note = existing.note.isEmpty ? text : existing.note + "\n" + text
            existing.isEnabled = true
            store.save(existing)
            return .result(dialog: "Added to your note for \(existing.placeName).")
        }

        let place = await Self.placeAt(here)
        var reminder = PlaceReminder(place: place)
        reminder.note = text
        store.save(reminder)
        return .result(dialog: "Saved for \(place.name). I'll remind you next time you're here.")
    }

    /// The business you're most likely at, or the street address if there isn't one close by.
    @MainActor
    private static func placeAt(_ location: CLLocation) async -> PlaceCandidate {
        if let nearest = try? await PlaceFinder.pointsOfInterest(near: location, radius: placeSearchRadius).first,
           CLLocation(latitude: nearest.latitude, longitude: nearest.longitude).distance(from: location) <= placeSearchRadius {
            return nearest
        }
        let described = await PlaceFinder.describe(location.coordinate)
        return PlaceCandidate(
            name: described.name ?? "Saved spot",
            address: described.address,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude)
    }
}

struct NextTimeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddNoteHereIntent(),
            phrases: [
                "Add a \(.applicationName) note",
                "Add a note in \(.applicationName)",
                "Remember this place in \(.applicationName)",
                "Leave a \(.applicationName) note",
                "Save a \(.applicationName) note for here",
            ],
            shortTitle: "Note for Here",
            systemImageName: "mappin.and.ellipse")
    }
}
