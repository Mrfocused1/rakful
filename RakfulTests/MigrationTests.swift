import Foundation
import SwiftData
import Testing
@testable import Rakful

/// The item and listing models exactly as they shipped before approvals
/// (commit 273b845), used to write a real legacy store on disk.
enum LegacySchemaV1 {
    @Model
    final class CandidateItem {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var categoryRaw: String
        var suggestedName: String
        var customName: String?
        var classifierLabel: String?
        var confidence: Double
        var ownershipRaw: String
        var ownershipUpdatedAt: Date?
        var conditionRaw: String?
        var brand: String?
        var model: String?
        var colour: String?
        var size: String?
        var notes: String?
        var discoveredInSessionID: UUID?
        var isDemo: Bool
        var demoSymbol: String?

        @Relationship(deleteRule: .cascade, inverse: \ItemPhoto.item)
        var photos: [ItemPhoto] = []
        @Relationship(deleteRule: .cascade, inverse: \ProductIdentification.item)
        var identifications: [ProductIdentification] = []
        @Relationship(deleteRule: .cascade, inverse: \OwnershipConfirmation.item)
        var ownershipHistory: [OwnershipConfirmation] = []
        @Relationship(deleteRule: .cascade, inverse: \PriceEstimate.item)
        var priceEstimates: [PriceEstimate] = []
        @Relationship(deleteRule: .cascade, inverse: \ListingDraft.item)
        var drafts: [ListingDraft] = []

        init(name: String, brand: String?, category: String = "clothing") {
            id = UUID()
            createdAt = .now
            updatedAt = .now
            categoryRaw = category
            suggestedName = name
            confidence = 0.9
            ownershipRaw = "owned"
            ownershipUpdatedAt = .now
            conditionRaw = "good"
            self.brand = brand
            isDemo = false
        }
    }

    @Model
    final class ItemPhoto {
        @Attribute(.unique) var id: UUID
        var assetLocalIdentifier: String?
        var importedFileName: String?
        var sourceRaw: String
        var addedAt: Date
        var capturedAt: Date?
        var isPrimary: Bool
        var isDuplicate: Bool
        var sortIndex: Int
        var featurePrint: Data?
        var showsPerson: Bool = false
        var item: CandidateItem?

        init(asset: String?, file: String?, source: String, sortIndex: Int, showsPerson: Bool) {
            id = UUID()
            assetLocalIdentifier = asset
            importedFileName = file
            sourceRaw = source
            addedAt = .now
            isPrimary = sortIndex == 0
            isDuplicate = false
            self.sortIndex = sortIndex
            self.showsPerson = showsPerson
        }
    }

    @Model
    final class OwnershipConfirmation {
        @Attribute(.unique) var id: UUID
        var date: Date
        var statusRaw: String
        var item: CandidateItem?

        init(status: String) {
            id = UUID()
            date = .now
            statusRaw = status
        }
    }

    @Model
    final class ProductIdentification {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var sourceRaw: String
        var categoryRaw: String?
        var brand: String?
        var model: String?
        var colour: String?
        var confidence: Double
        var evidence: String
        var isDismissed: Bool
        var item: CandidateItem?

        init(brand: String) {
            id = UUID()
            createdAt = .now
            sourceRaw = "onDeviceText"
            self.brand = brand
            confidence = 0.6
            evidence = "Detected text"
            isDismissed = false
        }
    }

    @Model
    final class PriceEstimate {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var providerName: String
        var kindRaw: String
        var currencyCode: String
        var low: Double
        var high: Double
        var median: Double?
        var sampleSize: Int
        var confidenceRaw: String
        var isDemo: Bool
        var item: CandidateItem?

        @Relationship(deleteRule: .cascade, inverse: \PricingEvidence.estimate)
        var evidence: [PricingEvidence] = []

        init() {
            id = UUID()
            createdAt = .now
            providerName = "Demo data"
            kindRaw = "estimatedRange"
            currencyCode = "GBP"
            low = 20
            high = 30
            sampleSize = 0
            confidenceRaw = "medium"
            isDemo = true
        }
    }

