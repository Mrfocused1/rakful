import StoreKit
import SwiftUI

/// Apple's native subscription store. Prices, terms and purchase flow come
/// from StoreKit; Rakful shows no invented savings or earnings claims.
struct PlansView: View {
    @Environment(EntitlementService.self) private var entitlements

    var body: some View {
        SubscriptionStoreView(productIDs: ProductCatalog.allProductIDs) {
            VStack(spacing: 18) {
                Image(systemName: "bolt.batteryblock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Brand.accent)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Rakful Plus & Pro").font(.title.weight(.bold))
                    Text("Your current plan: \(entitlements.tier.shortName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    FeatureLine(systemImage: "bolt.batteryblock", title: "Charge & Discover", detail: "Analyse photos while your phone charges, when the system allows.")
                    FeatureLine(systemImage: "photo.stack", title: "More photos each month", detail: "20,000 with Plus. Unlimited with Pro. Free includes 1,000.")
                    FeatureLine(systemImage: "square.and.pencil", title: "Unlimited listing drafts", detail: "Free includes 3 open drafts.")
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .cancellation)
        .storeButton(.visible, for: .policies)
        .subscriptionStorePolicyDestination(url: LegalLinks.termsOfUse, for: .termsOfService)
        .subscriptionStorePolicyDestination(for: .privacyPolicy) {
            NavigationStack { PrivacyPolicyView() }
        }
        .onInAppPurchaseCompletion { _, _ in
            await entitlements.refresh()
        }
    }
}

private struct FeatureLine: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SubscriptionStatusView: View {
    @Environment(EntitlementService.self) private var entitlements
    @Environment(AppRouter.self) private var router
    @State private var showsManage = false
    @State private var restoreMessage: String?
    @State private var isRestoring = false

    var body: some View {
        let limits = entitlements.limits
        List {
            Section {
                LabeledContent("Plan", value: entitlements.tier.displayName)
                LabeledContent("Photos per Month", value: limits.monthlyPhotoAllowance.map { Formatting.count($0) } ?? "Unlimited")
                LabeledContent("Open Listing Drafts", value: limits.maxActiveDrafts.map(String.init) ?? "Unlimited")
                LabeledContent("Charge & Discover", value: limits.chargeAndDiscover ? "Included" : "Not included")
            } footer: {
                if !entitlements.hasLoaded {
                    Text("Checking your subscription…")
                }
            }
            Section {
                Button(entitlements.tier == .free ? "View Plans" : "Change Plan") { router.isPlansPresented = true }
                if entitlements.tier != .free {
                    Button("Manage Subscription") { showsManage = true }
                }
                Button {
                    restore()
                } label: {
                    HStack {
                        Text("Restore Purchases")
                        if isRestoring { Spacer(); ProgressView() }
                    }
                }
                .disabled(isRestoring)
                if let restoreMessage {
                    Text(restoreMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Subscriptions are billed through your Apple Account and can be cancelled at any time in Settings.")
            }
            Section {
                NavigationLink("Privacy Policy") { PrivacyPolicyView() }
                Link("Terms of Use", destination: LegalLinks.termsOfUse)
            }
        }
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $showsManage)
    }

    private func restore() {
        isRestoring = true
        restoreMessage = nil
        Task {
            do {
                try await entitlements.restorePurchases()
                restoreMessage = entitlements.tier == .free ? "No active subscriptions were found." : "Restored \(entitlements.tier.displayName)."
            } catch {
                restoreMessage = "Purchases couldn't be restored. \(error.localizedDescription)"
            }
            isRestoring = false
        }
    }
}
