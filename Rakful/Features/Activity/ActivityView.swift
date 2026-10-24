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

    var body: some View {
        NavigationStack {
            List {
                if let report = latestReport {
                    Section {
                        Button { showsReport = true } label: {
                            HStack(spacing: 12) {
                                SettingsIcon(systemImage: "sun.horizon.fill", color: .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(DiscoveryReport.greeting()).font(.headline)
                                    Text("Your discovery review is ready.").font(.subheadline)
                                    Text(report.headline).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForEach(days, id: \.day) { day in
                    Section {
                        ForEach(day.events) { ActivityRow(event: $0) }
                    } header: {
                        Text(Self.title(for: day.day))
                    }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        events.isEmpty ? "No Activity Yet" : "No \(filter.displayName) Activity",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Discovery sessions, items you confirm and listings you prepare will appear here.")
                    )
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $filter) {
                            ForEach(ActivityGroup.allCases) { Text($0.displayName).tag($0) }
                        }
                    } label: {
                        Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showsReport) { DiscoveryReportView() }
            .animation(.smooth, value: filter)
        }
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

struct ActivityRow: View {
    let event: ActivityEvent

    private var color: Color {
        switch event.kind.group {
        case .discovery: .blue
        case .items: .green
        case .listings: .orange
        case .background: .indigo
        case .all: .gray
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(systemImage: event.kind.systemImage, color: event.kind == .scanInterrupted ? .gray : color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title).font(.subheadline.weight(.medium))
                    if event.isDemo { SampleBadge() }
                    Spacer(minLength: 8)
                    Text(event.date, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let detail = event.detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
