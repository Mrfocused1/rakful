import SwiftData
import SwiftUI

/// Developer diagnostics for Charge & Discover reliability: every request,
/// execution, expiration and outcome is recorded so behaviour can be checked
/// on a real device rather than assumed.
struct DiagnosticsView: View {
    @Environment(BackgroundDiscoveryManager.self) private var background
    @Environment(DiscoveryCoordinator.self) private var discovery
    @Environment(DeviceConditionMonitor.self) private var device
    @Environment(PhotoLibraryState.self) private var photoState
    @Environment(EntitlementService.self) private var entitlements

    @Query(sort: \BackgroundTaskRecord.createdAt, order: .reverse) private var records: [BackgroundTaskRecord]
    @State private var isSimulating = false

    private var requests: [BackgroundTaskRecord] { records.filter { $0.kind == .request } }
    private var executions: [BackgroundTaskRecord] { records.filter { $0.kind == .execution } }
    private var simulated: [BackgroundTaskRecord] { records.filter { $0.kind == .simulatedExecution } }

    var body: some View {
        @Bindable var entitlements = entitlements
        List {
            Section("Current State") {
                LabeledContent("Charge & Discover", value: background.isEnabled ? "On" : "Off")
                LabeledContent("Pending Requests", value: "\(background.pendingRequestCount)")
                if let error = background.lastScheduleError {
                    LabeledContent("Last Scheduling Error") { Text(error).font(.footnote) }
                }
                LabeledContent("Photo Access", value: photoState.accessLevel.displayName)
                LabeledContent("Power", value: device.chargingDescription)
                LabeledContent("Low Power Mode", value: device.isLowPowerMode ? "On" : "Off")
                LabeledContent("Thermal State", value: device.thermalDescription)
                LabeledContent("Wi-Fi", value: device.isOnWiFi ? "Connected" : "Not connected")
            }

            Section {
                LabeledContent("Requests Submitted", value: "\(requests.filter { $0.outcome == .requested }.count)")
                LabeledContent("Requests Rejected", value: "\(requests.filter { $0.outcome == .failed }.count)")
                LabeledContent("System Executions", value: "\(executions.count)")
                LabeledContent("Completed", value: "\(executions.filter { $0.outcome == .completed }.count)")
                LabeledContent("Expired by iOS", value: "\(executions.filter(\.expirationReceived).count)")
                LabeledContent("Skipped / Failed", value: "\(executions.filter { $0.outcome == .skipped || $0.outcome == .failed }.count)")
                LabeledContent("Average Duration", value: averageDuration(executions))
                LabeledContent("Photos per Execution", value: averagePhotos(executions))
                LabeledContent("Resume Success", value: resumeSuccess(executions))
            } header: {
                Text("Reliability (Real Executions)")
            } footer: {
                Text("Resume success is the share of executions that started from a checkpoint and analysed at least one photo.")
            }

            Section {
                Button {
                    simulate(expireAfter: nil)
                } label: {
                    Label("Simulate Background Launch", systemImage: "play.circle")
                }
                Button {
                    simulate(expireAfter: 4)
                } label: {
                    Label("Simulate Launch, Expire After 4s", systemImage: "timer")
                }
                Button {
                    Task { await background.scheduleIfEligible() }
                } label: {
                    Label("Submit Request Now", systemImage: "paperplane")
                }
                if isSimulating || discovery.isRunning {
                    HStack {
                        ProgressView()
                        Text(discovery.progress.map { "Analysing \($0.processed) of \($0.total)" } ?? "Running…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Test")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Simulations run the same handler iOS invokes, in the foreground, and are recorded separately.")
                    // Debug only: the selector name must not ship in release binaries.
                    #if DEBUG
                    Text("To trigger a real launch on a device, pause in the debugger after backgrounding the app and run:")
                    Text("e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@\"\(BackgroundDiscoveryManager.taskIdentifier)\"]")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    #endif
                }
            }
            .disabled(isSimulating || discovery.isRunning || !background.isEnabled)

            #if DEBUG
            Section {
                Picker("Entitlement Override", selection: $entitlements.debugTierOverride) {
                    Text("None (Use StoreKit)").tag(SubscriptionTier?.none)
                    ForEach(SubscriptionTier.allCases, id: \.self) { Text($0.shortName).tag(Optional($0)) }
                }
            } header: {
                Text("Debug Builds Only")
            } footer: {
                Text("Overrides the subscription tier for testing gated features. This control is compiled out of release builds.")
            }
            #endif

            Section("History") {
                if records.isEmpty {
                    Text("No background activity recorded yet.").foregroundStyle(.secondary)
                }
                ForEach(records.prefix(100)) { record in
                    RecordRow(record: record)
                }
            }
        }
        .navigationTitle("Background Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await background.refreshPendingRequests() }
        .refreshable { await background.refreshPendingRequests() }
    }

    private func simulate(expireAfter seconds: Double?) {
        isSimulating = true
        Task {
            await background.simulateLaunch(expireAfter: seconds)
            isSimulating = false
        }
    }

    private func averageDuration(_ records: [BackgroundTaskRecord]) -> String {
        let durations = records.compactMap(\.duration)
        guard !durations.isEmpty else { return "—" }
        return Formatting.duration(durations.reduce(0, +) / Double(durations.count))
    }

    private func averagePhotos(_ records: [BackgroundTaskRecord]) -> String {
        let ran = records.filter { $0.outcome != .skipped }
        guard !ran.isEmpty else { return "—" }
        return String(ran.map(\.photosProcessed).reduce(0, +) / ran.count)
    }

    private func resumeSuccess(_ records: [BackgroundTaskRecord]) -> String {
        let resumed = records.filter(\.resumedFromCheckpoint)
        guard !resumed.isEmpty else { return "—" }
        let succeeded = resumed.filter { $0.photosProcessed > 0 }.count
        return (Double(succeeded) / Double(resumed.count)).formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct RecordRow: View {
    let record: BackgroundTaskRecord

    private var title: String {
        switch record.kind {
        case .request: "Request"
        case .execution: "Execution"
        case .simulatedExecution: "Simulated Execution"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(record.outcome.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            Text(record.createdAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption).foregroundStyle(.secondary)
            if record.kind != .request {
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            if let note = record.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = ["\(record.photosProcessed) photos"]
        if let duration = record.duration { parts.append(Formatting.duration(duration)) }
        if let remaining = record.remainingAfter { parts.append("\(remaining) remaining") }
        if let charging = record.wasCharging { parts.append(charging ? "charging" : "on battery") }
        if record.expirationReceived { parts.append("expiration received") }
        if record.resumedFromCheckpoint { parts.append("resumed") }
        return parts.joined(separator: " · ")
    }

    private var color: Color {
        switch record.outcome {
        case .completed, .requested: .green
        case .expired, .skipped: .orange
        case .failed: .red
        case .running: .blue
        }
    }
}
