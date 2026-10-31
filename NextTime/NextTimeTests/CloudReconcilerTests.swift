import XCTest
@testable import NextTime

/// The iCloud sync engine, run against temporary folders standing in for iCloud Drive and the phone.
/// These are the cases where a bug would lose someone's places.
final class CloudReconcilerTests: XCTestCase {
    private var root: URL!
    private var folders: CloudFolders!
    private var localPhotos: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CloudReconcilerTests-\(UUID().uuidString)")
        folders = CloudFolders(places: root.appending(path: "iCloud/Places"), photos: root.appending(path: "iCloud/Photos"))
        localPhotos = root.appending(path: "Phone/Photos")
        for url in [folders.places, folders.photos, localPhotos!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        // A test may have made the iCloud folder read-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folders.places.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func place(_ name: String, note: String = "", updated: Date = Date(timeIntervalSince1970: 1_000), photos: [String] = []) -> PlaceReminder {
        var place = PlaceReminder(place: PlaceCandidate(name: name, latitude: 45.5, longitude: -122.6))
        place.note = note
        place.updatedAt = updated
        place.photos = photos
        return place
    }

    private func putInICloud(_ place: PlaceReminder) throws {
        try JSONEncoder().encode(place).write(to: folders.places.appending(path: "\(place.id.uuidString).json"))
    }

    private func iCloudPlace(_ id: UUID) -> PlaceReminder? {
        guard let data = try? Data(contentsOf: folders.places.appending(path: "\(id.uuidString).json")) else { return nil }
        return try? JSONDecoder().decode(PlaceReminder.self, from: data)
    }

