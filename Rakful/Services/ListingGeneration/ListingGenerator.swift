import Foundation

/// Facts the user has provided or confirmed. Generators may only use these.
struct ListingFacts: Sendable, Equatable {
    var category: ResaleCategory
    var itemNoun: String
    var brand: String?
    var brandConfirmed: Bool
    var model: String?
    var colour: String?
    var size: String?
    var condition: ItemCondition?
    var defects: String?
    var notes: String?
    var marketplace: Marketplace
    var estimate: PriceRange?
    var estimateMedian: Double?
    var estimateKind: PriceKind?
}

struct GeneratedListing: Sendable, Equatable {
    var title: String
    var description: String
    var category: String
    var keywords: [String]
    /// Fields that need the user's review before listing.
    var uncertainFields: Set<ListingField>
    /// Suggested asking price, only when backed by a verified estimate.
    var recommendedPrice: Double?
    var priceRationale: String
    var generatorName: String
}

protocol ListingGenerator: Sendable {
    var name: String { get }
    func generate(from facts: ListingFacts) async throws -> GeneratedListing
}

/// Deterministic generator that assembles a listing purely from confirmed
/// facts. Always available, fully offline, and never adds claims.
struct TemplateListingGenerator: ListingGenerator {
    let name = "On-Device Template"

    func generate(from facts: ListingFacts) async throws -> GeneratedListing {
        let brand = facts.brand?.nilIfBlank
        let model = facts.model?.nilIfBlank
        let colour = facts.colour?.nilIfBlank
        let size = facts.size?.nilIfBlank

        var titleParts = [brand, model, facts.itemNoun].compactMap { $0 }
        if let colour { titleParts.append(colour) }
        if let size { titleParts.append(Self.sizePhrase(size, category: facts.category)) }
        if let condition = facts.condition, condition == .newWithTags || condition == .newWithoutTags {
            titleParts.append(condition == .newWithTags ? "New with Tags" : "New")
        }
        let title = Self.truncate(Self.dedupeWords(titleParts.joined(separator: " ")), to: facts.marketplace.titleCharacterLimit)

        var lines: [String] = []
        lines.append(([brand, model, facts.itemNoun.lowercased()].compactMap { $0 }.joined(separator: " ") + ".").capitalizedFirst)
        if let colour { lines.append("Colour: \(colour)") }
        if let size { lines.append("Size: \(size)") }
        if let condition = facts.condition { lines.append("Condition: \(condition.displayName)") }
        if let defects = facts.defects?.nilIfBlank { lines.append("Defects: \(defects)") }
        if let notes = facts.notes?.nilIfBlank { lines.append(notes) }
        lines.append("Please see photos for full details.")

        let keywords = Self.uniqueLowercased([brand, model, facts.itemNoun, facts.category.displayName, colour].compactMap { $0 })

        var uncertain = Set<ListingField>()
        if brand != nil, !facts.brandConfirmed { uncertain.insert(.brand) }
        if facts.condition == nil { uncertain.insert(.condition) }
        if size == nil, facts.category == .clothing || facts.category == .trainers { uncertain.insert(.size) }

        let (price, rationale) = Self.recommendation(facts)
        if price == nil { uncertain.insert(.price) }

        return GeneratedListing(
            title: title,
            description: lines.joined(separator: "\n"),
            category: facts.category.displayName,
            keywords: keywords,
            uncertainFields: uncertain,
            recommendedPrice: price,
            priceRationale: rationale,
            generatorName: name
        )
    }

    static func recommendation(_ facts: ListingFacts) -> (Double?, String) {
        guard let median = facts.estimateMedian, let range = facts.estimate else {
            return (nil, "Check what similar items sold for, then enter your own asking price.")
        }
        let basis = facts.estimateKind == .completedSale ? "completed sales" : "active asking prices"
        return (median.rounded(), "Median of comparable \(basis) (\(range.formatted)).")
    }

    static func sizePhrase(_ size: String, category: ResaleCategory) -> String {
        size.lowercased().hasPrefix("size") || size.lowercased().hasPrefix("uk") ? size : "Size \(size)"
    }

    static func truncate(_ text: String, to limit: Int?) -> String {
        guard let limit, text.count > limit else { return text }
        let words = text.split(separator: " ")
        var result = ""
        for word in words {
            let candidate = result.isEmpty ? String(word) : result + " " + word
            if candidate.count > limit { break }
            result = candidate
        }
        return result.isEmpty ? String(text.prefix(limit)) : result
    }

    static func dedupeWords(_ text: String) -> String {
        var seen = Set<String>()
        return text.split(separator: " ").filter { seen.insert($0.lowercased()).inserted }.joined(separator: " ")
    }

    static func uniqueLowercased(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
