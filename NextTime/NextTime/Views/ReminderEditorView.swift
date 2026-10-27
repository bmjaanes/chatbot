import MapKit
import PhotosUI
import SwiftUI

/// Writes or edits the note, rating, dishes and photos for a place.
struct ReminderEditorView: View {
    @Environment(ReminderStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var draft: PlaceReminder
    @State private var confirmingDelete = false
    @State private var newDish = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isTakingPhoto = false
    @State private var viewingPhoto: PhotoSelection?
    @State private var photoError: String?
    /// Photos added or removed since the editor opened. Files are only cleaned up once we know whether the user saved.
    @State private var addedPhotos: Set<String> = []
    @State private var removedPhotos: Set<String> = []
    @State private var didSave = false
    @FocusState private var noteFocused: Bool
    private let isNew: Bool
    private let notice: String?
    private let onDone: (() -> Void)?

    private static let radiusOptions: [Double] = [100, 150, 250, 500]
    private static let photoColumns = [GridItem(.adaptive(minimum: 96), spacing: 6)]

    init(reminder: PlaceReminder, isNew: Bool, notice: String? = nil, onDone: (() -> Void)? = nil) {
        _draft = State(initialValue: reminder)
        self.isNew = isNew
        self.notice = notice
        self.onDone = onDone
    }

    var body: some View {
        Form {
            if let notice {
                Section {
                    Label(notice, systemImage: "person.2.fill")
                        .font(.subheadline)
                }
            }
            Section {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: draft.coordinate, latitudinalMeters: 800, longitudinalMeters: 800))) {
                    Marker(draft.placeName, coordinate: draft.coordinate)
                    MapCircle(center: draft.coordinate, radius: draft.radius)
                        .foregroundStyle(Color.accentColor.opacity(0.2))
                        .stroke(Color.accentColor, lineWidth: 1)
                }
                .frame(height: 200)
                .listRowInsets(EdgeInsets())
            }

            Section("Place") {
                TextField("Name", text: $draft.placeName)
                if let address = draft.address {
                    Text(address).foregroundStyle(.secondary)
                }
            }

            Section("Your rating") {
                StarRatingView(rating: $draft.rating)
                    .frame(maxWidth: .infinity)
            }

            Section("Next time I'm here…") {
                TextField("e.g. Ask for the patio. Cash only.", text: $draft.note, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($noteFocused)
            }

            dishesSection
            photosSection

            Section {
                Picker("Remind me within", selection: $draft.radius) {
                    ForEach(Self.radiusOptions, id: \.self) { meters in
                        Text(Measurement(value: meters, unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road)))
                            .tag(meters)
                    }
                }
            } footer: {
                Text("You'll get a notification every time you arrive. A bigger area is more reliable; a smaller one avoids alerts when you're only passing by.")
            }

