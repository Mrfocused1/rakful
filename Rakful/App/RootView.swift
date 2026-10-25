import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(AppRouter.self) private var router
    @Environment(DiscoveryCoordinator.self) private var discovery
    @Environment(BackgroundDiscoveryManager.self) private var background
    @Environment(PhotoLibraryState.self) private var photoState
    @Environment(DeviceConditionMonitor.self) private var device
    @Environment(EntitlementService.self) private var entitlements
    @Environment(SaveFailureCenter.self) private var saves
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<CandidateItem> { $0.ownershipRaw == "unconfirmed" })
    private var unconfirmedItems: [CandidateItem]

    /// The launch splash, shown once per cold launch.
    @State private var showsSplash = true
    /// The splash has finished fading out. Until then the screens beneath
    /// aren't reachable, so a tap during the fade can't land on them unseen.
    @State private var isSplashGone = false
    /// The dock steps aside while typing, as the system tab bar would.
    @State private var isKeyboardVisible = false
    /// Shown once per launch when work can't be saved.
    @State private var showsTemporaryStorageAlert = AppEnvironment.shared.storageMode.isTemporary

    var body: some View {
        ZStack {
            Group {
                tabs
                    .accessibilityHidden(!preferences.hasCompletedOnboarding)
                if !preferences.hasCompletedOnboarding {
                    OnboardingView()
                        .transition(.move(edge: .bottom))
                        .zIndex(1)
                }
            }
            .accessibilityHidden(!isSplashGone)
            if showsSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.smooth, value: preferences.hasCompletedOnboarding)
        .safeAreaInset(edge: .top, spacing: 0) {
            if AppEnvironment.shared.storageMode.isTemporary, isSplashGone {
                TemporaryStorageBanner { showsTemporaryStorageAlert = true }
            }
        }
        .saveFailureAlert(saves)
        .alert("Rakful Can't Save Your Work", isPresented: Binding(get: { showsTemporaryStorageAlert && isSplashGone }, set: { showsTemporaryStorageAlert = $0 })) {
            Button("I Understand", role: .cancel) {}
        } message: {
            Text(temporaryStorageMessage)
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-RRHoldSplash") { return }
            #endif
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.4)) {
                showsSplash = false
            } completion: {
                isSplashGone = true
            }
        }
        #if DEBUG
        .task { DebugLaunchOptions.apply(context: context, environment: AppEnvironment.shared) }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                photoState.refresh()
                device.refresh()
                discovery.appWillEnterForeground()
                Task { await entitlements.refresh() }
            case .background:
                discovery.appDidEnterBackground()
                Task { await background.scheduleIfEligible() }
            default:
                break
            }
        }
    }

    /// Onboarding sits above the tabs (not in a full-screen cover) so the
    /// launch splash can sit above both. The system tab bar is hidden; the
    /// floating dock drives the same TabView selection.
    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.discover) { docked(DiscoverView()) }
            Tab("Wardrobe", systemImage: "hanger", value: AppTab.items) { docked(ItemsView()) }
            Tab("Sell", systemImage: "tag", value: AppTab.sell) { docked(SellView()) }
            Tab("Activity", systemImage: "chart.bar", value: AppTab.activity) { docked(ActivityView()) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in isKeyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in isKeyboardVisible = false }
        .sheet(isPresented: $router.isReviewQueuePresented) {
            ReviewQueueView()
        }
        .sheet(isPresented: $router.isSettingsPresented, onDismiss: replayOnboardingIfRequested) {
            SettingsView()
        }
        // While Settings is open it presents Plans itself.
        .sheet(isPresented: Binding(
            get: { router.isPlansPresented && !router.isSettingsPresented },
            set: { router.isPlansPresented = $0 }
        )) {
            PlansView()
        }
    }

    /// Each tab carries the dock as a bottom inset, so its scroll views,
    /// lists and pushed screens all end above it.
    private func docked(_ content: some View) -> some View {
        @Bindable var router = router
        return content
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isKeyboardVisible {
                    FloatingDock(selection: $router.selectedTab, badges: [.items: unconfirmedItems.filter { !$0.isDemo }.count])
                }
            }
    }

    private var temporaryStorageMessage: String {
        guard case .temporary(let reason) = AppEnvironment.shared.storageMode else { return "" }
        return "Rakful couldn't open its saved data (\(reason)). You can look around, but anything you add or change now will be lost when the app closes. Close Rakful completely and open it again. If this keeps happening, free up storage on your iPhone."
    }

    private func replayOnboardingIfRequested() {
        guard router.replaysOnboardingAfterSettings else { return }
        router.replaysOnboardingAfterSettings = false
        preferences.hasCompletedOnboarding = false
    }
}

/// Always visible while Rakful is running without saving.
private struct TemporaryStorageBanner: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label("Not saving: changes will be lost when Rakful closes", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.red)
        }
        .accessibilityHint("Shows details")
    }
}

extension View {
    /// Presents failed saves with a retry. Attach to sheets too, since an
    /// alert can't appear beneath a presented sheet.
    func saveFailureAlert(_ saves: SaveFailureCenter) -> some View {
        alert(
            "Couldn't Save",
            isPresented: Binding(get: { saves.current != nil }, set: { if !$0 { saves.dismiss() } }),
            presenting: saves.current
        ) { _ in
            Button("Try Again") { saves.retry() }
            Button("Not Now", role: .cancel) { saves.dismiss() }
        } message: { failure in
            Text("\(failure.action) didn't work: \(failure.message) Your changes haven't been saved yet. Check your iPhone has free storage, then try again.")
        }
    }
}
