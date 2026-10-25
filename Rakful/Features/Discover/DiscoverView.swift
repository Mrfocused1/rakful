import SwiftData
import SwiftUI

struct DiscoverView: View {
    @Environment(\.modelContext) private var context
    @Environment(DiscoveryCoordinator.self) private var discovery
    @Environment(PhotoLibraryState.self) private var photoState
    @Environment(DeviceConditionMonitor.self) private var device
    @Environment(PreferencesStore.self) private var preferences
    @Environment(EntitlementService.self) private var entitlements
    @Environment(BackgroundDiscoveryManager.self) private var background
    @Environment(AppRouter.self) private var router

    @Query(sort: \CandidateItem.createdAt, order: .reverse) private var items: [CandidateItem]
    @Query(filter: #Predicate<DiscoverySession> { $0.isDemo == false }, sort: \DiscoverySession.startedAt, order: .reverse)
    private var sessions: [DiscoverySession]

    @State private var analyzedCount = 0
    @State private var pendingCount: Int?
    @State private var showsAccessAlert = false
    @State private var failureMessage: String?
    @State private var showsReport = false
    @State private var completedRuns = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    private var realItems: [CandidateItem] { items.filter { !$0.isDemo } }
    private var hasOnlySamples: Bool { realItems.isEmpty && !items.isEmpty }
    /// Summary covers real discoveries; sample items only when there are no real ones.
    private var summaryItems: [CandidateItem] {
        (hasOnlySamples ? items : realItems).filter { $0.ownership != .notOwned }
    }
    private var unconfirmed: [CandidateItem] { items.filter { $0.ownership == .unconfirmed } }
    private var lastCompleted: DiscoverySession? { sessions.first { $0.status == .completed } }
    private var latestSession: DiscoverySession? { sessions.first }

    private var refreshKey: String {
        "\(sessions.first?.photosAnalyzed ?? 0)-\(sessions.count)-\(discovery.isRunning)-\(photoState.authorizedPhotoCount)-\(photoState.accessLevel.rawValue)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    header
                    if let report = DiscoveryReport.make(sessions: sessions, items: items, drafts: [], since: preferences.lastReportViewedAt), !discovery.isRunning {
                        reportBanner(report)
                    }
                    if !photoState.accessLevel.canRead, photoState.accessLevel != .notDetermined {
                        accessBanner
                    }
                    if items.isEmpty && !discovery.isRunning {
                        emptyState
                    } else {
                        VStack(spacing: 18) {
                            if !summaryItems.isEmpty { discoveryFolder }
                            primaryAction
                        }
                        if discovery.isRunning { progressCard }
                        if !unconfirmed.isEmpty, !discovery.isRunning { reviewPrompt }
                        chargeRow
                        recentDiscoveries
                        status
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 24)
            }
            .glassPage()
            .navigationDestination(for: UUID.self) { ItemDetailView(itemID: $0) }
            .sheet(isPresented: $showsReport) { DiscoveryReportView() }
            .alert("Photo Access Needed", isPresented: $showsAccessAlert) {
                Button("Open Settings") { openSystemSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Rakful needs access to your photos to discover items. You can allow all photos or just a selection.")
            }
            .alert("Discovery Couldn't Run", isPresented: Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
            .sensoryFeedback(.success, trigger: completedRuns)
            .task(id: refreshKey) { await refreshCounts() }
            .animation(.smooth, value: discovery.isRunning)
            .animation(.smooth, value: items.count)
        }
    }

    // MARK: - Sections

    private var header: some View {
        ScreenHeader(title: "Rakful") {
            moreMenu
            Button {
                router.isSettingsPresented = true
            } label: {
                CircleIconLabel(systemImage: "gearshape")
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Settings")
        }
    }

    private var moreMenu: some View {
        Menu {
            if !unconfirmed.isEmpty {
                Button { router.isReviewQueuePresented = true } label: {
                    Label("Review Discoveries", systemImage: "checkmark.circle")
                }
            }
            if photoState.accessLevel == .limited {
                Button { photoState.presentLimitedLibraryPicker() } label: {
                    Label("Choose More Photos", systemImage: "photo.on.rectangle")
                }
            }
            Section {
                if items.contains(where: \.isDemo) {
                    Button(role: .destructive) { removeSamples() } label: {
                        Label("Remove Sample Items", systemImage: "trash")
                    }
                } else {
                    Button { addSamples() } label: {
                        Label("Explore Sample Items", systemImage: "square.stack.3d.up")
                    }
                }
            }
        } label: {
            CircleIconLabel(systemImage: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    /// The discoveries folder: what was found, and a value only when one exists.
    private var discoveryFolder: some View {
        let estimates = summaryItems.map { $0.latestEstimate?.range }
        let currency = hasOnlySamples ? SampleData.currencyCode : preferences.currencyCode
        let value = ValueSummary.compute(estimates: estimates, currencyCode: currency)
        let count = summaryItems.count
        let countText = hasOnlySamples
            ? (count == 1 ? "1 sample item" : "\(count) sample items")
            : (count == 1 ? "1 item" : "\(count) items")

        return FrostedFolder(
            previews: FolderPreview.categories(of: summaryItems),
            action: FolderAction(systemImage: "arrow.right", accessibilityLabel: "Open Wardrobe", identifier: "home.openWardrobe") {
                router.selectedTab = .items
            }
        ) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Your discoveries")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.ink)
                    if hasOnlySamples { SampleBadge() }
                }
                Text(countText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                if let range = value.range {
                    Text(hasOnlySamples ? "Demo value, not market data" : "Estimated value")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.top, 4)
                    Text(range.formatted)
                        .font(.title.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var reviewPrompt: some View {
        Button {
            router.isReviewQueuePresented = true
        } label: {
            GlassRow(
                icon: GlassIcon(symbol: "checkmark", pastel: .lavender, size: 50),
                title: unconfirmed.count == 1 ? "1 discovery to check" : "\(unconfirmed.count) discoveries to check",
                subtitle: "Swipe through and keep what's still yours."
            ) {
                RowChevron()
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("Opens the review queue")
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(title: "Scan details")
            VStack(spacing: 0) {
                GroupedRow(title: "Photos Analysed", systemImage: "photo.stack") {
                    if photoState.authorizedPhotoCount > 0 {
                        Text("\(Formatting.count(analyzedCount)) of \(Formatting.count(photoState.authorizedPhotoCount))")
                            .monospacedDigit()
                    } else {
                        Text(Formatting.count(analyzedCount)).monospacedDigit()
                    }
                }
                if let latestSession, latestSession.photosFailed + latestSession.photosInICloud > 0 {
                    GroupedRow(title: "Not Yet Analysed", systemImage: "exclamationmark.triangle") {
                        Text(unanalysedDescription(latestSession)).monospacedDigit()
                    }
                }
                GroupedRow(title: "Items Identified", systemImage: "viewfinder") {
                    Text(Formatting.count(realItems.count)).monospacedDigit()
                }
                Button {
                    router.isReviewQueuePresented = true
                } label: {
                    GroupedRow(title: "Awaiting Confirmation", systemImage: "questionmark.circle") {
                        HStack(spacing: 6) {
                            Text(Formatting.count(unconfirmed.count)).monospacedDigit()
                            RowChevron()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(unconfirmed.isEmpty)
                GroupedRow(title: "Last Completed Scan", systemImage: "clock") {
                    if let lastCompleted, let ended = lastCompleted.endedAt {
                        Text(ended, format: .relative(presentation: .named))
                    } else {
                        Text("Never")
                    }
                }
                GroupedRow(title: "Mode", systemImage: (discovery.activeMode ?? .manual).systemImage, showsDivider: false) {
                    Text(modeDescription)
                }
            }
            .tint(Theme.ink)
            .raisedCard(radius: Theme.cardRadius, padding: 0)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(discovery.phase == .preparing ? "Preparing…" : "Analysing photos…")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let progress = discovery.progress {
                    Text("\(Formatting.count(progress.processed)) of \(Formatting.count(progress.total))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryInk)
                        .contentTransition(.numericText())
                }
            }
            if let progress = discovery.progress {
                ProgressView(value: progress.fractionCompleted).tint(Pastel.lavender.deep)
                if progress.newCandidates > 0 {
                    Text(progress.newCandidates == 1 ? "1 new item found so far" : "\(progress.newCandidates) new items found so far")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryInk)
                }
            } else {
                ProgressView()
            }
        }
        .raisedCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var primaryAction: some View {
        VStack(spacing: 10) {
            if discovery.isRunning {
                Button(role: .cancel) {
                    discovery.stop()
                } label: {
                    Text("Stop discovery").frame(minWidth: 200)
                }
                .buttonStyle(WhitePillStyle())
                Text("Progress is saved as you go. You can resume at any time.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
            } else {
                Button {
                    startDiscovery()
                } label: {
                    HStack(spacing: 12) {
                        Text(isResumable ? "Resume discovery" : "Start discovery")
                        Spacer(minLength: 16)
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                    .frame(width: typeSize.isAccessibilitySize ? nil : 250)
                }
                .buttonStyle(BlackPillStyle())
                .accessibilityIdentifier("home.startDiscovery")
                Text(actionFootnote ?? "Only photos you allow. Analysis stays on your phone.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Charge & Discover runs only when iOS grants background time, so the
    /// copy never promises continuous processing.
    private var chargeRow: some View {
        GlassRow(
            icon: GlassIcon(symbol: "bolt", pastel: .powder, size: 50),
            title: "Charge & Discover",
            subtitle: chargeSubtitle
        ) {
            Button(background.isEnabled ? "Settings" : "Set up") { router.isSettingsPresented = true }
                .buttonStyle(WhitePillStyle(compact: true))
                .accessibilityLabel(background.isEnabled ? "Charge & Discover settings" : "Set up Charge & Discover")
        }
    }

    private var chargeSubtitle: String {
        if !background.isEnabled { return "Runs while charging, when iOS allows." }
        return device.isConnectedToPower ? "On · iOS decides when it runs." : "On · runs while charging, when iOS allows."
    }

    private var recentDiscoveries: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(title: "Recent discoveries", actionTitle: items.count > 4 ? "See all" : nil) {
                router.selectedTab = .items
            }
            if items.isEmpty {
                Text("Items will appear here as they're found.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            ForEach(items.prefix(4)) { item in
                NavigationLink(value: item.id) {
                    ItemGlassRow(item: item)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private var emptyState: some View {
        let analysedNothing = (lastCompleted?.photosAnalyzed ?? 0) > 0
        return VStack(spacing: 18) {
            FrostedFolder(
                previews: [FolderPreview(category: .clothing), FolderPreview(category: .electronics), FolderPreview(category: .bags)],
                frontHeight: 150
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(analysedNothing ? "No items found yet" : "Discover what you could sell")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.ink)
                    Text(analysedNothing
                         ? "Rakful analysed \(Formatting.count(lastCompleted?.photosAnalyzed ?? 0)) photos and didn't find anything that looks resellable."
                         : "Rakful looks through the photos you choose for things like clothes, footwear and bags.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Button {
                startDiscovery()
            } label: {
                HStack(spacing: 12) {
                    Text(analysedNothing ? "Discover again" : "Start discovery")
                    Spacer(minLength: 16)
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
                .frame(width: typeSize.isAccessibilitySize ? nil : 250)
            }
            .buttonStyle(BlackPillStyle())
            .accessibilityIdentifier("home.startDiscovery")
            Text("Only photos you allow. Analysis stays on your phone.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryInk)
            if photoState.accessLevel == .limited, analysedNothing {
                Button("Choose more photos") { photoState.presentLimitedLibraryPicker() }
                    .buttonStyle(WhitePillStyle())
            }
            Button("Explore sample items") { addSamples() }
                .buttonStyle(WhitePillStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private func reportBanner(_ report: DiscoveryReport) -> some View {
        Button {
            showsReport = true
        } label: {
            GlassRow(icon: GlassIcon(symbol: "sun.horizon", pastel: .apricot, size: 50), title: "Your discovery review is ready", subtitle: report.headline) {
                RowChevron()
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var accessBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                GlassIcon(symbol: "photo", pastel: .blush, size: 46)
                Text(photoState.accessWasRevoked ? "Photo access was turned off" : "Photo access is off")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
            }
            Text(photoState.accessLevel.explanation)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
            Button("Open Settings") { openSystemSettings() }
                .buttonStyle(WhitePillStyle(compact: true))
        }
        .raisedCard()
    }

    // MARK: - Derived text

    private var isResumable: Bool {
        guard let latestSession, latestSession.status == .interrupted else { return false }
        return (pendingCount ?? 0) > 0
    }

    private func unanalysedDescription(_ session: DiscoverySession) -> String {
        var parts: [String] = []
        if session.photosInICloud > 0 { parts.append("\(Formatting.count(session.photosInICloud)) in iCloud") }
        if session.photosFailed > 0 { parts.append("\(Formatting.count(session.photosFailed)) failed") }
        return parts.joined(separator: " · ")
    }

    private var modeDescription: String {
        if let mode = discovery.activeMode { return mode.displayName }
        return background.isEnabled ? "Manual + Charge & Discover" : "Manual · On This Phone"
    }

    private var actionFootnote: String? {
        if case .allowanceExhausted = discovery.lastResult?.outcome {
            return "You've reached this month's photo allowance for \(entitlements.tier.displayName)."
        }
        if let latestSession, latestSession.photosFailed > 0 {
            return "\(Formatting.count(latestSession.photosFailed)) photos couldn't be analysed last time. They'll be retried automatically."
        }
        if let latestSession, latestSession.photosInICloud > 0, !preferences.allowICloudDownloads {
            return "Some photos are stored only in iCloud. Turn on Download iCloud Photos in Settings to include them."
        }
        if photoState.accessLevel == .limited {
            return "Rakful can only see the photos you've selected."
        }
        if let pendingCount, pendingCount > 0, analyzedCount > 0 {
            return "\(Formatting.count(pendingCount)) photos haven't been analysed yet."
        }
        if let pendingCount, pendingCount == 0, analyzedCount > 0 {
            return "All authorised photos have been analysed. New photos will be included next time."
        }
        if device.isLowPowerMode {
            return "Low Power Mode is on. Discovery may run more slowly."
        }
        return nil
    }

    // MARK: - Actions

    private func startDiscovery() {
        Task {
            if photoState.accessLevel == .denied || photoState.accessLevel == .restricted {
                showsAccessAlert = true
                return
            }
            guard let result = await discovery.start(mode: .manual, canPromptForAccess: true) else { return }
            switch result.outcome {
            case .permissionDenied:
                showsAccessAlert = photoState.accessLevel != .notDetermined
            case .allowanceExhausted:
                router.isPlansPresented = true
            case .completed:
                completedRuns += 1
            case .failed(let message):
                failureMessage = message
            default:
                break
            }
            await refreshCounts()
        }
    }

    private func addSamples() {
        try? SampleData.insert(into: context)
    }

    private func removeSamples() {
        try? SampleData.remove(from: context)
    }

    private func refreshCounts() async {
        let analyzed = PhotoProcessingStatus.analyzed.rawValue
        analyzedCount = (try? context.fetchCount(FetchDescriptor<PhotoReference>(predicate: #Predicate { $0.statusRaw == analyzed }))) ?? 0
        if !discovery.isRunning, photoState.accessLevel.canRead {
            pendingCount = await discovery.pendingPhotoCount()
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// A recent item: glass icon, name, value (when known) and ownership.
struct ItemGlassRow: View {
    let item: CandidateItem

    var body: some View {
        GlassRow(icon: GlassIcon(category: item.category, size: 50), title: item.displayName, subtitle: subtitle, isSample: item.isDemo) {
            HStack(spacing: 10) {
                OwnershipBadge(status: item.ownership, showsLabel: false)
                RowChevron()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows item details")
    }

    private var subtitle: String {
        if let estimate = item.latestEstimate { return estimate.range.formatted }
        return "\(item.category.displayName) · \(item.ownership.displayName)"
    }
}
