import MapKit
import SwiftUI

/// Writes or edits the note for a place.
struct ReminderEditorView: View {
    @Environment(ReminderStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var draft: PlaceReminder
    @State private var confirmingDelete = false
    @FocusState private var noteFocused: Bool
    private let isNew: Bool
    private let onDone: (() -> Void)?

    private static let radiusOptions: [Double] = [100, 150, 250, 500]

    init(reminder: PlaceReminder, isNew: Bool, onDone: (() -> Void)? = nil) {
        _draft = State(initialValue: reminder)
        self.isNew = isNew
        self.onDone = onDone
    }

    var body: some View {
        Form {
            Section {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: draft.coordinate, latitudinalMeters: 800, longitudinalMeters: 800))) {
                    Marker(draft.placeName, coordinate: draft.coordinate)
                    MapCircle(center: draft.coordinate, radius: draft.radius)
                        .foregroundStyle(Color.accentColor.opacity(0.2))
                        .stroke(Color.accentColor, lineWidth: 1)
                }
                .frame(height: 200)
                .listRowInsets(EdgeInsets())
            }

            Section("Place") {
                TextField("Name", text: $draft.placeName)
                if let address = draft.address {
                    Text(address).foregroundStyle(.secondary)
                }
            }

            Section("Next time I'm here…") {
                TextField("e.g. Don't get the fish. The burger was great.", text: $draft.note, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($noteFocused)
            }

            Section {
                Picker("Remind me within", selection: $draft.radius) {
                    ForEach(Self.radiusOptions, id: \.self) { meters in
                        Text(Measurement(value: meters, unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road)))
                            .tag(meters)
                    }
                }
            } footer: {
                Text("You'll get a notification every time you arrive. A bigger area is more reliable; a smaller one avoids alerts when you're only passing by.")
            }

            if !isNew {
                Section {
                    Toggle("Reminder on", isOn: $draft.isEnabled)
                    Button {
                        let urls = draft.googleMapsURLs
                        openURL(urls.app) { opened in
                            if !opened { openURL(urls.web) }
                        }
                    } label: {
                        Label("Open in Google Maps", systemImage: "map")
                    }
                }
                Section {
                    Button("Delete Reminder", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(isNew ? "New Reminder" : draft.placeName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
            }
        }
        .confirmationDialog("Delete this reminder?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(id: draft.id)
                finish()
            }
        }
        .onAppear { if isNew { noteFocused = true } }
    }

    private var canSave: Bool {
        !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.placeName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        draft.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.placeName = draft.placeName.trimmingCharacters(in: .whitespaces)
        // Ask in context, the first time it's actually needed. Saving also asks for notification permission.
        location.requestPermission()
        store.save(draft)
        finish()
    }

    private func finish() {
        if let onDone { onDone() } else { dismiss() }
    }
}
