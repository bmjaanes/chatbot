import CoreLocation
import UserNotifications

/// Turns reminders into location-triggered notifications.
///
/// iOS does the geofencing itself (`UNLocationNotificationTrigger`), so the app doesn't need
/// to run in the background or ask for "Always" location access. "While Using" is enough.
enum NotificationScheduler {
    /// iOS keeps at most 64 pending notifications per app.
    static let maxScheduled = 64

    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Makes the pending notifications match `reminders`, touching only the ones that changed.
    /// (Re-registering an unchanged geofence can make it fire again while you're standing inside it.)
    static func sync(_ reminders: [PlaceReminder]) async {
        let center = UNUserNotificationCenter.current()
        let wanted = Dictionary(
            reminders.filter(\.isEnabled).prefix(maxScheduled).map { ($0.id.uuidString, $0) },
            uniquingKeysWith: { first, _ in first })

        // Requests added before permission is granted are rejected, so ask first (only once there's something to schedule).
        if !wanted.isEmpty, await authorizationStatus() == .notDetermined {
            await requestAuthorization()
        }

        let pending = await center.pendingNotificationRequests()
        var upToDate = Set<String>()
        var stale: [String] = []
        for request in pending {
            if let reminder = wanted[request.identifier],
               request.content.userInfo[signatureKey] as? String == signature(of: reminder) {
                upToDate.insert(request.identifier)
            } else {
                stale.append(request.identifier)
            }
        }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        for reminder in wanted.values where !upToDate.contains(reminder.id.uuidString) {
            let content = UNMutableNotificationContent()
            content.title = "Back at \(reminder.placeName)"
            content.body = reminder.note
            content.sound = .default
            content.threadIdentifier = reminder.id.uuidString
            content.userInfo = [signatureKey: signature(of: reminder)]

            let region = CLCircularRegion(
                center: reminder.coordinate,
                radius: reminder.radius,
                identifier: reminder.id.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = false

            // repeats: true means it fires every visit, not just the next one.
            let trigger = UNLocationNotificationTrigger(region: region, repeats: true)
            let request = UNNotificationRequest(
                identifier: reminder.id.uuidString, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                print("Couldn't schedule reminder for \(reminder.placeName): \(error)")
            }
        }
    }

    private static let signatureKey = "signature"

    private static func signature(of reminder: PlaceReminder) -> String {
        "\(reminder.latitude)|\(reminder.longitude)|\(reminder.radius)|\(reminder.placeName)|\(reminder.note)"
    }
}
