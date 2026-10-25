import Foundation
import SwiftData
import Testing
@testable import Rakful

/// A small library: two photos of the same trainers taken together, a
/// camera, a duplicate of the camera, a landscape and a screenshot.
private func makeLibrary() -> (MockPhotoSource, MockAnalyzer) {
    let assets = [
        Fixtures.descriptor("shoe-1", minutesAgo: 2),
        Fixtures.descriptor("shoe-2", minutesAgo: 0),
        Fixtures.descriptor("camera", minutesAgo: 600),
        Fixtures.descriptor("camera-copy", minutesAgo: 599),
        Fixtures.descriptor("landscape", minutesAgo: 900),
        Fixtures.descriptor("screenshot", minutesAgo: 1, screenshot: true),
    ]
    let shoe = Fixtures.vector(axis: 0), camera = Fixtures.vector(axis: 5)
    let analyzer = MockAnalyzer(results: [
        "shoe-1": Fixtures.analysis(.trainers, label: "sneaker", name: "Trainers", vector: shoe, text: ["NIKE"]),
        "shoe-2": Fixtures.analysis(.trainers, label: "sneaker", name: "Trainers", vector: Fixtures.vector(axis: 0, wobble: 0.43)),
        "camera": Fixtures.analysis(.cameras, label: "camera", name: "Camera", vector: camera),
        "camera-copy": Fixtures.analysis(.cameras, label: "camera", name: "Camera", vector: camera),
        "landscape": PhotoAnalysis(labels: [ClassifiedLabel(identifier: "waterfall", confidence: 0.9)], match: nil, featureVector: nil, salientRegion: nil, recognisedText: []),
    ])
    return (MockPhotoSource(assets: assets), analyzer)
}

@MainActor
private func fetchItems(_ container: ModelContainer) throws -> [CandidateItem] {
    try ModelContext(container).fetch(FetchDescriptor<CandidateItem>(sortBy: [SortDescriptor(\.createdAt)]))
}

