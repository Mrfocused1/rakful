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
                VStack(alignment: .leading, spacing: 24) {
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
                        if !summaryItems.isEmpty { summary }
                        primaryAction
                        if !unconfirmed.isEmpty, !discovery.isRunning { reviewPrompt }
                        if discovery.isRunning { GroupedSection { progressRow } }
                        if device.isConnectedToPower { chargingRow }
                        gallery
                        status
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Brand.canvas)
            .toolbar(.hidden, for: .navigationBar)
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

    /// Wordmark with the More menu and Settings.
    private var header: some View {
        HStack(spacing: 0) {
            RakfulLogo()
            Spacer()
            moreMenu
            Button {
                router.isSettingsPresented = true
            } label: {
                headerIcon("gearshape")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 2)
    }

    private func headerIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
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
            headerIcon("ellipsis.circle")
        }
        .tint(.primary)
        .accessibilityLabel("More")
    }

    private var summary: some View {
        let estimates = summaryItems.map { $0.latestEstimate?.range }
        let currency = hasOnlySamples ? SampleData.currencyCode : preferences.currencyCode
        let value = ValueSummary.compute(estimates: estimates, currencyCode: currency)

        return ValueHeroCard(
            value: value,
            itemCount: summaryItems.count,
            isSample: hasOnlySamples,
            previewItems: Array(summaryItems.prefix(4)),
            note: summaryNote(value)
        )
    }

    private func summaryNote(_ value: ValueSummary) -> String? {
        if hasOnlySamples {
            return "These are sample items for exploring Rakful. They aren't from your photos."
        } else if value.range == nil {
            return "Open any item to see what similar ones sold for on eBay, then set your own price."
        } else if value.pricedItemCount < value.itemCount {
            return "Based on \(value.pricedItemCount) of \(value.itemCount) items with verified pricing."
        }
        return nil
    }

    private var reviewPrompt: some View {
        Button {
            router.isReviewQueuePresented = true
        } label: {
            HStack(spacing: 16) {
                FannedThumbnails(items: Array(unconfirmed.prefix(3)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(unconfirmed.count == 1 ? "1 discovery to check" : "\(unconfirmed.count) discoveries to check")
                        .font(.headline)
                    Text("Swipe through and keep what's still yours.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.cardCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the review queue")
    }

    private var status: some View {
        GroupedSection(title: "Scan Details") {
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
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(discovery.phase == .preparing ? "Preparing…" : "Analysing photos…")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let progress = discovery.progress {
                    Text("\(Formatting.count(progress.processed)) of \(Formatting.count(progress.total))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            if let progress = discovery.progress {
                ProgressView(value: progress.fractionCompleted)
                if progress.newCandidates > 0 {
                    Text(progress.newCandidates == 1 ? "1 new item found so far" : "\(progress.newCandidates) new items found so far")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var primaryAction: some View {
        VStack(spacing: 10) {
            if discovery.isRunning {
                Button(role: .cancel) {
                    discovery.stop()
                } label: {
                    Text("Stop Discovery").frame(maxWidth: .infinity)
                }
                .secondaryActionStyle()
                .controlSize(.large)
                Text("Progress is saved as you go. You can resume at any time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    startDiscovery()
                } label: {
                    Text(isResumable ? "Resume Discovery" : "Start Discovery").frame(maxWidth: .infinity)
                }
                .prominentActionStyle()
                .controlSize(.large)
                if let footnote = actionFootnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var chargingRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Brand.accent)
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connected to Power").font(.subheadline.weight(.semibold))
                Text(background.isEnabled
                     ? "Discovery can continue when your phone allows background processing."
                     : "Turn on Charge & Discover in Settings to analyse photos while your phone charges.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: Metrics.groupedCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Discoveries")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if items.count > 6 {
                    Button("See All") { router.selectedTab = .items }
                }
            }
            if items.isEmpty {
                Text("Items will appear here as they're found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(items.prefix(12)) { item in
                        NavigationLink(value: item.id) {
                            DiscoveryTile(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Group {
            if let lastCompleted, lastCompleted.photosAnalyzed > 0 {
                ContentUnavailableView {
                    Label("No Items Found Yet", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text("Rakful analysed \(Formatting.count(lastCompleted.photosAnalyzed)) photos and didn't find anything that looks resellable. Try allowing more photos or adding categories.")
                } actions: {
                    Button {
                        startDiscovery()
                    } label: {
                        Text("Discover Again").padding(.horizontal, 12)
                    }
                    .prominentActionStyle()
                    .controlSize(.large)
                    if photoState.accessLevel == .limited {
                        Button("Choose More Photos") { photoState.presentLimitedLibraryPicker() }
                    }
                    Button("Explore Sample Items") { addSamples() }
                }
            } else {
                ContentUnavailableView {
                    Label("Discover What You Could Sell", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text("Rakful looks through the photos you choose for things like trainers, cameras and bags. Analysis happens on your phone.")
                } actions: {
                    Button {
                        startDiscovery()
                    } label: {
                        Text("Start Discovery").padding(.horizontal, 12)
                    }
                    .prominentActionStyle()
                    .controlSize(.large)
                    Button("Explore Sample Items") { addSamples() }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func reportBanner(_ report: DiscoveryReport) -> some View {
        Button {
            showsReport = true
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemImage: "sun.horizon.fill", color: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your discovery review is ready").font(.subheadline.weight(.semibold))
                    Text(report.headline).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Metrics.groupedCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accessBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(photoState.accessWasRevoked ? "Photo access was turned off" : "Photo access is off", systemImage: "photo.badge.exclamationmark")
                .font(.subheadline.weight(.semibold))
            Text(photoState.accessLevel.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Open Settings") { openSystemSettings() }
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: Metrics.groupedCornerRadius, style: .continuous))
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

/// Artwork-led card: the item's artwork (or photo) fills the card, with name
/// and value on a scrim.
struct DiscoveryTile: View {
    let item: CandidateItem

    var body: some View {
        ItemThumbnail(item: item, cornerRadius: 0)
            .aspectRatio(4 / 5, contentMode: .fit)
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.6), location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    HStack(alignment: .firstTextBaseline) {
                        Group {
                            if let estimate = item.latestEstimate {
                                Text(estimate.range.formatted)
                                    .monospacedDigit()
                            } else {
                                Text(item.category.displayName)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        Spacer(minLength: 4)
                        ConfidenceIndicator(level: item.confidenceLevel, showsLabel: false)
                    }
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .overlay(alignment: .topLeading) {
                if item.isDemo { SampleBadge().padding(10) }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: item.ownership.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OwnershipBadge(status: item.ownership).tint)
                    .padding(6)
                    .background(.regularMaterial, in: Circle())
                    .padding(8)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: Brand.cardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: Brand.cardCornerRadius, style: .continuous))
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

/// The summary at the top of Home: how many items were found and, when known,
/// a quiet estimate of their value.
struct ValueHeroCard: View {
    let value: ValueSummary
    let itemCount: Int
    let isSample: Bool
    let previewItems: [CandidateItem]
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Found in your photos")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                if isSample { SampleBadge().environment(\.colorScheme, .light) }
            }
            HStack(spacing: 12) {
                Text(itemCount == 1 ? "1 item" : "\(itemCount) items")
                    .font(.title2.weight(.semibold))
                ThumbnailStack(items: previewItems)
            }
            if let range = value.range {
                Text("Estimated \(range.formatted)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                Brand.heroGradient
                RadialGradient(colors: [.white.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 220)
            }
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Brand.deepBlue.opacity(0.25), radius: 16, y: 8)
    }
}

/// A few item thumbnails fanned like cards, for the review prompt.
private struct FannedThumbnails: View {
    let items: [CandidateItem]

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated().reversed()), id: \.element.id) { index, item in
                ItemThumbnail(item: item, cornerRadius: 8)
                    .frame(width: 40, height: 50)
                    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Brand.surface, lineWidth: 2) }
                    .rotationEffect(.degrees(Double(index) * 9 - 9))
                    .offset(x: CGFloat(index) * 9)
            }
        }
        .frame(width: 64, height: 56)
        .accessibilityHidden(true)
    }
}
