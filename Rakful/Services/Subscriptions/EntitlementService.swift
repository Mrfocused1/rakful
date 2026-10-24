import Foundation
import Observation
import StoreKit

/// Derives the subscription tier from verified StoreKit 2 transactions.
@MainActor
@Observable
final class EntitlementService {
    private(set) var verifiedTier: SubscriptionTier = .free
    private(set) var activeProductIDs: Set<String> = []
    private(set) var hasLoaded = false

    #if DEBUG
    /// Debug builds only: lets developers exercise gated features without a
    /// purchase. Compiled out of release builds.
    var debugTierOverride: SubscriptionTier?
    #endif

    private var updatesTask: Task<Void, Never>?

    var tier: SubscriptionTier {
        #if DEBUG
        return debugTierOverride ?? verifiedTier
        #else
        return verifiedTier
        #endif
    }

    var limits: EntitlementLimits { .limits(for: tier) }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        var ids = Set<String>()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if let expiration = transaction.expirationDate, expiration < .now { continue }
            ids.insert(transaction.productID)
        }
        activeProductIDs = ids
        verifiedTier = ProductCatalog.tier(forEntitledProductIDs: ids)
        hasLoaded = true
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await refresh()
    }
}
