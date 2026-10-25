import Foundation

/// A factual claim in listing text that the confirmed details don't back up.
struct ListingClaim: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case brand, material, size, measurement, authenticity, condition
    }

    var kind: Kind
    /// The words as they appear, lowercased (a brand uses its proper name).
    var term: String

    var id: String { "\(kind.rawValue):\(term.lowercased())" }

    var message: String {
        switch kind {
        case .brand: "Mentions “\(term)”, but that isn't the confirmed brand."
        case .material: "Mentions “\(term)”, which isn't in the material details."
        case .size: "Mentions “\(term)”, which doesn't match the size."
        case .measurement: "Mentions “\(term)”, which isn't in the measurements."
        case .authenticity: "Says “\(term)”. Rakful can't check that, so only keep it if you can back it up."
        case .condition: "Says “\(term)”, which doesn't match the condition or defects you chose."
        }
    }
}

/// The confirmed facts listing text may rely on.
struct ClaimEvidence: Sendable, Equatable {
    var brand = ""
    var model = ""
    var colour = ""
    var size = ""
    var material = ""
    var measurements = ""
    /// The item's name, e.g. "Denim Jacket".
    var itemName = ""
    var category = ""
    var notes = ""
    var defects = ""
    var condition: ItemCondition?
    var defectsAssessment: DefectsAssessment?
}

/// Finds brand, material, size, measurement, authenticity and condition
/// claims that aren't supported by confirmed facts. Deterministic and
/// deliberately conservative: it's used to reject generated text, and to
/// ask the seller to confirm or remove claims in their own text.
enum ListingClaimChecker {
    /// Brand names that are also everyday words ("coach", "converse",
    /// "swatch"). Generated text is checked against them too; the seller's
    /// own text isn't, to avoid false alarms.
    static let ambiguousBrands: Set<String> = [
        "coach", "apple", "omega", "citizen", "fossil", "beats", "fender", "converse", "vans", "tudor", "swatch", "canon", "polaroid",
    ]

    static let materials = [
        "organic cotton", "cotton", "merino wool", "merino", "lambswool", "wool", "cashmere", "mohair", "alpaca", "angora",
        "faux leather", "vegan leather", "patent leather", "leather", "suede", "nubuck", "silk", "linen", "denim",
        "polyester", "nylon", "viscose", "rayon", "acrylic", "elastane", "spandex", "lycra", "fleece", "gore tex",
        "goretex", "canvas", "velvet", "velour", "satin", "corduroy", "tweed", "faux fur", "fur", "sheepskin",
        "shearling", "bamboo", "modal", "tencel", "lyocell", "chiffon", "lace",
    ]

    static let authenticityTerms = [
        "authentic", "authenticity", "genuine", "original", "100 real", "guaranteed", "certified", "official",
        "legit", "not fake", "rare", "limited edition", "vintage", "deadstock",
    ]

    /// Claims of being new; supported only by a "new" condition.
    static let newTerms = ["brand new", "new with tags", "bnwt", "new without tags", "bnwot", "unworn", "never worn", "never used", "unused", "tags attached"]
    static let withTagsTerms: Set<String> = ["new with tags", "bnwt", "tags attached"]
    /// Claims of no wear; supported only by answering "none found" for defects.
    static let flawlessTerms = ["mint", "flawless", "perfect condition", "pristine", "immaculate", "no flaws", "no defects", "no marks", "no signs of wear", "no wear"]
    static let likeNewTerms = ["like new", "as new", "excellent condition", "great condition", "very good condition"]
    /// Wear history only the seller knows; supported if their notes say so.
    static let wearHistoryTerms = ["worn once", "barely worn", "hardly worn", "only worn", "worn a few times", "rarely worn", "lightly worn"]

