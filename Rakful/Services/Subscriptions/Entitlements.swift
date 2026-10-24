import Foundation

enum SubscriptionTier: Int, Comparable, Sendable, CaseIterable {
    case free = 0
    case plus = 1
    case pro = 2

    var displayName: String {
        switch self {
        case .free: "Rakful Free"
        case .plus: "Rakful Plus"
        case .pro: "Rakful Pro"
        }
    }

    var shortName: String {
        switch self {
        case .free: "Free"
        case .plus: "Plus"
        case .pro: "Pro"
        }
    }

    static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What each tier unlocks. All gating in the app reads from here so features
/// follow actual StoreKit entitlements.
struct EntitlementLimits: Sendable, Equatable {
    /// Photos that can be analysed per calendar month. `nil` = unlimited.
    var monthlyPhotoAllowance: Int?
    /// Listing drafts that can be open at once. `nil` = unlimited.
    var maxActiveDrafts: Int?
    var chargeAndDiscover: Bool
    var bulkListingTools: Bool
    var advancedPricing: Bool

    static func limits(for tier: SubscriptionTier) -> EntitlementLimits {
        switch tier {
        case .free:
            EntitlementLimits(monthlyPhotoAllowance: 1_000, maxActiveDrafts: 3, chargeAndDiscover: false, bulkListingTools: false, advancedPricing: false)
        case .plus:
            EntitlementLimits(monthlyPhotoAllowance: 20_000, maxActiveDrafts: nil, chargeAndDiscover: true, bulkListingTools: false, advancedPricing: false)
        case .pro:
            EntitlementLimits(monthlyPhotoAllowance: nil, maxActiveDrafts: nil, chargeAndDiscover: true, bulkListingTools: true, advancedPricing: true)
        }
    }

    /// Remaining photo allowance for the month, or `nil` when unlimited.
    func remainingPhotoAllowance(usedThisMonth: Int) -> Int? {
        monthlyPhotoAllowance.map { max(0, $0 - usedThisMonth) }
    }

    func canCreateDraft(activeDraftCount: Int) -> Bool {
        guard let maxActiveDrafts else { return true }
        return activeDraftCount < maxActiveDrafts
    }
}

enum ProductCatalog {
    static let subscriptionGroupName = "Rakful"
    static let plusMonthly = "com.rackful.plus.monthly"
    static let plusYearly = "com.rackful.plus.yearly"
    static let proMonthly = "com.rackful.pro.monthly"
    static let proYearly = "com.rackful.pro.yearly"

    static let allProductIDs = [plusMonthly, plusYearly, proMonthly, proYearly]

    static func tier(for productID: String) -> SubscriptionTier {
        switch productID {
        case proMonthly, proYearly: .pro
        case plusMonthly, plusYearly: .plus
        default: .free
        }
    }

    /// Highest tier among currently entitled product IDs.
    static func tier(forEntitledProductIDs ids: some Sequence<String>) -> SubscriptionTier {
        ids.map(tier(for:)).max() ?? .free
    }
}
