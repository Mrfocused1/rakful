import PhotosUI
import SwiftData
import SwiftUI

struct ItemDetailView: View {
    @Query private var results: [CandidateItem]

    init(itemID: UUID) {
        _results = Query(filter: #Predicate<CandidateItem> { $0.id == itemID })
    }

    var body: some View {
        if let item = results.first {
            ItemDetailContent(item: item)
        } else {
            ContentUnavailableView("Item Removed", systemImage: "square.dashed", description: Text("This item is no longer in Rakful."))
        }
    }
}

private struct ItemDetailContent: View {
    @Bindable var item: CandidateItem

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(PreferencesStore.self) private var preferences
    @Environment(EntitlementService.self) private var entitlements
    @Environment(SaveFailureCenter.self) private var saves

    @State private var showsRemoveConfirmation = false
    @State private var showsCombine = false
    @State private var feedback = 0

    var body: some View {
        List {
            Section {
                PhotoCarousel(item: item)
                    .frame(height: 320)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label(item.category.displayName, systemImage: item.category.systemImage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if item.isDemo { SampleBadge() }
                    }
                    Text(item.displayName).font(.title2.weight(.bold))
                    ConfidenceIndicator(level: item.confidenceLevel)
                }
                .padding(.vertical, 4)
            }

            ownershipSection
            identitySection
            valueSection
            readinessSection
            ItemPhotosSection(item: item)
            provenanceSection

            Section {
                if !item.isDemo {
                    Button("Combine With Another Item…") { showsCombine = true }
                }
                Button("Remove Item", role: .destructive) { showsRemoveConfirmation = true }
            } footer: {
                Text("Removing an item never deletes photos from your library.")
            }
        }
        .clearsDock()
        .navigationTitle(item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove this item from Rakful?", isPresented: $showsRemoveConfirmation, titleVisibility: .visible) {
            Button("Remove Item", role: .destructive) {
                dismiss()
                ItemActions.remove(item, in: context)
            }
        } message: {
            Text("Your photos won't be deleted.")
        }
        .sensoryFeedback(.success, trigger: feedback)
        .sheet(isPresented: $showsCombine) {
            CombineItemSheet(source: item) { target in
                showsCombine = false
                dismiss()
                ItemActions.combine(item, into: target, in: context)
            }
        }
        .onDisappear { saves.save(context, "Saving changes to this item") }
    }

    // MARK: - Ownership

