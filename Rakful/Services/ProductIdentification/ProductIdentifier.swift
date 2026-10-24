import Foundation

/// A suggestion about an item's identity. Suggestions are stored as
/// `ProductIdentification` records and only applied when the user confirms.
struct IdentificationSuggestion: Sendable, Equatable {
    var source: IdentificationSource
    var category: ResaleCategory?
    var brand: String?
    var model: String?
    var colour: String?
    var confidence: Double
    var evidence: String
}

/// Turns a photo analysis into identification suggestions.
protocol ProductIdentifier: Sendable {
    var displayName: String { get }
    func identify(_ analysis: PhotoAnalysis) async -> [IdentificationSuggestion]
}

/// On-device identification. Produces the object category (from Vision) and,
/// when a known brand name is literally visible in the photo, a brand
/// suggestion. It never guesses models — Vision's general classifier cannot
/// reliably recognise specific products.
struct OnDeviceProductIdentifier: ProductIdentifier {
    var brandMatcher = BrandTextMatcher()
    let displayName = "On-Device"

    func identify(_ analysis: PhotoAnalysis) async -> [IdentificationSuggestion] {
        guard let match = analysis.match else { return [] }
        var suggestions = [
            IdentificationSuggestion(
                source: .onDeviceClassifier,
                category: match.category,
                confidence: match.score,
                evidence: "Recognised as “\(match.label.replacingOccurrences(of: "_", with: " "))”"
            ),
        ]
        for brand in brandMatcher.matches(in: analysis.recognisedText, category: match.category).prefix(2) {
            suggestions.append(IdentificationSuggestion(
                source: .onDeviceText,
                brand: brand.brand,
                confidence: 0.6,
                evidence: "Text in the photo reads “\(brand.matchedText)”"
            ))
        }
        return suggestions
    }
}

/// Adapter for a specialised cloud identification service behind the
/// Rakful server. Requires explicit consent; sends one downsized JPEG.
struct CloudProductIdentifier: Sendable {
    let client: BackendClient

    var isAvailable: Bool { client.configuration.isConfigured }

    struct Request: Encodable, Sendable {
        let imageJPEGBase64: String
        let category: String?
    }

    struct Response: Decodable, Sendable {
        struct Candidate: Decodable, Sendable {
            let brand: String?
            let model: String?
            let colour: String?
            let confidence: Double
            let evidence: String
        }
        let candidates: [Candidate]
    }

    func identify(jpegData: Data, category: ResaleCategory?, consentGiven: Bool) async throws -> [IdentificationSuggestion] {
        guard isAvailable else { throw BackendError.notConfigured }
        guard consentGiven else { throw BackendError.consentRequired }
        let response = try await client.post(
            "v1/identify",
            body: Request(imageJPEGBase64: jpegData.base64EncodedString(), category: category?.rawValue),
            as: Response.self
        )
        // Unknown products stay unidentified: low-confidence candidates are dropped.
        return response.candidates.filter { $0.confidence >= 0.5 }.map {
            IdentificationSuggestion(source: .cloudService, category: category, brand: $0.brand, model: $0.model, colour: $0.colour, confidence: $0.confidence, evidence: $0.evidence)
        }
    }
}