@Suite("Discovery pipeline & persistence", .serialized)
@MainActor
struct DiscoveryPipelineTests {
    @Test func discoversGroupsAndDeduplicates() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)
        let progress = ProgressRecorder()

        let result = await engine.run(Fixtures.configuration(), control: RunControl()) { progress.record($0) }

        #expect(result.outcome == .completed)
        #expect(result.photosAnalyzed == 5, "Screenshot excluded by default")
        #expect(result.newCandidates == 2)
        #expect(result.remaining == 0)
        #expect(progress.all.last?.processed == 5)

        let items = try fetchItems(container)
        let trainers = try #require(items.first { $0.category == .trainers })
        let camera = try #require(items.first { $0.category == .cameras })
        #expect(trainers.photos.count == 2)
        #expect(trainers.ownership == .unconfirmed, "Never assume ownership")
        #expect(trainers.brand == nil, "Brand suggestions are never applied automatically")
        #expect(trainers.pendingBrandSuggestion?.brand == "Nike")
        #expect(camera.photos.count == 2)
        #expect(camera.photos.filter(\.isDuplicate).count == 1)
        #expect(camera.distinctPhotos.count == 1)
    }

    @Test func photosOfPeopleIdentifyButNeverList() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        var worn = Fixtures.analysis(.clothing, label: "jacket", name: "Jacket", vector: Fixtures.vector(axis: 2))
        worn.showsPerson = true
        let source = MockPhotoSource(assets: [Fixtures.descriptor("mirror-selfie")])
        let engine = DiscoveryEngine(source: source, analyzer: MockAnalyzer(results: ["mirror-selfie": worn]), identifier: OnDeviceProductIdentifier(), store: store)

        _ = await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }

        let jacket = try #require(try fetchItems(container).first)
        #expect(jacket.photos.first?.showsPerson == true)
        #expect(jacket.isOnlySeenWorn)
        #expect(jacket.listingPhotos.isEmpty)

        // A camera photo isn't listable until it's been checked.
        let front = ItemPhoto(importedFileName: "jacket-front.jpg", source: .camera)
        jacket.photos.append(front)
        #expect(jacket.listingPhotos.isEmpty)
        #expect(jacket.photosAwaitingCheck.count == 1)
        #expect(!jacket.isOnlySeenWorn)
        front.personCheck = .noPersonDetected
        #expect(jacket.listingPhotos.count == 1)
        #expect(jacket.hasPhotosOfPeople)
    }

    @Test func checkpointsPreventReanalysis() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)

        _ = await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }
        let loadsAfterFirstRun = source.loads
        let second = await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }

        #expect(second.outcome == .nothingToDo)
        #expect(source.loads == loadsAfterFirstRun)
        #expect(try await fetchItems(container).count == 2)
    }

    @Test func newPhotosOfAKnownItemJoinIt() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        var extended = analyzer
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)
        _ = await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }

        source.assets.append(Fixtures.descriptor("camera-later", minutesAgo: -60 * 24 * 7))
        extended.results["camera-later"] = Fixtures.analysis(.cameras, label: "camera", name: "Camera", vector: Fixtures.vector(axis: 5, wobble: 0.05))
        let later = DiscoveryEngine(source: source, analyzer: extended, identifier: OnDeviceProductIdentifier(), store: store)
        let result = await later.run(Fixtures.configuration(), control: RunControl()) { _ in }

        #expect(result.newCandidates == 0)
        let items = try fetchItems(container)
        #expect(items.count == 2)
        #expect(items.first { $0.category == .cameras }?.photos.count == 3)
    }

    @Test func interruptedDiscoveryResumesFromCheckpoint() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)
        let control = RunControl()
        // Expire as the second batch starts, after the first batch of 2 is checkpointed.
        source.onLoad = { count in if count == 3 { control.cancel(.systemExpiration) } }

        let task = Task { await engine.run(Fixtures.configuration(batchSize: 2), control: control) { _ in } }
        control.attach(task)
        let first = await task.value
        control.detach()

        // With two photos in flight, one may legitimately finish before the
        // expiration lands; what matters is that completed work is kept.
        #expect(first.outcome == .interrupted(.systemExpiration))
        #expect((2...3).contains(first.photosAnalyzed), "The first batch was checkpointed")
        #expect(first.remaining == 5 - first.photosAnalyzed)

        source.onLoad = nil
        let resumed = await engine.run(Fixtures.configuration(batchSize: 2), control: RunControl()) { _ in }
        #expect(resumed.outcome == .completed)
        #expect(resumed.resumedFromCheckpoint)
        #expect(first.photosAnalyzed + resumed.photosAnalyzed == 5, "Nothing lost or repeated")
        #expect(resumed.remaining == 0)
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<PhotoReference>()) == 5, "Each photo is checkpointed exactly once")
        #expect(try await fetchItems(container).count == 2, "Resuming doesn't create duplicate items")

        let sessions = try context.fetch(FetchDescriptor<DiscoverySession>(sortBy: [SortDescriptor(\.startedAt)]))
        #expect(sessions.map(\.status) == [.interrupted, .completed])
        #expect(sessions.last?.resumedFromSessionID == sessions.first?.id)
    }

    @Test func permissionStatesAreRespected() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)

        for level in [PhotoAccessLevel.denied, .restricted, .notDetermined] {
            source.access = level
            let result = await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }
            #expect(result.outcome == .permissionDenied)
        }
        #expect(source.loads == 0)
    }

    @Test func limitedAccessOnlyAnalysesSelectedPhotos() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (fullLibrary, analyzer) = makeLibrary()
        // With limited access PhotoKit only returns the user's selection.
        let limited = MockPhotoSource(access: .limited, assets: fullLibrary.assets.filter { $0.localIdentifier.hasPrefix("camera") })
        let engine = DiscoveryEngine(source: limited, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)

        let result = await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }
        #expect(result.outcome == .completed)
        #expect(result.photosAnalyzed == 2)
        #expect(try await fetchItems(container).map(\.category) == [.cameras])
    }

    @Test func iCloudPhotosAreRetriedWhenDownloadsAllowed() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        source.iCloudOnly = ["camera"]
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)

        let offline = await engine.run(Fixtures.configuration(network: false), control: RunControl()) { _ in }
        #expect(offline.photosInICloud == 1)
        #expect(await engine.run(Fixtures.configuration(network: false), control: RunControl()) { _ in }.outcome == .nothingToDo)

        let online = await engine.run(Fixtures.configuration(network: true), control: RunControl()) { _ in }
        #expect(online.photosAnalyzed == 1)
    }

    @Test func failedPhotosAreRetriedAFewTimes() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        source.failing = ["landscape"]
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)

        var failures = 0
        for _ in 0..<5 {
            failures += await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }.photosFailed
        }
        #expect(failures == DiscoveryStore.maxAttempts)
    }

    @Test func monthlyAllowanceCapsTheRun() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)

        let capped = await engine.run(Fixtures.configuration(allowance: 3), control: RunControl()) { _ in }
        #expect(capped.photosAnalyzed == 3)
        #expect(capped.remaining == 2)
        let exhausted = await engine.run(Fixtures.configuration(allowance: 0), control: RunControl()) { _ in }
        #expect(exhausted.outcome == .allowanceExhausted)
        #expect(try await store.photosAnalyzedThisMonth() == 3)
    }

    @Test func brokenModelNeverMarksPhotosAnalysed() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        var broken = analyzer
        broken.isAvailable = false
        let engine = DiscoveryEngine(source: source, analyzer: broken, identifier: OnDeviceProductIdentifier(), store: store)

        let result = await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }
        #expect(result.outcome == .failed(DiscoveryEngine.analysisUnavailableMessage))
        #expect(result.remaining == 5)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PhotoReference>()) == 0)

        let healthy = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)
        #expect(await healthy.run(Fixtures.configuration(), control: RunControl()) { _ in }.photosAnalyzed == 5, "Photos remain queued for a working analyser")
    }

    @Test func criticalThermalStatePausesDiscovery() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        var engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)
        engine.thermalState = { .critical }

        let result = await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }
        #expect(result.outcome == .interrupted(.thermalState))
        #expect(source.loads == 0)
    }

    @Test func historyPruningKeepsItems() async throws {
        let container = try Fixtures.makeContainer()
        let store = await Fixtures.makeStore(container)
        let (source, analyzer) = makeLibrary()
        let engine = DiscoveryEngine(source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), store: store)
        _ = await engine.run(Fixtures.configuration(), control: RunControl()) { _ in }

        try await store.pruneHistory(retentionDays: 30, now: Date().addingTimeInterval(86_400 * 60))
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<ActivityEvent>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DiscoverySession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CandidateItem>()) == 2)
    }
}

