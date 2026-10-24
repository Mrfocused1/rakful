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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<CandidateItem> { $0.ownershipRaw == "unconfirmed" })
    private var unconfirmedItems: [CandidateItem]

    /// The launch splash, shown once per cold launch.
    @State private var showsSplash = true
    /// The splash has finished fading out. Until then the screens beneath
    /// aren't reachable, so a tap during the fade can't land on them unseen.
    @State private var isSplashGone = false

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
        .task {
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
    /// launch splash can sit above both.
    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.selectedTab) {
            Tab(value: AppTab.discover) { DiscoverView() } label: { tabLabel("Home", "house", .discover) }
            Tab(value: AppTab.items) { ItemsView() } label: { tabLabel("Wardrobe", "hanger", .items) }
                .badge(unconfirmedItems.filter { !$0.isDemo }.count)
            Tab(value: AppTab.sell) { SellView() } label: { tabLabel("Sell", "tag", .sell) }
            Tab(value: AppTab.activity) { ActivityView() } label: { tabLabel("Activity", "chart.bar", .activity) }
        }
        .minimizingTabBarOnScroll()
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

    /// Line icons, filled only for the selected tab.
    private func tabLabel(_ title: String, _ systemImage: String, _ tab: AppTab) -> some View {
        Label(title, systemImage: systemImage)
            .environment(\.symbolVariants, router.selectedTab == tab ? .fill : .none)
    }

    private func replayOnboardingIfRequested() {
        guard router.replaysOnboardingAfterSettings else { return }
        router.replaysOnboardingAfterSettings = false
        preferences.hasCompletedOnboarding = false
    }
}
