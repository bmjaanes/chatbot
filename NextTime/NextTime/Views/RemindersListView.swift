import SwiftUI
import UserNotifications

struct RemindersListView: View {
    @Environment(ReminderStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(NotificationRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [UUID] = []
    @State private var isAdding = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if needsPermissions && !store.reminders.isEmpty {
                    PermissionBanner(locationDenied: location.isDenied,
                                     notificationsDenied: notificationStatus == .denied)
                }

                ForEach(store.reminders) { reminder in
                    NavigationLink(value: reminder.id) {
                        ReminderRow(reminder: reminder)
                    }
                }
                .onDelete { store.delete(atOffsets: $0) }
            }
            .overlay {
                if store.reminders.isEmpty {
                    EmptyStateView { isAdding = true }
                }
            }
            .navigationTitle("Next Time")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: {
                        Label("Add reminder", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let reminder = store.reminder(id: id) {
                    ReminderEditorView(reminder: reminder, isNew: false)
                } else {
                    ContentUnavailableView("Reminder deleted", systemImage: "mappin.slash")
                }
            }
            .sheet(isPresented: $isAdding) {
                AddReminderView()
            }
        }
        .onChange(of: router.openedReminderID, initial: true) { _, id in
            guard let id else { return }
            isAdding = false
            path = [id]
            router.openedReminderID = nil
        }
        .onChange(of: location.authorizationStatus) {
            // Location-triggered notifications can only be scheduled once location access is granted.
            store.reschedule()
        }
        .onAppear {
            switch ScreenshotMode.screen {
            case "detail": path = store.reminders.first.map { [$0.id] } ?? []
            case "add": isAdding = true
            default: break
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                store.reschedule()
                notificationStatus = await NotificationScheduler.authorizationStatus()
            }
        }
    }

    private var needsPermissions: Bool {
        location.isDenied || notificationStatus == .denied
    }
}

private struct ReminderRow: View {
    @Environment(ReminderStore.self) private var store
    let reminder: PlaceReminder

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(reminder.isEnabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.placeName)
                    .font(.headline)
                Text(reminder.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Toggle("Enabled", isOn: Binding(
                get: { reminder.isEnabled },
                set: { store.setEnabled($0, for: reminder.id) }))
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyStateView: View {
    let add: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No reminders yet", systemImage: "mappin.and.ellipse")
        } description: {
            Text("Leave a note for the next time you're somewhere, like “Don't get the fish” at a restaurant. You'll be reminded when you come back.")
        } actions: {
            Button("Add your first reminder", action: add)
                .buttonStyle(.borderedProminent)
            Text("Or just tell Siri: “Add a Next Time note”")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionBanner: View {
    let locationDenied: Bool
    let notificationsDenied: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Reminders are off", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var message: String {
        switch (locationDenied, notificationsDenied) {
        case (true, true): "Allow location (While Using) and notifications so Next Time can remind you."
        case (true, false): "Allow location access (While Using is enough) so Next Time knows when you arrive."
        default: "Allow notifications so Next Time can remind you when you arrive."
        }
    }
}
