import Foundation

/// Marketplaces Rakful can prepare listings for.
///
/// Only eBay offers documented seller APIs Rakful can use (subject to
/// developer approval). Every other marketplace uses manual handoff: the user
/// copies the prepared listing and posts it themselves. No scraping, no
/// automated account interaction.
enum Marketplace: String, Codable, Sendable, CaseIterable, Identifiable {
    case ebay
    case vinted
    case depop
    case facebook
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ebay: "eBay"
        case .vinted: "Vinted"
        case .depop: "Depop"
        case .facebook: "Facebook Marketplace"
        case .other: "Other"
        }
    }

    enum PublishingMethod: Sendable {
        /// Official seller API; requires a connected account and the Rakful server.
        case sellerAPI
        /// The user posts the listing themselves.
        case manualHandoff
    }

    var publishingMethod: PublishingMethod {
        self == .ebay ? .sellerAPI : .manualHandoff
    }

    /// Maximum title length enforced by the marketplace, where documented.
    var titleCharacterLimit: Int? {
        switch self {
        case .ebay: 80
        default: nil
        }
    }

    /// eBay's own search of completed sales, so people can see what similar
    /// items sold for and choose their own price. eBay's API licence doesn't
    /// allow suggesting prices from eBay data, so Rakful links out
    /// instead of estimating. Terms contained in a longer term are dropped
    /// ("Nike" + "Nike Air Max" searches "Nike Air Max").
    static func soldListingsURL(for terms: [String?]) -> URL? {
        let cleaned = terms.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var kept: [String] = []
        for (index, term) in cleaned.enumerated() {
            let lower = term.lowercased()
            let coveredByOther = cleaned.enumerated().contains { other in
                other.offset != index && other.element.lowercased().contains(lower)
                    && (other.element.count > term.count || other.offset < index)
            }
            if !coveredByOther { kept.append(term) }
        }
        guard !kept.isEmpty, var components = URLComponents(string: "https://www.ebay.co.uk/sch/i.html") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "_nkw", value: kept.joined(separator: " ")),
            URLQueryItem(name: "LH_Sold", value: "1"),
            URLQueryItem(name: "LH_Complete", value: "1"),
        ]
        return components.url
    }

    /// Public page where a person starts a new listing.
    var createListingURL: URL? {
        switch self {
        case .ebay: URL(string: "https://www.ebay.co.uk/sl/prelist")
        case .vinted: URL(string: "https://www.vinted.co.uk/items/new")
        case .depop: URL(string: "https://www.depop.com/products/create/")
        case .facebook: URL(string: "https://www.facebook.com/marketplace/create/item")
        case .other: nil
        }
    }
}