@Suite("Ownership, drafts & item corrections", .serialized)
@MainActor
struct OwnershipTests {
    @Test func ownershipChangesAreRecorded() throws {
        let container = try Fixtures.makeContainer()
        let context = container.mainContext
        let item = CandidateItem(category: .bags, suggestedName: "Backpack", confidence: 0.8)
        context.insert(item)
        #expect(item.ownership == .unconfirmed)
        #expect(!item.ownership.canPrepareListing)

        item.setOwnership(.unsure)
        item.setOwnership(.owned)
        try context.save()
        #expect(item.ownership.canPrepareListing)
        #expect(item.ownershipHistory.map(\.status).sorted { $0.rawValue < $1.rawValue } == [.owned, .unsure])
    }

    @Test func freeTierDraftLimitIsEnforced() throws {
        let container = try Fixtures.makeContainer()
        let context = container.mainContext
        let preferences = Fixtures.makePreferences()
        let limits = EntitlementLimits.limits(for: .free)
        var drafts: [ListingDraft] = []
        for index in 0..<4 {
            let item = CandidateItem(category: .watches, suggestedName: "Watch \(index)", confidence: 0.9)
            context.insert(item)
            item.setOwnership(.owned)
            if let draft = ItemActions.prepareDraft(for: item, in: context, preferences: preferences, limits: limits) { drafts.append(draft) }
        }
        #expect(drafts.count == 3)
        let unlimited = CandidateItem(category: .watches, suggestedName: "Another", confidence: 0.9)
        context.insert(unlimited)
        unlimited.setOwnership(.owned)
        #expect(ItemActions.prepareDraft(for: unlimited, in: context, preferences: preferences, limits: .limits(for: .plus)) != nil)
    }