    @Model
    final class PricingEvidence {
        @Attribute(.unique) var id: UUID
        var title: String
        var price: Double
        var currencyCode: String
        var kindRaw: String
        var sourceName: String
        var urlString: String?
        var observedAt: Date
        var estimate: PriceEstimate?

        init() {
            id = UUID()
            title = "x"
            price = 1
            currencyCode = "GBP"
            kindRaw = "completedSale"
            sourceName = "x"
            observedAt = .now
        }
    }

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
        var uncertainFieldsRaw: [String]
        var generatorName: String?
        var generatedAt: Date?
        var handedOffAt: Date?
        var externalListingURL: String?
        var isDemo: Bool
        var item: CandidateItem?

        init(title: String, status: String, defects: String) {
            id = UUID()
            createdAt = .now
            updatedAt = .now
            self.title = title
            descriptionText = "A description."
            categoryText = "Clothing"
            brand = ""
            model = ""
            colour = "Blue"
            size = "M"
            conditionRaw = "good"
            self.defects = defects
            keywords = ["denim", "jacket"]
            askingPrice = 25
            currencyCode = "GBP"
            marketplaceRaw = "vinted"
            statusRaw = status
            uncertainFieldsRaw = ["description"]
            isDemo = false
        }
    }

    static let models: [any PersistentModel.Type] = [
        CandidateItem.self, ItemPhoto.self, OwnershipConfirmation.self, ProductIdentification.self,
        PriceEstimate.self, PricingEvidence.self, ListingDraft.self,
    ]
}

@MainActor
@Suite("Data migration")
struct MigrationTests {
    struct LegacyIDs {
        var item: UUID
        var personPhoto: UUID
        var plainPhoto: UUID
        var listedDraft: UUID
        var openDraft: UUID
        var handedOffAt: Date
    }

