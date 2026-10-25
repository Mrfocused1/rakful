import Foundation

/// Everything that appears in an exported listing. An approval records one
/// of these; any difference from the draft's current content means the
/// seller is no longer looking at what they approved.
struct ListingContent: Codable, Equatable, Sendable {
    var title: String
    var description: String
    var category: String
    var brand: String
    var model: String
    var colour: String
    var size: String
    var material: String
    var measurements: String
    var condition: ItemCondition?
    var defectsAssessment: DefectsAssessment?
    /// Only set when the seller described wear or defects.
    var defects: String
    var keywords: [String]
    var askingPrice: Double?
    var currencyCode: String
    var marketplace: Marketplace
    /// Selected photos, in listing order.
    var photoIDs: [UUID]
}

extension ListingContent {
    /// Whitespace-only edits aren't material: the exported text trims it.
    init(draft: ListingDraft) {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.init(
            title: clean(draft.title),
            description: clean(draft.descriptionText),
            category: clean(draft.categoryText),
            brand: clean(draft.brand),
            model: clean(draft.model),
            colour: clean(draft.colour),
            size: clean(draft.size),
            material: clean(draft.material),
            measurements: clean(draft.measurements),
            condition: draft.condition,
            defectsAssessment: draft.defectsAssessment,
            defects: draft.defectsAssessment == .described ? clean(draft.defects) : "",
            keywords: draft.keywords.map(clean).filter { !$0.isEmpty },
            askingPrice: draft.askingPrice,
            currencyCode: draft.currencyCode,
            marketplace: draft.marketplace,
            photoIDs: draft.selectedPhotoIDs
        )
    }

