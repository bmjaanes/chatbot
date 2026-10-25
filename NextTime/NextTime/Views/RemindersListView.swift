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
    @State private var sort: SortOrder = .newest
    @State private var filter: RatingFilter = .all

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest", rating = "Highest Rated", name = "Name"
        var id: Self { self }
    }

    enum RatingFilter: String, CaseIterable, Identifiable {
        case all = "All Places", loved = "Loved (4–5 ★)", neverAgain = "Never Again (1–2 ★)"
        var id: Self { self }

        func includes(_ reminder: PlaceReminder) -> Bool {
            switch self {
            case .all: true
            case .loved: (reminder.rating ?? 0) >= 4
            case .neverAgain: (1...2).contains(reminder.rating ?? 0)
            }
        }
    }

    private var visibleReminders: [PlaceReminder] {
        let matching = store.reminders.filter(filter.includes)
        switch sort {
        case .newest: return matching.sorted { $0.createdAt > $1.createdAt }
        case .rating: return matching.sorted { ($0.rating ?? 0, $0.createdAt) > ($1.rating ?? 0, $1.createdAt) }
        case .name: return matching.sorted { $0.placeName.localizedCaseInsensitiveCompare($1.placeName) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if needsPermissions && !store.reminders.isEmpty {
                    PermissionBanner(locationDenied: location.isDenied,
                                     notificationsDenied: notificationStatus == .denied)
                }

                let visible = visibleReminders
                ForEach(visible) { reminder in
                    NavigationLink(value: reminder.id) {
                        ReminderRow(reminder: reminder)
                    }
                }
                .onDelete { offsets in store.delete(ids: offsets.map { visible[$0].id }) }
            }
            .overlay {
                if store.reminders.isEmpty {
                    EmptyStateView { isAdding = true }
                } else if visibleReminders.isEmpty {
                    ContentUnavailableView {
                        Label("No places here yet", systemImage: "star")
                    } description: {
                        Text("Nothing you've saved matches \u{201C}\(filter.rawValue)\u{201D}.")
                    } actions: {
                        Button("Show All Places") { filter = .all }
                    }
                }
            }
            .navigationTitle("Next Time")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Show", selection: $filter) {
                            ForEach(RatingFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Sort and Filter", systemImage: filter == .all
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .disabled(store.reminders.isEmpty)
                }
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
                // Places shared from Google Maps are written by the Share extension while the app is in the background.
                store.reloadFromDisk()
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
            if let photo = reminder.photos.first {
                PhotoThumbnail(name: photo, side: 44)
                    .frame(width: 44, height: 44)
                    .opacity(reminder.isEnabled ? 1 : 0.5)
            } else {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(reminder.isEnabled ? Color.accentColor : .secondary)
                    .frame(width: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.placeName)
                    .font(.headline)
                if let rating = reminder.rating {
                    StarsLabel(rating: rating)
                }
                if !reminder.note.isEmpty {
                    Text(reminder.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let dishes = reminder.dishSummary {
                    Text(dishes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
            Text("You can also share a place from Google Maps, or tell Siri: “Add a Next Time note”")
                .multilineTextAlignment(.center)
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