    private var ownershipSection: some View {
        Section {
            if item.ownership == .unconfirmed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Do you still own this item?").font(.headline)
                    Button { setOwnership(.owned) } label: {
                        Text("Yes, I Own It").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    HStack {
                        Button { setOwnership(.notOwned) } label: { Text("No").frame(maxWidth: .infinity) }
                        Button { setOwnership(.unsure) } label: { Text("Not Sure").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.vertical, 6)
            } else {
                LabeledContent("Ownership") {
                    Menu {
                        Button("Yes, I Own It", systemImage: "checkmark.circle") { setOwnership(.owned) }
                        Button("No", systemImage: "xmark.circle") { setOwnership(.notOwned) }
                        Button("Not Sure", systemImage: "questionmark.circle") { setOwnership(.unsure) }
                    } label: {
                        OwnershipBadge(status: item.ownership)
                    }
                }
            }
        } footer: {
            Text("Rakful never assumes something in a photo belongs to you. Only items you confirm can be listed.")
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            if let suggestion = item.pendingBrandSuggestion, let brand = suggestion.brand {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Possibly \(brand)", systemImage: "text.viewfinder").font(.subheadline.weight(.semibold))
                    Text("\(suggestion.evidence). Confirm only if it's correct.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Use \(brand)") {
                            item.brand = brand
                            item.updatedAt = .now
                            feedback += 1
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Dismiss") { suggestion.isDismissed = true }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            editableRow("Name", text: $item.customName, prompt: item.suggestedName)
            editableRow("Brand", text: $item.brand, prompt: "Add brand")
            editableRow("Model", text: $item.model, prompt: "Add model")
            editableRow("Colour", text: $item.colour, prompt: "Add colour")
            if item.category == .clothing || item.category == .trainers || item.category == .accessories {
                editableRow("Size", text: $item.size, prompt: "Add size")
            }
            Picker("Category", selection: Binding(get: { item.category }, set: { item.category = $0; item.updatedAt = .now })) {
                ForEach(ResaleCategory.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) }
            }
            Picker("Condition", selection: Binding(get: { item.condition }, set: { item.condition = $0; item.updatedAt = .now })) {
                Text("Not Set").tag(ItemCondition?.none)
                ForEach(ItemCondition.allCases) { Text($0.displayName).tag(Optional($0)) }
            }
        } header: {
            Text("Details")
        } footer: {
            Text("Brand and model are never filled in automatically. Add only what you know is correct.")
        }
    }

    private func editableRow(_ label: LocalizedStringKey, text: Binding<String?>, prompt: String) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: Binding(
                get: { text.wrappedValue ?? "" },
                set: { text.wrappedValue = $0.nilIfBlank; item.updatedAt = .now }
            ))
            .multilineTextAlignment(.trailing)
            .submitLabel(.done)
        }
    }

    // MARK: - Value

    private var valueSection: some View {
        Section {
            if let estimate = item.latestEstimate, estimate.isDemo {
                LabeledContent("Demo Value") {
                    Text(estimate.range.formatted).monospacedDigit()
                }
            }
            if let url = Marketplace.soldListingsURL(for: [item.brand, item.model, item.displayName]) {
                Link(destination: url) {
                    Label("See Sold Prices on eBay", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            Text("Price")
        } footer: {
            if item.latestEstimate?.isDemo == true {
                Text("Demo values are examples for exploring Rakful, not market data. For your own items, Rakful links to eBay's completed sales so you can choose your price.")
            } else {
                Text("Opens eBay's completed sales for similar items so you can choose your own asking price. Rakful doesn't estimate prices.")
            }
        }
    }

    // MARK: - Readiness

    private var readinessSection: some View {
        Section {
            ChecklistRow(title: "Ownership confirmed", isComplete: item.ownership == .owned)
            ChecklistRow(title: "Brand added", detail: "Optional, but helps buyers find it", isComplete: item.brand?.nilIfBlank != nil)
            ChecklistRow(title: "Condition selected", isComplete: item.condition != nil)
            ChecklistRow(
                title: "\(item.listingPhotos.count) of 3 recommended photos",
                detail: photoReadinessDetail,
                isComplete: item.listingPhotos.count >= 3 || item.isDemo
            )
            Button {
                prepareListing()
            } label: {
                Label(item.activeDraft == nil ? "Prepare Listing" : "Open Listing Draft", systemImage: "tag")
            }
            .disabled(item.ownership != .owned)
        } header: {
            Text("Listing Readiness")
        } footer: {
            if item.ownership != .owned {
                Text("Confirm you own this item to prepare a listing.")
            }
        }
    }

    private var photoReadinessDetail: LocalizedStringKey? {
        if item.isOnlySeenWorn { return "Found in a photo that shows a person. Add photos of the item on its own." }
        let waiting = item.photosAwaitingCheck.count
        guard waiting > 0, !item.isDemo else { return nil }
        return waiting == 1 ? "1 more photo needs checking for people." : "\(waiting) more photos need checking for people."
    }

    // MARK: - Provenance

    private var provenanceSection: some View {
        Section("How This Was Found") {
            ForEach(item.identifications.sorted { $0.createdAt < $1.createdAt }) { identification in
                VStack(alignment: .leading, spacing: 2) {
                    Text(identification.source.displayName).font(.subheadline)
                    Text(identification.evidence).font(.footnote).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Discovered", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let label = item.classifierLabel {
                LabeledContent("Classifier Label", value: label.replacingOccurrences(of: "_", with: " "))
            }
        }
    }

    // MARK: - Actions

    private func setOwnership(_ status: OwnershipStatus) {
        withAnimation {
            item.setOwnership(status)
            if status == .owned {
                context.logActivity(.ownershipConfirmed, title: "Ownership confirmed", detail: item.displayName, itemID: item.id, isDemo: item.isDemo)
            }
        }
        if saves.save(context, "Saving your answer") { feedback += 1 }
    }

    private func prepareListing() {
        guard let draft = ItemActions.prepareDraft(for: item, in: context, preferences: preferences, limits: entitlements.limits) else {
            router.isPlansPresented = true
            return
        }
        router.showDraft(draft.id)
    }
}

// MARK: - Photos section

struct ItemPhotosSection: View {
    @Bindable var item: CandidateItem
    @Environment(\.modelContext) private var context
    @Environment(SaveFailureCenter.self) private var saves
    @Environment(ListingPhotoReviewer.self) private var reviewer
    @State private var reviewing: ItemPhoto?

    var body: some View {
        Section {
            if !item.isDemo, !item.sortedPhotos.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                    ForEach(item.sortedPhotos) { photo in
                        ItemThumbnail(item: item, photo: photo, cornerRadius: 8)
                            .aspectRatio(1, contentMode: .fill)
                            .overlay(alignment: .topTrailing) {
                                if photo.isDuplicate {
                                    PhotoBadge(systemImage: "square.on.square", label: "Similar photo")
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                if photo.showsPerson {
                                    PhotoBadge(systemImage: "person.crop.circle.badge.xmark", label: "Shows a person. Not used in listings.")
                                } else if reviewer.checking.contains(photo.id) {
                                    ProgressView().controlSize(.mini).padding(6)
                                } else if photo.listingEligibility != .eligible {
                                    PhotoStatusIcon(eligibility: photo.listingEligibility).padding(4)
                                        .accessibilityLabel(PhotoStatusText.text(for: photo, isChecking: false))
                                }
                            }
                            .onTapGesture { reviewing = photo }
                            .accessibilityAddTraits(.isButton)
                            .contextMenu {
                                Button("Check Photo", systemImage: "eye") { reviewing = photo }
                                if !photo.showsPerson {
                                    Button("Shows a Person", systemImage: "person.crop.circle.badge.xmark") {
                                        reviewer.markShowsPerson(photo, in: context)
                                    }
                                }
                                if !photo.isPrimary {
                                    Button("Use as Main Photo", systemImage: "star") { makePrimary(photo) }
                                }
                                if photo.source == .library, item.photos.count > 1 {
                                    Button("Separate into New Item", systemImage: "rectangle.split.2x1") {
                                        ItemActions.separate(photo, from: item, in: context)
                                    }
                                }
                                if photo.source != .library {
                                    Button("Remove Photo", systemImage: "trash", role: .destructive) { removeImported(photo) }
                                }
                            }
                    }
                }
                .padding(.vertical, 6)
                .sheet(item: $reviewing) { PhotoReviewSheet(photo: $0) }
            }
            AddPhotosButtons(item: item)
        } header: {
            Text("Photos")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(CameraPicker.isAvailable
                     ? "Photos from your library stay there — Rakful keeps only a reference. New and imported photos are stored at listing size on this iPhone."
                     : "Camera isn't available on this device. Photos from your library stay there — Rakful keeps only a reference.")
                Text("Every photo is checked for people before it can be used in a listing. Photos that show a person stay private.")
            }
        }
        .task(id: item.photos.count) {
            if !item.isDemo, item.ownership == .owned { reviewer.checkUnchecked(item.photos, in: context) }
        }
    }

    private func makePrimary(_ photo: ItemPhoto) {
        for other in item.photos { other.isPrimary = other.id == photo.id }
        saves.save(context, "Saving the main photo")
    }

    private func removeImported(_ photo: ItemPhoto) {
        let fileName = photo.importedFileName
        let wasPrimary = photo.isPrimary
        ListingPhotoReviewer.excludeFromListings(photo)
        context.delete(photo)
        if wasPrimary, let next = item.sortedPhotos.first(where: { $0.id != photo.id }) { next.isPrimary = true }
        // Keep the file until the removal is saved, so a failed save loses nothing.
        if saves.save(context, "Removing the photo"), let fileName { ImportedImageStore.delete(fileName) }
    }
}

/// A small icon in the corner of a photo thumbnail.
private struct PhotoBadge: View {
    let systemImage: String
    let label: LocalizedStringKey

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption2.weight(.bold))
            .padding(4)
            .background(.regularMaterial, in: Circle())
            .padding(4)
            .accessibilityLabel(label)
    }
}

