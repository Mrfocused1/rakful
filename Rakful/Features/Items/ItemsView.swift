import SwiftData
import SwiftUI

struct ItemsView: View {
    enum Layout: String { case grid, list }
    enum SortOrder: String, CaseIterable, Identifiable {
        case newest, confidence, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newest: "Recently Found"
            case .confidence: "Confidence"
            case .name: "Name"
            }
        }
    }
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, needsReview, owned, notOwned
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All Items"
            case .needsReview: "Needs Review"
            case .owned: "Owned"
            case .notOwned: "Not Owned"
            }
        }
        func matches(_ status: OwnershipStatus) -> Bool {
            switch self {
            case .all: true
            case .needsReview: status == .unconfirmed || status == .unsure
            case .owned: status == .owned
            case .notOwned: status == .notOwned
            }
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \CandidateItem.createdAt, order: .reverse) private var items: [CandidateItem]

    @AppStorage("rr.items.layout") private var layout: Layout = .grid
    @AppStorage("rr.items.sort") private var sort: SortOrder = .newest
    @State private var searchText = ""
    @State private var category: ResaleCategory?
    @State private var statusFilter: StatusFilter = .all
    @State private var itemPendingRemoval: CandidateItem?
    @State private var feedback = 0

    private var filtered: [CandidateItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = items.filter { item in
            (category == nil || item.category == category)
                && statusFilter.matches(item.ownership)
                && (query.isEmpty || [item.displayName, item.category.displayName, item.brand ?? "", item.model ?? "", item.classifierLabel ?? ""]
                    .contains { $0.lowercased().contains(query) })
        }
        switch sort {
        case .newest: return matches
        case .confidence: return matches.sorted { $0.confidence > $1.confidence }
        case .name: return matches.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }

    private var presentCategories: [ResaleCategory] {
        let present = Set(items.map(\.category))
        return ResaleCategory.allCases.filter(present.contains)
    }

    private var isFiltering: Bool { category != nil || statusFilter != .all }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.itemsPath) {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("No Items Yet", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Items Rakful finds in your photos will appear here.")
                    } actions: {
                        Button("Go to Discover") { router.selectedTab = .discover }
                    }
                } else if filtered.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching Items", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("Try a different category or status.")
                        } actions: {
                            Button("Clear Filters") { clearFilters() }
                        }
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else if layout == .grid {
                    grid
                } else {
                    list
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if presentCategories.count > 1 { categoryBar }
            }
            .navigationTitle("Wardrobe")
            .searchable(text: $searchText, prompt: "Items, brands or categories")
            .toolbar { toolbarContent }
            .navigationDestination(for: UUID.self) { ItemDetailView(itemID: $0) }
            .confirmationDialog(
                "Remove this item from Rakful?",
                isPresented: Binding(get: { itemPendingRemoval != nil }, set: { if !$0 { itemPendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: itemPendingRemoval
            ) { item in
                Button("Remove Item", role: .destructive) { remove(item) }
            } message: { _ in
                Text("Your photos won't be deleted.")
            }
            .sensoryFeedback(.selection, trigger: feedback)
        }
    }

    // MARK: - Layouts

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(filtered) { item in
                    NavigationLink(value: item.id) {
                        ItemThumbnail(item: item, cornerRadius: 0)
                            .aspectRatio(1, contentMode: .fill)
                            .overlay(alignment: .bottomLeading) {
                                Image(systemName: item.ownership.systemImage)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(OwnershipBadge(status: item.ownership).tint)
                                    .padding(4)
                                    .background(.regularMaterial, in: Circle())
                                    .padding(5)
                            }
                            .overlay(alignment: .topLeading) {
                                if item.isDemo { SampleBadge().scaleEffect(0.85, anchor: .topLeading).padding(5) }
                            }
                            .accessibilityLabel(item.displayName)
                            .accessibilityValue("\(item.category.displayName), \(item.ownership.displayName)")
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextActions(for: item) } preview: {
                        ItemThumbnail(item: item, cornerRadius: 0).frame(width: 300, height: 300)
                    }
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(filtered) { item in
                NavigationLink(value: item.id) {
                    ItemRow(item: item)
                }
                .swipeActions(edge: .leading) {
                    if item.ownership != .owned {
                        Button { setOwnership(.owned, for: item) } label: { Label("I Own It", systemImage: "checkmark.circle") }
                            .tint(.green)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { itemPendingRemoval = item } label: { Label("Remove", systemImage: "trash") }
                    if item.ownership != .notOwned {
                        Button { setOwnership(.notOwned, for: item) } label: { Label("Not Mine", systemImage: "xmark.circle") }
                            .tint(.gray)
                    }
                }
                .contextMenu { contextActions(for: item) }
            }
        }
        .listStyle(.plain)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isSelected: category == nil) { category = nil }
                ForEach(presentCategories) { option in
                    chip(LocalizedStringKey(option.displayName), isSelected: category == option) {
                        category = category == option ? nil : option
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func chip(_ title: LocalizedStringKey, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: { withAnimation(.snappy) { action() }; feedback += 1 }) {
            Text(title).font(.subheadline.weight(.medium))
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        if isSelected {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered).tint(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Layout", selection: $layout) {
                    Label("Grid", systemImage: "square.grid.3x3").tag(Layout.grid)
                    Label("List", systemImage: "list.bullet").tag(Layout.list)
                }
                Picker("Sort By", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
                }
                Menu("Status") {
                    Picker("Status", selection: $statusFilter) {
                        ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
                    }
                }
                if isFiltering {
                    Button("Clear Filters", systemImage: "xmark.circle") { clearFilters() }
                }
            } label: {
                Label("View Options", systemImage: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            let pending = items.filter { $0.ownership == .unconfirmed }.count
            if pending > 0 {
                Button("Review (\(pending))") { router.isReviewQueuePresented = true }
            }
        }
    }

    @ViewBuilder
    private func contextActions(for item: CandidateItem) -> some View {
        Section("Do you still own this item?") {
            Button { setOwnership(.owned, for: item) } label: { Label("Yes, I Own It", systemImage: "checkmark.circle") }
            Button { setOwnership(.notOwned, for: item) } label: { Label("No", systemImage: "xmark.circle") }
            Button { setOwnership(.unsure, for: item) } label: { Label("Not Sure", systemImage: "questionmark.circle") }
        }
        if item.ownership == .owned {
            Button { router.selectedTab = .sell } label: { Label("Prepare Listing", systemImage: "tag") }
        }
        Button(role: .destructive) { itemPendingRemoval = item } label: { Label("Remove Item", systemImage: "trash") }
    }

    // MARK: - Actions

    private func setOwnership(_ status: OwnershipStatus, for item: CandidateItem) {
        withAnimation {
            item.setOwnership(status)
            if status == .owned {
                context.logActivity(.ownershipConfirmed, title: "Ownership confirmed", detail: item.displayName, itemID: item.id, isDemo: item.isDemo)
            }
            try? context.save()
        }
        feedback += 1
    }

    private func remove(_ item: CandidateItem) {
        ItemActions.remove(item, in: context)
        feedback += 1
    }

    private func clearFilters() {
        withAnimation { category = nil; statusFilter = .all }
    }
}

struct ItemRow: View {
    let item: CandidateItem

    var body: some View {
        HStack(spacing: 12) {
            ItemThumbnail(item: item, cornerRadius: 8)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if item.isDemo { SampleBadge() }
                }
                Text(item.category.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    OwnershipBadge(status: item.ownership)
                    if let estimate = item.latestEstimate {
                        Text(estimate.range.formatted)
                            .font(.footnote.weight(.medium))
                            .monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Shared item operations used by several screens.
@MainActor
enum ItemActions {
    /// Removes an item from Rakful. Never touches the photo library.
    static func remove(_ item: CandidateItem, in context: ModelContext) {
        for photo in item.photos {
            if let name = photo.importedFileName { ImportedImageStore.delete(name) }
        }
        context.delete(item)
        try? context.save()
        Task { await AppEnvironment.shared.discovery.store().invalidateIndex() }
    }

    /// Moves one photo into a new item of the same category — for when
    /// discovery grouped photos of two different things together.
    @discardableResult
    static func separate(_ photo: ItemPhoto, from item: CandidateItem, in context: ModelContext) -> CandidateItem? {
        guard item.photos.count > 1, item.photos.contains(where: { $0.id == photo.id }) else { return nil }
        let separated = CandidateItem(
            category: item.category,
            suggestedName: item.suggestedName,
            classifierLabel: item.classifierLabel,
            confidence: item.confidence,
            discoveredInSessionID: item.discoveredInSessionID
        )
        context.insert(separated)
        let wasPrimary = photo.isPrimary
        photo.item = separated
        photo.isPrimary = true
        photo.isDuplicate = false
        photo.sortIndex = 0
        if wasPrimary, let next = item.sortedPhotos.first(where: { $0.id != photo.id }) { next.isPrimary = true }
        item.updatedAt = .now
        try? context.save()
        Task { await AppEnvironment.shared.discovery.store().invalidateIndex() }
        return separated
    }

    /// Merges `source` into `target` — for when discovery split one item into
    /// several. Photos and suggestions move; `target` keeps its ownership.
    static func combine(_ source: CandidateItem, into target: CandidateItem, in context: ModelContext) {
        guard source.id != target.id else { return }
        var nextIndex = (target.photos.map(\.sortIndex).max() ?? -1) + 1
        for photo in source.photos {
            photo.item = target
            photo.isPrimary = false
            photo.sortIndex = nextIndex
            nextIndex += 1
        }
        for identification in source.identifications where !target.identifications.contains(where: { $0.source == identification.source && $0.brand == identification.brand }) {
            identification.item = target
        }
        target.confidence = max(target.confidence, source.confidence)
        target.updatedAt = .now
        try? context.save()
        context.delete(source)
        try? context.save()
        Task { await AppEnvironment.shared.discovery.store().invalidateIndex() }
    }

    /// Creates (or returns the existing) listing draft for an owned item.
    /// Returns nil for items the user hasn't confirmed they own, or when the
    /// free-tier draft limit is reached.
    static func prepareDraft(for item: CandidateItem, in context: ModelContext, preferences: PreferencesStore, limits: EntitlementLimits) -> ListingDraft? {
        guard item.ownership.canPrepareListing else { return nil }
        if let existing = item.activeDraft { return existing }
        let draftStatus = ListingStatus.draft.rawValue
        let active = (try? context.fetchCount(FetchDescriptor<ListingDraft>(predicate: #Predicate { $0.statusRaw == draftStatus && $0.isDemo == false }))) ?? 0
        guard item.isDemo || limits.canCreateDraft(activeDraftCount: active) else { return nil }

        let currency = item.latestEstimate?.currencyCode ?? preferences.currencyCode
        let draft = ListingDraft(item: item, currencyCode: currency)
        if item.brand == nil, let suggestion = item.pendingBrandSuggestion?.brand {
            draft.brand = suggestion
            draft.uncertainFields = draft.uncertainFields.union([.brand])
        }
        context.insert(draft)
        context.logActivity(.listingDraftCreated, title: "Listing draft created", detail: item.displayName, itemID: item.id, isDemo: item.isDemo)
        try? context.save()
        if !item.isDemo {
            let id = draft.id, title = draft.displayTitle
            Task { await AppEnvironment.shared.notifications.scheduleListingReminder(draftID: id, title: title) }
        }
        return draft
    }
}
