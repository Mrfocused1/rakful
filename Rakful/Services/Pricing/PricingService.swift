import Foundation

struct PricingQuery: Sendable, Equatable {
    var category: ResaleCategory
    var brand: String?
    var model: String?
    var title: String?
    var condition: ItemCondition?
    var currencyCode: String

    /// Comparable searches need at least a confirmed brand or a descriptive title.
    var isSpecificEnough: Bool {
        brand?.nilIfBlank != nil || (title?.nilIfBlank?.count ?? 0) >= 8
    }

    var searchText: String {
        [brand, model, title].compactMap { $0?.nilIfBlank }.joined(separator: " ")
    }
}

/// A single comparable listing or sale returned by a provider.
struct PriceComparable: Sendable, Equatable, Decodable {
    var title: String
    var price: Double
    var currencyCode: String
    var kind: Kind
    var source: String
    var url: String?
    var observedAt: Date

    enum Kind: String, Sendable, Decodable { case active, sold }
}

struct PricingEstimateData: Sendable, Equatable {
    var kind: PriceKind
    var range: PriceRange
    var median: Double
    var sampleSize: Int
    var confidence: ConfidenceLevel
    var providerName: String
    var comparables: [PriceComparable]
}

enum PricingUnavailableReason: Sendable, Equatable {
    case noProviderConfigured
    case insufficientDetails
    case notEnoughComparables
    case error(String)

    var message: String {
        switch self {
        case .noProviderConfigured: "No verified pricing source is connected. Rakful never estimates prices without real marketplace data."
        case .insufficientDetails: "Confirm the brand or enter a title so comparable items can be found."
        case .notEnoughComparables: "Not enough comparable listings were found to estimate a price."
        case .error(let message): message
        }
    }
}

enum PricingLookupResult: Sendable, Equatable {
    case estimate(PricingEstimateData)
    case unavailable(PricingUnavailableReason)
}

/// A source of real comparable listings/sales from a licensed data source.
/// None is wired up: eBay's API licence forbids using eBay data to suggest or
/// model prices without eBay's written consent, so the app links out to
/// eBay's sold listings instead (`Marketplace.soldListingsURL`).
protocol PricingProvider: Sendable {
    var name: String { get }
    var isConfigured: Bool { get }
    func comparables(for query: PricingQuery) async throws -> [PriceComparable]
}

struct PricingService: Sendable {
    var providers: [any PricingProvider]
    var minimumSample = 3

    var hasConfiguredProvider: Bool { providers.contains { $0.isConfigured } }

    func lookup(_ query: PricingQuery) async -> PricingLookupResult {
        let configured = providers.filter(\.isConfigured)
        guard !configured.isEmpty else { return .unavailable(.noProviderConfigured) }
        guard query.isSpecificEnough else { return .unavailable(.insufficientDetails) }

        var all: [PriceComparable] = []
        var lastError: String?
        for provider in configured {
            do { all += try await provider.comparables(for: query) } catch { lastError = error.localizedDescription }
        }
        if all.isEmpty, let lastError { return .unavailable(.error(lastError)) }
        return Self.estimate(from: all, currencyCode: query.currencyCode, providerName: configured.map(\.name).joined(separator: ", "), minimumSample: minimumSample)
            .map(PricingLookupResult.estimate) ?? .unavailable(.notEnoughComparables)
    }

    /// Completed sales are preferred over asking prices. Outliers are trimmed
    /// with the interquartile range; the range is the 25th–75th percentile.
    static func estimate(from comparables: [PriceComparable], currencyCode: String, providerName: String, minimumSample: Int = 3) -> PricingEstimateData? {
        let sameCurrency = comparables.filter { $0.currencyCode == currencyCode && $0.price > 0 }
        let sold = sameCurrency.filter { $0.kind == .sold }
        let basis = sold.count >= minimumSample ? sold : sameCurrency.filter { $0.kind == .active }
        let kind: PriceKind = sold.count >= minimumSample ? .completedSale : .activeAsking
        guard let stats = PriceStatistics.summarize(basis.map(\.price)), stats.count >= minimumSample else { return nil }

        let confidence: ConfidenceLevel
        switch (kind, stats.count) {
        case (.completedSale, 15...): confidence = .high
        case (.completedSale, 6...), (.activeAsking, 15...): confidence = .medium
        default: confidence = .low
        }
        return PricingEstimateData(
            kind: kind,
            range: PriceRange(low: stats.lowerQuartile, high: stats.upperQuartile, currencyCode: currencyCode),
            median: stats.median,
            sampleSize: stats.count,
            confidence: confidence,
            providerName: providerName,
            comparables: basis
        )
    }
}

enum PriceStatistics {
    struct Summary: Equatable {
        var lowerQuartile: Double
        var median: Double
        var upperQuartile: Double
        var count: Int
    }

    static func summarize(_ values: [Double]) -> Summary? {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count >= 3 else { return nil }
        let q1 = percentile(sorted, 0.25), q3 = percentile(sorted, 0.75)
        let iqr = q3 - q1
        let trimmed = sorted.filter { $0 >= q1 - 1.5 * iqr && $0 <= q3 + 1.5 * iqr }
        guard trimmed.count >= 3 else { return nil }
        return Summary(lowerQuartile: percentile(trimmed, 0.25), median: percentile(trimmed, 0.5), upperQuartile: percentile(trimmed, 0.75), count: trimmed.count)
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}
