import Foundation
import SwiftData

/// A price estimate produced by a pricing provider from real comparable data,
/// or sample data clearly flagged with `isDemo`.
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

    init(
        providerName: String,
        kind: PriceKind,
        currencyCode: String,
        low: Double,
        high: Double,
        median: Double? = nil,
        sampleSize: Int,
        confidence: ConfidenceLevel,
        isDemo: Bool = false
    ) {
        self.id = UUID()
        self.createdAt = .now
        self.providerName = providerName
        self.kindRaw = kind.rawValue
        self.currencyCode = currencyCode
        self.low = low
        self.high = high
        self.median = median
        self.sampleSize = sampleSize
        self.confidenceRaw = confidence.rawValue
        self.isDemo = isDemo
    }

    var kind: PriceKind { PriceKind(rawValue: kindRaw) ?? .estimatedRange }
    var confidence: ConfidenceLevel { ConfidenceLevel(rawValue: confidenceRaw) ?? .low }
    var range: PriceRange { PriceRange(low: low, high: high, currencyCode: currencyCode) }
}

/// One comparable listing or sale that supports an estimate.
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

    init(title: String, price: Double, currencyCode: String, kind: PriceKind, sourceName: String, urlString: String? = nil, observedAt: Date) {
        self.id = UUID()
        self.title = title
        self.price = price
        self.currencyCode = currencyCode
        self.kindRaw = kind.rawValue
        self.sourceName = sourceName
        self.urlString = urlString
        self.observedAt = observedAt
    }

    var kind: PriceKind { PriceKind(rawValue: kindRaw) ?? .activeAsking }
    var url: URL? { urlString.flatMap(URL.init(string:)) }
}
