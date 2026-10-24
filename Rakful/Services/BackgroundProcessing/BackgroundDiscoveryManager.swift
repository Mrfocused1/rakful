import BackgroundTasks
import Foundation
import Observation
import os

/// A background task the manager can drive. Wraps `BGProcessingTask` so the
/// same handler can be exercised by tests and the diagnostics simulator.
protocol BackgroundTaskHandle: AnyObject, Sendable {
    var isSimulated: Bool { get }
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    func setTaskCompleted(success: Bool)
}

final class SystemBackgroundTask: BackgroundTaskHandle, @unchecked Sendable {
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }
    var isSimulated: Bool { false }
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) { task.expirationHandler = handler }
    func setTaskCompleted(success: Bool) { task.setTaskCompleted(success: success) }
}

/// Simulates a system launch for on-device diagnostics, optionally expiring
/// after a delay exactly like iOS would.
final class SimulatedBackgroundTask: BackgroundTaskHandle, Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private let completion = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    var isSimulated: Bool { true }
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) { self.handler.withLock { $0 = handler } }
    func setTaskCompleted(success: Bool) { completion.withLock { $0 = success } }
    func expire() { handler.withLock { $0 }?() }
    var completedSuccessfully: Bool? { completion.withLock { $0 } }
}

/// Charge & Discover. Uses only `BGProcessingTask`: iOS decides when (and
/// whether) to run it — typically while the iPhone is idle and, when
/// requested, connected to power. Work is done in small checkpointed
/// batches, so any amount of granted time makes progress, expiration loses
/// nothing, and the next run resumes where this one stopped.
@MainActor
@Observable
final class BackgroundDiscoveryManager {
    static let taskIdentifier = "com.rackful.app.discovery"

    private(set) var pendingRequestCount = 0
    private(set) var lastScheduleError: String?

    private let coordinator: DiscoveryCoordinator
    private let preferences: PreferencesStore
    private let entitlements: EntitlementService
    private let device: DeviceConditionMonitor
    private let photoState: PhotoLibraryState
    private let notifications: NotificationService

    init(coordinator: DiscoveryCoordinator, preferences: PreferencesStore, entitlements: EntitlementService, device: DeviceConditionMonitor, photoState: PhotoLibraryState, notifications: NotificationService) {
        self.coordinator = coordinator
        self.preferences = preferences
        self.entitlements = entitlements
        self.device = device
        self.photoState = photoState
        self.notifications = notifications
    }

    var isEnabled: Bool { preferences.chargeAndDiscoverEnabled && entitlements.limits.chargeAndDiscover }