    @Test func unconfirmedItemsCannotGetDrafts() throws {
        let container = try Fixtures.makeContainer()
        let context = container.mainContext
        let item = CandidateItem(category: .bags, suggestedName: "Bag", confidence: 0.9)
        context.insert(item)
        for status in [OwnershipStatus.unconfirmed, .unsure, .notOwned] {
            item.setOwnership(status)
            #expect(ItemActions.prepareDraft(for: item, in: context, preferences: Fixtures.makePreferences(), limits: .limits(for: .pro)) == nil)
        }
    }

    @Test func draftPrefillFlagsUnconfirmedBrand() throws {
        let container = try Fixtures.makeContainer()
        let context = container.mainContext
        let item = CandidateItem(category: .trainers, suggestedName: "Trainers", confidence: 0.9)
        context.insert(item)
        item.identifications.append(ProductIdentification(source: .onDeviceText, brand: "Nike", confidence: 0.6, evidence: "Text"))
        item.setOwnership(.owned)
        let draft = try #require(ItemActions.prepareDraft(for: item, in: context, preferences: Fixtures.makePreferences(), limits: .limits(for: .plus)))
        #expect(draft.brand == "Nike")
        #expect(draft.uncertainFields.contains(.brand))
        #expect(item.brand == nil)
        #expect(ItemActions.prepareDraft(for: item, in: context, preferences: Fixtures.makePreferences(), limits: .limits(for: .plus))?.id == draft.id, "Reuses the open draft")
    }

    @Test func separateAndCombineItems() throws {
        let container = try Fixtures.makeContainer()
        let context = container.mainContext
        let item = CandidateItem(category: .electronics, suggestedName: "Laptop", confidence: 0.8)
        context.insert(item)
        item.photos.append(ItemPhoto(assetLocalIdentifier: "a", source: .library, isPrimary: true, sortIndex: 0))
        item.photos.append(ItemPhoto(assetLocalIdentifier: "b", source: .library, sortIndex: 1))
        try context.save()

        let photoB = try #require(item.photos.first { $0.assetLocalIdentifier == "b" })
        let separated = try #require(ItemActions.separate(photoB, from: item, in: context))
        #expect(item.photos.map(\.assetLocalIdentifier) == ["a"])
        #expect(separated.photos.map(\.assetLocalIdentifier) == ["b"])
        #expect(separated.ownership == .unconfirmed)

        item.setOwnership(.owned)
        ItemActions.combine(separated, into: item, in: context)
        let remaining = try context.fetch(FetchDescriptor<CandidateItem>())
        #expect(remaining.count == 1)
        #expect(Set(item.photos.compactMap(\.assetLocalIdentifier)) == ["a", "b"])
        #expect(item.ownership == .owned)
        #expect(try context.fetchCount(FetchDescriptor<ItemPhoto>()) == 2, "Combining must not delete photos")
    }

