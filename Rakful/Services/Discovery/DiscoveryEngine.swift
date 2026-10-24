import CoreGraphics
import Foundation
import os

struct DiscoveryConfiguration: Sendable {
    var mode: DiscoveryMode
    var enabledCategories: Set<ResaleCategory>
    var includeScreenshots: Bool
    var allowNetworkAccess: Bool
    /// Remaining photos this run may analyse; `nil` = unlimited.
    var photoAllowance: Int?
    var batchSize = 24
    var maxConcurrency = 2
    var analysisDimension: CGFloat = 512
}

struct DiscoveryProgress: Sendable, Equatable {
    var processed: Int
    var total: Int
    var newCandidates: Int

    var fractionCompleted: Double { total > 0 ? Double(processed) / Double(total) : 0 }
}

struct DiscoveryRunResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case completed
        case nothingToDo
        case interrupted(InterruptionReason)
        case permissionDenied
        case allowanceExhausted
        case failed(String)
    }

    var outcome: Outcome
    var mode: DiscoveryMode
    var sessionID: UUID?
    var photosAnalyzed = 0
    var photosSkipped = 0
    var photosInICloud = 0
    var photosFailed = 0
    var newCandidates = 0
    /// Photos still waiting to be analysed after this run.
    var remaining = 0
    var resumedFromCheckpoint = false
    var startedAt: Date
    var endedAt: Date

    var photosProcessed: Int { photosAnalyzed + photosSkipped + photosInICloud + photosFailed }
}

/// Lets a run be stopped from any context (e.g. a BGTask expiration handler)
/// with a reason the engine can report.
final class RunControl: Sendable {
    private let state = OSAllocatedUnfairLock<(task: Task<DiscoveryRunResult, Never>?, reason: InterruptionReason?)>(initialState: (nil, nil))

    func attach(_ task: Task<DiscoveryRunResult, Never>) {
        state.withLock { $0 = (task, nil) }
    }

    func detach() {
        state.withLock { $0 = (nil, nil) }
    }

    func cancel(_ reason: InterruptionReason) {
        let task = state.withLock { state -> Task<DiscoveryRunResult, Never>? in
            if state.reason == nil { state.reason = reason }
            return state.task
        }
        task?.cancel()
    }

    var reason: InterruptionReason? { state.withLock { $0.reason } }

    /// Records a reason decided by the engine itself (e.g. thermal pressure).
    func setReasonIfNeeded(_ reason: InterruptionReason) {
        state.withLock { if $0.reason == nil { $0.reason = reason } }
    }
}

