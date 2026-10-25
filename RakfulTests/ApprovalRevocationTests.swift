import Foundation
import SwiftData
import Testing
@testable import Rakful

/// Journal storage whose writes can be made to fail.
final class FlakyRevocationStorage: RevocationStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileRevocationStorage
    private var _failWrites = false
    private var _writes = 0

    init(url: URL) {
        file = FileRevocationStorage(url: url)
    }

    var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }

    var successfulWrites: Int { lock.withLock { _writes } }

    func read() throws -> Data? { try file.read() }

    func write(_ data: Data) throws {
        try lock.withLock {
            if _failWrites { throw TestSaveError() }
            _writes += 1
        }
        try file.write(data)
    }
}

/// A store on disk with its own journal, and the app's "relaunch": a fresh
/// container and journal read only from what's on disk.
@MainActor
struct DiskStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rakful-revocation-\(UUID().uuidString).store")
    var journalURL: URL { ApprovalRevocationJournal.defaultFileURL(forStoreAt: url) }

    /// The first launch, with journal writes that can be made to fail.
    func launch(storage: FlakyRevocationStorage) throws -> ModelContainer {
        ApprovalRevocationJournal.register(ApprovalRevocationJournal(storage: storage), forStoreAt: url)
        return try openContainer()
    }

    /// A later launch: nothing carried over in memory.
    func relaunch() throws -> ModelContainer {
        ApprovalRevocationJournal.register(ApprovalRevocationJournal(storage: FileRevocationStorage(url: journalURL)), forStoreAt: url)
        return try openContainer()
    }

    private func openContainer() throws -> ModelContainer {
        let container = try PersistenceController.makeContainer(url: url)
        // No autosave: the only saves are the ones a test makes.
        container.mainContext.autosaveEnabled = false
        return container
    }

    func journal(_ container: ModelContainer) -> ApprovalRevocationJournal {
        ApprovalRevocationJournal.journal(for: container)
    }

    func draft(_ id: UUID, in container: ModelContainer) throws -> ListingDraft {
        try #require(try container.mainContext.fetch(FetchDescriptor<ListingDraft>(predicate: #Predicate { $0.id == id })).first)
    }

    /// Entries stored on disk right now.
    func storedEntries() -> [ApprovalRevocationJournal.Entry] {
        ApprovalRevocationJournal(storage: FileRevocationStorage(url: journalURL)).entries
    }
}