    /// The listing as one block of text for pasting into a marketplace.
    /// Condition and defects come from the structured answers, never from
    /// generated prose, so defects added after writing the description are
    /// always included.
    var exportText: String {
        var lines = [title, ""]
        if !description.isEmpty { lines += [description, ""] }
        let details = [
            ("Brand", brand), ("Model", model), ("Colour", colour), ("Size", size),
            ("Material", material), ("Measurements", measurements),
            ("Condition", condition?.displayName ?? ""),
        ].filter { !$0.1.isEmpty }
        lines += details.map { "\($0.0): \($0.1)" }
        switch defectsAssessment {
        case .noneFound: lines.append("Wear and defects: None found")
        case .described: lines.append("Wear and defects: \(defects)")
        case nil: break
        }
        if let askingPrice {
            lines += ["", "Price: \(Formatting.currency(askingPrice, code: currencyCode, fractionDigits: askingPrice.rounded() == askingPrice ? 0 : 2))"]
        }
        if !keywords.isEmpty {
            lines += ["", keywords.map { "#" + $0.replacingOccurrences(of: " ", with: "") }.joined(separator: " ")]
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// The exact package a seller approved: content, the text that's copied,
/// and copies of the photos (see `ApprovedPhotoStore`). Stored on the draft
/// as JSON; exports read only from here.
struct ListingSnapshot: Codable, Equatable, Sendable {
    static let currentFormat = 1

    struct Photo: Codable, Equatable, Sendable {
        var photoID: UUID
        /// File name inside the snapshot's folder.
        var fileName: String
        var sha256: String
        var byteCount: Int
    }

    var format: Int
    /// Increases with every approval of the same draft.
    var version: Int
    var approvedAt: Date
    var content: ListingContent
    var text: String
    var photos: [Photo]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) -> ListingSnapshot? {
        try? JSONDecoder().decode(ListingSnapshot.self, from: data)
    }
}

/// Why a draft can't be exported as approved.
enum ApprovalProblem: Equatable, Sendable {
    case notApproved
    /// The item is no longer marked owned, or the seller withdrew their
    /// declaration that they own it and intend to sell it.
    case ownershipChanged
    /// Text, facts, photos, price or marketplace changed after approval.
    case contentChanged
    /// An approved photo has since been marked as showing a person or removed.
    case photoNoLongerUsable
}

/// Why an approval was withdrawn, persisted so the seller sees why.
enum ApprovalInvalidation: String, Codable, Sendable {
    case ownershipChanged

    var message: String {
        switch self {
        case .ownershipChanged:
            "Ownership confirmation changed. Confirm you own this item and intend to sell it, then review and approve the listing again."
        }
    }
}

// MARK: - Workflow

extension ListingDraft {
    var content: ListingContent { ListingContent(draft: self) }

    var approvedSnapshot: ListingSnapshot? { approvedSnapshotData.flatMap(ListingSnapshot.decode) }

    /// The selected photos in order; `nil` where a photo no longer exists.
    var selectedPhotos: [ItemPhoto?] {
        let photos = item?.photos ?? []
        return selectedPhotoIDs.map { id in photos.first { $0.id == id } }
    }

    /// The item is owned and the seller has declared they own it and intend
    /// to sell it.
    var meetsOwnershipRequirements: Bool {
        (item?.ownership ?? .owned) == .owned && sellerDeclaredOwnership
    }

    var approvalProblem: ApprovalProblem? {
        guard let snapshot = approvedSnapshot, status != .draft else { return .notApproved }
        guard meetsOwnershipRequirements else { return .ownershipChanged }
        guard snapshot.content == content else { return .contentChanged }
        let usable = selectedPhotos.allSatisfy { $0?.listingEligibility == .eligible }
        return usable ? nil : .photoNoLongerUsable
    }

    var hasCurrentApproval: Bool { approvalProblem == nil }

    /// Clears an approval that no longer matches the draft. A listing the
    /// seller confirmed is live keeps its status and snapshot as a record.
    /// Returns whether anything changed.
    @discardableResult
    func invalidateApprovalIfNeeded() -> Bool {
        guard status == .approved || status == .exported, let problem = approvalProblem else { return false }
        approvedSnapshotData = nil
        approvedAt = nil
        status = .draft
        if problem == .ownershipChanged { approvalInvalidation = .ownershipChanged }
        return true
    }

    /// Copying, sharing or opening the marketplace hands the listing off.
    /// It never marks it as listed.
    @discardableResult
    func recordHandoff(at date: Date = .now) -> Bool {
        guard hasCurrentApproval, status == .approved || status == .exported else { return false }
        status = .exported
        handedOffAt = date
        return true
    }

    /// The seller says the listing is live. Rakful records this but can't verify it.
    func confirmListed(url: URL?, at date: Date = .now) -> Bool {
        guard hasCurrentApproval, status == .approved || status == .exported else { return false }
        status = .listed
        sellerConfirmedListedAt = date
        externalListingURL = url?.absoluteString
        return true
    }

    func undoListed() {
        guard status == .listed else { return }
        sellerConfirmedListedAt = nil
        externalListingURL = nil
        status = .approved
        if approvalProblem != nil {
            status = .draft
            approvedSnapshotData = nil
            approvedAt = nil
        } else if handedOffAt != nil {
            status = .exported
        }
    }

    /// Drops photos from the selection, e.g. once one is found to show a person.
    func deselectPhotos(_ ids: Set<UUID>) {
        let remaining = selectedPhotoIDs.filter { !ids.contains($0) }
        if remaining != selectedPhotoIDs { selectedPhotoIDs = remaining }
    }

    /// Workflow fields, captured so a failed save can be undone exactly.
    struct WorkflowState {
        let statusRaw: String
        let approvalVersion: Int
        let approvedSnapshotData: Data?
        let approvedAt: Date?
        let handedOffAt: Date?
        let sellerConfirmedListedAt: Date?
        let externalListingURL: String?
        let approvalInvalidationRaw: String?
    }

    var workflowState: WorkflowState {
        WorkflowState(statusRaw: statusRaw, approvalVersion: approvalVersion, approvedSnapshotData: approvedSnapshotData, approvedAt: approvedAt, handedOffAt: handedOffAt, sellerConfirmedListedAt: sellerConfirmedListedAt, externalListingURL: externalListingURL, approvalInvalidationRaw: approvalInvalidationRaw)
    }

    func restore(_ state: WorkflowState) {
        statusRaw = state.statusRaw
        approvalVersion = state.approvalVersion
        approvedSnapshotData = state.approvedSnapshotData
        approvedAt = state.approvedAt
        handedOffAt = state.handedOffAt
        sellerConfirmedListedAt = state.sellerConfirmedListedAt
        externalListingURL = state.externalListingURL
        approvalInvalidationRaw = state.approvalInvalidationRaw
    }
}

// MARK: - Validation and generation inputs

extension ListingDraft {
    private func value(of field: ListingField) -> String {
        switch field {
        case .title: title
        case .description: descriptionText
        case .category: categoryText
        case .brand: brand
        case .model: model
        case .colour: colour
        case .size: size
        case .material: material
        case .measurements: measurements
        case .defects: defects
        case .keywords: keywords.joined(separator: ", ")
        case .condition: condition?.displayName ?? ""
        case .price, .photos: ""
        }
    }

    /// Facts that were prefilled from suggestions and still have a value the
    /// seller hasn't confirmed. Blank unconfirmed fields aren't claims.
    var unconfirmedValues: [ListingField: String] {
        var values: [ListingField: String] = [:]
        for field in uncertainFields where ListingValidator.factualFields.contains(field) {
            if let value = value(of: field).nilIfBlank { values[field] = value }
        }
        return values
    }

    private func confirmedValue(_ field: ListingField) -> String? {
        uncertainFields.contains(field) ? nil : value(of: field).nilIfBlank
    }

    var itemName: String {
        item?.customName?.nilIfBlank ?? item?.suggestedName ?? categoryText
    }

    var claimEvidence: ClaimEvidence {
        ClaimEvidence(
            brand: confirmedValue(.brand) ?? "",
            model: confirmedValue(.model) ?? "",
            colour: confirmedValue(.colour) ?? "",
            size: confirmedValue(.size) ?? "",
            material: confirmedValue(.material) ?? "",
            measurements: confirmedValue(.measurements) ?? "",
            itemName: itemName,
            category: item?.category.displayName ?? categoryText,
            notes: item?.notes ?? "",
            defects: defectsAssessment == .described ? defects : "",
            condition: condition,
            defectsAssessment: defectsAssessment
        )
    }

    /// Claims in the title, description or keywords that the confirmed
    /// details don't support and the seller hasn't confirmed.
    var unsupportedClaims: [ListingClaim] {
        let text = [title, descriptionText, keywords.joined(separator: " ")].joined(separator: "\n")
        let confirmed = confirmedClaims
        return ListingClaimChecker.unsupportedClaims(in: text, evidence: claimEvidence).filter { !confirmed.contains($0.id) }
    }

    /// Only confirmed facts go to a generator, so generated text can't
    /// repeat a suggestion the seller hasn't checked.
    var listingFacts: ListingFacts {
        let estimate = item?.latestEstimate
        return ListingFacts(
            category: item?.category ?? .other,
            itemNoun: itemName,
            brand: confirmedValue(.brand),
            model: confirmedValue(.model),
            colour: confirmedValue(.colour),
            size: confirmedValue(.size),
            material: confirmedValue(.material),
            condition: condition,
            notes: item?.notes,
            marketplace: marketplace,
            estimate: estimate?.range,
            estimateMedian: estimate?.median,
            estimateKind: estimate?.kind
        )
    }

    func validationInput() -> ListingValidationInput {
        ListingValidationInput(
            ownership: item?.ownership ?? .owned,
            sellerDeclaredOwnership: sellerDeclaredOwnership,
            title: title,
            description: descriptionText,
            condition: condition,
            defectsAssessment: defectsAssessment,
            defects: defects,
            askingPrice: askingPrice,
            photos: selectedPhotos.map { $0?.listingEligibility },
            hasOnlyPhotosOfPeople: item?.isOnlySeenWorn ?? false,
            isSample: isDemo,
            marketplace: marketplace,
            category: item?.category ?? .other,
            size: size,
            unconfirmedValues: unconfirmedValues,
            unsupportedClaims: unsupportedClaims
        )
    }
}
