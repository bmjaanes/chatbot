import SwiftUI
import UserNotifications

@main
struct NextTimeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Shared with the Siri intent, so a note added by voice shows up immediately.
    @State private var store = ReminderStore.shared
    @State private var location = LocationService()

    var body: some Scene {
        WindowGroup {
            RemindersListView()
                .environment(store)
                .environment(location)
                .environment(NotificationRouter.shared)
        }
    }
}

/// Lets a tapped notification open the matching reminder.
@MainActor
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()
    var openedReminderID: UUID?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Show the banner even if the app happens to be open when you arrive.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = UUID(uuidString: response.notification.request.identifier)
        Task { @MainActor in NotificationRouter.shared.openedReminderID = id }
        completionHandler()
    }
}
