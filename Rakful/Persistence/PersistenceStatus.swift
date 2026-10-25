import Foundation
import Observation
import SwiftData

/// Whether Rakful's work is being saved to disk.
enum StorageMode: Equatable, Sendable {
    case persistent
    /// The on-disk store couldn't be opened, so data lives in memory and
    /// disappears when the app closes. Always shown to the user.
    case temporary(reason: String)

    var isTemporary: Bool { self != .persistent }
}

/// Surfaces failed saves with a retry, so the app never shows work as
/// saved when it isn't.
@MainActor
@Observable
final class SaveFailureCenter {
    struct Failure: Identifiable {
        let id = UUID()
        /// What was being saved, e.g. "Approving your listing".
        let action: String
        let message: String
        let retry: @MainActor () throws -> Void
    }

    private(set) var current: Failure?

    /// Saves `context`, reporting any failure. Returns whether it succeeded.
    @discardableResult
    func save(_ context: ModelContext, _ action: String) -> Bool {
        attempt(action) { try Self.save(context) }
    }

    /// Saves, keeping the approval-revocation journal in step: it retries
    /// any revocation that couldn't be written, and removes entries once the
    /// database records them. If the save fails while a revocation is
    /// recorded nowhere, the error says the change may be lost.
    static func save(_ context: ModelContext, using save: (() throws -> Void)? = nil) throws {
        let journal = ApprovalRevocationJournal.journal(for: context.container)
        journal.retryUnwritten()
        do {
            try (save ?? { try context.save() })()
        } catch {
            if journal.hasUnwrittenRevocations { throw RevocationNotSavedError(underlying: error.localizedDescription) }
            throw error
        }
        journal.removeRecorded(in: context)
    }

    /// Runs `operation`, reporting a thrown error with a retry.
    @discardableResult
    func attempt(_ action: String, _ operation: @escaping @MainActor () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            report(error, action: action, retry: operation)
            return false
        }
    }

    func report(_ error: Error, action: String, retry: @escaping @MainActor () throws -> Void) {
        current = Failure(action: action, message: error.localizedDescription, retry: retry)
    }

    func retry() {
        guard let failure = current else { return }
        current = nil
        attempt(failure.action, failure.retry)
    }

    func dismiss() { current = nil }
}

extension PersistenceController {
    /// Opens the on-disk store, retrying once. If it still can't be opened,
    /// falls back to memory and says so: the UI then warns that nothing will
    /// be kept, so no one creates work that silently disappears.
    static func loadContainer(
        open: () throws -> ModelContainer = { try makeContainer() },
        fallback: () throws -> ModelContainer = { try makeContainer(inMemory: true) }
    ) -> (ModelContainer, StorageMode) {
        do {
            return (try open(), .persistent)
        } catch {
            if let container = try? open() { return (container, .persistent) }
            do {
                return (try fallback(), .temporary(reason: error.localizedDescription))
            } catch {
                fatalError("Rakful couldn't create even a temporary store: \(error)")
            }
        }
    }
}