            if !isNew {
                Section {
                    let shared = SharedPlace(draft)
                    ShareLink(item: shared.link, subject: Text(draft.placeName), message: Text(shared.summary)) {
                        Label("Share with a Friend", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Sends your rating, note and dishes as a link. Photos stay on your phone.")
                }
                Section {
                    Toggle("Reminder on", isOn: $draft.isEnabled)
                    Button {
                        let urls = draft.googleMapsURLs
                        openURL(urls.app) { opened in
                            if !opened { openURL(urls.web) }
                        }
                    } label: {
                        Label("Open in Google Maps", systemImage: "map")
                    }
                }
                Section {
                    Button("Delete Reminder", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(isNew ? "New Reminder" : draft.placeName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
            }
        }
        .confirmationDialog("Delete this reminder?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                PhotoStore.delete(Array(addedPhotos))
                didSave = true
                store.delete(id: draft.id)
                finish()
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await importPicked(items) }
        }
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPicker { image in addPhoto(image) }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $viewingPhoto) { selection in
            PhotoViewer(photos: draft.photos, startIndex: selection.index) { name in
                removePhoto(name)
            }
        }
        .onAppear { if isNew { noteFocused = true } }
        .onDisappear {
            // Leaving without saving: drop photos that were only added in this session.
            if !didSave { PhotoStore.delete(Array(addedPhotos)) }
        }
    }

    // MARK: - Dishes

    private var dishesSection: some View {
        Section {
            ForEach($draft.dishes) { $dish in
                HStack {
                    TextField("Dish", text: $dish.name)
                    Button {
                        dish.verdict = dish.verdict == .good ? .bad : .good
                    } label: {
                        Text(dish.verdict.emoji).font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(dish.verdict == .good ? "Get again" : "Skip next time")
                    .accessibilityHint("Double-tap to switch")
                }
            }
            .onDelete { draft.dishes.remove(atOffsets: $0) }

            HStack {
                TextField("Add a dish, e.g. Fish tacos", text: $newDish)
                    .submitLabel(.done)
                    .onSubmit { addDish(.good) }
                Button { addDish(.good) } label: { Text("👍").font(.title3) }
                    .accessibilityLabel("Add as good")
                Button { addDish(.bad) } label: { Text("👎").font(.title3) }
                    .accessibilityLabel("Add as skip")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("What I had")
        } footer: {
            Text("Tap 👍 or 👎 to change your verdict. Swipe left to remove.")
        }
    }

    private func addDish(_ verdict: DishNote.Verdict) {
        let name = newDish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        draft.dishes.append(DishNote(name: name, verdict: verdict))
        newDish = ""
    }

    // MARK: - Photos

    private var photosSection: some View {
        Section {
            if !draft.photos.isEmpty {
                LazyVGrid(columns: Self.photoColumns, spacing: 6) {
                    ForEach(Array(draft.photos.enumerated()), id: \.element) { index, name in
                        Button {
                            viewingPhoto = PhotoSelection(index: index)
                        } label: {
                            PhotoThumbnail(name: name)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Photo \(index + 1)")
                    }
                }
                .padding(.vertical, 4)
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    isTakingPhoto = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                Label("Add from Photos", systemImage: "photo.on.rectangle")
            }
            if let photoError {
                Text(photoError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Photos")
        } footer: {
            Text("Menus, dishes, receipts or screenshots. Photos stay on your iPhone.")
        }
    }

    private func addPhoto(_ image: UIImage) {
        do {
            let name = try PhotoStore.save(image)
            addedPhotos.insert(name)
            draft.photos.append(name)
            photoError = nil
        } catch {
            photoError = "Couldn't save that photo. Check that your iPhone has free space."
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                photoError = "One of those photos couldn't be loaded."
                continue
            }
            addPhoto(image)
        }
    }

    private func removePhoto(_ name: String) {
        draft.photos.removeAll { $0 == name }
        if addedPhotos.remove(name) != nil {
            PhotoStore.delete([name])
        } else {
            removedPhotos.insert(name)
        }
    }

    // MARK: - Saving

    private var canSave: Bool {
        let hasContent = !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.rating != nil || !draft.dishes.isEmpty || !draft.photos.isEmpty
        return hasContent && !draft.placeName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        addDish(.good) // keep a dish that was typed but not added
        draft.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.placeName = draft.placeName.trimmingCharacters(in: .whitespaces)
        draft.dishes.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        // Ask in context, the first time it's actually needed. Saving also asks for notification permission.
        location.requestPermission()
        store.save(draft)
        PhotoStore.delete(Array(removedPhotos))
        didSave = true
        finish()
    }

    private func finish() {
        if let onDone { onDone() } else { dismiss() }
    }
}

private struct PhotoSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

/// A square, cropped thumbnail of a saved photo.
struct PhotoThumbnail: View {
    let name: String
    var side: CGFloat = 96

    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: name) {
                image = await PhotoStore.thumbnail(named: name, side: side * 3)
            }
    }
}

/// Swipe through a place's photos full screen.
private struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [String]
    @State private var index: Int
    let onDelete: (String) -> Void

    init(photos: [String], startIndex: Int, onDelete: @escaping (String) -> Void) {
        _photos = State(initialValue: photos)
        _index = State(initialValue: startIndex)
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element) { i, name in
                    Group {
                        if let image = PhotoStore.image(named: name) {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            ContentUnavailableView("Photo missing", systemImage: "photo")
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
            .background(Color.black)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        guard photos.indices.contains(index) else { return }
                        let name = photos.remove(at: index)
                        onDelete(name)
                        if photos.isEmpty { dismiss() } else { index = min(index, photos.count - 1) }
                    } label: {
                        Label("Delete Photo", systemImage: "trash")
                    }
                }
            }
        }
    }
}

/// The system camera, for taking a photo of a menu, dish or receipt.
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
