import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Entry point for "Share → Next Time" from Google Maps (or any app that shares a Maps link).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

@MainActor
@Observable
final class ShareModel {
    enum Phase {
        case loading
        case ready(PlaceCandidate)
        case failed(String)
    }

    var phase: Phase = .loading
    var name = ""
    var note = ""
    var rating: Int?
    var isSaving = false
    /// A saved place at the same spot; the note is added to it instead of making a duplicate.
    private(set) var existing: PlaceReminder?

    private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    func load() async {
        let text = await sharedText()
        do {
            let place = try await GoogleMapsImporter.importPlace(from: text, near: nil)
            let here = Spot(place)
            existing = ReminderStore.shared.reminders.first { Spot($0).distance(to: here) <= 40 }
            name = existing?.placeName ?? place.name
            rating = existing?.rating
            phase = .ready(place)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    var canSave: Bool {
        guard case .ready = phase, !isSaving else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func save() async {
        guard case .ready(let place) = phase else { return }
        isSaving = true
        let store = ReminderStore.shared
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var reminder = existing ?? PlaceReminder(place: place)
        reminder.placeName = name.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            reminder.note = reminder.note.isEmpty ? text : reminder.note + "\n" + text
        }
        if let rating { reminder.rating = rating }
        reminder.isEnabled = true
        store.save(reminder)
        // Schedule the arrival reminder now. The app schedules it again the next time it opens, in case this didn't stick.
        await store.finishScheduling()
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    /// Everything the other app shared, as text: Google Maps sends the place name and a link.
    private func sharedText() async -> String {
        var parts: [String] = []
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                if let url = item as? URL { parts.append(url.absoluteString) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { parts.append(url.absoluteString) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                if let string = item as? String { parts.append(string) }
                else if let data = item as? Data, let string = String(data: data, encoding: .utf8) { parts.append(string) }
            }
        }
        // Text first so its first line (the place name) wins over a bare link.
        return parts.sorted { !$0.hasPrefix("http") && $1.hasPrefix("http") }.joined(separator: "\n")
    }
}

/// Just enough geometry to match a shared place with a saved one.
private struct Spot {
    let latitude: Double
    let longitude: Double

    init(_ place: PlaceCandidate) { latitude = place.latitude; longitude = place.longitude }
    init(_ reminder: PlaceReminder) { latitude = reminder.latitude; longitude = reminder.longitude }

    func distance(to other: Spot) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (other.latitude - latitude) * rad, dLng = (other.longitude - longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * rad) * cos(other.latitude * rad) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView("Finding the place…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't add this place", systemImage: "mappin.slash")
                    } description: {
                        Text(message)
                    }
                case .ready(let place):
                    form(place)
                }
            }
            .navigationTitle("Next Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await model.save() } }
                        .disabled(!model.canSave)
                }
            }
        }
        .task { await model.load() }
    }

    private func form(_ place: PlaceCandidate) -> some View {
        Form {
            Section {
                TextField("Name", text: $model.name)
                if let address = place.address {
                    Text(address).foregroundStyle(.secondary)
                }
            } header: {
                Text("Place")
            } footer: {
                if model.existing != nil {
                    Text("You've already saved this place. Your note will be added to it.")
                }
            }
            Section("Your rating") {
                StarRatingView(rating: $model.rating)
                    .frame(maxWidth: .infinity)
            }
            Section {
                TextField("e.g. Don't get the fish", text: $model.note, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Next time I'm here…")
            } footer: {
                Text("Add dishes and photos later in the Next Time app.")
            }
        }
    }
}