    @Test func sampleDataIsIsolatedAndRemovable() throws {
        let container = try Fixtures.makeContainer()
        let context = container.mainContext
        let real = CandidateItem(category: .bags, suggestedName: "Bag", confidence: 0.7)
        context.insert(real)
        try SampleData.insert(into: context)
        try SampleData.insert(into: context)

        let all = try context.fetch(FetchDescriptor<CandidateItem>())
        #expect(all.filter(\.isDemo).count == SampleData.specs.count, "Inserting twice doesn't duplicate")
        #expect(all.filter(\.isDemo).allSatisfy { $0.latestEstimate?.isDemo == true }, "Sample values are marked as demo data")

        let total = ValueSummary.compute(estimates: all.filter(\.isDemo).map { $0.latestEstimate?.range }, currencyCode: "GBP")
        #expect(total.range == PriceRange(low: 370, high: 570, currencyCode: "GBP"))

        try SampleData.remove(from: context)
        let left = try context.fetch(FetchDescriptor<CandidateItem>())
        #expect(left.map(\.id) == [real.id])
        #expect(try context.fetchCount(FetchDescriptor<PriceEstimate>()) == 0)
    }

    @Test func eraseAllDataRemovesTheWholeGraph() throws {
        let container = try Fixtures.makeContainer()
        let context = container.mainContext
        try SampleData.insert(into: context)
        let item = CandidateItem(category: .bags, suggestedName: "Bag", confidence: 0.7)
        context.insert(item)
        item.photos.append(ItemPhoto(assetLocalIdentifier: "p", source: .library, isPrimary: true))
        item.identifications.append(ProductIdentification(source: .onDeviceText, brand: "Coach", confidence: 0.6, evidence: "Text"))
        item.setOwnership(.owned)
        context.insert(ListingDraft(item: item, currencyCode: "GBP"))
        context.insert(PhotoReference(localIdentifier: "p", creationDate: nil, status: .analyzed, sessionID: nil))
        context.insert(DiscoverySession(mode: .manual, authorizedPhotoCount: 1, queuedPhotoCount: 1))
        context.insert(BackgroundTaskRecord(kind: .execution, outcome: .completed))
        context.insert(MarketplaceConnection(marketplace: .ebay))
        try context.save()

        let preferences = Fixtures.makePreferences()
        preferences.chargeAndDiscoverEnabled = true
        try DataManagement.eraseAllData(in: context, preferences: preferences)

        #expect(try context.fetch(FetchDescriptor<CandidateItem>()).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ItemPhoto>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ProductIdentification>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<OwnershipConfirmation>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PriceEstimate>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PricingEvidence>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ListingDraft>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PhotoReference>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DiscoverySession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BackgroundTaskRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<MarketplaceConnection>()) == 0)
        #expect(!preferences.chargeAndDiscoverEnabled)
    }

    @Test func deletingHistoryNeverTouchesItems() throws {
        let container = try Fixtures.makeContainer()
        let context = container.mainContext
        context.insert(CandidateItem(category: .bags, suggestedName: "Bag", confidence: 0.7))
        context.insert(PhotoReference(localIdentifier: "x", creationDate: nil, status: .analyzed, sessionID: nil))
        context.insert(ActivityEvent(kind: .discoveryStarted, title: "Started"))
        try context.save()

        try DataManagement.deleteDiscoveryHistory(in: context)
        #expect(try context.fetchCount(FetchDescriptor<PhotoReference>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ActivityEvent>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CandidateItem>()) == 1)
    }
}

@Suite("Charge & Discover background handling", .serialized)
@MainActor
struct BackgroundTaskTests {
    struct Harness {
        let container: ModelContainer
        let source: MockPhotoSource
        let preferences: PreferencesStore
        let entitlements: EntitlementService
        let coordinator: DiscoveryCoordinator
        let manager: BackgroundDiscoveryManager
    }

