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
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    @State private var category: ResaleCategory?
    @State private var statusFilter: StatusFilter = .all
    @State private var itemPendingRemoval: CandidateItem?
    @State private var feedback = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Two columns, or one at accessibility text sizes.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.cardGap), count: typeSize.isAccessibilitySize ? 1 : 2)
    }

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
    private var pendingReview: Int { items.filter { $0.ownership == .unconfirmed }.count }
    private var showsFolders: Bool { category == nil && statusFilter == .all && searchText.isEmpty && presentCategories.count > 1 }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.itemsPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if showsSearch { searchField }
                    if presentCategories.count > 1 { categoryPills }
                    content
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 24)
            }
            .glassPage()
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
            .animation(.smooth(duration: 0.25), value: category)
            .animation(.smooth(duration: 0.25), value: showsSearch)
        }
    }

    // MARK: - Header

    private var header: some View {
        ScreenHeader(title: "Wardrobe") {
            if pendingReview > 0 {
                Button("Review (\(pendingReview))") { router.isReviewQueuePresented = true }
                    .buttonStyle(WhitePillStyle(compact: true))
            }
            optionsMenu
            Button {
                showsSearch.toggle()
                searchFocused = showsSearch
                if !showsSearch { searchText = "" }
            } label: {
                CircleIconLabel(systemImage: showsSearch ? "xmark" : "magnifyingglass")
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(showsSearch ? "Close Search" : "Search")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryInk)
            TextField("Items, brands or categories", text: $searchText)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryInk) }
                    .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .background(Capsule().fill(Theme.card))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Layout", selection: $layout) {
                Label("Cards", systemImage: "square.grid.2x2").tag(Layout.grid)
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
            CircleIconLabel(systemImage: "line.3.horizontal.decrease", isActive: statusFilter != .all)
        }
        .accessibilityLabel("View Options")
    }

    private var categoryPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterPill(title: "All", isSelected: category == nil) { select(nil) }
                ForEach(presentCategories) { option in
                    FilterPill(title: option.displayName, isSelected: category == option) {
                        select(category == option ? nil : option)
                    }
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, Theme.pagePadding)
        }
        .padding(.horizontal, -Theme.pagePadding)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyState(
                title: "No items yet",
                message: "Items Rakful finds in your photos will appear here.",
                actionTitle: "Go to Home"
            ) { router.selectedTab = .discover }
        } else if filtered.isEmpty {
            emptyState(
                title: searchText.isEmpty ? "No matching items" : "No results for “\(searchText)”",
                message: searchText.isEmpty ? "Try a different category or status." : "Check the spelling or try a different search.",
                actionTitle: "Clear Filters"
            ) { clearFilters(); searchText = "" }
        } else {
            if showsFolders { categoryFolders }
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: category?.displayName ?? (statusFilter == .all ? "All items" : statusFilter.title))
                if layout == .grid { cards } else { rows }
            }
        }
    }

    private var categoryFolders: some View {
        LazyVGrid(columns: columns, spacing: Theme.cardGap) {
            ForEach(presentCategories) { option in
                let count = items.filter { $0.category == option }.count
                FrostedFolder(
                    previews: Array(repeating: FolderPreview(category: option), count: min(count, 2)).enumerated().map {
                        FolderPreview(id: "\(option.rawValue)-\($0.offset)", symbol: $0.element.symbol, pastel: $0.element.pastel)
                    },
                    rise: 82,
                    frontHeight: 104,
                    compact: true,
                    action: FolderAction(systemImage: "arrow.right", accessibilityLabel: "Show \(option.displayName)") { select(option) }
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.displayName)
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text(count == 1 ? "1 item" : "\(count) items")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var cards: some View {
        LazyVGrid(columns: columns, spacing: Theme.cardGap) {
            ForEach(filtered) { item in
                NavigationLink(value: item.id) {
                    ItemCard(item: item)
                }
                .buttonStyle(PressableStyle())
                .contextMenu { contextActions(for: item) }
            }
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 10) {
            ForEach(filtered) { item in
                NavigationLink(value: item.id) {
                    ItemGlassRow(item: item)
                }
                .buttonStyle(PressableStyle())
                .contextMenu { contextActions(for: item) }
            }
        }
    }

    private func emptyState(title: String, message: String, actionTitle: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            GlassIcon(symbol: "hanger", pastel: .lavender, size: 84)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action).buttonStyle(WhitePillStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func select(_ option: ResaleCategory?) {
        category = option
        feedback += 1
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
        }
        if AppEnvironment.shared.saveFailures.save(context, "Saving your answer") { feedback += 1 }
    }

    private func remove(_ item: CandidateItem) {
        ItemActions.remove(item, in: context)
        feedback += 1
    }

    private func clearFilters() {
        withAnimation { category = nil; statusFilter = .all }
    }
}

/// A two-column Wardrobe card: glass icon, name, value when known, and
/// ownership and confidence.
struct ItemCard: View {
    let item: CandidateItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassIcon(category: item.category, size: 80)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(item.latestEstimate?.range.formatted ?? item.category.displayName)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                OwnershipBadge(status: item.ownership)
                    .foregroundStyle(Theme.secondaryInk)
                Spacer(minLength: 0)
                ConfidenceIndicator(level: item.confidenceLevel, showsLabel: false)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card))
        .overlay(alignment: .topTrailing) {
            if item.isDemo { SampleBadge().padding(10) }
        }
        .shadow(color: .black.opacity(0.05), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows item details")
    }

    private var accessibilityValue: String {
        var parts = [item.category.displayName]
        if let estimate = item.latestEstimate { parts.append(estimate.range.formatted) }
        parts += [item.ownership.displayName, item.confidenceLevel.displayName]
        if item.isDemo { parts.append("Sample item") }
        return parts.joined(separator: ", ")
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
        let draftIDs = item.drafts.map(\.id)
        context.delete(item)
        if saves.save(context, "Removing the item") {
            for id in draftIDs { ApprovedPhotoStore.standard.removeAll(draftID: id) }
        }
        Task { await AppEnvironment.shared.discovery.store().invalidateIndex() }
    }

    private static var saves: SaveFailureCenter { AppEnvironment.shared.saveFailures }

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
        // It's a different item now, so it leaves this item's listings.
        for draft in item.drafts where draft.status.isActive {
            draft.deselectPhotos([photo.id])
            draft.invalidateApprovalIfNeeded()
        }
        saves.save(context, "Separating the photo")
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
        context.delete(source)
        saves.save(context, "Combining the items")
        Task { await AppEnvironment.shared.discovery.store().invalidateIndex() }
    }

    /// Creates (or returns the existing) listing draft for an owned item.
    /// Returns nil for items the user hasn't confirmed they own, or when the
    /// free-tier draft limit is reached.
    static func prepareDraft(for item: CandidateItem, in context: ModelContext, preferences: PreferencesStore, limits: EntitlementLimits) -> ListingDraft? {
        guard item.ownership.canPrepareListing else { return nil }
        if let existing = item.activeDraft { return existing }
        let draftStatus = ListingStatus.draft.rawValue, approvedStatus = ListingStatus.approved.rawValue
        let active = (try? context.fetchCount(FetchDescriptor<ListingDraft>(predicate: #Predicate {
            ($0.statusRaw == draftStatus || $0.statusRaw == approvedStatus) && $0.isDemo == false
        }))) ?? 0
        guard item.isDemo || limits.canCreateDraft(activeDraftCount: active) else { return nil }

        let currency = item.latestEstimate?.currencyCode ?? preferences.currencyCode
        let draft = ListingDraft(item: item, currencyCode: currency)
        if item.brand == nil, let suggestion = item.pendingBrandSuggestion?.brand {
            draft.brand = suggestion
            draft.uncertainFields = draft.uncertainFields.union([.brand])
        }
        // Start with every photo that might be usable. Each must still pass
        // the person check (or the seller's review) before approval.
        draft.selectedPhotoIDs = Array(item.distinctPhotos.filter { !$0.showsPerson }.prefix(20).map(\.id))
        context.insert(draft)
        context.logActivity(.listingDraftCreated, title: "Listing draft created", detail: item.displayName, itemID: item.id, isDemo: item.isDemo)
        saves.save(context, "Creating the listing draft")
        if !item.isDemo {
            let id = draft.id, title = draft.displayTitle
            Task { await AppEnvironment.shared.notifications.scheduleListingReminder(draftID: id, title: title) }
        }
        return draft
    }
}
