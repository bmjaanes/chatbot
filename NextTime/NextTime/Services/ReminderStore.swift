import Foundation
import Observation

/// Keeps the saved reminders on disk and in sync with the scheduled notifications.
@MainActor
@Observable
final class ReminderStore {
    /// The one store for the app and its Siri intent. Two instances would overwrite each other's saves.
    static let shared = ReminderStore()

    private(set) var reminders: [PlaceReminder] = []

    private let fileURL: URL
    private var syncTask: Task<Void, Never>?

    init(fileURL: URL = ReminderStore.defaultFileURL) {
        self.fileURL = fileURL
        if ScreenshotMode.isOn {
            reminders = ScreenshotMode.sampleReminders
            return
        }
        load()
        reschedule()
    }

    nonisolated static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "reminders.json")
    }

    func reminder(id: UUID) -> PlaceReminder? {
        reminders.first { $0.id == id }
    }

    /// Adds a new reminder or replaces an existing one with the same id.
    func save(_ reminder: PlaceReminder) {
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[index] = reminder
        } else {
            reminders.insert(reminder, at: 0)
        }
        changed()
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].isEnabled = isEnabled
        changed()
    }

    func delete(id: UUID) {
        reminders.removeAll { $0.id == id }
        changed()
    }

    func delete(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            reminders.remove(at: index)
        }
        changed()
    }

    // MARK: - Persistence

    private func changed() {
        guard !ScreenshotMode.isOn else { return }
        persist()
        reschedule()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            reminders = try JSONDecoder().decode([PlaceReminder].self, from: data)
        } catch {
            print("Couldn't read reminders: \(error)")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(reminders).write(to: fileURL, options: .atomic)
        } catch {
            print("Couldn't save reminders: \(error)")
        }
    }

    /// Re-registers notifications. Runs one at a time so an older snapshot never overwrites a newer one.
    /// Cheap to call: unchanged reminders are left alone.
    func reschedule() {
        guard !ScreenshotMode.isOn else { return }
        let snapshot = reminders
        let previous = syncTask
        syncTask = Task {
            await previous?.value
            await NotificationScheduler.sync(snapshot)
        }
    }
}