@MainActor
@Suite("Approval revocation journal")
struct ApprovalRevocationTests {
    func expectBlocked(_ draft: ListingDraft, in context: ModelContext, store: ApprovedPhotoStore, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: ListingExportError.ownershipChanged, sourceLocation: sourceLocation) { try ListingExporter.package(for: draft, store: store) }
        #expect(throws: ListingExportError.ownershipChanged, sourceLocation: sourceLocation) { try ListingExporter.recordHandoff(draft, in: context) }
        #expect(throws: ListingExportError.ownershipChanged, sourceLocation: sourceLocation) { try ListingExporter.confirmListed(draft, url: nil, in: context) }
    }

    func approve(_ draft: ListingDraft, in context: ModelContext, store: ApprovedPhotoStore) async throws -> ListingSnapshot {
        let approval = ListingApproval(store: store, loader: MockListingPhotoLoader())
        let preview = try await approval.prepare(draft)
        return try approval.approve(draft, preview: preview, in: context)
    }

    // MARK: - The real failure

    @Test func aWithdrawalSurvivesAFailedSaveAndARelaunch() async throws {
        let disk = DiskStore()
        let storage = FlakyRevocationStorage(url: disk.journalURL)
        let first = try disk.launch(storage: storage)
        let fixture = try ListingFixture(container: first)

        // 1. A saved approval.
        try await fixture.approve()
        let id = fixture.draft.id

        // 2. Ownership is withdrawn; the journal is written straight away.
        fixture.item.setOwnership(.notOwned)
        #expect(!disk.journal(first).hasUnwrittenRevocations)
        #expect(disk.storedEntries().map(\.draftID) == [id])

        // 3. The database save fails, and the error is reported.
        #expect(throws: TestSaveError.self) { try SaveFailureCenter.save(fixture.context) { throw TestSaveError() } }

        // 4–5. The app closes before any successful save. Reopen only what's on disk.
        let relaunched = try disk.relaunch()
        let context = relaunched.mainContext
        let draft = try disk.draft(id, in: relaunched)
        #expect(draft.status == .approved, "The database never recorded the withdrawal")
        #expect(draft.item?.ownership == .owned)

        // 6. The journal still blocks export, handoff and seller-confirmed publication.
        #expect(draft.isApprovalRevoked)
        #expect(draft.approvalProblem == .ownershipChanged)
        expectBlocked(draft, in: context, store: fixture.store)

        // 7. Restoring ownership doesn't revive the old approval.
        draft.item?.setOwnership(.owned)
        draft.sellerDeclaredOwnership = true
        #expect(!draft.hasCurrentApproval)
        expectBlocked(draft, in: context, store: fixture.store)

        // 8. Startup reconciliation records it in the database and clears the
        // journal; a new, explicit approval exports normally.
        let report = try ApprovalRevocationJournal.reconcile(in: context)
        #expect(report.remainingEntries == 0)
        #expect(disk.storedEntries().isEmpty)
        #expect(draft.status == .draft)
        #expect(draft.approvedSnapshotData == nil)
        #expect(draft.approvalInvalidation == .ownershipChanged)

        let fresh = try await approve(draft, in: context, store: fixture.store)
        #expect(fresh.version == 2)
        #expect(draft.approvalInvalidation == nil)
        #expect(try ListingExporter.package(for: draft, store: fixture.store).version == 2)
        try ListingExporter.recordHandoff(draft, in: context)
        try ListingExporter.confirmListed(draft, url: nil, in: context)
        #expect(draft.status == .listed)
    }

    @Test func reconcilingAtStartupBeforeAnyActionWithdrawsTheApproval() async throws {
        let disk = DiskStore()
        let first = try disk.launch(storage: FlakyRevocationStorage(url: disk.journalURL))
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()
        fixture.item.setOwnership(.unsure)
        // No database save at all.

        let relaunched = try disk.relaunch()
        let report = try ApprovalRevocationJournal.reconcile(in: relaunched.mainContext)
        #expect(report == ApprovalRevocationJournal.ReconcileReport(withdrawn: 1, remainingEntries: 0))

        // Read back from disk once more: the database now records it.
        let again = try disk.relaunch()
        let draft = try disk.draft(fixture.draft.id, in: again)
        #expect(draft.status == .draft)
        #expect(draft.approvedSnapshotData == nil)
        #expect(draft.approvalInvalidation == .ownershipChanged)
        #expect(!draft.isApprovalRevoked)
    }

    @Test func reconciliationIsSafeToRepeat() async throws {
        let disk = DiskStore()
        let first = try disk.launch(storage: FlakyRevocationStorage(url: disk.journalURL))
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()
        fixture.item.setOwnership(.notOwned)

        let relaunched = try disk.relaunch()
        let context = relaunched.mainContext
        // A failed save leaves the entry for next time; the withdrawal still applies now.
        #expect(throws: TestSaveError.self) { try ApprovalRevocationJournal.reconcile(in: context) { throw TestSaveError() } }
        #expect(disk.storedEntries().count == 1)
        #expect(try disk.draft(fixture.draft.id, in: relaunched).status == .draft)

        // Then it succeeds, and repeating changes nothing.
        #expect(try ApprovalRevocationJournal.reconcile(in: context).remainingEntries == 0)
        #expect(try ApprovalRevocationJournal.reconcile(in: context) == ApprovalRevocationJournal.ReconcileReport())
        let third = try disk.relaunch()
        #expect(try ApprovalRevocationJournal.reconcile(in: third.mainContext) == ApprovalRevocationJournal.ReconcileReport())
        #expect(try disk.draft(fixture.draft.id, in: third).status == .draft)
    }

    // MARK: - Coverage

    @Test func everyAffectedDraftOfAnItemIsRecorded() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        let second = ListingDraft(item: fixture.item, currencyCode: "GBP", marketplace: .depop)
        fixture.context.insert(second)
        second.title = "Denim Jacket"
        second.descriptionText = "Denim jacket."
        second.size = "M"
        second.condition = .good
        second.defectsAssessment = .noneFound
        second.askingPrice = 30
        second.sellerDeclaredOwnership = true
        second.selectedPhotoIDs = fixture.item.sortedPhotos.map(\.id)
        _ = try await approve(second, in: fixture.context, store: fixture.store)

        fixture.item.setOwnership(.notOwned)

        let journal = ApprovalRevocationJournal.journal(for: fixture.container)
        #expect(Set(journal.entries.map(\.draftID)) == [fixture.draft.id, second.id])
        for draft in [fixture.draft, second] {
            #expect(draft.status == .draft)
            #expect(draft.approvalInvalidation == .ownershipChanged)
        }
    }

    @Test func withdrawingTheDeclarationIsRecordedToo() async throws {
        let disk = DiskStore()
        let first = try disk.launch(storage: FlakyRevocationStorage(url: disk.journalURL))
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()

        fixture.draft.sellerDeclaredOwnership = false
        #expect(disk.storedEntries().map(\.draftID) == [fixture.draft.id])

        let relaunched = try disk.relaunch()
        let draft = try disk.draft(fixture.draft.id, in: relaunched)
        #expect(draft.sellerDeclaredOwnership, "The database lost the withdrawal")
        expectBlocked(draft, in: relaunched.mainContext, store: fixture.store)
    }

    // MARK: - Storage failures

    @Test func aFailedCleanupLeavesAHarmlessEntry() async throws {
        let disk = DiskStore()
        let storage = FlakyRevocationStorage(url: disk.journalURL)
        let first = try disk.launch(storage: storage)
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()
        fixture.item.setOwnership(.notOwned)

        // The database saves, but removing the entry can't be written.
        storage.failWrites = true
        try SaveFailureCenter.save(fixture.context)
        #expect(disk.storedEntries().count == 1, "The entry stays on disk")
        storage.failWrites = false

        // A new approval isn't affected by the leftover entry.
        fixture.item.setOwnership(.owned)
        let fresh = try await approve(fixture.draft, in: fixture.context, store: fixture.store)
        #expect(fresh.version == 2)
        #expect(try ListingExporter.package(for: fixture.draft, store: fixture.store).version == 2)

        // Next launch removes it and leaves the new approval alone.
        let relaunched = try disk.relaunch()
        #expect(try ApprovalRevocationJournal.reconcile(in: relaunched.mainContext) == ApprovalRevocationJournal.ReconcileReport())
        #expect(disk.storedEntries().isEmpty)
        let draft = try disk.draft(fixture.draft.id, in: relaunched)
        #expect(draft.status == .approved)
        #expect(draft.hasCurrentApproval)
    }

    @Test func aJournalThatCantBeWrittenBlocksTheSessionAndSaysSo() async throws {
        let disk = DiskStore()
        let storage = FlakyRevocationStorage(url: disk.journalURL)
        let first = try disk.launch(storage: storage)
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()

        storage.failWrites = true
        fixture.item.setOwnership(.notOwned)
        let journal = disk.journal(first)
        #expect(journal.hasUnwrittenRevocations)
        #expect(disk.storedEntries().isEmpty)

        // Blocked for the rest of this session.
        expectBlocked(fixture.draft, in: fixture.context, store: fixture.store)

        // When the database save fails too, the error says the change may be
        // lost, and nothing reports success.
        #expect {
            try SaveFailureCenter.save(fixture.context) { throw TestSaveError() }
        } throws: { error in
            (error as? RevocationNotSavedError)?.errorDescription?.contains("may be lost") == true
        }
        let saves = SaveFailureCenter()
        #expect(!saves.attempt("Saving your answer") { try SaveFailureCenter.save(fixture.context) { throw TestSaveError() } })
        #expect(saves.current?.message.contains("may be lost") == true)

        // Documented limitation: with neither written, a relaunch only has
        // the old database, so the withdrawal is lost.
        let relaunched = try disk.relaunch()
        let draft = try disk.draft(fixture.draft.id, in: relaunched)
        #expect(draft.hasCurrentApproval)
    }

    @Test func aJournalWriteCanSucceedOnRetry() async throws {
        let disk = DiskStore()
        let storage = FlakyRevocationStorage(url: disk.journalURL)
        let first = try disk.launch(storage: storage)
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()

        storage.failWrites = true
        fixture.item.setOwnership(.notOwned)
        storage.failWrites = false

        // The next save retries the journal before the database; the database
        // fails, but the withdrawal is now on disk.
        #expect(throws: TestSaveError.self) { try SaveFailureCenter.save(fixture.context) { throw TestSaveError() } }
        #expect(!disk.journal(first).hasUnwrittenRevocations)
        let relaunched = try disk.relaunch()
        expectBlocked(try disk.draft(fixture.draft.id, in: relaunched), in: relaunched.mainContext, store: fixture.store)
    }

    // MARK: - Missing or corrupt recovery data

    @Test func noJournalMeansNothingIsWithdrawn() async throws {
        let disk = DiskStore()
        let first = try disk.launch(storage: FlakyRevocationStorage(url: disk.journalURL))
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()

        #expect(!FileManager.default.fileExists(atPath: disk.journalURL.path))
        let relaunched = try disk.relaunch()
        #expect(!disk.journal(relaunched).isCorrupt)
        #expect(try ApprovalRevocationJournal.reconcile(in: relaunched.mainContext) == ApprovalRevocationJournal.ReconcileReport())
        let draft = try disk.draft(fixture.draft.id, in: relaunched)
        #expect(try ListingExporter.package(for: draft, store: fixture.store).version == 1)
    }

    /// Unreadable data: Rakful can't tell which approvals were withdrawn, so
    /// it withdraws every approval not yet listed, keeps listed records, and
    /// starts a fresh journal once that's saved.
    @Test func aCorruptJournalWithdrawsUnlistedApprovalsOnly() async throws {
        let disk = DiskStore()
        let first = try disk.launch(storage: FlakyRevocationStorage(url: disk.journalURL))
        let approved = try ListingFixture(container: first)
        try await approved.approve()
        let listed = try ListingFixture(container: first)
        try await listed.approve()
        try ListingExporter.recordHandoff(listed.draft, in: listed.context)
        try ListingExporter.confirmListed(listed.draft, url: nil, in: listed.context)
        let listedRecord = (listed.draft.approvedSnapshotData, listed.draft.sellerConfirmedListedAt)

        try Data("not a journal".utf8).write(to: disk.journalURL)
        let relaunched = try disk.relaunch()
        #expect(disk.journal(relaunched).isCorrupt)

        // If saving fails, the withdrawal applies now and recovery repeats next time.
        #expect(throws: TestSaveError.self) { try ApprovalRevocationJournal.reconcile(in: relaunched.mainContext) { throw TestSaveError() } }
        #expect(disk.journal(relaunched).isCorrupt)
        #expect(try disk.draft(approved.draft.id, in: relaunched).status == .draft)

        let report = try ApprovalRevocationJournal.reconcile(in: relaunched.mainContext)
        #expect(report.remainingEntries == 0)
        #expect(!disk.journal(relaunched).isCorrupt)

        let again = try disk.relaunch()
        #expect(!disk.journal(again).isCorrupt, "A fresh, valid journal was written")
        let withdrawn = try disk.draft(approved.draft.id, in: again)
        #expect(withdrawn.status == .draft)
        #expect(withdrawn.approvalInvalidation == .couldNotVerify)
        let kept = try disk.draft(listed.draft.id, in: again)
        #expect(kept.status == .listed)
        #expect(kept.approvedSnapshotData == listedRecord.0)
        #expect(kept.sellerConfirmedListedAt == listedRecord.1)

        // Approving again works.
        let fresh = try await approve(withdrawn, in: again.mainContext, store: approved.store)
        #expect(try ListingExporter.package(for: withdrawn, store: approved.store).version == fresh.version)
    }

    // MARK: - History and normal operation

    @Test func listedRecordsAreNeverRewritten() async throws {
        let disk = DiskStore()
        let first = try disk.launch(storage: FlakyRevocationStorage(url: disk.journalURL))
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()
        try ListingExporter.recordHandoff(fixture.draft, in: fixture.context)
        try ListingExporter.confirmListed(fixture.draft, url: ListingExporter.listingURL(from: "vinted.co.uk/items/9"), in: fixture.context)
        let record = (fixture.draft.approvedSnapshotData, fixture.draft.sellerConfirmedListedAt, fixture.draft.externalListingURL)

        // Even with an entry for this version on disk, export is blocked
        // until recovery runs…
        disk.journal(first).revoke(draftID: fixture.draft.id, version: fixture.draft.approvalVersion)
        let relaunched = try disk.relaunch()
        let draft = try disk.draft(fixture.draft.id, in: relaunched)
        #expect(throws: ListingExportError.ownershipChanged) { try ListingExporter.package(for: draft, store: fixture.store) }

        // …and recovery never rewrites the listed record.
        #expect(try ApprovalRevocationJournal.reconcile(in: relaunched.mainContext).withdrawn == 0)
        #expect(draft.status == .listed)
        #expect(draft.approvedSnapshotData == record.0)
        #expect(draft.sellerConfirmedListedAt == record.1)
        #expect(draft.externalListingURL == record.2)

        // From then on its export follows the current ownership rules.
        draft.item?.setOwnership(.notOwned)
        #expect(throws: ListingExportError.ownershipChanged) { try ListingExporter.package(for: draft, store: fixture.store) }
        #expect(draft.status == .listed)
    }

    @Test func whenSavingSucceedsTheJournalEmptiesItself() async throws {
        let disk = DiskStore()
        let storage = FlakyRevocationStorage(url: disk.journalURL)
        let first = try disk.launch(storage: storage)
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()
        fixture.item.setOwnership(.notOwned)
        #expect(disk.storedEntries().count == 1)

        try SaveFailureCenter.save(fixture.context)
        #expect(disk.storedEntries().isEmpty)
        #expect(disk.journal(first).entries.isEmpty)

        let relaunched = try disk.relaunch()
        #expect(try ApprovalRevocationJournal.reconcile(in: relaunched.mainContext) == ApprovalRevocationJournal.ReconcileReport())
        let draft = try disk.draft(fixture.draft.id, in: relaunched)
        #expect(draft.status == .draft)
        #expect(draft.approvalInvalidation == .ownershipChanged)
    }

    @Test func unaffectedListingsExportNormally() async throws {
        let disk = DiskStore()
        let first = try disk.launch(storage: FlakyRevocationStorage(url: disk.journalURL))
        let fixture = try ListingFixture(container: first)
        try await fixture.approve()
        try SaveFailureCenter.save(fixture.context)

        let relaunched = try disk.relaunch()
        try ApprovalRevocationJournal.reconcile(in: relaunched.mainContext)
        let draft = try disk.draft(fixture.draft.id, in: relaunched)
        #expect(try ListingExporter.package(for: draft, store: fixture.store).version == 1)
        try ListingExporter.recordHandoff(draft, in: relaunched.mainContext)
        try ListingExporter.confirmListed(draft, url: nil, in: relaunched.mainContext)
        #expect(draft.status == .listed)
        #expect(disk.storedEntries().isEmpty)
    }
}
