import Foundation

/// A price range in a single currency.
struct PriceRange: Sendable, Hashable {
    var low: Double
    var high: Double
    var currencyCode: String

    init(low: Double, high: Double, currencyCode: String) {
        self.low = min(low, high)
        self.high = max(low, high)
        self.currencyCode = currencyCode
    }

    var formatted: String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: currencyCode)
            .precision(.fractionLength(0))
        if low == high { return low.formatted(style) }
        return "\(low.formatted(style)) – \(high.formatted(style))"
    }

    static func + (lhs: PriceRange, rhs: PriceRange) -> PriceRange? {
        guard lhs.currencyCode == rhs.currencyCode else { return nil }
        return PriceRange(low: lhs.low + rhs.low, high: lhs.high + rhs.high, currencyCode: lhs.currencyCode)
    }
}

/// Summarises the potential resale value of a set of items. Only items with
/// an estimate in the requested currency contribute — nothing is inferred.
struct ValueSummary: Sendable, Equatable {
    var range: PriceRange?
    var itemCount: Int
    var pricedItemCount: Int

    static func compute(estimates: [PriceRange?], currencyCode: String) -> ValueSummary {
        var total: PriceRange?
        var priced = 0
        for case let estimate? in estimates where estimate.currencyCode == currencyCode {
            priced += 1
            total = total.flatMap { $0 + estimate } ?? estimate
        }
        return ValueSummary(range: total, itemCount: estimates.count, pricedItemCount: priced)
    }
}

enum Formatting {
    static func currency(_ value: Double, code: String, fractionDigits: Int = 0) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(fractionDigits)))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
