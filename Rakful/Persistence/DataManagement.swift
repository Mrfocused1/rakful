import Foundation
import SwiftData

/// Privacy controls. None of these ever touch the user's photo library —
/// Rakful never deletes, edits or moves photos.
@MainActor
enum DataManagement {
    /// Deletes sessions, activity, background records and photo checkpoints.
    /// Discovered items are kept; photos will be re-analysed next time.
    static func deleteDiscoveryHistory(in context: ModelContext) throws {
        try deleteEach(DiscoverySession.self, in: context)
        try deleteEach(ActivityEvent.self, in: context)
        try deleteEach(BackgroundTaskRecord.self, in: context)
        // Checkpoints have no relationships and can number in the tens of
        // thousands, so they're removed with a store-level batch delete.
        try context.delete(model: PhotoReference.self)
        try context.save()
    }

    /// Removes photos the user took or imported for listings.
    static func removeImportedImages(in context: ModelContext) throws -> Int {
        let photos = try context.fetch(FetchDescriptor<ItemPhoto>(predicate: #Predicate { $0.importedFileName != nil }))
        for photo in photos {
            if let name = photo.importedFileName { ImportedImageStore.delete(name) }
            context.delete(photo)
        }
        ImportedImageStore.deleteAll()
        try context.save()
        return photos.count
    }

    /// Disconnects marketplaces and clears server session tokens.
    static func revokeIntegrations(in context: ModelContext, keychain: KeychainStore = KeychainStore()) throws {
        try deleteEach(MarketplaceConnection.self, in: context)
        keychain.removeAll()
        try context.save()
    }

    /// Erases everything Rakful stores on this iPhone.
    static func eraseAllData(in context: ModelContext, preferences: PreferencesStore) throws {
        // Per-object deletes honour cascade rules (items → photos, suggestions,
        // estimates → evidence, drafts) and keep live queries in sync.
        try deleteEach(ListingDraft.self, in: context)
        try deleteEach(CandidateItem.self, in: context)
        try deleteDiscoveryHistory(in: context)
        try revokeIntegrations(in: context)
        ImportedImageStore.deleteAll()
        ThumbnailLoader.shared.purge()
        preferences.reset()
        try context.save()
    }

    private static func deleteEach<Model: PersistentModel>(_ type: Model.Type, in context: ModelContext) throws {
        for object in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(object)
        }
    }
}
