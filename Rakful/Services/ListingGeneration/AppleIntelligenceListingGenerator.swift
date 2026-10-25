import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum ListingGeneratorFactory {
    /// The on-device Apple Intelligence model when available and enabled;
    /// otherwise the deterministic template generator.
    static func best(useAppleIntelligence: Bool) -> any ListingGenerator {
        #if canImport(FoundationModels)
        if useAppleIntelligence, #available(iOS 26.0, *), AppleIntelligenceListingGenerator.isAvailable {
            return AppleIntelligenceListingGenerator()
        }
        #endif
        return TemplateListingGenerator()
    }

    static var appleIntelligenceStatus: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Available"
            case .unavailable(.deviceNotEligible): return "Not supported on this iPhone"
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings"
            case .unavailable(.modelNotReady): return "Model is downloading"
            case .unavailable: return "Unavailable"
            }
        }
        #endif
        return "Requires iOS 26"
    }
}

#if canImport(FoundationModels)
/// Writes listing text with Apple's on-device language model. The model is
/// given only confirmed facts and instructed not to add any; its output is
/// then checked, and anything that adds an unsupported brand, material,
/// size, measurement, authenticity or condition claim falls back to the
/// template. The seller reviews the exact text before approving it.
@available(iOS 26.0, *)
struct AppleIntelligenceListingGenerator: ListingGenerator {
    let name = "Apple Intelligence"

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Generable
    struct Output {
        @Guide(description: "A concise marketplace listing title using only the provided facts")
        var title: String
        @Guide(description: "A friendly, factual listing description of 2 to 4 short sentences using only the provided facts")
        var description: String
        @Guide(description: "Up to 6 lowercase search keywords taken from the provided facts")
        var keywords: [String]
    }

    func generate(from facts: ListingFacts) async throws -> GeneratedListing {
        let template = try await TemplateListingGenerator().generate(from: facts)

        let session = LanguageModelSession(instructions: """
            You write second-hand marketplace listings. Use ONLY the facts provided. \
            Never add a brand, model, size, material, measurements, specifications, age, \
            or authenticity claims that are not in the facts. Don't describe the item's \
            condition, wear or defects: they're listed separately. \
            If a fact is missing, leave it out. Do not mention prices. British English.
            """)
        let response = try await session.respond(to: Self.prompt(for: facts), generating: Output.self)
        let output = response.content

        guard Self.respectsFacts(output, facts: facts) else { return template }

        var uncertain = template.uncertainFields
        uncertain.insert(.description)
        let keywords = TemplateListingGenerator.uniqueLowercased(output.keywords).prefix(6)
        return GeneratedListing(
            title: TemplateListingGenerator.truncate(output.title.trimmingCharacters(in: .whitespacesAndNewlines), to: facts.marketplace.titleCharacterLimit),
            description: output.description.trimmingCharacters(in: .whitespacesAndNewlines),
            category: template.category,
            keywords: keywords.isEmpty ? template.keywords : Array(keywords),
            uncertainFields: uncertain,
            recommendedPrice: template.recommendedPrice,
            priceRationale: template.priceRationale,
            generatorName: name
        )
    }

    static func prompt(for facts: ListingFacts) -> String {
        var lines = ["Item: \(facts.itemNoun)", "Category: \(facts.category.displayName)"]
        if let brand = facts.brand?.nilIfBlank { lines.append("Brand: \(brand)") }
        if let model = facts.model?.nilIfBlank { lines.append("Model: \(model)") }
        if let colour = facts.colour?.nilIfBlank { lines.append("Colour: \(colour)") }
        if let size = facts.size?.nilIfBlank { lines.append("Size: \(size)") }
        if let material = facts.material?.nilIfBlank { lines.append("Material: \(material)") }
        if let notes = facts.notes?.nilIfBlank { lines.append("Seller notes: \(notes)") }
        lines.append("Marketplace: \(facts.marketplace.displayName)")
        return "Write a listing from these facts:\n" + lines.joined(separator: "\n")
    }

    /// Rejects output with any claim the facts don't support, including
    /// brands that are also everyday words.
    static func respectsFacts(_ output: Output, facts: ListingFacts) -> Bool {
        let text = [output.title, output.description, output.keywords.joined(separator: " ")].joined(separator: "\n")
        return ListingClaimChecker.unsupportedClaims(in: text, evidence: ClaimEvidence(facts: facts), includeAmbiguousBrands: true).isEmpty
    }
}
#endif
