import Foundation
import SwiftData

enum PersistenceController {
    static let schema = Schema([
        DiscoverySession.self,
        PhotoReference.self,
        CandidateItem.self,
        ItemPhoto.self,
        OwnershipConfirmation.self,
        ProductIdentification.self,
        PriceEstimate.self,
        PricingEvidence.self,
        ListingDraft.self,
        MarketplaceConnection.self,
        BackgroundTaskRecord.self,
        ActivityEvent.self,
    ])

    /// Local store only. PhotoKit identifiers are device-specific, so syncing
    /// them through CloudKit would not be meaningful.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        // The store keeps its original file name so existing data survives
        // the rename to Rakful.
        let configuration = ModelConfiguration(
            "ResaleReady",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

/// Main-context helpers for recording user actions in the activity timeline.
extension ModelContext {
    @discardableResult
    func logActivity(_ kind: ActivityKind, title: String, detail: String? = nil, itemID: UUID? = nil, isDemo: Bool = false) -> ActivityEvent {
        let event = ActivityEvent(kind: kind, title: title, detail: detail, itemID: itemID, isDemo: isDemo)
        insert(event)
        return event
    }
}
