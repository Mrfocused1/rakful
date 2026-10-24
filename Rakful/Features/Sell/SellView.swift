import PhotosUI
import SwiftData
import SwiftUI

struct SellView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(PreferencesStore.self) private var preferences
    @Environment(EntitlementService.self) private var entitlements

    @Query(sort: \ListingDraft.updatedAt, order: .reverse) private var drafts: [ListingDraft]
    @Query(filter: #Predicate<CandidateItem> { $0.ownershipRaw == "owned" }, sort: \CandidateItem.updatedAt, order: .reverse)
    private var ownedItems: [CandidateItem]
    @Query(filter: #Predicate<CandidateItem> { $0.ownershipRaw == "unconfirmed" }) private var unconfirmed: [CandidateItem]

    @State private var showsNewListing = false
    @State private var draftPendingDeletion: ListingDraft?

    private var readyItems: [CandidateItem] { ownedItems.filter { $0.drafts.isEmpty } }
    private var activeDrafts: [ListingDraft] { drafts.filter { $0.status == .draft } }
    private var listed: [ListingDraft] { drafts.filter { $0.status != .draft } }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.sellPath) {
            List {
                if !readyItems.isEmpty {
                    Section {
                        ForEach(readyItems) { item in
                            Button { prepare(item) } label: {
                                HStack {
                                    ItemRow(item: item)
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint).imageScale(.large)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Creates a listing draft")
                        }
                    } header: {
                        Text("Ready to List")
                    } footer: {
                        Text("Items you've confirmed you own.")
                    }
                }
                if !activeDrafts.isEmpty {
                    Section("Drafts") {
                        ForEach(activeDrafts) { draft in
                            NavigationLink(value: draft.id) { DraftRow(draft: draft) }
                                .swipeActions {
                                    Button(role: .destructive) { draftPendingDeletion = draft } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
                if !listed.isEmpty {
                    Section("Listed") {
                        ForEach(listed) { draft in
                            NavigationLink(value: draft.id) { DraftRow(draft: draft) }
                        }
                    }
                }
            }
            .overlay {
                if readyItems.isEmpty && drafts.isEmpty {
                    ContentUnavailableView {
                        Label("No Listings Yet", systemImage: "tag")
                    } description: {
                        Text("Confirm that you own a discovered item, or add something new, to start preparing a listing.")
                    } actions: {
                        if !unconfirmed.isEmpty {
                            Button("Review Discoveries") { router.isReviewQueuePresented = true }
                                .prominentActionStyle()
                        }
                        Button("New Listing") { showsNewListing = true }
                    }
                }
            }
            .navigationTitle("Sell")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsNewListing = true } label: { Label("New Listing", systemImage: "plus") }
                }
            }
            .navigationDestination(for: UUID.self) { ListingEditorView(draftID: $0) }
            .sheet(isPresented: $showsNewListing) {
                NewListingSheet { item in
                    showsNewListing = false
                    prepare(item)
                }
            }
            .confirmationDialog("Delete this draft?", isPresented: Binding(get: { draftPendingDeletion != nil }, set: { if !$0 { draftPendingDeletion = nil } }), titleVisibility: .visible, presenting: draftPendingDeletion) { draft in
                Button("Delete Draft", role: .destructive) { delete(draft) }
            }
        }
    }

    private func prepare(_ item: CandidateItem) {
        guard let draft = ItemActions.prepareDraft(for: item, in: context, preferences: preferences, limits: entitlements.limits) else {
            router.isPlansPresented = true
            return
        }
        router.sellPath = [draft.id]
    }

    private func delete(_ draft: ListingDraft) {
        AppEnvironment.shared.notifications.cancelListingReminder(draftID: draft.id)
        context.delete(draft)
        try? context.save()
    }
}

struct DraftRow: View {
    let draft: ListingDraft

    var body: some View {
        HStack(spacing: 12) {
            if let item = draft.item {
                ItemThumbnail(item: item, cornerRadius: 8).frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(draft.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                    if draft.isDemo { SampleBadge() }
                }
                Text("\(draft.marketplace.displayName) · \(draft.status.displayName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Edited \(draft.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let price = draft.askingPrice {
                Text(Formatting.currency(price, code: draft.currencyCode, fractionDigits: price.rounded() == price ? 0 : 2))
                    .font(.subheadline)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Start a listing from an owned item or from brand-new photos.
struct NewListingSheet: View {
    let onSelect: (CandidateItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<CandidateItem> { $0.ownershipRaw == "owned" }, sort: \CandidateItem.updatedAt, order: .reverse)
    private var ownedItems: [CandidateItem]

    @State private var category: ResaleCategory = .other
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if !ownedItems.isEmpty {
                    Section("Your Items") {
                        ForEach(ownedItems) { item in
                            Button { onSelect(item) } label: { ItemRow(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(ResaleCategory.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) }
                    }
                    Button { showsCamera = true } label: { Label("Take Photos", systemImage: "camera") }
                        .disabled(!CameraPicker.isAvailable)
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images, photoLibrary: .shared()) {
                        Label("Choose Photos", systemImage: "photo.on.rectangle")
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Something Else")
                } footer: {
                    Text("Start a listing for an item Rakful hasn't discovered. Adding it confirms that you own it.")
                }
            }
            .navigationTitle("New Listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onChange(of: pickerItems) { _, selections in
                guard !selections.isEmpty else { return }
                Task { await createFromLibrary(selections) }
            }
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { image in createFromCamera(image) }.ignoresSafeArea()
            }
        }
    }

    private func makeItem() -> CandidateItem {
        let item = CandidateItem(category: category, suggestedName: category == .other ? "New Item" : category.itemNoun, confidence: 1)
        item.identifications.append(ProductIdentification(source: .user, category: category, confidence: 1, evidence: "Added by you"))
        context.insert(item)
        item.setOwnership(.owned)
        return item
    }

    private func createFromLibrary(_ selections: [PhotosPickerItem]) async {
        var names: [String] = []
        for selection in selections {
            if let data = try? await selection.loadTransferable(type: Data.self),
               let name = try? await Task.detached(operation: { try ImportedImageStore.save(imageData: data) }).value {
                names.append(name)
            }
        }
        pickerItems = []
        guard !names.isEmpty else {
            errorMessage = "Those photos couldn't be imported."
            return
        }
        let item = makeItem()
        for (index, name) in names.enumerated() {
            item.photos.append(ItemPhoto(importedFileName: name, source: .imported, capturedAt: .now, isPrimary: index == 0, sortIndex: index))
        }
        try? context.save()
        onSelect(item)
    }

    private func createFromCamera(_ image: UIImage) {
        guard let name = try? ImportedImageStore.save(image: image) else {
            errorMessage = "The photo couldn't be saved."
            return
        }
        let item = makeItem()
        item.photos.append(ItemPhoto(importedFileName: name, source: .camera, capturedAt: .now, isPrimary: true))
        try? context.save()
        onSelect(item)
    }
}
