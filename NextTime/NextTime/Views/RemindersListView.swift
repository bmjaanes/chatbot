import SwiftUI
import UserNotifications

struct RemindersListView: View {
    @Environment(ReminderStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(NotificationRouter.self) private var router
    @Environment(CloudSync.self) private var cloud
    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [UUID] = []
    @State private var isAdding = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var sort: SortOrder = .newest
    @State private var filter: RatingFilter = .all
    @State private var categoryFilter: PlaceCategory?
    @State private var importing: ImportedPlace?

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
        let matching = store.reminders.filter { filter.includes($0) && (categoryFilter == nil || $0.category == categoryFilter) }
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
                    .contextMenu {
                        let shared = SharedPlace(reminder)
                        ShareLink(item: shared.link, subject: Text(reminder.placeName), message: Text(shared.summary)) {
                            Label("Share with a Friend", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .onDelete { offsets in store.delete(ids: offsets.map { visible[$0].id }) }

                if !store.reminders.isEmpty {
                    Section {
                    } footer: {
                        CloudStatusView()
                    }
                }
            }
            .overlay {
                if store.reminders.isEmpty {
                    EmptyStateView { isAdding = true }
                } else if visibleReminders.isEmpty {
                    ContentUnavailableView {
                        Label("No places here yet", systemImage: "star")
                    } description: {
                        Text("Nothing you've saved matches these filters.")
                    } actions: {
                        Button("Show All Places") { filter = .all; categoryFilter = nil }
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
                        Picker("Category", selection: $categoryFilter) {
                            Text("All Categories").tag(PlaceCategory?.none)
                            ForEach(PlaceCategory.allCases) { category in
                                Label(category.title, systemImage: category.symbol).tag(PlaceCategory?.some(category))
                            }
                        }
                    } label: {
                        Label("Sort and Filter", systemImage: filter == .all && categoryFilter == nil
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
            .sheet(item: $importing) { imported in
                NavigationStack {
                    ReminderEditorView(
                        reminder: imported.place.reminder(),
                        isNew: true,
                        notice: "A friend shared this place. Change anything you like, then save it to your places.",
                        onDone: { importing = nil })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { importing = nil }
                        }
                    }
                }
            }
        }
        .onChange(of: router.importedPlace, initial: true) { _, place in
            guard let place else { return }
            isAdding = false
            importing = ImportedPlace(place: place)
            router.importedPlace = nil
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
                cloud.start()
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
                Image(systemName: reminder.category?.symbol ?? (reminder.isArea ? "building.2" : "mappin"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(reminder.isEnabled ? Color.accentColor : .secondary, in: Circle())
                    .frame(width: 44)
                    .accessibilityLabel(reminder.category?.title ?? "Place")
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

private struct ImportedPlace: Identifiable {
    let id = UUID()
    let place: SharedPlace
}

/// "Backed up to iCloud · 2 min ago". Tap to sync now.
private struct CloudStatusView: View {
    @Environment(CloudSync.self) private var cloud

    var body: some View {
        Button {
            cloud.requestSync()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(message)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Double-tap to back up now")
    }

    private var icon: String {
        switch cloud.status {
        case .starting, .syncing: "arrow.triangle.2.circlepath.icloud"
        case .synced: "checkmark.icloud"
        case .unavailable: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }

    private var message: String {
        switch cloud.status {
        case .starting: "Checking iCloud…"
        case .syncing: "Backing up to iCloud…"
        case .synced(let date):
            date.timeIntervalSinceNow > -60
                ? "Backed up to iCloud just now"
                : "Backed up to iCloud " + date.formatted(.relative(presentation: .named))
        case .unavailable: "Not backed up. Sign in to iCloud and turn on iCloud Drive in Settings."
        case .failed(let reason): reason
        }
    }
}
