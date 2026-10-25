import PhotosUI
import SwiftData
import SwiftUI

struct SellView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(PreferencesStore.self) private var preferences
    @Environment(EntitlementService.self) private var entitlements
    @Environment(SaveFailureCenter.self) private var saves

    @Query(sort: \ListingDraft.updatedAt, order: .reverse) private var drafts: [ListingDraft]
    @Query(filter: #Predicate<CandidateItem> { $0.ownershipRaw == "owned" }, sort: \CandidateItem.updatedAt, order: .reverse)
    private var ownedItems: [CandidateItem]
    @Query(filter: #Predicate<CandidateItem> { $0.ownershipRaw == "unconfirmed" }) private var unconfirmed: [CandidateItem]

    @State private var showsNewListing = false
    @State private var draftPendingDeletion: ListingDraft?

    private var readyItems: [CandidateItem] { ownedItems.filter { $0.drafts.isEmpty } }
    private var activeDrafts: [ListingDraft] { drafts.filter { $0.status == .draft || $0.status == .approved } }
    private var handedOff: [ListingDraft] { drafts.filter { $0.status == .exported } }
    private var listed: [ListingDraft] { drafts.filter { $0.status == .listed || $0.status == .published } }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.sellPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.sectionGap) {
                        ScreenHeader(title: "Sell") {
                            Button { showsNewListing = true } label: { CircleIconLabel(systemImage: "plus") }
                                .buttonStyle(PressableStyle())
                                .accessibilityLabel("New Listing")
                        }
                        if readyItems.isEmpty && drafts.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: Theme.cardGap + 4) {
                                if !readyItems.isEmpty { readyFolder(proxy) }
                                draftsFolder(proxy)
                            }
                            if !readyItems.isEmpty { readySection.id("ready") }
                            if !activeDrafts.isEmpty {
                                draftSection("Drafts", drafts: activeDrafts, footer: nil).id("drafts")
                            }
                            if !handedOff.isEmpty {
                                draftSection("Handed off", drafts: handedOff, footer: "Not confirmed as listed yet. Open one and tap “I've Posted It” once it's live.")
                            }
                            if !listed.isEmpty {
                                draftSection("Listed", drafts: listed, footer: "Confirmed by you. Rakful can't check marketplaces.")
                            }
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 24)
                }
            }
            .glassPage()
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

    // MARK: - Folders

    private func readyFolder(_ proxy: ScrollViewProxy) -> some View {
        FrostedFolder(
            previews: FolderPreview.categories(of: readyItems),
            rise: 116,
            frontHeight: 150,
            action: FolderAction(systemImage: "arrow.right", accessibilityLabel: "Show items ready to list", identifier: "sell.ready") {
                withAnimation(.smooth) { proxy.scrollTo("ready", anchor: .top) }
            }
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ready to list").font(.title2.weight(.bold)).foregroundStyle(Theme.ink)
                Text(readyItems.count == 1 ? "1 item" : "\(readyItems.count) items")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func draftsFolder(_ proxy: ScrollViewProxy) -> some View {
        let approved = activeDrafts.filter { $0.status == .approved }.count
        let count = activeDrafts.count
        var subtitle = count == 1 ? "1 draft" : "\(count) drafts"
        if approved > 0 { subtitle += " · \(approved) approved" }
        return FrostedFolder(
            previews: FolderPreview.categories(of: activeDrafts.compactMap(\.item), limit: 2),
            rise: count == 0 ? 34 : 96,
            frontHeight: 140,
            action: FolderAction(systemImage: "plus", accessibilityLabel: "New Listing", identifier: "sell.newListing") {
                showsNewListing = true
            }
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Drafts").font(.title2.weight(.bold)).foregroundStyle(Theme.ink)
                Text(count == 0 ? "No drafts in progress" : subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            .accessibilityElement(children: .combine)
        }
        .onTapGesture { if count > 0 { withAnimation(.smooth) { proxy.scrollTo("drafts", anchor: .top) } } }
    }

    // MARK: - Lists

    private var readySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader(title: "Ready to list")
            ForEach(readyItems) { item in
                Button { prepare(item) } label: {
                    GlassRow(icon: GlassIcon(category: item.category, size: 50), title: item.displayName, subtitle: item.category.displayName, isSample: item.isDemo) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.actionBlack)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint("Creates a listing draft")
            }
        }
    }

    private func draftSection(_ title: String, drafts: [ListingDraft], footer: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader(title: title)
            ForEach(drafts) { draft in
                NavigationLink(value: draft.id) { DraftRow(draft: draft) }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        if draft.status != .listed {
                            Button("Delete Draft", systemImage: "trash", role: .destructive) { draftPendingDeletion = draft }
                        }
                    }
            }
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            FrostedFolder(previews: [FolderPreview(category: .clothing), FolderPreview(category: .trainers)], rise: 96, frontHeight: 150) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No listings yet").font(.title2.weight(.bold)).foregroundStyle(Theme.ink)
                    Text("Confirm that you own a discovered item, or add something new, to start preparing a listing.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if !unconfirmed.isEmpty {
                Button("Review discoveries") { router.isReviewQueuePresented = true }
                    .buttonStyle(BlackPillStyle())
            }
            Button("New listing") { showsNewListing = true }
                .buttonStyle(WhitePillStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private func prepare(_ item: CandidateItem) {
        guard let draft = ItemActions.prepareDraft(for: item, in: context, preferences: preferences, limits: entitlements.limits) else {
            router.isPlansPresented = true
            return
        }
        router.sellPath = [draft.id]
    }

    private func delete(_ draft: ListingDraft) {
        let id = draft.id
        AppEnvironment.shared.notifications.cancelListingReminder(draftID: id)
        context.delete(draft)
        if saves.save(context, "Deleting the draft") { ApprovedPhotoStore.standard.removeAll(draftID: id) }
    }
}

struct DraftRow: View {
    let draft: ListingDraft

    private var statusLine: String {
        let base = "\(draft.marketplace.displayName) · \(draft.status.displayName)"
        switch draft.status {
        case .exported: return base + " · Not confirmed"
        case .listed: return base + " · Confirmed by you"
        default: return base
        }
    }

    var body: some View {
        GlassRow(
            icon: GlassIcon(category: draft.item?.category ?? .other, size: 50),
            title: draft.displayTitle,
            subtitle: statusLine,
            isSample: draft.isDemo
        ) {
            HStack(spacing: 10) {
                if let price = draft.askingPrice {
                    Text(Formatting.currency(price, code: draft.currencyCode, fractionDigits: price.rounded() == price ? 0 : 2))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
                RowChevron()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("Edited \(draft.updatedAt.formatted(.relative(presentation: .named)))")
    }
}

/// Start a listing from an owned item or from brand-new photos.
struct NewListingSheet: View {
    let onSelect: (CandidateItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SaveFailureCenter.self) private var saves
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
            errorMessage = "Those photos couldn't be imported. If they're stored in iCloud, check you're online and try again."
            return
        }
        let item = makeItem()
        for (index, name) in names.enumerated() {
            item.photos.append(ItemPhoto(importedFileName: name, source: .imported, capturedAt: .now, isPrimary: index == 0, sortIndex: index))
        }
        guard saves.save(context, "Saving your new item") else { return }
        onSelect(item)
    }

    private func createFromCamera(_ image: UIImage) {
        guard let name = try? ImportedImageStore.save(image: image) else {
            errorMessage = "The photo couldn't be saved."
            return
        }
        let item = makeItem()
        item.photos.append(ItemPhoto(importedFileName: name, source: .camera, capturedAt: .now, isPrimary: true))
        guard saves.save(context, "Saving your new item") else { return }
        onSelect(item)
    }
}
