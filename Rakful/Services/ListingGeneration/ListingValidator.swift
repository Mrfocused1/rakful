import Foundation

struct ListingIssue: Sendable, Hashable, Identifiable {
    enum Severity: Sendable, Hashable { case error, warning }

    var severity: Severity
    var field: ListingField?
    var message: String

    var id: String { "\(severity)-\(field?.rawValue ?? "general")-\(message)" }
}

struct ListingValidationInput: Sendable, Equatable {
    var ownership: OwnershipStatus
    var title: String
    var description: String
    var condition: ItemCondition?
    var defects: String
    var askingPrice: Double?
    /// Photos that may go in the listing (not those showing a person).
    var photoCount: Int
    /// The item has photos, but all of them show a person.
    var hasOnlyPhotosOfPeople = false
    var marketplace: Marketplace
    var uncertainFields: Set<ListingField>
}

/// Checks a draft before it can be handed off or published. Errors block;
/// warnings are shown but don't block.
struct ListingValidator: Sendable {
    var recommendedPhotoCount = 3

    func validate(_ input: ListingValidationInput) -> [ListingIssue] {
        var issues: [ListingIssue] = []
        func error(_ field: ListingField?, _ message: String) { issues.append(ListingIssue(severity: .error, field: field, message: message)) }
        func warning(_ field: ListingField?, _ message: String) { issues.append(ListingIssue(severity: .warning, field: field, message: message)) }

        if input.ownership != .owned { error(nil, "Confirm you own this item before listing it.") }

        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            error(.title, "Add a title.")
        } else if let limit = input.marketplace.titleCharacterLimit, title.count > limit {
            error(.title, "\(input.marketplace.displayName) titles can be up to \(limit) characters.")
        }

        if input.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { error(.description, "Add a description.") }
        if input.condition == nil { error(.condition, "Select the item's condition.") }

        if let price = input.askingPrice {
            if price <= 0 { error(.price, "Enter an asking price above zero.") }
        } else {
            error(.price, "Enter an asking price.")
        }

        if input.photoCount == 0 {
            error(nil, input.hasOnlyPhotosOfPeople
                  ? "Add a photo of the item on its own. Photos that show a person aren't used in listings."
                  : "Add at least one photo.")
        } else if input.photoCount < recommendedPhotoCount {
            warning(nil, "Listings with \(recommendedPhotoCount) or more photos tend to sell faster.")
        }

        if let condition = input.condition, condition.expectsDefectDescription, input.defects.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warning(.condition, "Describe any wear or defects for items in \(condition.displayName.lowercased()) condition.")
        }

        if let term = Self.restrictedTerm(in: "\(input.title) \(input.description)") {
            let rules = input.marketplace == .other ? "the marketplace's" : "\(input.marketplace.displayName)'s"
            warning(nil, "Marketplaces ban or restrict some items, such as “\(term)”. Check \(rules) rules before listing.")
        }

        for field in input.uncertainFields.sorted(by: { $0.rawValue < $1.rawValue }) where field != .price {
            warning(field, "Review \(field.displayName.lowercased()) — it hasn't been confirmed.")
        }
        return issues
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