    static func unsupportedClaims(in text: String, evidence: ClaimEvidence, includeAmbiguousBrands: Bool = false) -> [ListingClaim] {
        let words = normalise(text)
        guard !words.isEmpty else { return [] }
        let facts = normalise([
            evidence.brand, evidence.model, evidence.colour, evidence.size, evidence.material, evidence.measurements,
            evidence.itemName, evidence.category, evidence.notes, evidence.defects,
        ].joined(separator: " \n "))
        var claims: [ListingClaim] = []
        func add(_ kind: ListingClaim.Kind, _ term: String) {
            let claim = ListingClaim(kind: kind, term: term)
            if !claims.contains(claim) { claims.append(claim) }
        }

        // Brands
        let confirmedBrand = normalise([evidence.brand, evidence.model, evidence.itemName, evidence.notes].joined(separator: " \n "))
        for brand in BrandTextMatcher.brands {
            let names = ([brand.name] + brand.aliases).map(normalise).filter { $0.count >= 3 }
            guard let found = names.first(where: { contains($0, in: words) }) else { continue }
            if !includeAmbiguousBrands, ambiguousBrands.contains(found) { continue }
            if names.contains(where: { contains($0, in: confirmedBrand) }) { continue }
            add(.brand, brand.name)
        }

        // Materials: report the longest phrase only ("faux leather", not also "leather").
        let foundMaterials = materials.filter { contains($0, in: words) && !contains($0, in: facts) }
        for material in foundMaterials where !foundMaterials.contains(where: { $0 != material && contains(material, in: $0) }) {
            add(.material, material)
        }

        // Sizes
        let sizeFacts = Set(normalise([evidence.size, evidence.measurements, evidence.notes].joined(separator: " ")).split(separator: " ").map(String.init))
        let sizeToken = #"(\d{1,2}(?:\.5)?|xxs|xs|s|m|l|xl|xxl|xxxl|small|medium|large)"#
        for match in matches(#"\bsize\s+(?:uk\s+|eu\s+|us\s+)?"# + sizeToken + #"\b"#, in: words) where !sizeFacts.contains(match.captures[0]) {
            add(.size, match.whole)
        }
        for match in matches(#"\b(?:uk|eu)\s?(\d{1,2}(?:\.5)?)\b"#, in: words) where !sizeFacts.contains(match.captures[0]) {
            add(.size, match.whole)
        }
        for match in matches(#"\b(xxs|xs|xl|xxl|xxxl|2xl|3xl|4xl)\b"#, in: words) where !sizeFacts.contains(match.captures[0]) {
            add(.size, match.whole)
        }

        // Measurements
        let numberFacts = Set(normalise([evidence.measurements, evidence.size, evidence.notes].joined(separator: " ")).split(separator: " ").map(String.init))
        // One claim per number: `32" waist` isn't also reported as `waist 32`.
        var measuredNumbers = numberFacts
        let measurementText = text.lowercased()
        for pattern in [#"(\d+(?:\.\d+)?)\s?(?:cm|mm|inch|inches)\b"#, #"(\d+(?:\.\d+)?)(?:"|″)"#] {
            for match in matches(pattern, in: measurementText) where measuredNumbers.insert(match.captures[0]).inserted {
                add(.measurement, match.whole.trimmingCharacters(in: .whitespaces))
            }
        }
        for match in matches(#"\b(?:pit to pit|p2p|ptp|chest|waist|inseam|inside leg|sleeve|shoulders?|length)\s(?:of\s|is\s)?(\d+(?:\.\d+)?)\b"#, in: words) where measuredNumbers.insert(match.captures[0]).inserted {
            add(.measurement, match.whole)
        }

        // Authenticity and provenance
        for term in authenticityTerms where contains(term, in: words) && !contains(term, in: facts) {
            add(.authenticity, term)
        }

        // Condition
        let condition = evidence.condition
        let isNew = condition == .newWithTags || condition == .newWithoutTags
        let noDefects = evidence.defectsAssessment == .noneFound
        for term in newTerms where contains(term, in: words) {
            let supported = withTagsTerms.contains(term) ? condition == .newWithTags : isNew
            if !supported { add(.condition, term) }
        }
        for term in flawlessTerms where contains(term, in: words) && !noDefects {
            add(.condition, term)
        }
        for term in likeNewTerms where contains(term, in: words) {
            if !(noDefects && (isNew || condition == .likeNew)) { add(.condition, term) }
        }
        if contains("good condition", in: words), condition == .fair || condition == .forParts || condition == nil {
            add(.condition, "good condition")
        }
        for term in wearHistoryTerms where contains(term, in: words) && !contains(term, in: facts) {
            add(.condition, term)
        }
        return claims
    }

    // MARK: - Text helpers

    /// Lowercased, accent-free words separated by single spaces. Decimal
    /// points between digits are kept ("9.5").
    static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var result = ""
        let characters = Array(folded)
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                result.append(character)
            } else if character == ".", index > 0, index + 1 < characters.count, characters[index - 1].isNumber, characters[index + 1].isNumber {
                result.append(character)
            } else if character == "'" || character == "’" {
                continue // "Levi's" → "levis"
            } else {
                result.append(" ")
            }
        }
        return result.split(separator: " ").joined(separator: " ")
    }

    static func contains(_ phrase: String, in words: String) -> Bool {
        " \(words) ".contains(" \(phrase) ")
    }

    private struct Match {
        let whole: String
        let captures: [String]
    }

    private static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { result in
            guard let whole = Range(result.range, in: text) else { return nil }
            let captures = (1..<result.numberOfRanges).compactMap { index -> String? in
                Range(result.range(at: index), in: text).map { String(text[$0]) }
            }
            return Match(whole: String(text[whole]), captures: captures)
        }
    }
}

extension ClaimEvidence {
    /// Evidence for checking generated text: only the facts the generator was
    /// given. Condition is withheld, so generated condition claims fail.
    init(facts: ListingFacts) {
        self.init(
            brand: facts.brand ?? "",
            model: facts.model ?? "",
            colour: facts.colour ?? "",
            size: facts.size ?? "",
            material: facts.material ?? "",
            itemName: facts.itemNoun,
            category: facts.category.displayName,
            notes: facts.notes ?? ""
        )
    }
}
