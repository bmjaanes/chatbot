import Foundation
import Observation

/// Backs places and photos up to the user's own iCloud Drive and keeps their devices in sync.
///
/// Each place is one JSON file and each photo one JPEG in the app's private iCloud container, so two
/// devices editing different places never conflict. When both edited the same place, the newer edit wins.
/// The app keeps working from its local copy; this runs in the background after edits and on launch.
@MainActor
@Observable
final class CloudSync {
    enum Status: Equatable {
        case starting
        case unavailable
        case syncing
        case synced(Date)
        case failed(String)
    }

    nonisolated static let containerIdentifier = "iCloud.com.bmjaanes.nexttime"

    private(set) var status: Status = .starting

    private let store: ReminderStore
    private var folders: CloudFolders?
    private var query: NSMetadataQuery?
    private var syncTask: Task<Void, Never>?
    private var pendingSync: Task<Void, Never>?
    private var needsAnotherPass = false
    private var state: SyncState

    init(store: ReminderStore) {
        self.store = store
        state = SyncState.load()
    }

    /// Call on launch and whenever the app comes to the foreground.
    func start() {
        guard !ScreenshotMode.isOn else { return }
        if folders != nil {
            requestSync()
            return
        }
        Task {
            // Looking up the container can block, so it stays off the main thread.
            let found = await Task.detached { CloudFolders.locate() }.value
            guard let found else {
                status = .unavailable
                return
            }
            folders = found
            store.onLocalChange = { [weak self] in self?.requestSync(after: .seconds(2)) }
            watch()
            requestSync()
        }
    }

    /// Syncs soon, coalescing bursts of edits and iCloud notifications into one pass.
    func requestSync(after delay: Duration = .zero) {
        pendingSync?.cancel()
        pendingSync = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            runSync()
        }
    }

    private func runSync() {
        guard let folders else { return }
        if syncTask != nil {
            needsAnotherPass = true
            return
        }
        syncTask = Task {
            repeat {
                needsAnotherPass = false
                await syncOnce(folders)
            } while needsAnotherPass
            syncTask = nil
        }
    }

    private func syncOnce(_ folders: CloudFolders) async {
        status = .syncing

        // A different iCloud account has its own, empty container: start over rather than read
        // "nothing in iCloud" as "everything was deleted".
        let account = CloudFolders.accountFingerprint()
        if account != state.account {
            state = SyncState(account: account, synced: [])
        }

        let local = store.reminders
        let synced = state.synced
        let result = await Task.detached { CloudReconciler.run(local: local, synced: synced, folders: folders) }.value

        store.applyRemote(upserts: result.upserts, deletions: result.deletions)
        state.synced = result.synced
        state.save()
        status = result.failures == 0
            ? .synced(Date())
            : .failed("Some places couldn't be backed up. They'll be retried automatically.")
    }

    /// iCloud tells us when files change on another device.
    private func watch() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestSync(after: .seconds(1)) }
            }
        }
        query.start()
        self.query = query
    }
}

/// Which places are known to be in iCloud, so a missing file can be told apart from one never uploaded.
private struct SyncState: Codable {
    var account: Data?
    var synced: Set<UUID>

    private static var url: URL { AppGroup.containerURL.appending(path: "icloud-sync.json") }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState(account: nil, synced: [])
        }
        return state
    }

    func save() {
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

struct CloudFolders: Sendable {
    let places: URL
    let photos: URL

    /// nil when the user isn't signed in to iCloud or has iCloud Drive turned off for the app.
    static func locate() -> CloudFolders? {
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: CloudSync.containerIdentifier) else {
            return nil
        }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let folders = CloudFolders(places: documents.appending(path: "Places", directoryHint: .isDirectory),
                                   photos: documents.appending(path: "Photos", directoryHint: .isDirectory))
        for url in [folders.places, folders.photos] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return folders
    }

    /// Changes when the user signs in to a different iCloud account.
    static func accountFingerprint() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
    }
}

enum CloudReconciler {
    struct Result: Sendable {
        var upserts: [PlaceReminder] = []
        var deletions: Set<UUID> = []
        var synced: Set<UUID> = []
        var failures = 0
    }

