import Foundation
import SwiftData
import SwiftUI

/// The "morning report": a summary of discovery work that has *actually*
/// finished since the user last looked. Suggested actions are kept separate
/// from completed work.
struct DiscoveryReport: Equatable {
    var periodStart: Date
    var sessionCount: Int
    var backgroundSessionCount: Int
    var photosAnalyzed: Int
    var newItemCount: Int
    var awaitingConfirmation: Int
    var draftsPrepared: Int
    var verifiedValue: PriceRange?
    /// Set when the most recent session was paused before finishing.
    var pausedWithRemaining: Int?

    var headline: String {
        let photos = "\(Formatting.count(photosAnalyzed)) photos analysed"
        switch newItemCount {
        case 0: return photos
        case 1: return "\(photos) · 1 potential item"
        default: return "\(photos) · \(newItemCount) potential items"
        }
    }

    static func make(sessions: [DiscoverySession], items: [CandidateItem], drafts: [ListingDraft], since: Date?, currencyCode: String = Locale.current.currency?.identifier ?? "GBP", now: Date = .now) -> DiscoveryReport? {
        let start = since ?? now.addingTimeInterval(-24 * 3600)
        let relevant = sessions.filter { session in
            !session.isDemo && session.status != .running && session.photosAnalyzed > 0 && (session.endedAt ?? session.startedAt) > start
        }
        guard !relevant.isEmpty else { return nil }

        let sessionIDs = Set(relevant.map(\.id))
        let newItems = items.filter { item in
            !item.isDemo && item.discoveredInSessionID.map(sessionIDs.contains) == true
        }
        let value = ValueSummary.compute(estimates: newItems.map { $0.latestEstimate?.range }, currencyCode: currencyCode).range
        let latest = relevant.max { $0.startedAt < $1.startedAt }
        var paused: Int?
        if let latest, latest.status == .interrupted {
            let processed = latest.photosAnalyzed + latest.photosSkipped + latest.photosInICloud + latest.photosFailed
            paused = max(0, latest.queuedPhotoCount - processed)
        }

        return DiscoveryReport(
            periodStart: start,
            sessionCount: relevant.count,
            backgroundSessionCount: relevant.filter { $0.mode == .chargeAndDiscover }.count,
            photosAnalyzed: relevant.reduce(0) { $0 + $1.photosAnalyzed },
            newItemCount: newItems.count,
            awaitingConfirmation: items.filter { !$0.isDemo && $0.ownership == .unconfirmed }.count,
            draftsPrepared: drafts.filter { !$0.isDemo && $0.createdAt > start }.count,
            verifiedValue: value,
            pausedWithRemaining: paused
        )
    }

    static func greeting(for date: Date = .now, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

struct DiscoveryReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PreferencesStore.self) private var preferences
    @Environment(AppRouter.self) private var router

    @Query(sort: \DiscoverySession.startedAt, order: .reverse) private var sessions: [DiscoverySession]
    @Query private var items: [CandidateItem]
    @Query private var drafts: [ListingDraft]

    /// Captured on appear so marking the report as viewed doesn't empty it.
    @State private var since: Date?
    @State private var hasCapturedPeriod = false

    var body: some View {
        NavigationStack {
            Group {
                if let report = DiscoveryReport.make(sessions: sessions, items: items, drafts: drafts, since: since, currencyCode: preferences.currencyCode) {
                    content(report)
                } else {
                    ContentUnavailableView("No New Discoveries", systemImage: "sun.horizon", description: Text("Your report will appear here after a discovery finishes."))
                }
            }
            .navigationTitle("Discovery Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            guard !hasCapturedPeriod else { return }
            since = preferences.lastReportViewedAt
            hasCapturedPeriod = true
        }
        .onDisappear { preferences.lastReportViewedAt = .now }
    }

    private func content(_ report: DiscoveryReport) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(DiscoveryReport.greeting()).font(.largeTitle.weight(.bold))
                    Text("Your discovery review is ready.").font(.title3).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }

            Section {
                LabeledContent("Photos Analysed", value: Formatting.count(report.photosAnalyzed))
                LabeledContent("Potential Items Discovered", value: Formatting.count(report.newItemCount))
                LabeledContent("Drafts Prepared", value: Formatting.count(report.draftsPrepared))
                if let value = report.verifiedValue {
                    LabeledContent("Potential Resale Value", value: value.formatted)
                }
            } header: {
                Text("Completed")
            } footer: {
                Text(periodFooter(report))
            }

            if let remaining = report.pausedWithRemaining, remaining > 0 {
                Section {
                    Label {
                        Text("Discovery paused before finishing. \(Formatting.count(remaining)) photos remain and will be analysed when you resume or when iOS next allows background processing.")
                    } icon: {
                        Image(systemName: "pause.circle").foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                }
            }

            Section("Suggested") {
                if report.awaitingConfirmation > 0 {
                    Button {
                        dismiss()
                        router.isReviewQueuePresented = true
                    } label: {
                        Label("Review \(report.awaitingConfirmation) \(report.awaitingConfirmation == 1 ? "item" : "items") you might own", systemImage: "checkmark.circle")
                    }
                }
                Button {
                    dismiss()
                    router.selectedTab = .sell
                } label: {
                    Label("Prepare listings for items you own", systemImage: "tag")
                }
            }
        }
    }

    private func periodFooter(_ report: DiscoveryReport) -> String {
        let sessions = report.sessionCount == 1 ? "1 discovery session" : "\(report.sessionCount) discovery sessions"
        let background = report.backgroundSessionCount > 0 ? ", including \(report.backgroundSessionCount) while charging" : ""
        return "Covers \(sessions)\(background) since \(report.periodStart.formatted(date: .abbreviated, time: .shortened)). Only finished work is shown."
    }
}
