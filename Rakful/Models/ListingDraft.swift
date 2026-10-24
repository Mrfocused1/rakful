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
    var handedOffAt: Date?
    var externalListingURL: String?
    var isDemo: Bool
    var item: CandidateItem?

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
    }

    var status: ListingStatus {
        get { ListingStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
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