    /// Must be called before the app finishes launching.
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            let handle = SystemBackgroundTask(task)
            Task { @MainActor in
                guard let self else { handle.setTaskCompleted(success: false); return }
                await self.handle(handle)
            }
        }
    }

    /// Submits a processing request if Charge & Discover is on and there's
    /// work left. Re-submitting replaces any earlier request.
    func scheduleIfEligible() async {
        guard isEnabled, photoState.accessLevel.canRead else {
            cancelScheduled()
            return
        }
        let pending = await coordinator.pendingPhotoCount()
        guard pending > 0 else {
            cancelScheduled()
            return
        }
        let alreadyPending = await BGTaskScheduler.shared.pendingTaskRequests().contains { $0.identifier == Self.taskIdentifier }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = preferences.requireExternalPower
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        let store = await coordinator.store()
        do {
            try BGTaskScheduler.shared.submit(request)
            lastScheduleError = nil
            if !alreadyPending {
                try? await store.recordBackgroundRequest(outcome: .requested, requiresExternalPower: request.requiresExternalPower, note: "\(Formatting.count(pending)) photos waiting")
            }
        } catch {
            let message = Self.describe(error)
            lastScheduleError = message
            try? await store.recordBackgroundRequest(outcome: .failed, requiresExternalPower: request.requiresExternalPower, note: message)
        }
        await refreshPendingRequests()
    }

    func cancelScheduled() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        pendingRequestCount = 0
    }

    func refreshPendingRequests() async {
        pendingRequestCount = await BGTaskScheduler.shared.pendingTaskRequests().filter { $0.identifier == Self.taskIdentifier }.count
    }

    /// Runs the same handler iOS invokes, for diagnostics on a real device or
    /// in Simulator (where `BGTaskScheduler` never launches tasks).
    func simulateLaunch(expireAfter seconds: Double?) async {
        let task = SimulatedBackgroundTask()
        if let seconds {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                task.expire()
            }
        }
        await handle(task)
    }

    // MARK: - Handler

    func handle(_ handle: BackgroundTaskHandle) async {
        let store = await coordinator.store()
        let conditions = device.snapshot()
        let recordID = try? await store.beginBackgroundExecution(simulated: handle.isSimulated, conditions: conditions, requiresExternalPower: preferences.requireExternalPower)

        let expired = OSAllocatedUnfairLock(initialState: false)
        let control = coordinator.control
        handle.setExpirationHandler {
            expired.withLock { $0 = true }
            control.cancel(.systemExpiration)
        }

        func end(_ outcome: BackgroundTaskOutcome, result: DiscoveryRunResult? = nil, note: String?) async {
            if let recordID {
                try? await store.endBackgroundExecution(
                    recordID,
                    outcome: outcome,
                    photosProcessed: result?.photosProcessed ?? 0,
                    remaining: result?.remaining,
                    expirationReceived: expired.withLock { $0 },
                    resumedFromCheckpoint: result?.resumedFromCheckpoint ?? false,
                    sessionID: result?.sessionID,
                    note: note
                )
            }
        }

        guard isEnabled else {
            await end(.skipped, note: "Charge & Discover is off")
            handle.setTaskCompleted(success: true)
            return
        }
        if preferences.pauseInLowPowerMode, conditions.isLowPowerMode {
            await end(.skipped, note: "Low Power Mode is on")
            handle.setTaskCompleted(success: true)
            await scheduleIfEligible()
            return
        }
        guard let result = await coordinator.start(mode: .chargeAndDiscover, canPromptForAccess: false) else {
            await end(.skipped, note: "A discovery was already running")
            handle.setTaskCompleted(success: true)
            return
        }

        let outcome: BackgroundTaskOutcome
        var note: String?
        switch result.outcome {
        case .completed:
            outcome = .completed
        case .nothingToDo:
            outcome = .completed
            note = "Nothing new to analyse"
        case .interrupted(let reason):
            outcome = reason == .systemExpiration ? .expired : .completed
            note = reason.displayName
        case .permissionDenied:
            outcome = .failed
            note = "Photo access is off"
        case .allowanceExhausted:
            outcome = .skipped
            note = "Monthly photo allowance reached"
        case .failed(let message):
            outcome = .failed
            note = message
        }
        await end(outcome, result: result, note: note)

        if result.photosProcessed > 0 {
            let found = result.newCandidates == 1 ? "1 potential item" : "\(result.newCandidates) potential items"
            try? await store.logEvent(
                .backgroundTaskCompleted,
                title: outcome == .expired ? "Background discovery paused by iOS" : "Background discovery finished",
                detail: "\(Formatting.count(result.photosAnalyzed)) photos analysed · \(found)",
                count: result.photosAnalyzed,
                sessionID: result.sessionID
            )
            if outcome == .completed, !handle.isSimulated {
                await notifications.discoveryFinished(result)
            }
        }

        if result.remaining > 0, result.outcome != .allowanceExhausted { await scheduleIfEligible() }
        handle.setTaskCompleted(success: outcome != .failed)
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? BGTaskScheduler.Error else { return error.localizedDescription }
        switch error.code {
        case .unavailable: return "Background tasks are unavailable (Simulator, or Background App Refresh is off)."
        case .tooManyPendingTaskRequests: return "Too many pending background requests."
        case .notPermitted: return "This background task isn't permitted by the app configuration."
        default: return error.localizedDescription
        }
    }
}
