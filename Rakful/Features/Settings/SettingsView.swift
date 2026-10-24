import SwiftData
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(PreferencesStore.self) private var preferences
    @Environment(PhotoLibraryState.self) private var photoState
    @Environment(DeviceConditionMonitor.self) private var device
    @Environment(EntitlementService.self) private var entitlements
    @Environment(DiscoveryCoordinator.self) private var discovery
    @Environment(BackgroundDiscoveryManager.self) private var background
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<BackgroundTaskRecord> { $0.kindRaw != "request" }, sort: \BackgroundTaskRecord.createdAt, order: .reverse)
    private var executions: [BackgroundTaskRecord]
    @Query(filter: #Predicate<CandidateItem> { $0.isDemo == true }) private var sampleItems: [CandidateItem]

    @State private var usedThisMonth = 0
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var pendingConfirmation: DestructiveAction?
    @State private var showsCloudConsent = false
    @State private var resultMessage: String?

    enum DestructiveAction: Identifiable {
        case deleteHistory, removeImages, revokeIntegrations, eraseAll
        var id: Self { self }
    }

    private let backend = AppEnvironment.shared.backend

    var body: some View {
        @Bindable var preferences = preferences
        NavigationStack {
            Form {
                subscriptionHeader
                discoverySection(preferences)
                chargingSection(preferences)
                privacySection(preferences)
                notificationsSection
                accountSection
                Section {
                    if sampleItems.isEmpty {
                        Button("Add Sample Items") { try? SampleData.insert(into: context) }
                    } else {
                        Button("Remove Sample Items", role: .destructive) { try? SampleData.remove(from: context) }
                    }
                } header: {
                    Text("Sample Data")
                } footer: {
                    Text("Sample items are labelled and kept separate from your own discoveries.")
                }
                Section {
                    Button("Show Welcome Screens") {
                        router.replaysOnboardingAfterSettings = true
                        dismiss()
                    }
                    NavigationLink("Privacy Policy") { PrivacyPolicyView() }
                    Link("Terms of Use", destination: LegalLinks.termsOfUse)
                    LabeledContent("Version", value: Self.versionString)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: Binding(get: { router.isPlansPresented }, set: { router.isPlansPresented = $0 })) {
                PlansView()
            }
            .task { await refresh() }
            .onChange(of: preferences.includeScreenshots) { photoState.refresh() }
            .onChange(of: preferences.chargeAndDiscoverEnabled) { Task { await background.scheduleIfEligible() } }
            .onChange(of: preferences.requireExternalPower) { Task { await background.scheduleIfEligible() } }
            .confirmationDialog(confirmationTitle, isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }), titleVisibility: .visible, presenting: pendingConfirmation) { action in
                Button(confirmationButton(action), role: .destructive) { perform(action) }
            } message: { action in
                Text(confirmationMessage(action))
            }
            .alert("Allow Cloud Analysis?", isPresented: $showsCloudConsent) {
                Button("Allow") { preferences.cloudAnalysisConsent = true }
                Button("Don't Allow", role: .cancel) {}
            } message: {
                Text("When you ask for cloud identification, a small, downsized copy of that item's photo is sent to the Rakful server for analysis and then discarded. Nothing is uploaded automatically.")
            }
            .alert("Done", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var subscriptionHeader: some View {
        Section {
            NavigationLink {
                SubscriptionStatusView()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "tag.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Brand.accent.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entitlements.tier.displayName).font(.headline)
                        Text(entitlements.tier == .free ? "Upgrade for Charge & Discover" : "Subscription active")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func discoverySection(_ preferences: PreferencesStore) -> some View {
        @Bindable var preferences = preferences
        return Section {
            NavigationLink {
                PhotoAccessView()
            } label: {
                LabeledContent {
                    Text(photoState.accessLevel.displayName)
                } label: {
                    Label { Text("Photos") } icon: { SettingsIcon(systemImage: "photo.on.rectangle", color: .blue) }
                }
            }
            NavigationLink {
                CategoriesSettingsView()
            } label: {
                LabeledContent {
                    Text("\(preferences.enabledCategories.count) of \(ResaleCategory.allCases.count)")
                } label: {
                    Label { Text("Categories") } icon: { SettingsIcon(systemImage: "square.grid.2x2", color: .purple) }
                }
            }
            Toggle("Include Screenshots", isOn: $preferences.includeScreenshots)
            Toggle("Download iCloud Photos", isOn: $preferences.allowICloudDownloads)
            LabeledContent("Analysed This Month") {
                if let allowance = entitlements.limits.monthlyPhotoAllowance {
                    Text("\(Formatting.count(usedThisMonth)) of \(Formatting.count(allowance))")
                } else {
                    Text("\(Formatting.count(usedThisMonth)) · Unlimited")
                }
            }
        } header: {
            Text("Discovery")
        } footer: {
            Text("Photos stored only in iCloud are downloaded at a small size for analysis when allowed. Screenshots are skipped unless included.")
        }
    }

    private func chargingSection(_ preferences: PreferencesStore) -> some View {
        @Bindable var preferences = preferences
        let lastRun = executions.first { $0.startedAt != nil }
        return Section {
            Toggle(isOn: Binding(
                get: { preferences.chargeAndDiscoverEnabled && entitlements.limits.chargeAndDiscover },
                set: { newValue in
                    if newValue && !entitlements.limits.chargeAndDiscover {
                        router.isPlansPresented = true
                    } else {
                        preferences.chargeAndDiscoverEnabled = newValue
                    }
                }
            )) {
                Label { Text("Charge & Discover") } icon: { SettingsIcon(systemImage: "bolt.batteryblock.fill", color: .green) }
            }
            Group {
                Toggle("Only While Charging", isOn: $preferences.requireExternalPower)
                Toggle("Wi-Fi Only for iCloud Photos", isOn: $preferences.wifiOnlyForICloud)
                Toggle("Pause in Low Power Mode", isOn: $preferences.pauseInLowPowerMode)
            }
            .disabled(!background.isEnabled)
            LabeledContent("Charging Status", value: device.chargingDescription)
            LabeledContent("Last Background Run") {
                if let started = lastRun?.startedAt {
                    Text("\(started.formatted(.relative(presentation: .named))) · \(lastRun?.outcome.displayName ?? "")")
                } else {
                    Text("Never")
                }
            }
            LabeledContent("Next Run", value: background.pendingRequestCount > 0 ? "Requested — iOS decides when" : "Not scheduled")
            NavigationLink("Background Diagnostics") { DiagnosticsView() }
        } header: {
            Text("Charge & Discover")
        } footer: {
            Text(entitlements.limits.chargeAndDiscover
                 ? "iOS decides when background processing runs, typically while your iPhone is idle and charging. Discovery saves progress in small steps and resumes where it left off. Background App Refresh must be on."
                 : "Charge & Discover is included with Rakful Plus and Pro. iOS decides when background processing runs.")
        }
    }

    private func privacySection(_ preferences: PreferencesStore) -> some View {
        @Bindable var preferences = preferences
        return Section {
            LabeledContent("Photo Analysis", value: "On This iPhone")
            if backend.isConfigured {
                Toggle("Cloud Identification", isOn: Binding(
                    get: { preferences.cloudAnalysisConsent },
                    set: { if $0 { showsCloudConsent = true } else { preferences.cloudAnalysisConsent = false } }
                ))
            }
            Toggle(isOn: $preferences.useAppleIntelligence) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence for Listings")
                    Text(ListingGeneratorFactory.appleIntelligenceStatus).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Picker("Keep Activity History", selection: $preferences.retention) {
                ForEach(PreferencesStore.RetentionPeriod.allCases) { Text($0.displayName).tag($0) }
            }
            Button("Delete Discovery History", role: .destructive) { pendingConfirmation = .deleteHistory }
            Button("Remove Imported Images", role: .destructive) { pendingConfirmation = .removeImages }
            Button("Revoke Integrations", role: .destructive) { pendingConfirmation = .revokeIntegrations }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Photos are analysed on this iPhone with Apple's Vision framework. Rakful stores small references and image fingerprints, never copies of your library, and never deletes or edits your photos.")
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Discovery Completed", isOn: notificationBinding(\.notifyDiscoveryCompleted))
            Toggle("Morning Report", isOn: notificationBinding(\.notifyMorningReport))
            Toggle("Listing Reminders", isOn: notificationBinding(\.notifyListingReminders))
            if notificationStatus == .denied {
                Button("Turn On in Settings") { openSystemSettings() }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(notificationStatus == .denied
                 ? "Notifications are turned off for Rakful in Settings."
                 : "Notifications are only sent about work that has actually finished.")
        }
    }

    private var accountSection: some View {
        Section {
            NavigationLink("Subscription") { SubscriptionStatusView() }
            NavigationLink("Marketplace Connections") { MarketplaceConnectionsView() }
            Button("Delete All Data", role: .destructive) { pendingConfirmation = .eraseAll }
        } header: {
            Text("Account")
        } footer: {
            Text("Rakful doesn't need an account — everything is stored on this iPhone. Deleting removes all Rakful data but never your photos.")
        }
    }

    // MARK: - Helpers

    private func notificationBinding(_ keyPath: ReferenceWritableKeyPath<PreferencesStore, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences[keyPath: keyPath] && notificationStatus != .denied },
            set: { newValue in
                preferences[keyPath: keyPath] = newValue
                guard newValue else { return }
                Task {
                    if notificationStatus == .notDetermined {
                        let granted = await AppEnvironment.shared.notifications.requestAuthorization()
                        if !granted { preferences[keyPath: keyPath] = false }
                    }
                    notificationStatus = await AppEnvironment.shared.notifications.authorizationStatus()
                }
            }
        )
    }

    private func refresh() async {
        usedThisMonth = await discovery.photosAnalyzedThisMonth()
        notificationStatus = await AppEnvironment.shared.notifications.authorizationStatus()
        await background.refreshPendingRequests()
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .deleteHistory: "Delete discovery history?"
        case .removeImages: "Remove imported images?"
        case .revokeIntegrations: "Revoke all integrations?"
        case .eraseAll: "Delete all Rakful data?"
        case nil: ""
        }
    }

    private func confirmationButton(_ action: DestructiveAction) -> String {
        switch action {
        case .deleteHistory: "Delete History"
        case .removeImages: "Remove Images"
        case .revokeIntegrations: "Revoke"
        case .eraseAll: "Delete Everything"
        }
    }

    private func confirmationMessage(_ action: DestructiveAction) -> String {
        switch action {
        case .deleteHistory: "Sessions, activity and analysed-photo records are removed. Your items are kept, and photos will be analysed again next time."
        case .removeImages: "Photos you took or imported for listings are deleted from Rakful. Your photo library isn't affected."
        case .revokeIntegrations: "Marketplace connections are removed and their access tokens are deleted from this iPhone."
        case .eraseAll: "Items, drafts, history and settings are permanently deleted. Your photo library isn't affected. Subscriptions are managed by Apple and aren't cancelled."
        }
    }

    private func perform(_ action: DestructiveAction) {
        do {
            switch action {
            case .deleteHistory:
                try DataManagement.deleteDiscoveryHistory(in: context)
                resultMessage = "Discovery history deleted."
            case .removeImages:
                let count = try DataManagement.removeImportedImages(in: context)
                resultMessage = count == 1 ? "1 imported image removed." : "\(count) imported images removed."
            case .revokeIntegrations:
                try DataManagement.revokeIntegrations(in: context)
                resultMessage = "Integrations revoked."
            case .eraseAll:
                discovery.stop()
                background.cancelScheduled()
                AppEnvironment.shared.notifications.cancelAll()
                try DataManagement.eraseAllData(in: context, preferences: preferences)
            }
            Task { await discovery.store().invalidateIndex() }
        } catch {
            resultMessage = "That couldn't be completed. \(error.localizedDescription)"
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Photo access

struct PhotoAccessView: View {
    @Environment(PhotoLibraryState.self) private var photoState

    var body: some View {
        List {
            Section {
                LabeledContent("Access", value: photoState.accessLevel.displayName)
                if photoState.accessLevel.canRead {
                    LabeledContent("Photos Available", value: Formatting.count(photoState.authorizedPhotoCount))
                }
            } footer: {
                Text(photoState.accessLevel.explanation)
            }
            Section {
                switch photoState.accessLevel {
                case .notDetermined:
                    Button("Allow Photo Access") { Task { _ = await photoState.requestAccess() } }
                case .limited:
                    Button("Select More Photos") { photoState.presentLimitedLibraryPicker() }
                    Button("Change in Settings") { openSettings() }
                case .full:
                    Button("Change in Settings") { openSettings() }
                case .denied, .restricted:
                    Button("Open Settings") { openSettings() }
                }
            } footer: {
                Text("Rakful reads small versions of your photos to look for items. It never edits, moves or deletes anything in your library.")
            }
        }
        .navigationTitle("Photo Access")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { photoState.refresh() }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

// MARK: - Categories

struct CategoriesSettingsView: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        List {
            Section {
                CategorySelectionList(selection: Binding(get: { preferences.enabledCategories }, set: { preferences.enabledCategories = $0 }))
            } footer: {
                Text("Discovery looks for these kinds of items. At least one category must stay on.")
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CategorySelectionList: View {
    @Binding var selection: Set<ResaleCategory>

    var body: some View {
        ForEach(ResaleCategory.allCases) { category in
            Button {
                withAnimation(.snappy) {
                    if selection.contains(category) {
                        if selection.count > 1 { selection.remove(category) }
                    } else {
                        selection.insert(category)
                    }
                }
            } label: {
                HStack {
                    Label(category.displayName, systemImage: category.systemImage)
                        .foregroundStyle(.primary)
                    Spacer()
                    if selection.contains(category) {
                        Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(category) ? .isSelected : [])
            .sensoryFeedback(.selection, trigger: selection.contains(category))
        }
    }
}

// MARK: - Marketplace connections

struct MarketplaceConnectionsView: View {
    @Environment(\.modelContext) private var context
    @Query private var connections: [MarketplaceConnection]
    @State private var errorMessage: String?
    @State private var isConnecting = false

    private let backend = AppEnvironment.shared.backend

    private var ebay: MarketplaceConnection? { connections.first { $0.marketplace == .ebay } }

    var body: some View {
        List {
            if backend.isConfigured {
                ebaySection
            }

            Section {
                ForEach(manualMarketplaces) { marketplace in
                    LabeledContent(marketplace.displayName, value: "Manual listing")
                }
            } header: {
                Text(backend.isConfigured ? "Other Marketplaces" : "Marketplaces")
            } footer: {
                Text("Rakful prepares the listing text; you post it yourself. It never signs in to, automates or scrapes these services.")
            }
        }
        .navigationTitle("Marketplace Connections")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// eBay is listed manually until the Rakful server is available.
    private var manualMarketplaces: [Marketplace] {
        Marketplace.allCases.filter { $0 != .other && ($0.publishingMethod == .manualHandoff || !backend.isConfigured) }
    }

    private var ebaySection: some View {
        Section {
            LabeledContent("Status", value: ebay?.status == .connected ? "Connected" : "Not Connected")
            if ebay?.status == .connected {
                Button("Disconnect", role: .destructive) { disconnectEbay() }
            } else {
                Button {
                    connectEbay()
                } label: {
                    HStack {
                        Text("Connect eBay Account")
                        if isConnecting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isConnecting)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("eBay")
        } footer: {
            Text("Uses eBay's official sign-in. Rakful never sees your eBay password.")
        }
    }

    private func connectEbay() {
        isConnecting = true
        errorMessage = nil
        let linker = EbayAccountLinker(client: AppEnvironment.shared.backendClient)
        Task {
            do {
                try await linker.connect()
                let connection = ebay ?? {
                    let created = MarketplaceConnection(marketplace: .ebay)
                    context.insert(created)
                    return created
                }()
                connection.status = .connected
                connection.connectedAt = .now
                try? context.save()
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func disconnectEbay() {
        EbayAccountLinker(client: AppEnvironment.shared.backendClient).disconnect()
        if let ebay { context.delete(ebay) }
        try? context.save()
    }
}
