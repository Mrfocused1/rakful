import Foundation
import SwiftData

@Model
final class ListingDraft {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var descriptionText: String
    var categoryText: String
    var brand: String
    var model: String
    var colour: String
    var size: String
    var conditionRaw: String?
    var defects: String
    var keywords: [String]
    var askingPrice: Double?
    var currencyCode: String
    var marketplaceRaw: String
    var statusRaw: String
    /// Fields generated or prefilled from unconfirmed data that still need review.
    var uncertainFieldsRaw: [String]
    var generatorName: String?
    var generatedAt: Date?
    /// Last time the approved listing was copied, shared or the marketplace opened.
    var handedOffAt: Date?
    /// Optional link the seller recorded after confirming it's listed. Not verified.
    var externalListingURL: String?
    var isDemo: Bool
    var item: CandidateItem?

    // Added with approvals. Every property has a default so existing stores
    // migrate automatically; `DataMigration` fixes up meanings.
    var material: String = ""
    var measurements: String = ""
    /// `nil` until the seller says whether there's wear or defects.
    var defectsAssessmentRaw: String?
    /// The photos chosen for the listing, in order (`ItemPhoto.id` strings).
    var selectedPhotoIDsRaw: [String] = []
    /// When the seller confirmed they own the item and intend to sell it.
    var sellerDeclaredOwnershipAt: Date?
    /// Claims in the text the seller confirmed are accurate (`ListingClaim.id`).
    var confirmedClaimsRaw: [String] = []
    /// The version of the current approval; increases with every approval.
    var approvalVersion: Int = 0
    /// JSON-encoded `ListingSnapshot` the seller approved. Exports use only this.
    var approvedSnapshotData: Data?
    var approvedAt: Date?
    var sellerConfirmedListedAt: Date?
    /// `DataMigration.currentDraftVersion` once this record has been upgraded.
    var dataVersion: Int = 0
    /// Why the last approval was withdrawn, kept until the seller approves again.
    var approvalInvalidationRaw: String?

    init(item: CandidateItem?, currencyCode: String, marketplace: Marketplace = .ebay) {
        self.id = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.title = ""
        self.descriptionText = ""
        self.categoryText = item?.category.displayName ?? ""
        self.brand = item?.brand ?? ""
        self.model = item?.model ?? ""
        self.colour = item?.colour ?? ""
        self.size = item?.size ?? ""
        self.conditionRaw = item?.conditionRaw
        self.defects = ""
        self.keywords = []
        self.askingPrice = nil
        self.currencyCode = currencyCode
        self.marketplaceRaw = marketplace.rawValue
        self.statusRaw = ListingStatus.draft.rawValue
        self.uncertainFieldsRaw = []
        self.isDemo = item?.isDemo ?? false
        self.item = item
        self.dataVersion = DataMigration.currentDraftVersion
    }

    var status: ListingStatus {
        get { ListingStatus(storedValue: statusRaw) }
        set { statusRaw = newValue.rawValue }
    }

    var defectsAssessment: DefectsAssessment? {
        get { defectsAssessmentRaw.flatMap(DefectsAssessment.init(rawValue:)) }
        set { defectsAssessmentRaw = newValue?.rawValue }
    }

    var selectedPhotoIDs: [UUID] {
        get { selectedPhotoIDsRaw.compactMap(UUID.init(uuidString:)) }
        set { selectedPhotoIDsRaw = newValue.map(\.uuidString) }
    }

    var confirmedClaims: Set<String> {
        get { Set(confirmedClaimsRaw) }
        set { confirmedClaimsRaw = newValue.sorted() }
    }

    /// Withdrawing the declaration withdraws any approval that isn't yet
    /// confirmed listed.
    var sellerDeclaredOwnership: Bool {
        get { sellerDeclaredOwnershipAt != nil }
        set {
            sellerDeclaredOwnershipAt = newValue ? (sellerDeclaredOwnershipAt ?? .now) : nil
            if !newValue { invalidateApprovalIfNeeded() }
        }
    }

    var approvalInvalidation: ApprovalInvalidation? {
        get { approvalInvalidationRaw.flatMap(ApprovalInvalidation.init(rawValue:)) }
        set { approvalInvalidationRaw = newValue?.rawValue }
    }

    var marketplace: Marketplace {
        get { Marketplace(rawValue: marketplaceRaw) ?? .ebay }
        set { marketplaceRaw = newValue.rawValue }
    }

    var condition: ItemCondition? {
        get { conditionRaw.flatMap(ItemCondition.init(rawValue:)) }
        set { conditionRaw = newValue?.rawValue }
    }

    var uncertainFields: Set<ListingField> {
        get { Set(uncertainFieldsRaw.compactMap(ListingField.init(rawValue:))) }
        set { uncertainFieldsRaw = newValue.map(\.rawValue).sorted() }
    }

    var displayTitle: String {
        title.nilIfBlank ?? item?.displayName ?? "Untitled Listing"
    }

    func markConfirmed(_ field: ListingField) {
        var fields = uncertainFields
        fields.remove(field)
        uncertainFields = fields
    }

    func touch() { updatedAt = .now }
}

@Model
final class MarketplaceConnection {
    @Attribute(.unique) var marketplaceRaw: String
    var statusRaw: String
    var connectedAt: Date?
    var accountDisplayName: String?

    init(marketplace: Marketplace) {
        self.marketplaceRaw = marketplace.rawValue
        self.statusRaw = ConnectionStatus.notConnected.rawValue
    }

    var marketplace: Marketplace { Marketplace(rawValue: marketplaceRaw) ?? .ebay }
    var status: ConnectionStatus {
        get { ConnectionStatus(rawValue: statusRaw) ?? .notConnected }
        set { statusRaw = newValue.rawValue }
    }

    enum ConnectionStatus: String, Codable, Sendable {
        case notConnected, connected, expired
    }
}
