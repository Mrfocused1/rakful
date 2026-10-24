import Foundation
import SwiftData

/// The result of analysing one photo, ready to persist.
struct AnalyzedPhoto: Sendable {
    enum Outcome: Sendable {
        case analyzed(PhotoAnalysis, [IdentificationSuggestion])
        case iCloudOnly
        case notFound
        case failed(String)
        /// Interrupted before finishing; not persisted, so it's retried later.
        case cancelled
    }

    let descriptor: PhotoAssetDescriptor
    let outcome: Outcome
}

struct BatchCommitSummary: Sendable, Equatable {
    var analyzed = 0
    var skipped = 0
    var inICloud = 0
    var failed = 0
    var newCandidates = 0
    var matchedToExisting = 0

    /// Photos that were checkpointed (won't be re-queued in this run).
    var processed: Int { analyzed + skipped + inICloud + failed }
}

/// Snapshot of device state recorded with background executions.
struct DeviceConditions: Sendable, Equatable {
    var isCharging: Bool?
    var isLowPowerMode: Bool
    var thermalState: String
}

/// Background-context persistence for discovery. All writes made during a
/// scan go through this actor so the UI's main context stays responsive; the
/// main context's `@Query`s pick up saves automatically.
@ModelActor
actor DiscoveryStore {
    private var candidateIndex: [ExistingCandidate] = []
    private var isIndexLoaded = false

    static let maxAttempts = 3

    // MARK: - Queue & checkpoints

    /// Identifiers that don't need analysing again. iCloud-only photos are
    /// retried when network access is allowed; failures are retried a few times.
    func processedIdentifiers(retryICloud: Bool) throws -> Set<String> {
        var descriptor = FetchDescriptor<PhotoReference>()
        descriptor.propertiesToFetch = [\.localIdentifier, \.statusRaw, \.attemptCount]
        let references = try modelContext.fetch(descriptor)
        var result = Set<String>()
        result.reserveCapacity(references.count)
        for reference in references {
            switch reference.status {
            case .analyzed, .skipped:
                result.insert(reference.localIdentifier)
            case .iCloudUnavailable:
                if !retryICloud { result.insert(reference.localIdentifier) }
            case .failed:
                if reference.attemptCount >= Self.maxAttempts { result.insert(reference.localIdentifier) }
            }
        }
        return result
    }

    func analyzedPhotoCount() throws -> Int {
        let analyzed = PhotoProcessingStatus.analyzed.rawValue
        return try modelContext.fetchCount(FetchDescriptor<PhotoReference>(predicate: #Predicate { $0.statusRaw == analyzed }))
    }

    /// Photos analysed in the current calendar month, for allowance limits.
    func photosAnalyzedThisMonth(now: Date = .now, calendar: Calendar = .current) throws -> Int {
        guard let start = calendar.dateInterval(of: .month, for: now)?.start else { return 0 }
        let sessions = try modelContext.fetch(FetchDescriptor<DiscoverySession>(predicate: #Predicate { $0.startedAt >= start && $0.isDemo == false }))
        return sessions.reduce(0) { $0 + $1.photosAnalyzed }
    }

    func lastSessionWasInterrupted() throws -> UUID? {
        var descriptor = FetchDescriptor<DiscoverySession>(
            predicate: #Predicate { $0.isDemo == false },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let last = try modelContext.fetch(descriptor).first else { return nil }
        return last.status == .interrupted || last.status == .running ? last.id : nil
    }

    // MARK: - Sessions

    func beginSession(mode: DiscoveryMode, authorizedCount: Int, queuedCount: Int, resumedFrom: UUID?) throws -> UUID {
        // A session left "running" means the app was terminated mid-scan.
        let running = SessionStatus.running.rawValue
        for stale in try modelContext.fetch(FetchDescriptor<DiscoverySession>(predicate: #Predicate { $0.statusRaw == running })) {
            stale.status = .interrupted
            stale.endedAt = stale.endedAt ?? .now
        }

        let session = DiscoverySession(mode: mode, authorizedPhotoCount: authorizedCount, queuedPhotoCount: queuedCount)
        session.resumedFromSessionID = resumedFrom
        modelContext.insert(session)
        if resumedFrom != nil {
            log(.scanResumed, title: "Discovery resumed", detail: "Continuing from the last checkpoint · \(mode.displayName)", count: queuedCount, sessionID: session.id)
        } else {
            log(.discoveryStarted, title: "Discovery started", detail: "\(Formatting.count(queuedCount)) photos to analyse · \(mode.displayName)", count: queuedCount, sessionID: session.id)
        }
        try modelContext.save()
        return session.id
    }

    func finishSession(_ id: UUID, status: SessionStatus, interruption: InterruptionReason?, error: String?, remaining: Int) throws {
        guard let session = try fetchSession(id) else { return }
        session.status = status
        session.endedAt = .now
        session.interruptionRaw = interruption?.rawValue
        session.errorMessage = error

        let found = session.newCandidates == 1 ? "1 potential item found" : "\(session.newCandidates) potential items found"
        switch status {
        case .completed:
            log(.photosAnalyzed, title: "Analysed \(Formatting.count(session.photosAnalyzed)) photos", detail: found, count: session.photosAnalyzed, sessionID: id)
        case .interrupted:
            let reason = interruption?.displayName ?? "Paused"
            log(.scanInterrupted, title: "Discovery paused", detail: "\(reason) · \(Formatting.count(remaining)) photos remain · \(found)", count: session.photosAnalyzed, sessionID: id)
        case .failed:
            log(.scanInterrupted, title: "Discovery couldn't finish", detail: error ?? "An error occurred", sessionID: id)
        case .running:
            break
        }
        try modelContext.save()
    }

    // MARK: - Committing results

    /// Persists a batch: checkpoints every photo, groups candidate photos into
    /// items (existing or new), and records suggestions. One save per batch.
    func commit(_ photos: [AnalyzedPhoto], sessionID: UUID, grouper: CandidateGrouper) throws -> BatchCommitSummary {
        try loadIndexIfNeeded()
        var summary = BatchCommitSummary()

        let ids = photos.map(\.descriptor.localIdentifier)
        let existingReferences = try modelContext.fetch(FetchDescriptor<PhotoReference>(predicate: #Predicate { ids.contains($0.localIdentifier) }))
        var references = Dictionary(existingReferences.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

        func checkpoint(_ descriptor: PhotoAssetDescriptor, _ status: PhotoProcessingStatus, detail: String? = nil, label: ClassifiedLabel? = nil, category: ResaleCategory? = nil) {
            let reference: PhotoReference
            if let existing = references[descriptor.localIdentifier] {
                reference = existing
                reference.attemptCount += 1
                reference.processedAt = .now
                reference.status = status
                reference.detail = detail
                reference.sessionID = sessionID
            } else {
                reference = PhotoReference(localIdentifier: descriptor.localIdentifier, creationDate: descriptor.creationDate, status: status, detail: detail, sessionID: sessionID)
                modelContext.insert(reference)
                references[descriptor.localIdentifier] = reference
            }
            reference.topLabel = label?.identifier
            reference.topLabelConfidence = label?.confidence
            reference.categoryRaw = category?.rawValue
        }

        var observations: [CandidateObservation] = []
        var payloads: [(descriptor: PhotoAssetDescriptor, match: CategoryMatch, analysis: PhotoAnalysis, suggestions: [IdentificationSuggestion])] = []

        for photo in photos {
            switch photo.outcome {
            case .cancelled:
                continue
            case .analyzed(let analysis, let suggestions):
                checkpoint(photo.descriptor, .analyzed, label: analysis.labels.first, category: analysis.match?.category)
                summary.analyzed += 1
                if let match = analysis.match {
                    observations.append(CandidateObservation(photoID: photo.descriptor.localIdentifier, category: match.category, vector: analysis.featureVector, date: photo.descriptor.creationDate))
                    payloads.append((photo.descriptor, match, analysis, suggestions))
                }
            case .iCloudOnly:
                checkpoint(photo.descriptor, .iCloudUnavailable, detail: "Stored in iCloud")
                summary.inICloud += 1
            case .notFound:
                checkpoint(photo.descriptor, .skipped, detail: "No longer in the photo library")
                summary.skipped += 1
            case .failed(let message):
                checkpoint(photo.descriptor, .failed, detail: message)
                summary.failed += 1
            }
        }

        let assignments = grouper.assign(observations, existing: candidateIndex)
        var newItems: [Int: CandidateItem] = [:]
        var touchedExisting: [UUID: CandidateItem] = [:]

        for (index, assignment) in assignments.enumerated() {
            let payload = payloads[index]
            let photo = ItemPhoto(
                assetLocalIdentifier: payload.descriptor.localIdentifier,
                source: .library,
                capturedAt: payload.descriptor.creationDate,
                isDuplicate: assignment.isDuplicate,
                featurePrint: payload.analysis.featureVector?.data,
                showsPerson: payload.analysis.showsPerson
            )

            let item: CandidateItem
            switch assignment {
            case .existing(let id, _):
                guard let existing = try touchedExisting[id] ?? fetchItem(id) else { continue }
                touchedExisting[id] = existing
                item = existing
                item.confidence = max(item.confidence, payload.match.score)
                item.updatedAt = .now
                summary.matchedToExisting += 1
                updateIndex(id: id, vector: assignment.isDuplicate ? nil : payload.analysis.featureVector, date: payload.descriptor.creationDate)
            case .new(let group, _):
                if let created = newItems[group] {
                    item = created
                    item.confidence = max(item.confidence, payload.match.score)
                } else {
                    item = CandidateItem(
                        category: payload.match.category,
                        suggestedName: payload.match.suggestedName,
                        classifierLabel: payload.match.label,
                        confidence: payload.match.score,
                        discoveredInSessionID: sessionID
                    )
                    modelContext.insert(item)
                    newItems[group] = item
                    summary.newCandidates += 1
                    photo.isPrimary = true
                }
            }

            photo.sortIndex = item.photos.count
            item.photos.append(photo)
            addSuggestions(payload.suggestions, to: item)
        }

        for item in newItems.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            log(.candidateIdentified, title: "Possible \(item.suggestedName.lowercased()) found",
                detail: "\(item.category.displayName) · \(item.confidenceLevel.displayName)", sessionID: sessionID, itemID: item.id)
            candidateIndex.append(ExistingCandidate(
                id: item.id,
                category: item.category,
                vectors: item.photos.filter { !$0.isDuplicate }.compactMap { $0.featurePrint.flatMap(FeatureVector.init(data:)) },
                dates: item.photos.compactMap(\.capturedAt)
            ))
        }

        if let session = try fetchSession(sessionID) {
            session.photosAnalyzed += summary.analyzed
            session.photosSkipped += summary.skipped
            session.photosInICloud += summary.inICloud
            session.photosFailed += summary.failed
            session.newCandidates += summary.newCandidates
            session.photosMatchedToExisting += summary.matchedToExisting
        }

        try modelContext.save()
        return summary
    }

    // MARK: - Background task diagnostics

    func recordBackgroundRequest(outcome: BackgroundTaskOutcome, requiresExternalPower: Bool, note: String?) throws {
        let record = BackgroundTaskRecord(kind: .request, outcome: outcome)
        record.requiresExternalPower = requiresExternalPower
        record.note = note
        modelContext.insert(record)
        try modelContext.save()
    }

    func beginBackgroundExecution(simulated: Bool, conditions: DeviceConditions, requiresExternalPower: Bool) throws -> UUID {
        let record = BackgroundTaskRecord(kind: simulated ? .simulatedExecution : .execution, outcome: .running)
        record.startedAt = .now
        record.wasCharging = conditions.isCharging
        record.lowPowerMode = conditions.isLowPowerMode
        record.thermalStateRaw = conditions.thermalState
        record.requiresExternalPower = requiresExternalPower
        modelContext.insert(record)
        try modelContext.save()
        return record.id
    }

    func endBackgroundExecution(_ id: UUID, outcome: BackgroundTaskOutcome, photosProcessed: Int, remaining: Int?, expirationReceived: Bool, resumedFromCheckpoint: Bool, sessionID: UUID?, note: String?) throws {
        let records = try modelContext.fetch(FetchDescriptor<BackgroundTaskRecord>(predicate: #Predicate { $0.id == id }))
        guard let record = records.first else { return }
        record.outcome = outcome
        record.endedAt = .now
        record.photosProcessed = photosProcessed
        record.remainingAfter = remaining
        record.expirationReceived = expirationReceived
        record.resumedFromCheckpoint = resumedFromCheckpoint
        record.sessionID = sessionID
        record.note = note
        try modelContext.save()
    }

    // MARK: - Activity & retention

    func logEvent(_ kind: ActivityKind, title: String, detail: String?, count: Int? = nil, sessionID: UUID? = nil) throws {
        log(kind, title: title, detail: detail, count: count, sessionID: sessionID)
        try modelContext.save()
    }

    /// Deletes activity, sessions and background records older than the
    /// retention period. Items and photo checkpoints are kept.
    func pruneHistory(retentionDays: Int, now: Date = .now) throws {
        guard retentionDays > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        try modelContext.delete(model: ActivityEvent.self, where: #Predicate { $0.date < cutoff })
        try modelContext.delete(model: DiscoverySession.self, where: #Predicate { $0.startedAt < cutoff })
        try modelContext.delete(model: BackgroundTaskRecord.self, where: #Predicate { $0.createdAt < cutoff })
        try modelContext.save()
    }

    /// Forces the candidate index to reload (e.g. after items are deleted).
    func invalidateIndex() {
        isIndexLoaded = false
        candidateIndex = []
    }

    // MARK: - Private

    private func log(_ kind: ActivityKind, title: String, detail: String?, count: Int? = nil, sessionID: UUID? = nil, itemID: UUID? = nil) {
        modelContext.insert(ActivityEvent(kind: kind, title: title, detail: detail, count: count, sessionID: sessionID, itemID: itemID))
    }

    private func fetchSession(_ id: UUID) throws -> DiscoverySession? {
        try modelContext.fetch(FetchDescriptor<DiscoverySession>(predicate: #Predicate { $0.id == id })).first
    }

    private func fetchItem(_ id: UUID) throws -> CandidateItem? {
        try modelContext.fetch(FetchDescriptor<CandidateItem>(predicate: #Predicate { $0.id == id })).first
    }

    private func loadIndexIfNeeded() throws {
        guard !isIndexLoaded else { return }
        let items = try modelContext.fetch(FetchDescriptor<CandidateItem>(predicate: #Predicate { $0.isDemo == false }))
        candidateIndex = items.map { item in
            let photos = item.photos.filter { !$0.isDuplicate }
            return ExistingCandidate(
                id: item.id,
                category: item.category,
                vectors: photos.compactMap { $0.featurePrint.flatMap(FeatureVector.init(data:)) }.suffix(8).map { $0 },
                dates: photos.compactMap(\.capturedAt)
            )
        }
        isIndexLoaded = true
    }

    private func updateIndex(id: UUID, vector: FeatureVector?, date: Date?) {
        guard let index = candidateIndex.firstIndex(where: { $0.id == id }) else { return }
        if let vector, candidateIndex[index].vectors.count < 8 { candidateIndex[index].vectors.append(vector) }
        if let date { candidateIndex[index].dates.append(date) }
    }

    private func addSuggestions(_ suggestions: [IdentificationSuggestion], to item: CandidateItem) {
        for suggestion in suggestions {
            // Keep one classifier record per item, and one record per suggested brand.
            let duplicate = item.identifications.contains { existing in
                existing.source == suggestion.source
                    && (suggestion.source == .onDeviceClassifier || existing.brand == suggestion.brand)
            }
            guard !duplicate else { continue }
            let record = ProductIdentification(
                source: suggestion.source,
                category: suggestion.category,
                brand: suggestion.brand,
                model: suggestion.model,
                colour: suggestion.colour,
                confidence: suggestion.confidence,
                evidence: suggestion.evidence
            )
            item.identifications.append(record)
        }
    }
}
