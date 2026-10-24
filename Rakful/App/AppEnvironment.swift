import Foundation
import Observation
import SwiftData

/// Composition root. Services are created once and injected into SwiftUI
/// through the environment; tests construct their own instances.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let modelContainer: ModelContainer
    let preferences: PreferencesStore
    let photoSource: PhotoAssetSource
    let photoState: PhotoLibraryState
    let device: DeviceConditionMonitor
    let entitlements: EntitlementService
    let notifications: NotificationService
    let discovery: DiscoveryCoordinator
    let background: BackgroundDiscoveryManager
    let backend: BackendConfiguration
    let router = AppRouter()

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        let inMemory = Self.isRunningTests
        do {
            modelContainer = try PersistenceController.makeContainer(inMemory: inMemory)
        } catch {
            // A corrupt store must not brick the app; fall back to memory and surface it.
            modelContainer = try! PersistenceController.makeContainer(inMemory: true)
        }
        preferences = PreferencesStore(defaults: inMemory ? UserDefaults(suiteName: "RakfulTests") ?? .standard : .standard)
        photoSource = PhotoKitAssetSource()
        photoState = PhotoLibraryState(source: photoSource, preferences: preferences)
        device = DeviceConditionMonitor()
        entitlements = EntitlementService()
        notifications = NotificationService(preferences: preferences)
        backend = .fromBundle()
        discovery = DiscoveryCoordinator(
            container: modelContainer,
            source: photoSource,
            analyzer: VisionPhotoAnalyzer(),
            identifier: OnDeviceProductIdentifier(),
            preferences: preferences,
            entitlements: entitlements,
            device: device,
            photoState: photoState
        )
        background = BackgroundDiscoveryManager(
            coordinator: discovery,
            preferences: preferences,
            entitlements: entitlements,
            device: device,
            photoState: photoState,
            notifications: notifications
        )
    }

    var backendClient: BackendClient { BackendClient(configuration: backend) }

    /// Work done once per launch (foreground or background).
    func launch() {
        device.start()
        entitlements.start()
        photoState.refresh()
        let retention = preferences.retention.rawValue
        Task {
            let store = await discovery.store()
            try? await store.pruneHistory(retentionDays: retention)
        }
    }
}

/// Home, Wardrobe, Sell and Activity. Settings opens from Home's header.
enum AppTab: Hashable {
    case discover, items, sell, activity
}

/// Cross-tab navigation (e.g. "Review items" from a report).
@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .discover
    var isReviewQueuePresented = false
    var isPlansPresented = false
    var isSettingsPresented = false
    /// Set by Settings' "Show Welcome Screens"; onboarding opens once the sheet closes.
    var replaysOnboardingAfterSettings = false
    var itemsPath: [UUID] = []
    var sellPath: [UUID] = []

    func showItem(_ id: UUID) {
        selectedTab = .items
        itemsPath = [id]
    }

    func showDraft(_ id: UUID) {
        selectedTab = .sell
        sellPath = [id]
    }
}
