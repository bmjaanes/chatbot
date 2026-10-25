import Foundation

/// Storage shared by the app and its Share extension.
enum AppGroup {
    static let identifier = "group.com.bmjaanes.nexttime"

    /// The shared container, or the app's own Application Support folder when the
    /// App Group isn't available (unsigned simulator builds).
    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? URL.applicationSupportDirectory
    }
}
