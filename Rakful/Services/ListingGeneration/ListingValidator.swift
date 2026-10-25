import Foundation

struct ListingIssue: Sendable, Hashable, Identifiable {
    enum Severity: Sendable, Hashable { case error, warning }

    /// A one-tap fix offered next to the issue.
    enum Action: Sendable, Hashable {
        case confirmField(ListingField)
        case clearField(ListingField)
        case confirmClaim(ListingClaim)
        case useAsBrand(String)
        case addMaterial(String)
        case reviewPhotos
    }

    var severity: Severity
    var field: ListingField?
    var message: String
    var actions: [Action] = []

    var id: String { "\(severity)-\(field?.rawValue ?? "general")-\(message)" }
}

struct ListingValidationInput: Sendable, Equatable {
    var ownership: OwnershipStatus
    /// The seller confirmed they own the item and intend to sell it.
    var sellerDeclaredOwnership: Bool
    var title: String
    var description: String
    var condition: ItemCondition?
    var defectsAssessment: DefectsAssessment?
    var defects: String
    var askingPrice: Double?
    /// The selected photos in order; `nil` where a photo no longer exists.
    var photos: [PhotoEligibility?]
    /// The item has photos, but all of them show a person.
    var hasOnlyPhotosOfPeople = false
    /// Sample items have artwork instead of photos.
    var isSample = false
    var marketplace: Marketplace
    var category: ResaleCategory = .other
    var size = ""
    /// Prefilled suggestions that still have a value and aren't confirmed.
    var unconfirmedValues: [ListingField: String] = [:]
    /// Claims in the text the confirmed details don't support.
    var unsupportedClaims: [ListingClaim] = []
}

/// Checks a draft before it can be approved. Errors block; warnings are
/// shown but don't block. Optional details (model, material, measurements…)
/// can stay blank; anything stated must be confirmed.
struct ListingValidator: Sendable {
    var recommendedPhotoCount = 3

    /// Facts a suggestion can prefill, which the seller must confirm or clear.
    static let factualFields: Set<ListingField> = [.category, .brand, .model, .colour, .size, .material, .measurements]

    func validate(_ input: ListingValidationInput) -> [ListingIssue] {
        var issues: [ListingIssue] = []
        func error(_ field: ListingField?, _ message: String, _ actions: [ListingIssue.Action] = []) {
            issues.append(ListingIssue(severity: .error, field: field, message: message, actions: actions))
        }
        func warning(_ field: ListingField?, _ message: String) { issues.append(ListingIssue(severity: .warning, field: field, message: message)) }

        if input.ownership != .owned {
            error(nil, "Confirm you own this item before listing it.")
        } else if !input.sellerDeclaredOwnership {
            error(nil, "Confirm you own this item and intend to sell it.")
        }

        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            error(.title, "Add a title.")
        } else if let limit = input.marketplace.titleCharacterLimit, title.count > limit {
            error(.title, "\(input.marketplace.displayName) titles can be up to \(limit) characters.")
        }

        if input.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { error(.description, "Add a description.") }
        if input.condition == nil { error(.condition, "Select the item's condition.") }

        let defects = input.defects.trimmingCharacters(in: .whitespacesAndNewlines)
        switch input.defectsAssessment {
        case nil:
            error(.defects, "Say whether you found any wear or defects.")
        case .described where defects.isEmpty:
            error(.defects, "Describe the wear or defects you found.")
        case .noneFound:
            if let condition = input.condition, condition.expectsDefectDescription {
                warning(.defects, "Items in \(condition.displayName.lowercased()) condition usually have some wear. Check your defects answer.")
            }
        case .described:
            break
        }

        if let price = input.askingPrice {
            if price <= 0 { error(.price, "Enter an asking price above zero.") }
        } else {
            error(.price, "Enter an asking price.")
        }

        validatePhotos(input, error: error, warning: warning)

        for field in ListingField.allCases where input.unconfirmedValues[field] != nil {
            let value = input.unconfirmedValues[field] ?? ""
            error(field, "Confirm or remove the suggested \(field.displayName.lowercased()) “\(value)”.", [.confirmField(field), .clearField(field)])
        }

        for claim in input.unsupportedClaims {
            var actions: [ListingIssue.Action] = []
            switch claim.kind {
            case .brand: actions.append(.useAsBrand(claim.term))
            case .material: actions.append(.addMaterial(claim.term))
            default: break
            }
            actions.append(.confirmClaim(claim))
            error(nil, claim.message + " Edit the text, or confirm it's accurate.", actions)
        }

        if input.size.trimmingCharacters(in: .whitespaces).isEmpty, input.category == .clothing || input.category == .trainers {
            warning(.size, "Add the size if you know it. Buyers often search by size.")
        }

        if let term = Self.restrictedTerm(in: "\(input.title) \(input.description)") {
            let rules = input.marketplace == .other ? "the marketplace's" : "\(input.marketplace.displayName)'s"
            warning(nil, "Marketplaces ban or restrict some items, such as “\(term)”. Check \(rules) rules before listing.")
        }
        return issues
    }

    private func validatePhotos(
        _ input: ListingValidationInput,
        error: (ListingField?, String, [ListingIssue.Action]) -> Void,
        warning: (ListingField?, String) -> Void
    ) {
        guard !input.isSample else { return }
        if input.photos.isEmpty {
            error(.photos, input.hasOnlyPhotosOfPeople
                  ? "Add a photo of the item on its own. Photos that show a person aren't used in listings."
                  : "Choose at least one photo for the listing.", [.reviewPhotos])
            return
        }
        for (index, photo) in input.photos.enumerated() {
            let number = index + 1
            switch photo {
            case .eligible: continue
            case nil: error(.photos, "Photo \(number) is no longer available. Remove it from the listing.", [.reviewPhotos])
            case .showsPerson?: error(.photos, "Photo \(number) shows a person. Remove it from the listing.", [.reviewPhotos])
            case .unchecked?: error(.photos, "Photo \(number) is still being checked for people.", [.reviewPhotos])
            case .needsReview?: error(.photos, "Photo \(number) couldn't be checked automatically. Look at it and confirm there are no people in it.", [.reviewPhotos])
            }
        }
        if input.photos.count < recommendedPhotoCount {
            warning(.photos, "Listings with \(recommendedPhotoCount) or more photos tend to sell faster.")
        }
    }

    func isReady(_ input: ListingValidationInput) -> Bool {
        !validate(input).contains { $0.severity == .error }
    }

    /// Items eBay UK and most marketplaces ban or restrict: weapons, alcohol,
    /// tobacco, medicines and counterfeits. Matched by whole word and only
    /// warned about, since a legitimate item can share a word.
    static let restrictedTerms = [
        "knife", "knives", "sword", "machete", "firearm", "handgun", "pistol", "rifle", "shotgun", "ammunition",
        "crossbow", "taser", "stun gun", "pepper spray", "alcohol", "whisky", "whiskey", "vodka", "vape",
        "e-cigarette", "e-liquid", "tobacco", "cigarettes", "prescription", "medication", "counterfeit",
    ]

    static func restrictedTerm(in text: String) -> String? {
        let words = text.lowercased().split { !$0.isLetter && $0 != "-" }.joined(separator: " ")
        return restrictedTerms.first { " \(words) ".contains(" \($0) ") }
    }
}
