import Foundation
import SwiftData

/// A possession Rakful believes may be resellable, built from one or
/// more grouped photos. Brand/model/colour/size only hold values the user has
/// confirmed or entered; unconfirmed suggestions live in `identifications`.
@Model
final class CandidateItem {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var categoryRaw: String
    /// Generic noun derived from the classifier label (e.g. "Backpack").
    var suggestedName: String
    /// Name the user typed, if any.
    var customName: String?
    /// The classifier label that produced the category, e.g. "sneaker".
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
    /// Sample items are isolated from real discoveries and always labelled.
    var isDemo: Bool
    /// SF Symbol used as the thumbnail for sample items.
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

    init(
        id: UUID = UUID(),
        category: ResaleCategory,
        suggestedName: String,
        classifierLabel: String? = nil,
        confidence: Double,
        discoveredInSessionID: UUID? = nil,
        isDemo: Bool = false,
        demoSymbol: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.categoryRaw = category.rawValue
        self.suggestedName = suggestedName
        self.classifierLabel = classifierLabel
        self.confidence = confidence
        self.ownershipRaw = OwnershipStatus.unconfirmed.rawValue
        self.discoveredInSessionID = discoveredInSessionID
        self.isDemo = isDemo
        self.demoSymbol = demoSymbol
    }