    private func iCloudPlaceIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folders.places.path)) ?? []
        return Set(names.compactMap { UUID(uuidString: $0.replacingOccurrences(of: ".json", with: "")) })
    }

    private func sync(local: [PlaceReminder], synced: Set<UUID>) -> CloudReconciler.Result {
        CloudReconciler.run(local: local, synced: synced, folders: folders, localPhotos: localPhotos)
    }

    // MARK: - Places

    func testNewPlaceOnThisPhoneIsBackedUp() {
        let harbor = place("Harbor Fish House")
        let result = sync(local: [harbor], synced: [])

        XCTAssertEqual(iCloudPlace(harbor.id)?.placeName, "Harbor Fish House")
        XCTAssertEqual(result.synced, [harbor.id])
        XCTAssertTrue(result.upserts.isEmpty)
        XCTAssertTrue(result.deletions.isEmpty)
        XCTAssertEqual(result.failures, 0)
    }

    func testPlaceAddedOnAnotherDeviceComesToThisPhone() throws {
        let luna = place("Luna Taqueria")
        try putInICloud(luna)

        let result = sync(local: [], synced: [])

        XCTAssertEqual(result.upserts.map(\.id), [luna.id])
        XCTAssertEqual(result.synced, [luna.id])
    }

    func testRestoringOnANewPhoneBringsEverythingBack() throws {
        let places = [place("A"), place("B"), place("C")]
        try places.forEach(putInICloud)

        let result = sync(local: [], synced: [])

        XCTAssertEqual(Set(result.upserts.map(\.id)), Set(places.map(\.id)))
        XCTAssertTrue(result.deletions.isEmpty)
    }

    func testDeletingOnThisPhoneRemovesItFromICloud() throws {
        let deleted = place("Deleted"), kept = place("Kept")
        try putInICloud(deleted)
        try putInICloud(kept)

        let result = sync(local: [kept], synced: [deleted.id, kept.id])

        XCTAssertEqual(iCloudPlaceIDs(), [kept.id])
        XCTAssertTrue(result.upserts.isEmpty, "a place deleted here must not come back")
        XCTAssertEqual(result.synced, [kept.id])
    }

    func testDeletingOnAnotherDeviceRemovesItHere() throws {
        let deleted = place("Deleted"), kept = place("Kept")
        try putInICloud(kept)

        let result = sync(local: [deleted, kept], synced: [deleted.id, kept.id])

        XCTAssertEqual(result.deletions, [deleted.id])
        XCTAssertEqual(iCloudPlaceIDs(), [kept.id], "a place deleted elsewhere must not be uploaded again")
    }

    func testNewerEditFromAnotherDeviceWins() throws {
        let mine = place("Harbor", note: "old note", updated: Date(timeIntervalSince1970: 1_000))
        var theirs = mine
        theirs.note = "newer note"
        theirs.updatedAt = Date(timeIntervalSince1970: 2_000)
        try putInICloud(theirs)

        let result = sync(local: [mine], synced: [mine.id])

        XCTAssertEqual(result.upserts.first?.note, "newer note")
        XCTAssertEqual(iCloudPlace(mine.id)?.note, "newer note")
    }

    func testNewerEditOnThisPhoneIsUploaded() throws {
        let theirs = place("Harbor", note: "old note", updated: Date(timeIntervalSince1970: 1_000))
        var mine = theirs
        mine.note = "newer note"
        mine.updatedAt = Date(timeIntervalSince1970: 2_000)
        try putInICloud(theirs)

        let result = sync(local: [mine], synced: [mine.id])

        XCTAssertTrue(result.upserts.isEmpty)
        XCTAssertEqual(iCloudPlace(mine.id)?.note, "newer note")
    }

    func testEmptyICloudIsRefilledInsteadOfDeletingEverything() {
        // iCloud was reset, or this is a different account: nothing there, though we'd synced before.
        let a = place("A"), b = place("B")

        let result = sync(local: [a, b], synced: [a.id, b.id])

        XCTAssertTrue(result.deletions.isEmpty, "an empty iCloud must never wipe the phone")
        XCTAssertEqual(iCloudPlaceIDs(), [a.id, b.id])
        XCTAssertEqual(result.synced, [a.id, b.id])
    }

    func testPlaceNotYetDownloadedFromICloudIsKept() throws {
        let other = place("Other"), waiting = place("Waiting")
        try putInICloud(other)
        // iCloud has the file but hasn't downloaded it yet: only a placeholder is on disk.
        try Data().write(to: folders.places.appending(path: ".\(waiting.id.uuidString).json.icloud"))

        let result = sync(local: [other, waiting], synced: [other.id, waiting.id])

        XCTAssertTrue(result.deletions.isEmpty, "a place still downloading is not a deleted place")
        XCTAssertTrue(result.synced.contains(waiting.id))
    }

    func testFailedBackupIsRetriedNotMistakenForADeletion() throws {
        let harbor = place("Harbor")
        try putInICloud(place("Something else")) // so iCloud isn't empty
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folders.places.path)

        let result = sync(local: [harbor], synced: [])

        XCTAssertGreaterThan(result.failures, 0)
        XCTAssertFalse(result.synced.contains(harbor.id),
                       "if it's marked synced, the next sync would think it was deleted elsewhere")
    }

    // MARK: - Photos

    func testPhotosAreBackedUpAndRestored() throws {
        try Data("mine".utf8).write(to: localPhotos.appending(path: "mine.jpg"))
        try Data("theirs".utf8).write(to: folders.photos.appending(path: "theirs.jpg"))
        let mine = place("Mine", photos: ["mine.jpg"])
        let theirs = place("Theirs", photos: ["theirs.jpg"])
        try putInICloud(theirs)

        _ = sync(local: [mine], synced: [])

        XCTAssertEqual(try Data(contentsOf: folders.photos.appending(path: "mine.jpg")), Data("mine".utf8))
        XCTAssertEqual(try Data(contentsOf: localPhotos.appending(path: "theirs.jpg")), Data("theirs".utf8))
    }

    func testOnlyOldUnusedPhotosAreRemovedFromICloud() throws {
        let old = folders.photos.appending(path: "old.jpg")
        let fresh = folders.photos.appending(path: "fresh.jpg")
        try Data("x".utf8).write(to: old)
        try Data("x".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)

        _ = sync(local: [place("A")], synced: [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "another device may have uploaded the photo before its place")
    }
}
