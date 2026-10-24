import Foundation
import Observation
import SwiftData
import UIKit

/// Main-actor façade over the discovery engine: owns run state for the UI,
/// enforces a single active run, applies preferences and entitlements, and
/// protects manual runs when the app moves to the background.
@MainActor
@Observable
final class DiscoveryCoordinator {
    enum Phase: Equatable {
        case idle
        case preparing
        case analyzing
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: DiscoveryProgress?
    private(set) var activeMode: DiscoveryMode?
    private(set) var lastResult: DiscoveryRunResult?

    var isRunning: Bool { phase != .idle }

    /// Thread-safe handle for stopping the current run from any context.
    nonisolated let control = RunControl()

    private let container: ModelContainer
    private let source: PhotoAssetSource
    private let analyzer: PhotoAnalyzer
    private let identifier: ProductIdentifier
    private let preferences: PreferencesStore
    private let entitlements: EntitlementService
    private let device: DeviceConditionMonitor
    private let photoState: PhotoLibraryState
    private var cachedStore: DiscoveryStore?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(
        container: ModelContainer,
        source: PhotoAssetSource,
        analyzer: PhotoAnalyzer,
        identifier: ProductIdentifier,
        preferences: PreferencesStore,
        entitlements: EntitlementService,
        device: DeviceConditionMonitor,
        photoState: PhotoLibraryState
    ) {
        self.container = container
        self.source = source
        self.analyzer = analyzer
        self.identifier = identifier
        self.preferences = preferences
        self.entitlements = entitlements
        self.device = device
        self.photoState = photoState
    }

    /// The background persistence actor. Created off the main thread so its
    /// model context doesn't run on the main queue.
    func store() async -> DiscoveryStore {
        if let cachedStore { return cachedStore }
        let container = container
        let store = await Task.detached(priority: .utility) { DiscoveryStore(modelContainer: container) }.value
        cachedStore = store
        return store
    }

    /// Whether network downloads of iCloud photos are permitted right now.
    var allowsNetworkAccess: Bool {
        preferences.allowICloudDownloads && (!preferences.wifiOnlyForICloud || device.isOnWiFi)
    }

    /// Starts a discovery run. Returns `nil` if a run is already active.
    @discardableResult
    func start(mode: DiscoveryMode, canPromptForAccess: Bool) async -> DiscoveryRunResult? {
        guard !isRunning else { return nil }
        phase = .preparing
        activeMode = mode
        let startedAt = Date()

        var access = photoState.accessLevel
        if access == .notDetermined, canPromptForAccess {
            access = await photoState.requestAccess()
        }
        guard access.canRead else {
            return finish(DiscoveryRunResult(outcome: .permissionDenied, mode: mode, startedAt: startedAt, endedAt: .now))
        }

        let store = await store()
        let used = (try? await store.photosAnalyzedThisMonth()) ?? 0
        let configuration = DiscoveryConfiguration(
            mode: mode,
            enabledCategories: preferences.enabledCategories,
            includeScreenshots: preferences.includeScreenshots,
            allowNetworkAccess: allowsNetworkAccess,
            photoAllowance: entitlements.limits.remainingPhotoAllowance(usedThisMonth: used),
            maxConcurrency: mode == .manual ? 2 : 1
        )
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: identifier, store: store)
        let control = control

        phase = .analyzing
        let task = Task.detached(priority: mode == .manual ? .userInitiated : .utility) { [weak self] in
            await engine.run(configuration, control: control) { progress in
                Task { @MainActor in self?.progress = progress }
            }
        }
        control.attach(task)
        let result = await task.value
        control.detach()
        photoState.refresh()
        return finish(result)
    }

    func stop() {
        control.cancel(.cancelledByUser)
    }

    /// Photos not yet analysed (approximate; used for scheduling decisions).
    func pendingPhotoCount() async -> Int {
        guard photoState.accessLevel.canRead else { return 0 }
        let store = await store()
        let source = source
        let includeScreenshots = preferences.includeScreenshots
        let retry = allowsNetworkAccess
        let processed = (try? await store.processedIdentifiers(retryICloud: retry)) ?? []
        return await Task.detached(priority: .utility) {
            source.fetchImageAssets(includeScreenshots: includeScreenshots).count { !processed.contains($0.localIdentifier) }
        }.value
    }

    func photosAnalyzedThisMonth() async -> Int {
        (try? await store().photosAnalyzedThisMonth()) ?? 0
    }

    // MARK: - App lifecycle

    /// Gives an in-progress manual run a short window to reach a checkpoint
    /// when the app is backgrounded. iOS decides how long that window is.
    func appDidEnterBackground() {
        guard isRunning, activeMode == .manual, backgroundTaskID == .invalid else { return }
        let control = control
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Discovery checkpoint") { [weak self] in
            control.cancel(.appBackgrounded)
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    func appWillEnterForeground() {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func finish(_ result: DiscoveryRunResult) -> DiscoveryRunResult {
        lastResult = result
        phase = .idle
        progress = nil
        activeMode = nil
        endBackgroundTask()
        return result
    }
}
