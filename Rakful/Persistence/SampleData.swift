import Foundation
import SwiftData

/// Clearly labelled sample items for exploring Rakful before (or instead
/// of) granting photo access. Every record is flagged `isDemo`, shown as demo
/// data, excluded from real statistics, and removable in one step. Their
/// valuations are illustrative examples, never market data.
enum SampleData {
    struct Spec {
        let name: String
        let category: ResaleCategory
        let label: String
        var symbol: String?
        let confidence: Double
        let low: Double
        let high: Double
        let ownership: OwnershipStatus
    }

    static let currencyCode = "GBP"

    /// Newest first.
    static let specs: [Spec] = [
        Spec(name: "Denim Jacket", category: .clothing, label: "jean_jacket", symbol: "tshirt.fill", confidence: 0.92, low: 85, high: 120, ownership: .owned),
        Spec(name: "Trainers", category: .trainers, label: "sneaker", symbol: "shoe.fill", confidence: 0.88, low: 50, high: 80, ownership: .unconfirmed),
        Spec(name: "Wool Knit Jumper", category: .clothing, label: "sweater", symbol: "tshirt.fill", confidence: 0.82, low: 60, high: 90, ownership: .unconfirmed),
        Spec(name: "Leather Handbag", category: .bags, label: "handbag", symbol: "handbag.fill", confidence: 0.9, low: 90, high: 140, ownership: .owned),
        Spec(name: "Linen Shirt", category: .clothing, label: "shirt", symbol: "tshirt.fill", confidence: 0.74, low: 14, high: 22, ownership: .owned),
        Spec(name: "Silk Scarf", category: .accessories, label: "scarf", confidence: 0.66, low: 10, high: 18, ownership: .unconfirmed),
        Spec(name: "Chinos", category: .clothing, label: "trousers", symbol: "tshirt.fill", confidence: 0.7, low: 17, high: 28, ownership: .owned),
        Spec(name: "Leather Belt", category: .accessories, label: "belt", confidence: 0.68, low: 12, high: 20, ownership: .owned),
        Spec(name: "Canvas Tote", category: .bags, label: "tote_bag", symbol: "bag.fill", confidence: 0.72, low: 10, high: 16, ownership: .owned),
        Spec(name: "Cotton T-Shirt", category: .clothing, label: "t-shirt", symbol: "tshirt.fill", confidence: 0.8, low: 8, high: 12, ownership: .owned),
        Spec(name: "Baseball Cap", category: .accessories, label: "cap", confidence: 0.62, low: 8, high: 14, ownership: .unsure),
        Spec(name: "Beanie", category: .accessories, label: "beanie", confidence: 0.6, low: 6, high: 10, ownership: .owned),
    ]

    static func hasSampleItems(in context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<CandidateItem>(predicate: #Predicate { $0.isDemo == true }))) ?? 0) > 0
    }

    static func insert(into context: ModelContext, now: Date = .now) throws {
        guard !hasSampleItems(in: context) else { return }
        for (index, spec) in specs.enumerated() {
            let created = now.addingTimeInterval(TimeInterval(-index * 3600))
            let item = CandidateItem(
                category: spec.category,
                suggestedName: spec.name,
                classifierLabel: spec.label,
                confidence: spec.confidence,
                isDemo: true,
                demoSymbol: spec.symbol,
                createdAt: created
            )
            context.insert(item)
            if spec.ownership != .unconfirmed { item.setOwnership(spec.ownership, at: created) }
            item.identifications.append(ProductIdentification(
                source: .onDeviceClassifier,
                category: spec.category,
                confidence: spec.confidence,
                evidence: "Sample item — not from your photos"
            ))
            item.priceEstimates.append(PriceEstimate(
                providerName: "Demo data",
                kind: .estimatedRange,
                currencyCode: currencyCode,
                low: spec.low,
                high: spec.high,
                median: ((spec.low + spec.high) / 2).rounded(),
                sampleSize: 0,
                confidence: .medium,
                isDemo: true
            ))
        }
        context.logActivity(.candidateIdentified, title: "Sample items added", detail: "\(specs.count) sample items for exploring the app", isDemo: true)
        try context.save()
    }

    static func remove(from context: ModelContext) throws {
        // Per-object deletes so cascade rules remove photos, estimates and drafts.
        for item in try context.fetch(FetchDescriptor<CandidateItem>(predicate: #Predicate { $0.isDemo == true })) {
            context.delete(item)
        }
        try context.delete(model: ListingDraft.self, where: #Predicate { $0.isDemo == true })
        try context.delete(model: ActivityEvent.self, where: #Predicate { $0.isDemo == true })
        try context.save()
    }
}