/// The discovery pipeline:
/// authorised photo refs → small renditions → Vision analysis → category
/// mapping → feature prints → grouping & dedup → candidate records →
/// checkpoint per batch. Safe to stop at any time and resume later.
struct DiscoveryEngine: Sendable {
    let source: PhotoAssetSource
    let analyzer: PhotoAnalyzer
    let identifier: ProductIdentifier
    let store: DiscoveryStore
    var grouper = CandidateGrouper()
    var thermalState: @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }

    static let analysisUnavailableMessage = "On-device image analysis isn't available right now, so no photos were analysed. This can happen in Simulator; please try on iPhone."

    func run(_ configuration: DiscoveryConfiguration, control: RunControl, progress: @escaping @Sendable (DiscoveryProgress) -> Void) async -> DiscoveryRunResult {
        let startedAt = Date()
        var result = DiscoveryRunResult(outcome: .completed, mode: configuration.mode, startedAt: startedAt, endedAt: startedAt)
        func finish(_ outcome: DiscoveryRunResult.Outcome) -> DiscoveryRunResult {
            result.outcome = outcome
            result.endedAt = .now
            return result
        }

        guard source.accessLevel().canRead else { return finish(.permissionDenied) }

        let all = source.fetchImageAssets(includeScreenshots: configuration.includeScreenshots)
        let processed: Set<String>
        let resumedFrom: UUID?
        do {
            processed = try await store.processedIdentifiers(retryICloud: configuration.allowNetworkAccess)
            resumedFrom = try await store.lastSessionWasInterrupted()
        } catch {
            return finish(.failed(error.localizedDescription))
        }

        let pendingAll = all.filter { !processed.contains($0.localIdentifier) }
        guard !pendingAll.isEmpty else { return finish(.nothingToDo) }

        var queue = pendingAll
        if let allowance = configuration.photoAllowance {
            guard allowance > 0 else {
                result.remaining = pendingAll.count
                return finish(.allowanceExhausted)
            }
            queue = Array(pendingAll.prefix(allowance))
        }

        guard await analyzer.verifyAvailability() else {
            result.remaining = pendingAll.count
            return finish(.failed(Self.analysisUnavailableMessage))
        }

        let sessionID: UUID
        do {
            sessionID = try await store.beginSession(
                mode: configuration.mode,
                authorizedCount: all.count,
                queuedCount: queue.count,
                resumedFrom: processed.isEmpty ? nil : resumedFrom
            )
        } catch {
            return finish(.failed(error.localizedDescription))
        }
        result.sessionID = sessionID
        result.resumedFromCheckpoint = !processed.isEmpty && resumedFrom != nil

        var touched = 0
        let total = queue.count
        progress(DiscoveryProgress(processed: 0, total: total, newCandidates: 0))

        var failure: String?
        var start = queue.startIndex
        while start < queue.endIndex {
            if Task.isCancelled { break }
            let thermal = thermalState()
            if thermal == .critical {
                control.setReasonIfNeeded(.thermalState)
                break
            }
            let concurrency = thermal == .serious ? 1 : configuration.maxConcurrency
            let end = min(start + configuration.batchSize, queue.endIndex)
            let batch = Array(queue[start..<end])
            start = end

            let baseline = touched
            let newSoFar = result.newCandidates
            let analyzed = await analyze(batch, configuration: configuration, concurrency: concurrency) { completedInBatch in
                progress(DiscoveryProgress(processed: baseline + completedInBatch, total: total, newCandidates: newSoFar))
            }

            do {
                let summary = try await store.commit(analyzed, sessionID: sessionID, grouper: grouper)
                result.photosAnalyzed += summary.analyzed
                result.photosSkipped += summary.skipped
                result.photosInICloud += summary.inICloud
                result.photosFailed += summary.failed
                result.newCandidates += summary.newCandidates
                touched += summary.processed
            } catch {
                failure = error.localizedDescription
                break
            }
            progress(DiscoveryProgress(processed: touched, total: total, newCandidates: result.newCandidates))
        }

        result.remaining = max(0, pendingAll.count - touched)

        let outcome: DiscoveryRunResult.Outcome
        let status: SessionStatus
        var interruption: InterruptionReason?
        if let failure {
            outcome = .failed(failure)
            status = .failed
        } else if Task.isCancelled || control.reason != nil || touched < queue.count {
            let reason = control.reason ?? .cancelledByUser
            interruption = reason
            outcome = .interrupted(reason)
            status = .interrupted
        } else {
            outcome = .completed
            status = .completed
        }

        try? await store.finishSession(sessionID, status: status, interruption: interruption, error: failure, remaining: result.remaining)
        return finish(outcome)
    }

    /// Analyses a batch with bounded concurrency. Photos not finished when the
    /// task is cancelled come back as `.cancelled` and are not checkpointed.
    private func analyze(_ batch: [PhotoAssetDescriptor], configuration: DiscoveryConfiguration, concurrency: Int, onProgress: @escaping @Sendable (Int) -> Void) async -> [AnalyzedPhoto] {
        await withTaskGroup(of: AnalyzedPhoto.self, returning: [AnalyzedPhoto].self) { group in
            var iterator = batch.makeIterator()
            var results: [AnalyzedPhoto] = []
            results.reserveCapacity(batch.count)

            for _ in 0..<max(1, concurrency) {
                guard let next = iterator.next() else { break }
                group.addTask { await analyzeOne(next, configuration: configuration) }
            }
            for await analyzed in group {
                results.append(analyzed)
                onProgress(results.count)
                if let next = iterator.next() {
                    if Task.isCancelled {
                        results.append(AnalyzedPhoto(descriptor: next, outcome: .cancelled))
                    } else {
                        group.addTask { await analyzeOne(next, configuration: configuration) }
                    }
                }
            }
            return results
        }
    }

    private func analyzeOne(_ descriptor: PhotoAssetDescriptor, configuration: DiscoveryConfiguration) async -> AnalyzedPhoto {
        guard !Task.isCancelled else { return AnalyzedPhoto(descriptor: descriptor, outcome: .cancelled) }
        do {
            let image = try await source.loadAnalysisImage(
                for: descriptor.localIdentifier,
                maxDimension: configuration.analysisDimension,
                allowNetworkAccess: configuration.allowNetworkAccess
            )
            let analysis = try await analyzer.analyze(image, enabledCategories: configuration.enabledCategories)
            try Task.checkCancellation()
            let suggestions = await identifier.identify(analysis)
            return AnalyzedPhoto(descriptor: descriptor, outcome: .analyzed(analysis, suggestions))
        } catch {
            if Task.isCancelled { return AnalyzedPhoto(descriptor: descriptor, outcome: .cancelled) }
            switch error as? PhotoLoadError {
            case .iCloudOnly: return AnalyzedPhoto(descriptor: descriptor, outcome: .iCloudOnly)
            case .assetNotFound: return AnalyzedPhoto(descriptor: descriptor, outcome: .notFound)
            case .cancelled: return AnalyzedPhoto(descriptor: descriptor, outcome: .cancelled)
            case .unavailable(let message): return AnalyzedPhoto(descriptor: descriptor, outcome: .failed(message))
            case nil: return AnalyzedPhoto(descriptor: descriptor, outcome: .failed(error.localizedDescription))
            }
        }
    }
}
