import MapKit
import SwiftUI

/// Step 1: pick a place. Step 2: write the note (ReminderEditorView).
struct AddReminderView: View {
    enum Source: String, CaseIterable, Identifiable {
        case nearby = "Near Me"
        case search = "Search"
        case googleMaps = "Google Maps"
        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .nearby
    @State private var selected: PlaceCandidate?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Find a place", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .bottom])

                switch source {
                case .nearby: NearbyPlacesView { selected = $0 }
                case .search: SearchPlacesView { selected = $0 }
                case .googleMaps: GoogleMapsImportView { selected = $0 }
                }
            }
            .navigationTitle("Where?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $selected) { place in
                ReminderEditorView(reminder: PlaceReminder(place: place), isNew: true) {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Near me

/// "I'm at the restaurant right now": lists places around you.
private struct NearbyPlacesView: View {
    @Environment(LocationService.self) private var location
    let onSelect: (PlaceCandidate) -> Void

    @State private var places: [PlaceCandidate] = []
    @State private var here: PlaceCandidate?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let here {
                Section {
                    PlaceRow(place: here, systemImage: "location.fill") { onSelect(here) }
                } footer: {
                    Text("Use your exact spot if the place isn't listed below.")
                }
            }
            if !places.isEmpty {
                Section("Nearby") {
                    ForEach(places) { place in
                        PlaceRow(place: place) { onSelect(place) }
                    }
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView("Finding places near you…")
            } else if let errorMessage {
                ContentUnavailableView("Can't find places", systemImage: "location.slash", description: Text(errorMessage))
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = places.isEmpty
        defer { isLoading = false }
        guard let current = await location.currentLocation() else {
            errorMessage = location.isDenied
                ? "Location access is off. Turn it on in Settings, or use Search or Google Maps instead."
                : "Couldn't get your location. Pull to try again."
            return
        }
        errorMessage = nil

        let described = await PlaceFinder.describe(current.coordinate)
        here = PlaceCandidate(
            name: described.name ?? "Current location",
            address: described.address,
            latitude: current.coordinate.latitude,
            longitude: current.coordinate.longitude)

        do {
            places = try await PlaceFinder.pointsOfInterest(near: current)
        } catch {
            places = []
        }
    }
}

// MARK: - Search

private struct SearchPlacesView: View {
    @Environment(LocationService.self) private var location
    let onSelect: (PlaceCandidate) -> Void

    @State private var query = ""
    @State private var completer = PlaceSearchCompleter()
    @State private var isResolving = false

    var body: some View {
        List(completer.results, id: \.self) { result in
            Button {
                Task { await select(result) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).foregroundStyle(.primary)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Restaurant, shop, address…")
        .onChange(of: query) { _, newValue in
            completer.update(query: newValue, near: location.lastLocation)
        }
        .overlay {
            if isResolving { ProgressView() }
            else if query.isEmpty {
                ContentUnavailableView("Search for a place", systemImage: "magnifyingglass",
                                       description: Text("Find somewhere you've been or plan to go back to."))
            }
        }
    }

    private func select(_ result: MKLocalSearchCompletion) async {
        isResolving = true
        defer { isResolving = false }
        if let place = try? await PlaceFinder.resolve(result) {
            onSelect(place)
        }
    }
}

// MARK: - Google Maps

private struct GoogleMapsImportView: View {
    @Environment(LocationService.self) private var location
    let onSelect: (PlaceCandidate) -> Void

    @State private var link = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("https://maps.app.goo.gl/…", text: $link, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    link = text
                    Task { await importLink() }
                }
            } header: {
                Text("Google Maps link")
            } footer: {
                Text("In Google Maps, open the place, tap **Share**, then **Copy**. Paste it here.")
            }

            Section {
                Button {
                    Task { await importLink() }
                } label: {
                    HStack {
                        Text("Find Place")
                        if isImporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func importLink() async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            let place = try await GoogleMapsImporter.importPlace(from: link, near: location.lastLocation)
            onSelect(place)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Shared

private struct PlaceRow: View {
    let place: PlaceCandidate
    var systemImage = "mappin.circle"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    if let address = place.address {
                        Text(address).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
