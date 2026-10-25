import SwiftData
import SwiftUI

struct ActivityView: View {
    @Environment(PreferencesStore.self) private var preferences
    @Query(sort: \ActivityEvent.date, order: .reverse) private var events: [ActivityEvent]
    @Query(sort: \DiscoverySession.startedAt, order: .reverse) private var sessions: [DiscoverySession]
    @Query private var items: [CandidateItem]
    @Query private var drafts: [ListingDraft]

    @State private var filter: ActivityGroup = .all
    @State private var showsReport = false

    private var filtered: [ActivityEvent] {
        filter == .all ? events : events.filter { $0.kind.group == filter }
    }

    private var days: [(day: Date, events: [ActivityEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    /// The most recent report regardless of whether it has been viewed.
    private var latestReport: DiscoveryReport? {
        DiscoveryReport.make(sessions: sessions, items: items, drafts: drafts, since: preferences.lastReportViewedAt, currencyCode: preferences.currencyCode)
    }

    /// Items found so far; sample items only when there are no real ones.
    private var progressItems: [CandidateItem] {
        let real = items.filter { !$0.isDemo }
        return real.isEmpty ? items : real
    }
    private var progressIsSample: Bool { items.allSatisfy(\.isDemo) && !items.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    ScreenHeader(title: "Activity") {
                        Menu {
                            Picker("Show", selection: $filter) {
                                ForEach(ActivityGroup.allCases) { Text($0.displayName).tag($0) }
                            }
                        } label: {
                            CircleIconLabel(systemImage: "line.3.horizontal.decrease", isActive: filter != .all)
                        }
                        .accessibilityLabel("Filter")
                    }
                    progressCard
                    if let report = latestReport {
                        Button { showsReport = true } label: {
                            GlassRow(icon: GlassIcon(symbol: "sun.horizon", pastel: .apricot, size: 50), title: DiscoveryReport.greeting(), subtitle: "Your discovery review is ready. \(report.headline)") {
                                RowChevron()
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }
                    if filtered.isEmpty {
                        VStack(spacing: 12) {
                            GlassIcon(symbol: "clock", pastel: .lavender, size: 80)
                            Text(events.isEmpty ? "No activity yet" : "No \(filter.displayName.lowercased()) activity")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("Discovery sessions, items you confirm and listings you prepare will appear here.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryInk)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                    }
                    ForEach(days, id: \.day) { day in
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: Self.title(for: day.day, isSample: day.events.allSatisfy(\.isDemo)))
                            ForEach(day.events) { ActivityRow(event: $0) }
                        }
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 24)
            }
            .glassPage()
            .sheet(isPresented: $showsReport) { DiscoveryReportView() }
            .animation(.smooth, value: filter)
        }
    }

    /// Real counts only: what's been found, what's ready to list and the
    /// drafts in progress.
    private var progressCard: some View {
        let found = progressItems.filter { $0.ownership != .notOwned }.count
        let ready = progressItems.filter { $0.ownership == .owned && $0.drafts.isEmpty }.count
        let inProgress = drafts.filter { $0.status == .draft || $0.status == .approved }.filter { $0.isDemo == progressIsSample || !$0.isDemo }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Your progress").font(.headline).foregroundStyle(Theme.ink)
                if progressIsSample { SampleBadge() }
            }
            HStack(spacing: 0) {
                progressStat(symbol: "folder", pastel: .lavender, value: found, label: "discovered")
                Divider().frame(height: 56).overlay(Color.white.opacity(0.7))
                progressStat(symbol: "tag", pastel: .blush, value: ready, label: "ready")
                Divider().frame(height: 56).overlay(Color.white.opacity(0.7))
                progressStat(symbol: "doc.text", pastel: .lavender, value: inProgress, label: inProgress == 1 ? "draft" : "drafts")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(LinearGradient(colors: [Pastel.lavender.front.opacity(0.22), Pastel.powder.front.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        }
        .overlay { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.white, lineWidth: 1) }
        .shadow(color: Pastel.lavender.deep.opacity(0.1), radius: 14, y: 6)
    }

    private func progressStat(symbol: String, pastel: Pastel, value: Int, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(pastel.deep)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white))
                .shadow(color: pastel.deep.opacity(0.15), radius: 6, y: 3)
            Text(Formatting.count(value))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private static func title(for day: Date, isSample: Bool) -> String {
        let calendar = Calendar.current
        if isSample, calendar.isDateInToday(day) { return "Sample activity" }
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        GlassRow(icon: GlassIcon(symbol: event.kind.glyph, pastel: event.kind.pastel, size: 46), title: event.title, subtitle: event.detail, isSample: event.isDemo) {
            Text(ShortTime.string(for: event.date))
                .font(.caption)
                .foregroundStyle(Theme.secondaryInk)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

extension ActivityKind {
    /// Outline symbol and pastel for the activity's glass icon.
    var glyph: String {
        switch self {
        case .discoveryStarted: "sparkle.magnifyingglass"
        case .photosAnalyzed: "photo"
        case .candidateIdentified: "viewfinder"
        case .ownershipConfirmed: "checkmark"
        case .valuationCompleted: "sterlingsign"
        case .listingDraftCreated: "doc.text"
        case .listingApproved: "checkmark.rectangle"
        case .listingHandedOff: "tag"
        case .listingConfirmedListed: "checkmark.seal"
        case .scanInterrupted: "pause"
        case .scanResumed: "play"
        case .backgroundTaskCompleted: "moon.stars"
        case .backgroundTaskScheduled: "bolt"
        }
    }

    var pastel: Pastel {
        switch self {
        case .discoveryStarted, .photosAnalyzed, .candidateIdentified, .scanResumed, .backgroundTaskScheduled: .powder
        case .ownershipConfirmed: .blush
        case .valuationCompleted, .listingHandedOff: .apricot
        case .listingDraftCreated, .listingApproved, .scanInterrupted, .backgroundTaskCompleted: .lavender
        case .listingConfirmedListed: .mint
        }
    }
}
