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
        let url = AppGroup.containerURL.appending(path: "reminders.json")
        // Versions before the Share extension kept reminders in the app's own folder.
        let legacy = URL.applicationSupportDirectory.appending(path: "reminders.json")
        if legacy != url, !FileManager.default.fileExists(atPath: url.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: url)
        }
        return url
    }

    /// Picks up places the Share extension saved while the app was in the background.
    func reloadFromDisk() {
        guard !ScreenshotMode.isOn else { return }
        load()
        reschedule()
    }

    /// Waits for pending notification scheduling, for the Share extension before it closes.
    func finishScheduling() async {
        await syncTask?.value
    }

    func reminder(id: UUID) -> PlaceReminder? {
        reminders.first { $0.id == id }
    }

    /// Called after every local edit, so iCloud sync can upload it.
    var onLocalChange: (() -> Void)?

    /// Adds a new reminder or replaces an existing one with the same id.
    func save(_ reminder: PlaceReminder) {
        var reminder = reminder
        reminder.updatedAt = Date()
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
        reminders[index].updatedAt = Date()
        changed()
    }

    func delete(id: UUID) {
        PhotoStore.delete(reminders.filter { $0.id == id }.flatMap(\.photos))
        reminders.removeAll { $0.id == id }
        changed()
    }

    func delete(ids: [UUID]) {
        let doomed = Set(ids)
        PhotoStore.delete(reminders.filter { doomed.contains($0.id) }.flatMap(\.photos))
        reminders.removeAll { doomed.contains($0.id) }
        changed()
    }

    // MARK: - Persistence

    /// Applies places changed or deleted on another device. Unlike `save`, it keeps their timestamps.
    func applyRemote(upserts: [PlaceReminder], deletions: Set<UUID>) {
        guard !upserts.isEmpty || !deletions.isEmpty else { return }
        PhotoStore.delete(reminders.filter { deletions.contains($0.id) }.flatMap(\.photos))
        reminders.removeAll { deletions.contains($0.id) }
        for reminder in upserts {
            if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
                let dropped = Set(reminders[index].photos).subtracting(reminder.photos)
                PhotoStore.delete(Array(dropped))
                reminders[index] = reminder
            } else {
                reminders.insert(reminder, at: 0)
            }
        }
        guard !ScreenshotMode.isOn else { return }
        persist()
        reschedule()
    }

    private func changed() {
        guard !ScreenshotMode.isOn else { return }
        persist()
        reschedule()
        onLocalChange?()
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