    /// iCloud files that exist but aren't downloaded yet show up as ".name.icloud" placeholders.
    private static func placeholderName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// `localPhotos` is where this device keeps photos; tests pass a temporary folder.
    static func run(local: [PlaceReminder], synced: Set<UUID>, folders: CloudFolders,
                    localPhotos: URL = PhotoStore.directory) -> Result {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var result = Result()

        // 1. What's in iCloud.
        var cloud: [UUID: PlaceReminder] = [:]
        var notDownloaded: Set<UUID> = []
        let listing = (try? fm.contentsOfDirectory(atPath: folders.places.path)) ?? []
        for name in listing {
            let fileName = placeholderName(name) ?? name
            guard fileName.hasSuffix(".json"), let id = UUID(uuidString: String(fileName.dropLast(5))) else { continue }
            let url = folders.places.appending(path: fileName)
            if placeholderName(name) != nil {
                notDownloaded.insert(id)
                try? fm.startDownloadingUbiquitousItem(at: url)
            } else if let data = coordinatedRead(url), let place = try? decoder.decode(PlaceReminder.self, from: data) {
                cloud[id] = place
            } else {
                notDownloaded.insert(id)
            }
        }
        let cloudIDs = Set(cloud.keys).union(notDownloaded)

        // If iCloud is suddenly empty but we'd synced before, the iCloud data was reset. Restore it from
        // this device instead of deleting everything here.
        let trusted = cloudIDs.isEmpty ? Set<UUID>() : synced

        // 2. Decide what moves where.
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var uploads: [PlaceReminder] = []
        var cloudDeletions: [UUID] = []

        for (id, remote) in cloud {
            if let mine = localByID[id] {
                if remote.updatedAt > mine.updatedAt { result.upserts.append(remote) }
                else if mine.updatedAt > remote.updatedAt { uploads.append(mine) }
            } else if trusted.contains(id) {
                cloudDeletions.append(id) // deleted on this device
            } else {
                result.upserts.append(remote) // added on another device
            }
        }
        for id in notDownloaded where localByID[id] == nil && trusted.contains(id) {
            cloudDeletions.append(id)
        }
        for mine in local where !cloudIDs.contains(mine.id) {
            if trusted.contains(mine.id) {
                result.deletions.insert(mine.id) // deleted on another device
            } else {
                uploads.append(mine) // new here
            }
        }

        // 3. Apply to iCloud.
        var inCloud = cloudIDs
        for place in uploads {
            if let data = try? encoder.encode(place),
               coordinatedWrite(data, to: folders.places.appending(path: "\(place.id.uuidString).json")) {
                inCloud.insert(place.id)
            } else {
                result.failures += 1
            }
        }
        for id in cloudDeletions {
            coordinatedDelete(folders.places.appending(path: "\(id.uuidString).json"))
            inCloud.remove(id)
        }

        // 4. Photos: make sure every photo of every place is both here and in iCloud.
        let deleted = Set(cloudDeletions).union(result.deletions)
        var merged = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for place in result.upserts { merged[place.id] = place }
        for id in deleted { merged[id] = nil }
        let wanted = Set(merged.values.flatMap(\.photos))

        let cloudPhotoListing = (try? fm.contentsOfDirectory(atPath: folders.photos.path)) ?? []
        var cloudPhotos: Set<String> = []
        var cloudPhotosPending: Set<String> = []
        for name in cloudPhotoListing {
            if let real = placeholderName(name) { cloudPhotosPending.insert(real) } else { cloudPhotos.insert(name) }
        }
        try? fm.createDirectory(at: localPhotos, withIntermediateDirectories: true)
        for name in wanted {
            let here = localPhotos.appending(path: name)
            let there = folders.photos.appending(path: name)
            let isHere = fm.fileExists(atPath: here.path)
            if isHere, !cloudPhotos.contains(name), !cloudPhotosPending.contains(name) {
                if let data = try? Data(contentsOf: here), !coordinatedWrite(data, to: there) { result.failures += 1 }
            } else if !isHere, cloudPhotos.contains(name) {
                if let data = coordinatedRead(there) { try? data.write(to: here, options: .atomic) }
            } else if !isHere, cloudPhotosPending.contains(name) {
                try? fm.startDownloadingUbiquitousItem(at: there)
            }
        }
        // Remove photos nobody uses any more. Wait a day, in case another device uploaded the photo before its place.
        let dayAgo = Date().addingTimeInterval(-86_400)
        for name in cloudPhotos where !wanted.contains(name) {
            let url = folders.photos.appending(path: name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < dayAgo { coordinatedDelete(url) }
        }

        // Only places confirmed in iCloud count as synced; a failed upload is retried, never mistaken for a deletion.
        result.synced = Set(merged.keys).intersection(inCloud)
        return result
    }

    // MARK: - Coordinated file access (required for iCloud files)

    private static func coordinatedRead(_ url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) -> Bool {
        var ok = false
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            ok = (try? data.write(to: url, options: .atomic)) != nil
        }
        return ok && error == nil
    }

    private static func coordinatedDelete(_ url: URL) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }
}