    /// Writes a store with the pre-approval schema, then releases it.
    func writeLegacyStore(at url: URL) throws -> LegacyIDs {
        let schema = Schema(LegacySchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(container)
        let item = LegacySchemaV1.CandidateItem(name: "Denim Jacket", brand: "Levi's")
        context.insert(item)
        let worn = LegacySchemaV1.ItemPhoto(asset: "library-1", file: nil, source: "library", sortIndex: 0, showsPerson: true)
        let plain = LegacySchemaV1.ItemPhoto(asset: nil, file: "camera.jpg", source: "camera", sortIndex: 1, showsPerson: false)
        item.photos = [worn, plain]
        item.ownershipHistory = [LegacySchemaV1.OwnershipConfirmation(status: "owned")]
        item.identifications = [LegacySchemaV1.ProductIdentification(brand: "Levi's")]
        let estimate = LegacySchemaV1.PriceEstimate()
        estimate.evidence = [LegacySchemaV1.PricingEvidence()]
        item.priceEstimates = [estimate]

        let listed = LegacySchemaV1.ListingDraft(title: "Listed Jacket", status: "handedOff", defects: "")
        let handedOffAt = Date(timeIntervalSince1970: 1_790_000_000)
        listed.handedOffAt = handedOffAt
        listed.externalListingURL = "https://www.vinted.co.uk/items/1"
        let open = LegacySchemaV1.ListingDraft(title: "Draft Jacket", status: "draft", defects: "Faded on the collar")
        item.drafts = [listed, open]
        // Watches were their own category before being merged into accessories.
        context.insert(LegacySchemaV1.CandidateItem(name: "Old Watch", brand: nil, category: "watches"))
        try context.save()
        return LegacyIDs(item: item.id, personPhoto: worn.id, plainPhoto: plain.id, listedDraft: listed.id, openDraft: open.id, handedOffAt: handedOffAt)
    }

    @Test func legacyItemsDraftsAndPhotosSurviveTheUpgrade() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rakful-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ResaleReady.store")
        let ids = try writeLegacyStore(at: url)

        // Open with today's schema, exactly as the app does.
        let container = try PersistenceController.makeContainer(url: url)
        let context = container.mainContext
        let report = try DataMigration.run(in: context)
        #expect(report == DataMigration.Report(listedDrafts: 1, photos: 2, drafts: 2, recategorised: 1))

        let watch = try #require(try context.fetch(FetchDescriptor<CandidateItem>()).first { $0.suggestedName == "Old Watch" })
        #expect(watch.categoryRaw == "accessories")
        #expect(watch.category == .accessories)

        let item = try #require(try context.fetch(FetchDescriptor<CandidateItem>()).first { $0.id == ids.item })
        #expect(item.id == ids.item)
        #expect(item.displayName == "Levi's")
        #expect(item.ownership == .owned)
        #expect(item.ownershipHistory.count == 1)
        #expect(item.identifications.count == 1)
        #expect(item.priceEstimates.first?.evidence.count == 1)

        let person = try #require(item.photos.first { $0.id == ids.personPhoto })
        let plain = try #require(item.photos.first { $0.id == ids.plainPhoto })
        #expect(person.personCheck == .personDetected)
        #expect(person.listingEligibility == .showsPerson)
        #expect(plain.personCheck == .unchecked, "An old 'no person' result is re-checked, never trusted")
        #expect(plain.listingEligibility == .unchecked)
        #expect(plain.importedFileName == "camera.jpg")

        let listed = try #require(item.drafts.first { $0.id == ids.listedDraft })
        #expect(listed.status == .listed, "Legacy “Mark as Listed” was the seller's confirmation")
        #expect(listed.sellerConfirmedListedAt == ids.handedOffAt)
        #expect(listed.externalListingURL == "https://www.vinted.co.uk/items/1")
        #expect(listed.title == "Listed Jacket")

        let open = try #require(item.drafts.first { $0.id == ids.openDraft })
        #expect(open.status == .draft)
        #expect(open.defectsAssessment == .described)
        #expect(open.defects == "Faded on the collar")
        #expect(open.keywords == ["denim", "jacket"])
        #expect(open.askingPrice == 25)
        #expect(open.marketplace == .vinted)
        #expect(open.selectedPhotoIDs == [ids.plainPhoto], "Previously usable photos stay selected")
        #expect(open.material.isEmpty && open.measurements.isEmpty)
        #expect(open.approvalVersion == 0 && open.approvedSnapshot == nil)
        #expect(!open.sellerDeclaredOwnership, "Sellers confirm intent to sell again")
        #expect(open.dataVersion == DataMigration.currentDraftVersion)
        #expect(item.activeDraft?.id == ids.openDraft)

        // Running again changes nothing.
        #expect(try DataMigration.run(in: context) == DataMigration.Report())

        // And the upgraded store reopens cleanly.
        let reopened = try PersistenceController.makeContainer(url: url)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<ListingDraft>()) == 2)
    }

    @Test func mergedCategoriesStillReadBeforeMigration() {
        #expect(ResaleCategory.stored("cameras") == .electronics)
        #expect(ResaleCategory.stored("watches") == .accessories)
        #expect(ResaleCategory.stored("trainers") == .trainers)
        #expect(ResaleCategory.trainers.displayName == "Footwear")
        #expect(!ResaleCategory.allCases.map(\.rawValue).contains { ["cameras", "watches"].contains($0) })
        #expect(CategoryClassifier().match([ClassifiedLabel(identifier: "camera", confidence: 0.9)], enabledCategories: ResaleCategory.allEnabledByDefault)?.category == .electronics)
        #expect(CategoryClassifier().match([ClassifiedLabel(identifier: "watch", confidence: 0.9)], enabledCategories: ResaleCategory.allEnabledByDefault)?.category == .accessories)
    }

    @Test func legacyStatusValueReadsAsListedEvenBeforeMigration() {
        #expect(ListingStatus(storedValue: "handedOff") == .listed)
        #expect(ListingStatus(storedValue: "draft") == .draft)
        #expect(ListingStatus(storedValue: "unknown") == .draft)
    }
}