/// Import and camera rows that add listing-size photos to an item. Each row
/// carries its own presentation so it works inside a List section.
struct AddPhotosButtons: View {
    @Bindable var item: CandidateItem
    var cameraTitle: LocalizedStringKey = "Take Photo"
    /// Called with new photos once they're stored, e.g. to add them to a listing.
    var onAdded: ([ItemPhoto]) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(SaveFailureCenter.self) private var saves
    @Environment(ListingPhotoReviewer.self) private var reviewer
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var importError: String?

    var body: some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images, photoLibrary: .shared()) {
            Label("Import Photos", systemImage: "photo.badge.plus")
        }
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { await importPhotos(newItems) }
        }
        Button {
            showsCamera = true
        } label: {
            Label(cameraTitle, systemImage: "camera")
        }
        .disabled(!CameraPicker.isAvailable)
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { image in addCameraImage(image) }
                .ignoresSafeArea()
        }
        if let importError {
            Text(importError).font(.footnote).foregroundStyle(.red)
        }
    }

    private func importPhotos(_ selections: [PhotosPickerItem]) async {
        importError = nil
        var added: [ItemPhoto] = []
        var failures = 0
        for selection in selections {
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadNoSuchFile) }
                let name = try await Task.detached { try ImportedImageStore.save(imageData: data) }.value
                let photo = ItemPhoto(importedFileName: name, source: .imported, capturedAt: .now)
                append(photo)
                added.append(photo)
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            importError = "\(added.isEmpty ? "The photos" : "Some photos") couldn't be imported. If they're stored in iCloud, check you're online and try again."
        }
        pickerItems = []
        finish(added)
    }

    private func addCameraImage(_ image: UIImage) {
        do {
            let name = try ImportedImageStore.save(image: image)
            let photo = ItemPhoto(importedFileName: name, source: .camera, capturedAt: .now)
            append(photo)
            finish([photo])
        } catch {
            importError = "The photo couldn't be saved. Check your iPhone has free storage and try again."
        }
    }

    /// New photos start unchecked, like every other photo, and are checked
    /// for people straight away.
    private func finish(_ added: [ItemPhoto]) {
        guard !added.isEmpty else { return }
        onAdded(added)
        saves.save(context, "Saving your new photos")
        reviewer.checkUnchecked(added, in: context)
    }

    private func append(_ photo: ItemPhoto) {
        photo.sortIndex = (item.photos.map(\.sortIndex).max() ?? -1) + 1
        photo.isPrimary = item.photos.isEmpty
        item.photos.append(photo)
        item.updatedAt = .now
    }
}

