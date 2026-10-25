import SwiftData
import SwiftUI

/// The listing's photos in the editor: the chosen ones in order, and a link
/// to choose, order and review them.
struct ListingPhotosSection: View {
    @Bindable var draft: ListingDraft
    @Environment(ListingPhotoReviewer.self) private var reviewer

    private var selection: [(id: UUID, photo: ItemPhoto?)] {
        Array(zip(draft.selectedPhotoIDs, draft.selectedPhotos)).map { (id: $0.0, photo: $0.1) }
    }

    var body: some View {
        Section {
            if let item = draft.item, item.isDemo {
                HStack(spacing: 12) {
                    ItemThumbnail(item: item, cornerRadius: 10).frame(width: 64, height: 64)
                    Text("Sample items use artwork instead of photos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                if !selection.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(selection.enumerated()), id: \.element.id) { index, entry in
                                SelectedPhotoTile(photo: entry.photo, position: index + 1, isChecking: entry.photo.map { reviewer.checking.contains($0.id) } ?? false)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                NavigationLink {
                    ListingPhotosView(draft: draft)
                } label: {
                    Label(selection.isEmpty ? "Choose Photos" : "Choose & Order Photos", systemImage: "photo.stack")
                }
                .accessibilityIdentifier("listing.choosePhotos")
            }
        } header: {
            Text("Photos")
        } footer: {
            if draft.item?.isDemo != true {
                Text(summary)
            }
        }
    }

    private var summary: String {
        let photos = draft.selectedPhotos
        guard !photos.isEmpty else { return "Choose the photos buyers will see. Photos that show a person are never used." }
        let pending = photos.filter { $0?.listingEligibility != .eligible }.count
        let count = photos.count == 1 ? "1 photo" : "\(photos.count) photos"
        return pending == 0 ? "\(count) in your listing. You'll see each one again before approving." : "\(count) in your listing · \(pending) need\(pending == 1 ? "s" : "") attention"
    }
}

private struct SelectedPhotoTile: View {
    let photo: ItemPhoto?
    let position: Int
    let isChecking: Bool

    var body: some View {
        Color(.secondarySystemFill)
            .overlay { PhotoImage(photo: photo) }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text("\(position)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Brand.accent, in: Circle())
                    .padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                if isChecking {
                    ProgressView().controlSize(.mini).padding(4)
                } else if let photo, photo.listingEligibility != .eligible {
                    PhotoStatusIcon(eligibility: photo.listingEligibility).padding(4)
                } else if photo == nil {
                    PhotoStatusIcon(eligibility: nil).padding(4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo \(position)")
            .accessibilityValue(photo.map { PhotoStatusText.text(for: $0, isChecking: isChecking) } ?? "Unavailable")
    }
}

/// Choose, order and review the photos in a listing.
struct ListingPhotosView: View {
    @Bindable var draft: ListingDraft

    @Environment(\.modelContext) private var context
    @Environment(ListingPhotoReviewer.self) private var reviewer
    @Environment(SaveFailureCenter.self) private var saves
    @State private var reviewing: ItemPhoto?

    private var item: CandidateItem? { draft.item }

    private var otherPhotos: [ItemPhoto] {
        let selected = Set(draft.selectedPhotoIDs)
        return (item?.sortedPhotos ?? []).filter { !selected.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                if draft.selectedPhotoIDs.isEmpty {
                    Text("No photos chosen yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(zip(draft.selectedPhotoIDs, draft.selectedPhotos).enumerated()), id: \.element.0) { index, entry in
                    selectedRow(id: entry.0, photo: entry.1, position: index + 1)
                }
                .onMove { offsets, destination in
                    var ids = draft.selectedPhotoIDs
                    ids.move(fromOffsets: offsets, toOffset: destination)
                    draft.selectedPhotoIDs = ids
                    draft.touch()
                }
            } header: {
                Text("In Your Listing")
            } footer: {
                Text("Drag to reorder. Photo 1 is the main photo.")
            }

            if !otherPhotos.isEmpty {
                Section("Other Photos of This Item") {
                    ForEach(otherPhotos) { photo in otherRow(photo) }
                }
            }

            if let item {
                Section {
                    AddPhotosButtons(item: item) { added in
                        draft.selectedPhotoIDs += added.map(\.id)
                        draft.touch()
                    }
                } footer: {
                    Text("Rakful checks each photo for people, but automatic checks can miss things. You'll see every photo again before you approve the listing.")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .clearsDock()
        .navigationTitle("Listing Photos")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reviewing) { photo in
            PhotoReviewSheet(photo: photo, draft: draft)
        }
        .task {
            if let item { reviewer.checkUnchecked(item.photos, in: context) }
        }
        .onDisappear { saves.save(context, "Saving your photo choices") }
    }

    private func selectedRow(id: UUID, photo: ItemPhoto?, position: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                reviewing = photo
            } label: {
                Color(.secondarySystemFill)
                    .overlay { PhotoImage(photo: photo) }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.borderless)
            .disabled(photo == nil)
            .accessibilityLabel("Review photo \(position)")
            VStack(alignment: .leading, spacing: 2) {
                Text(position == 1 ? "Photo 1 · Main" : "Photo \(position)").font(.subheadline.weight(.medium))
                if let photo {
                    PhotoStatusLine(photo: photo, isChecking: reviewer.checking.contains(photo.id), problem: reviewer.problem(for: photo))
                } else {
                    Label("No longer available", systemImage: "photo.badge.exclamationmark").font(.footnote).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            Button {
                withAnimation { draft.deselectPhotos([id]); draft.touch() }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red).imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove photo \(position) from listing")
        }
    }

    private func otherRow(_ photo: ItemPhoto) -> some View {
        HStack(spacing: 12) {
            Button {
                reviewing = photo
            } label: {
                Color(.secondarySystemFill)
                    .overlay { PhotoImage(photo: photo) }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Review photo")
            VStack(alignment: .leading, spacing: 2) {
                PhotoStatusLine(photo: photo, isChecking: reviewer.checking.contains(photo.id), problem: reviewer.problem(for: photo))
                if photo.isDuplicate {
                    Text("Similar to another photo").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            switch photo.listingEligibility {
            case .eligible:
                Button {
                    withAnimation { draft.selectedPhotoIDs.append(photo.id); draft.touch() }
                } label: {
                    Image(systemName: "plus.circle.fill").imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add to listing")
            case .unchecked, .needsReview:
                Button("Review") { reviewing = photo }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .showsPerson:
                EmptyView()
            }
        }
    }
}

// MARK: - Review

/// A large view of one photo, so the seller can check it themselves.
struct PhotoReviewSheet: View {
    let photo: ItemPhoto
    /// When set, confirming a photo also adds it to this listing.
    var draft: ListingDraft?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ListingPhotoReviewer.self) private var reviewer

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LargePhotoImage(photo: photo)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    PhotoStatusLine(photo: photo, isChecking: reviewer.checking.contains(photo.id), problem: reviewer.problem(for: photo))
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let problem = reviewer.problem(for: photo) {
                        PhotoProblemButton(problem: problem) {
                            Task { await reviewer.check(photo, in: context) }
                        } remove: {
                            draft?.deselectPhotos([photo.id])
                            dismiss()
                        }
                    }
                    actions
                }
                .padding()
            }
            .navigationTitle("Check Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .saveFailureAlert(reviewer.saves)
    }

    private var explanation: String {
        switch photo.listingEligibility {
        case .showsPerson:
            "Photos that show a person stay private and are never used in a listing. Add a photo of the item on its own instead."
        case .eligible, .unchecked, .needsReview:
            "Look for people, faces, reflections in mirrors or windows, and personal details such as addresses. Automatic checks can miss things."
        }
    }

    @ViewBuilder
    private var actions: some View {
        let eligibility = photo.listingEligibility
        VStack(spacing: 10) {
            if eligibility == .unchecked || eligibility == .needsReview {
                Button {
                    if reviewer.confirmNoPerson(photo, in: context) {
                        if let draft, !draft.selectedPhotoIDs.contains(photo.id) { draft.selectedPhotoIDs.append(photo.id) }
                        dismiss()
                    }
                } label: {
                    Text(draft == nil ? "No People in This Photo" : "No People · Use in Listing").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("photoReview.confirm")
            } else if eligibility == .eligible, let draft, !draft.selectedPhotoIDs.contains(photo.id) {
                Button {
                    draft.selectedPhotoIDs.append(photo.id)
                    dismiss()
                } label: {
                    Text("Use in Listing").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if eligibility != .showsPerson {
                Button(role: .destructive) {
                    if reviewer.markShowsPerson(photo, in: context) { dismiss() }
                } label: {
                    Text("It Shows a Person").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            if photo.personCheck == .failed, reviewer.problem(for: photo) == nil {
                Button("Check Automatically Again") {
                    Task { await reviewer.check(photo, in: context) }
                }
                .disabled(reviewer.checking.contains(photo.id))
            }
        }
    }
}

/// The recovery action for a photo that can't be loaded.
struct PhotoProblemButton: View {
    let problem: ListingPhotoProblem
    let retry: () -> Void
    let remove: () -> Void

    @Environment(PhotoLibraryState.self) private var photoState
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
            switch problem.recovery {
            case .openSettings:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .changeSharedPhotos:
                Button("Choose Photos to Share") { photoState.presentLimitedLibraryPicker() }
            case .tryAgain:
                Button("Try Again", action: retry)
            case .remove:
                Button("Remove from Listing", role: .destructive, action: remove)
            }
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Status

enum PhotoStatusText {
    static func text(for photo: ItemPhoto, isChecking: Bool) -> String {
        if isChecking { return "Checking for people…" }
        switch photo.listingEligibility {
        case .eligible: return photo.userReview == .confirmedNoPerson ? "Checked by you" : "Checked · no people found"
        case .unchecked: return "Not checked yet"
        case .needsReview: return "Couldn't check automatically · review it"
        case .showsPerson: return photo.userReview == .markedShowsPerson ? "You marked it as showing a person" : "Shows a person · not used"
        }
    }
}

struct PhotoStatusLine: View {
    let photo: ItemPhoto
    let isChecking: Bool
    var problem: ListingPhotoProblem?

    var body: some View {
        HStack(spacing: 6) {
            if isChecking {
                ProgressView().controlSize(.mini)
            } else {
                PhotoStatusIcon(eligibility: problem == nil ? photo.listingEligibility : nil)
            }
            Text(problem?.message ?? PhotoStatusText.text(for: photo, isChecking: isChecking))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
    }
}

/// A small status symbol; `nil` means the photo is unavailable.
struct PhotoStatusIcon: View {
    let eligibility: PhotoEligibility?

    var body: some View {
        let (symbol, colour): (String, Color) = switch eligibility {
        case .eligible?: ("checkmark.circle.fill", Brand.accent)
        case .unchecked?: ("clock.fill", .secondary)
        case .needsReview?: ("exclamationmark.triangle.fill", .orange)
        case .showsPerson?: ("person.crop.circle.badge.xmark", .red)
        case nil: ("photo.badge.exclamationmark", .red)
        }
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(colour)
            .padding(2)
            .background(.regularMaterial, in: Circle())
            .accessibilityHidden(true)
    }
}

/// A photo at reviewing size, uncropped.
struct LargePhotoImage: View {
    let photo: ItemPhoto
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if didFail {
                ContentUnavailableView("Photo Unavailable", systemImage: "photo.badge.exclamationmark")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(Color(.secondarySystemFill))
        .task(id: photo.id) {
            let loaded = await ThumbnailLoader.shared.thumbnail(for: photo, pointSize: CGSize(width: 420, height: 420), scale: displayScale)
            image = loaded
            didFail = loaded == nil
        }
        .accessibilityLabel("Photo")
    }
}

/// One of the exact files that will be exported.
struct ApprovedFileImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(Color(.secondarySystemFill))
        .task(id: url) {
            image = await Task.detached(priority: .userInitiated) { [url] in
                ImportedImageStore.downsample(url: url, maxPixel: 1400)
            }.value
        }
    }
}
