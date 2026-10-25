import Foundation
import os
import SwiftData

/// Where the journal's bytes live. Injectable so tests can make writes fail.
protocol RevocationStorage: Sendable {
    /// The stored bytes, or nil when nothing has been stored yet.
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// A small file beside the database, replaced atomically on every write.
struct FileRevocationStorage: RevocationStorage {
    let url: URL

    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data) throws {
        try data.write(to: url, options: .atomic)
    }
}

/// For in-memory databases (tests, previews).
final class MemoryRevocationStorage: RevocationStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
}

/// Approvals withdrawn because ownership changed, recorded outside the
/// database.
///
/// Withdrawing ownership only reaches the database on the next successful
/// save. If that save fails and the app then closes, the database still
/// holds the old ownership and approval. So the withdrawal is first written
/// here (a separate file, replaced atomically), and:
/// - every export, handoff and listing confirmation checks it;
/// - at launch, `reconcile` applies it to the database;
/// - entries are removed only once a save has recorded their effect.
///
/// Limitation: if neither this file nor the database can be written, an
/// unsaved withdrawal can't survive the app closing. It's blocked for the
/// rest of the session, and the save error says so.
final class ApprovalRevocationJournal: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// `ListingDraft.id`.
        var draftID: UUID
        /// Approvals up to and including this version are revoked.
        var version: Int
        var recordedAt: Date
    }

    private struct Contents: Codable {
        var format = 1
        var entries: [Entry]
    }

    private let lock = NSLock()
    private let storage: RevocationStorage
    private var _entries: [Entry] = []
    private var _hasUnwritten = false
    private var _isCorrupt = false

    init(storage: RevocationStorage) {
        self.storage = storage
        do {
            if let data = try storage.read() {
                _entries = try JSONDecoder().decode(Contents.self, from: data).entries
            }
        } catch {
            // Unreadable: which approvals were withdrawn is unknown, so
            // `reconcile` withdraws every approval not yet listed.
            _isCorrupt = true
        }
    }

    var entries: [Entry] { lock.withLock { _entries } }
    /// A revocation couldn't be written to storage. It still applies in this session.
    var hasUnwrittenRevocations: Bool { lock.withLock { _hasUnwritten } }
    var isCorrupt: Bool { lock.withLock { _isCorrupt } }

    /// Records that a draft's approval, up to `version`, is withdrawn.
    /// Returns whether it's durably stored; either way it applies to this
    /// session immediately.
    @discardableResult
    func revoke(draftID: UUID, version: Int, at date: Date = .now) -> Bool {
        lock.withLock {
            if !_entries.contains(where: { $0.draftID == draftID && $0.version >= version }) {
                _entries.append(Entry(draftID: draftID, version: version, recordedAt: date))
            }
            return writeLocked()
        }
    }

    func isRevoked(draftID: UUID, version: Int) -> Bool {
        lock.withLock { _entries.contains { $0.draftID == draftID && $0.version >= version } }
    }

    func highestRevokedVersion(draftID: UUID) -> Int? {
        lock.withLock { _entries.filter { $0.draftID == draftID }.map(\.version).max() }
    }

    /// Tries again to store revocations that couldn't be written.
    @discardableResult
    func retryUnwritten() -> Bool {
        lock.withLock { _hasUnwritten ? writeLocked() : true }
    }

    /// Removes entries whose effect `context` records. Call only after the
    /// context has saved successfully. If the cleanup can't be written, the
    /// file keeps those entries; applying them again later is harmless.
    @MainActor
    @discardableResult
    func removeRecorded(in context: ModelContext) -> Bool {
        let recorded = entries.filter { entry in
            let id = entry.draftID
            guard let draft = try? context.fetch(FetchDescriptor<ListingDraft>(predicate: #Predicate { $0.id == id })).first else { return true }
            return !Self.stillApproved(draft, upTo: entry.version)
        }
        guard !recorded.isEmpty else { return true }
        return lock.withLock {
            let wasUnwritten = _hasUnwritten
            _entries.removeAll { recorded.contains($0) }
            if writeLocked() { return true }
            // The database records the removed entries, so only ones that were
            // never written still need writing.
            _hasUnwritten = wasUnwritten && !_entries.isEmpty
            return false
        }
    }

    /// Replaces unreadable contents with an empty journal, once `reconcile`
    /// has withdrawn every affected approval and saved.
    func resetAfterRecovery() throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(Contents(entries: []))
            try storage.write(data)
            _entries = []
            _isCorrupt = false
            _hasUnwritten = false
        }
    }

    private func writeLocked() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try storage.write(try encoder.encode(Contents(entries: _entries)))
            _hasUnwritten = false
            return true
        } catch {
            _hasUnwritten = true
            return false
        }
    }

    /// The draft still has an approval, not yet listed, at or below `version`.
    /// Listed records are history: recovery never rewrites them, and their
    /// export follows the current ownership rules.
    static func stillApproved(_ draft: ListingDraft, upTo version: Int) -> Bool {
        (draft.status == .approved || draft.status == .exported) && draft.approvedSnapshotData != nil && draft.approvalVersion <= version
    }

    // MARK: - Recovery

    struct ReconcileReport: Equatable {
        var withdrawn = 0
        var remainingEntries = 0
    }

    /// Applies recorded revocations to the database, saves, then removes
    /// the entries. Run at launch before listings can be exported; safe to
    /// repeat. If the save fails, the withdrawals still apply in this session
    /// and the entries stay for next time.
    @MainActor
    @discardableResult
    static func reconcile(in context: ModelContext, save: (() throws -> Void)? = nil) throws -> ReconcileReport {
        let journal = journal(for: context.container)
        var report = ReconcileReport()
        let approved = [ListingStatus.approved.rawValue, ListingStatus.exported.rawValue]
        let drafts = try context.fetch(FetchDescriptor<ListingDraft>(predicate: #Predicate { approved.contains($0.statusRaw) }))
        let corrupt = journal.isCorrupt
        for draft in drafts {
            if corrupt {
                // Unknown withdrawals: every approval not yet listed is withdrawn.
                draft.withdrawApproval(reason: .couldNotVerify)
                report.withdrawn += 1
            } else if let revoked = journal.highestRevokedVersion(draftID: draft.id), stillApproved(draft, upTo: revoked) {
                draft.withdrawApproval(reason: .ownershipChanged)
                report.withdrawn += 1
            }
        }
        if context.hasChanges { try (save ?? { try context.save() })() }
        if corrupt {
            try journal.resetAfterRecovery()
        } else {
            journal.removeRecorded(in: context)
        }
        report.remainingEntries = journal.entries.count
        return report
    }

    // MARK: - One journal per database

    private static let registry = OSAllocatedUnfairLock<[String: ApprovalRevocationJournal]>(initialState: [:])

    /// The journal for a database: a file beside an on-disk store, or memory
    /// for an in-memory one.
    static func journal(for container: ModelContainer) -> ApprovalRevocationJournal {
        let key = key(for: container)
        return registry.withLock { journals in
            if let existing = journals[key] { return existing }
            let storage: RevocationStorage = if let url = fileURL(for: container) {
                FileRevocationStorage(url: url)
            } else {
                MemoryRevocationStorage()
            }
            let created = ApprovalRevocationJournal(storage: storage)
            journals[key] = created
            return created
        }
    }

    /// Uses `journal` for the database at `storeURL`, e.g. after a relaunch
    /// or with storage that fails on purpose in tests.
    static func register(_ journal: ApprovalRevocationJournal, forStoreAt storeURL: URL) {
        registry.withLock { $0["file:" + storeURL.standardizedFileURL.path] = journal }
    }

    static func defaultFileURL(forStoreAt storeURL: URL) -> URL {
        URL(fileURLWithPath: storeURL.standardizedFileURL.path + "-approval-revocations.json")
    }

    private static func key(for container: ModelContainer) -> String {
        if let configuration = container.configurations.first, !configuration.isStoredInMemoryOnly {
            return "file:" + configuration.url.standardizedFileURL.path
        }
        return "memory:\(ObjectIdentifier(container).hashValue)"
    }

    private static func fileURL(for container: ModelContainer) -> URL? {
        guard let configuration = container.configurations.first, !configuration.isStoredInMemoryOnly else { return nil }
        return defaultFileURL(forStoreAt: configuration.url)
    }
}

/// Saving failed, and a withdrawn approval couldn't be recorded anywhere.
struct RevocationNotSavedError: LocalizedError {
    let underlying: String

    var errorDescription: String? {
        "Rakful couldn't save that ownership change, so exporting the affected listing is blocked for now. If Rakful closes before it's saved, the change may be lost. \(underlying)"
    }
}