/// Shown when an item was spotted in photos of people: those photos stay
/// private, so suggest the shots a buyer expects and offer the camera.
struct ShotListSection: View {
    @Bindable var item: CandidateItem
    var recommendedCount = 3
    var onAdded: ([ItemPhoto]) -> Void = { _ in }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Spotted being worn", systemImage: "person.crop.rectangle")
                    .font(.subheadline.weight(.semibold))
                Text("It was found in a photo that shows a person. That photo stays private and isn't used. Add photos of the item on its own:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.category.listingShots.enumerated()), id: \.offset) { index, shot in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.accent)
                                .frame(width: 20, height: 20)
                                .background(Brand.accent.opacity(0.12), in: Circle())
                            Text(shot).font(.subheadline)
                        }
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            AddPhotosButtons(item: item, cameraTitle: "Take Photos", onAdded: onAdded)
        } footer: {
            Text("\(item.listingPhotos.count) of \(recommendedCount) photos added")
        }
    }
}

// MARK: - Combine

/// Picks the item that photos of `source` should be merged into.
struct CombineItemSheet: View {
    let source: CandidateItem
    let onCombine: (CandidateItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<CandidateItem> { $0.isDemo == false }, sort: \CandidateItem.createdAt, order: .reverse)
    private var items: [CandidateItem]

    var body: some View {
        let candidates = items.filter { $0.id != source.id && $0.category == source.category }
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { item in
                        Button { onCombine(item) } label: { ItemRow(item: item) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Photos of “\(source.displayName)” will move to the item you choose, and this item will be removed. The chosen item keeps its ownership status.")
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("No Similar Items", systemImage: source.category.systemImage, description: Text("There are no other \(source.category.displayName.lowercased()) items to combine with."))
                }
            }
            .navigationTitle("Combine With")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Camera

/// Wraps the system camera. SwiftUI has no native camera picker.
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