    func makeHarness(tier: SubscriptionTier = .plus, chargeAndDiscover: Bool = true) throws -> Harness {
        let container = try Fixtures.makeContainer()
        let (source, analyzer) = makeLibrary()
        let preferences = Fixtures.makePreferences()
        preferences.chargeAndDiscoverEnabled = chargeAndDiscover
        let entitlements = EntitlementService()
        entitlements.debugTierOverride = tier
        let device = DeviceConditionMonitor()
        let photoState = PhotoLibraryState(source: source, preferences: preferences, observesLibrary: false)
        let coordinator = DiscoveryCoordinator(container: container, source: source, analyzer: analyzer, identifier: OnDeviceProductIdentifier(), preferences: preferences, entitlements: entitlements, device: device, photoState: photoState)
        let manager = BackgroundDiscoveryManager(coordinator: coordinator, preferences: preferences, entitlements: entitlements, device: device, photoState: photoState, notifications: NotificationService(preferences: preferences))
        return Harness(container: container, source: source, preferences: preferences, entitlements: entitlements, coordinator: coordinator, manager: manager)
    }

    func executions(_ harness: Harness) throws -> [BackgroundTaskRecord] {
        let simulated = BackgroundTaskKind.simulatedExecution.rawValue
        return try ModelContext(harness.container).fetch(FetchDescriptor<BackgroundTaskRecord>(
            predicate: #Predicate { $0.kindRaw == simulated },
            sortBy: [SortDescriptor(\.createdAt)]
        ))
    }

    @Test func completesAndRecordsExecution() async throws {
        let harness = try makeHarness()
        let task = SimulatedBackgroundTask()
        await harness.manager.handle(task)

        #expect(task.completedSuccessfully == true)
        let record = try #require(try executions(harness).last)
        #expect(record.outcome == .completed)
        #expect(record.photosProcessed == 5)
        #expect(record.remainingAfter == 0)
        let sessions = try ModelContext(harness.container).fetch(FetchDescriptor<DiscoverySession>())
        #expect(sessions.first?.mode == .chargeAndDiscover)
    }

    @Test func expirationCheckpointsAndNextRunResumes() async throws {
        let harness = try makeHarness()
        let first = SimulatedBackgroundTask()
        // iOS expires the task while the second photo is being analysed.
        harness.source.onLoad = { count in if count == 2 { first.expire() } }
        await harness.manager.handle(first)

        let expired = try #require(try executions(harness).last)
        #expect(first.completedSuccessfully == true, "Task must still be completed after expiration")
        #expect(expired.outcome == .expired)
        #expect(expired.expirationReceived)
        #expect((expired.remainingAfter ?? 0) > 0)

        harness.source.onLoad = nil
        let second = SimulatedBackgroundTask()
        await harness.manager.handle(second)
        let resumed = try #require(try executions(harness).last)
        #expect(resumed.outcome == .completed)
        #expect(resumed.resumedFromCheckpoint)
        #expect(resumed.remainingAfter == 0)
        #expect(expired.photosProcessed == 1)
        #expect(expired.photosProcessed + resumed.photosProcessed == 5, "Nothing lost or repeated across expiration")
    }

    @Test func skipsWhenNotEntitledOrDisabled() async throws {
        for harness in [try makeHarness(tier: .free), try makeHarness(chargeAndDiscover: false)] {
            let task = SimulatedBackgroundTask()
            await harness.manager.handle(task)
            #expect(task.completedSuccessfully == true)
            #expect(try executions(harness).last?.outcome == .skipped)
            #expect(harness.source.loads == 0)
        }
    }

    @Test func revokedAccessFailsGracefully() async throws {
        let harness = try makeHarness()
        harness.source.access = .denied
        let task = SimulatedBackgroundTask()
        await harness.manager.handle(task)
        #expect(task.completedSuccessfully == false)
        #expect(try executions(harness).last?.outcome == .failed)
        #expect(try executions(harness).last?.note == "Photo access is off")
    }

    @Test func coordinatorAllowsOnlyOneRunAtATime() async throws {
        let harness = try makeHarness()
        async let first = harness.coordinator.start(mode: .manual, canPromptForAccess: false)
        async let second = harness.coordinator.start(mode: .manual, canPromptForAccess: false)
        let results = await [first, second]
        #expect(results.compactMap { $0 }.count == 1)
    }
}