    var category: ResaleCategory {
        get { ResaleCategory.stored(categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var ownership: OwnershipStatus {
        get { OwnershipStatus(rawValue: ownershipRaw) ?? .unconfirmed }
        set { ownershipRaw = newValue.rawValue }
    }

    var condition: ItemCondition? {
        get { conditionRaw.flatMap(ItemCondition.init(rawValue:)) }
        set { conditionRaw = newValue?.rawValue }
    }

    var confidenceLevel: ConfidenceLevel { ConfidenceLevel(score: confidence) }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        let confirmed = [brand, model].compactMap { $0?.nilIfBlank }.joined(separator: " ")
        return confirmed.isEmpty ? suggestedName : confirmed
    }

    var sortedPhotos: [ItemPhoto] {
        photos.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            return $0.sortIndex < $1.sortIndex
        }
    }

    /// Photos excluding near-duplicates (bursts, edits).
    var distinctPhotos: [ItemPhoto] { sortedPhotos.filter { !$0.isDuplicate } }

    /// Photos that may go in a listing now: checked automatically or by the
    /// seller, not showing a person, and not near-duplicates.
    var listingPhotos: [ItemPhoto] { distinctPhotos.filter { $0.listingEligibility == .eligible } }

    /// Photos that could be listed once they've been checked.
    var photosAwaitingCheck: [ItemPhoto] {
        distinctPhotos.filter { $0.listingEligibility == .unchecked || $0.listingEligibility == .needsReview }
    }

    /// Some photos show a person, e.g. the item being worn.
    var hasPhotosOfPeople: Bool { distinctPhotos.contains(where: \.showsPerson) }

    /// Seen only in photos of people, so it needs photos of its own to list.
    var isOnlySeenWorn: Bool { hasPhotosOfPeople && distinctPhotos.allSatisfy(\.showsPerson) }

    var primaryPhoto: ItemPhoto? { sortedPhotos.first }

    /// The most recent verified estimate, if any pricing source produced one.
    var latestEstimate: PriceEstimate? {
        priceEstimates.max { $0.createdAt < $1.createdAt }
    }

    /// The draft still being prepared or posted, if any.
    var activeDraft: ListingDraft? {
        drafts.filter { $0.status.isActive }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Unconfirmed brand suggestion from on-device text or a cloud service.
    var pendingBrandSuggestion: ProductIdentification? {
        guard brand?.nilIfBlank == nil else { return nil }
        return identifications
            .filter { $0.brand?.nilIfBlank != nil && !$0.isDismissed && $0.source != .user }
            .max { $0.confidence < $1.confidence }
    }

    func setOwnership(_ status: OwnershipStatus, at date: Date = .now) {
        ownership = status
        ownershipUpdatedAt = date
        updatedAt = date
        ownershipHistory.append(OwnershipConfirmation(status: status, date: date))
    }
}

@Model
final class ItemPhoto {
    @Attribute(.unique) var id: UUID
    /// PhotoKit local identifier for photos from the user's library.
    var assetLocalIdentifier: String?
    /// File name inside the app's imported-images directory.
    var importedFileName: String?
    var sourceRaw: String
    var addedAt: Date
    var capturedAt: Date?
    var isPrimary: Bool
    var isDuplicate: Bool
    var sortIndex: Int
    /// Normalised feature vector bytes used for grouping and deduplication.
    var featurePrint: Data?
    /// A person is visible, e.g. someone wearing the item — detected
    /// automatically or marked by the seller. The photo identifies the item
    /// but is never used in a listing. Kept in sync by `personCheck` and
    /// `userReview`.
    var showsPerson: Bool = false
    /// The automatic person check. `nil` only on records from before checks
    /// were tracked, until `DataMigration` fills it in.
    var personCheckRaw: String?
    var personCheckedAt: Date?
    /// The seller's own review of the photo, if any.
    var userReviewRaw: String?
    var item: CandidateItem?

    init(
        assetLocalIdentifier: String? = nil,
        importedFileName: String? = nil,
        source: PhotoSource,
        capturedAt: Date? = nil,
        isPrimary: Bool = false,
        isDuplicate: Bool = false,
        sortIndex: Int = 0,
        featurePrint: Data? = nil,
        personCheck: PersonCheck = .unchecked
    ) {
        self.id = UUID()
        self.assetLocalIdentifier = assetLocalIdentifier
        self.importedFileName = importedFileName
        self.sourceRaw = source.rawValue
        self.addedAt = .now
        self.capturedAt = capturedAt
        self.isPrimary = isPrimary
        self.isDuplicate = isDuplicate
        self.sortIndex = sortIndex
        self.featurePrint = featurePrint
        self.personCheck = personCheck
    }

    var source: PhotoSource { PhotoSource(rawValue: sourceRaw) ?? .library }

    var personCheck: PersonCheck {
        get { personCheckRaw.flatMap(PersonCheck.init(rawValue:)) ?? (showsPerson ? .personDetected : .unchecked) }
        set {
            personCheckRaw = newValue.rawValue
            personCheckedAt = newValue == .unchecked ? nil : .now
            showsPerson = newValue == .personDetected || userReview == .markedShowsPerson
        }
    }

    var userReview: PhotoUserReview? {
        get { userReviewRaw.flatMap(PhotoUserReview.init(rawValue:)) }
        set {
            userReviewRaw = newValue?.rawValue
            showsPerson = personCheck == .personDetected || newValue == .markedShowsPerson
        }
    }

    /// A detected person always excludes the photo; the seller's confirmation
    /// only stands in for a check that hasn't run or couldn't.
    var listingEligibility: PhotoEligibility {
        if personCheck == .personDetected || userReview == .markedShowsPerson { return .showsPerson }
        if userReview == .confirmedNoPerson { return .eligible }
        switch personCheck {
        case .noPersonDetected: return .eligible
        case .failed: return .needsReview
        case .unchecked: return .unchecked
        case .personDetected: return .showsPerson
        }
    }

    var reference: PhotoRef {
        PhotoRef(id: id, assetLocalIdentifier: assetLocalIdentifier, importedFileName: importedFileName)
    }
}

/// Where a photo's pixels live, as a plain value for loaders.
struct PhotoRef: Sendable, Hashable {
    let id: UUID
    let assetLocalIdentifier: String?
    let importedFileName: String?
}

@Model
final class OwnershipConfirmation {
    @Attribute(.unique) var id: UUID
    var date: Date
    var statusRaw: String
    var item: CandidateItem?

    init(status: OwnershipStatus, date: Date = .now) {
        self.id = UUID()
        self.date = date
        self.statusRaw = status.rawValue
    }

    var status: OwnershipStatus { OwnershipStatus(rawValue: statusRaw) ?? .unconfirmed }
}

/// A suggestion about what an item is, with its source and evidence. These
/// are never applied to the item without the user's confirmation.
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
    /// Human-readable evidence, e.g. "Detected text “NIKE”".
    var evidence: String
    var isDismissed: Bool
    var item: CandidateItem?

    init(
        source: IdentificationSource,
        category: ResaleCategory? = nil,
        brand: String? = nil,
        model: String? = nil,
        colour: String? = nil,
        confidence: Double,
        evidence: String
    ) {
        self.id = UUID()
        self.createdAt = .now
        self.sourceRaw = source.rawValue
        self.categoryRaw = category?.rawValue
        self.brand = brand
        self.model = model
        self.colour = colour
        self.confidence = confidence
        self.evidence = evidence
        self.isDismissed = false
    }

    var source: IdentificationSource { IdentificationSource(rawValue: sourceRaw) ?? .onDeviceClassifier }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
