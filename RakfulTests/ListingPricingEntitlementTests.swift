import Foundation
import Testing
@testable import Rakful

@Suite("Listing validation")
struct ListingValidatorTests {
    let validator = ListingValidator()

    func input(ownership: OwnershipStatus = .owned, title: String = "Running Trainers", price: Double? = 40, photos: Int = 3, condition: ItemCondition? = .good, assessment: DefectsAssessment? = .noneFound, defects: String = "", marketplace: Marketplace = .vinted) -> ListingValidationInput {
        ListingValidationInput(
            ownership: ownership, sellerDeclaredOwnership: true, title: title, description: "Lightweight running trainers.",
            condition: condition, defectsAssessment: assessment, defects: defects, askingPrice: price,
            photos: Array(repeating: .eligible, count: photos), marketplace: marketplace, category: .trainers, size: "UK 9"
        )
    }

    @Test func photosOfPeopleDontCountTowardsAListing() {
        var worn = input(photos: 0)
        worn.hasOnlyPhotosOfPeople = true
        #expect(!validator.isReady(worn))
        #expect(validator.validate(worn).contains { $0.severity == .error && $0.message.hasPrefix("Add a photo of the item on its own") })
        #expect(validator.validate(input(photos: 0)).contains { $0.message == "Choose at least one photo for the listing." })
    }

    @Test func completeListingIsReady() {
        #expect(validator.isReady(input()))
        #expect(validator.validate(input()).isEmpty)
    }

    @Test func unownedItemsCannotBeListed() {
        for status in [OwnershipStatus.unconfirmed, .notOwned, .unsure] {
            #expect(!validator.isReady(input(ownership: status)))
        }
        var undeclared = input()
        undeclared.sellerDeclaredOwnership = false
        #expect(validator.validate(undeclared).map(\.message) == ["Confirm you own this item and intend to sell it."])
    }

    @Test func requiresTitlePriceConditionAndPhotos() {
        #expect(!validator.isReady(input(title: "  ")))
        #expect(!validator.isReady(input(price: nil)))
        #expect(!validator.isReady(input(price: 0)))
        #expect(!validator.isReady(input(condition: nil)))
        #expect(!validator.isReady(input(photos: 0)))
    }

    @Test func enforcesEbayTitleLimit() {
        let long = String(repeating: "a", count: 81)
        #expect(!validator.isReady(input(title: long, marketplace: .ebay)))
        #expect(validator.isReady(input(title: long, marketplace: .vinted)))
    }

    @Test func warnsWithoutBlocking() {
        var vague = input(photos: 1, condition: .fair)
        vague.size = ""
        let issues = validator.validate(vague)
        #expect(issues.allSatisfy { $0.severity == .warning })
        #expect(issues.count == 3, "Few photos, fair condition with no defects, missing size")
    }

    @Test func warnsAboutRestrictedItemsByWholeWord() {
        let issues = validator.validate(input(title: "Chef's Knife Set", marketplace: .ebay))
        #expect(issues.map(\.message) == ["Marketplaces ban or restrict some items, such as “knife”. Check eBay's rules before listing."])
        #expect(validator.isReady(input(title: "Chef's Knife Set")), "A warning never blocks")
        #expect(ListingValidator.restrictedTerm(in: "Vintage e-cigarette case") == "e-cigarette")
        #expect(ListingValidator.restrictedTerm(in: "Pocket stun gun") == "stun gun")
        #expect(ListingValidator.restrictedTerm(in: "Swordfish print T-shirt") == nil)
        #expect(ListingValidator.restrictedTerm(in: "Massage gun, barely used") == nil)
    }
}

@Suite("Sold price links")
struct SoldPriceLinkTests {
    @Test func searchesEbayCompletedSales() throws {
        let url = try #require(Marketplace.soldListingsURL(for: ["Canon", "EOS 250D", "Compact Camera"]))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host() == "www.ebay.co.uk")
        #expect(items.first { $0.name == "_nkw" }?.value == "Canon EOS 250D Compact Camera")
        #expect(items.contains(URLQueryItem(name: "LH_Sold", value: "1")))
        #expect(items.contains(URLQueryItem(name: "LH_Complete", value: "1")))
    }

    @Test func dropsTermsRepeatedInLongerOnes() throws {
        let url = try #require(Marketplace.soldListingsURL(for: ["Nike", nil, "Nike Air Max", " "]))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Nike Air Max")
        #expect(Marketplace.soldListingsURL(for: [nil, "  "]) == nil)
    }
}

@Suite("Listing generation")
struct ListingGenerationTests {
    func facts(brand: String? = nil, size: String? = nil, condition: ItemCondition? = .good, estimate: PriceRange? = nil, median: Double? = nil, marketplace: Marketplace = .ebay) -> ListingFacts {
        ListingFacts(category: .trainers, itemNoun: "Trainers", brand: brand, model: nil, colour: "White", size: size, material: nil, condition: condition, notes: nil, marketplace: marketplace, estimate: estimate, estimateMedian: median, estimateKind: estimate == nil ? nil : .completedSale)
    }

    @Test func usesOnlyProvidedFacts() async throws {
        let listing = try await TemplateListingGenerator().generate(from: facts())
        #expect(listing.title == "Trainers White")
        #expect(!listing.description.localizedCaseInsensitiveContains("nike"))
        #expect(!listing.description.contains("Size"))
        #expect(!listing.description.contains("Condition"), "Condition and defects are added at export, not written into prose")
        #expect(listing.recommendedPrice == nil)
        #expect(ListingClaimChecker.unsupportedClaims(in: listing.title + "\n" + listing.description, evidence: ClaimEvidence(facts: facts())).isEmpty)
    }

    @Test func includesConfirmedBrandAndSize() async throws {
        let listing = try await TemplateListingGenerator().generate(from: facts(brand: "Nike", size: "UK 9"))
        #expect(listing.title.hasPrefix("Nike Trainers"))
        #expect(listing.title.contains("UK 9"))
    }

    @Test func recommendsPriceOnlyFromVerifiedEstimate() async throws {
        let range = PriceRange(low: 40, high: 60, currencyCode: "GBP")
        let listing = try await TemplateListingGenerator().generate(from: facts(estimate: range, median: 49.6))
        #expect(listing.recommendedPrice == 50)
        #expect(listing.priceRationale.contains("completed sales"))
    }

    @Test func truncatesTitlesOnWordBoundaries() {
        let title = TemplateListingGenerator.truncate("Alpha Beta Gamma Delta", to: 12)
        #expect(title == "Alpha Beta")
    }

    @Test func handoffTextContainsListing() {
        let content = ListingContent(title: "Camera", description: "Works well.", category: "Electronics", brand: "Canon", model: "", colour: "", size: "", material: "", measurements: "", condition: .good, defectsAssessment: .noneFound, defects: "", keywords: ["camera", "canon eos"], askingPrice: 120, currencyCode: "GBP", marketplace: .ebay, photoIDs: [])
        let text = content.exportText
        #expect(text.contains("Camera"))
        #expect(text.contains("Brand: Canon"))
        #expect(text.contains("£120"))
        #expect(text.contains("#canoneos"))
        #expect(!text.contains("Model:"))
    }
}

struct StubPricingProvider: PricingProvider {
    var name = "Stub"
    var isConfigured = true
    var comparables: [PriceComparable]
    func comparables(for query: PricingQuery) async throws -> [PriceComparable] { comparables }
}

@Suite("Pricing data availability")
struct PricingTests {
    let query = PricingQuery(category: .electronics, brand: "Canon", model: nil, title: nil, condition: .good, currencyCode: "GBP")

    func comparable(_ price: Double, _ kind: PriceComparable.Kind) -> PriceComparable {
        PriceComparable(title: "x", price: price, currencyCode: "GBP", kind: kind, source: "Stub", url: nil, observedAt: .now)
    }

    @Test func unavailableWithoutAConfiguredProvider() async {
        #expect(await PricingService(providers: []).lookup(query) == .unavailable(.noProviderConfigured))
        let unconfigured = StubPricingProvider(isConfigured: false, comparables: [comparable(10, .sold)])
        #expect(await PricingService(providers: [unconfigured]).lookup(query) == .unavailable(.noProviderConfigured))
    }

    @Test func requiresEnoughDetail() async {
        let vague = PricingQuery(category: .electronics, brand: nil, model: nil, title: "cam", condition: nil, currencyCode: "GBP")
        let service = PricingService(providers: [StubPricingProvider(comparables: [])])
        #expect(await service.lookup(vague) == .unavailable(.insufficientDetails))
    }

    @Test func prefersCompletedSalesAndTrimsOutliers() async throws {
        let provider = StubPricingProvider(comparables: [100, 110, 120, 130, 2000].map { comparable($0, .sold) } + [comparable(500, .active)])
        guard case .estimate(let estimate) = await PricingService(providers: [provider]).lookup(query) else {
            Issue.record("Expected an estimate"); return
        }
        #expect(estimate.kind == .completedSale)
        #expect(estimate.sampleSize == 4)
        #expect(estimate.range.high < 200)
        #expect(estimate.median == 115)
    }

    @Test func fallsBackToLabelledAskingPrices() async {
        let provider = StubPricingProvider(comparables: [comparable(80, .active), comparable(90, .active), comparable(100, .active), comparable(85, .sold)])
        guard case .estimate(let estimate) = await PricingService(providers: [provider]).lookup(query) else {
            Issue.record("Expected an estimate"); return
        }
        #expect(estimate.kind == .activeAsking)
        #expect(estimate.confidence == .low)
    }

    @Test func notEnoughComparables() async {
        let provider = StubPricingProvider(comparables: [comparable(80, .sold)])
        #expect(await PricingService(providers: [provider]).lookup(query) == .unavailable(.notEnoughComparables))
    }

    @Test func valueSummaryOnlyCountsPricedItems() {
        let summary = ValueSummary.compute(estimates: [
            PriceRange(low: 10, high: 20, currencyCode: "GBP"), nil, PriceRange(low: 5, high: 5, currencyCode: "GBP"),
            PriceRange(low: 100, high: 100, currencyCode: "USD"),
        ], currencyCode: "GBP")
        #expect(summary.range == PriceRange(low: 15, high: 25, currencyCode: "GBP"))
        #expect(summary.pricedItemCount == 2)
        #expect(summary.itemCount == 4)
    }
}

@Suite("Subscription entitlements")
struct EntitlementTests {
    @Test func tierFromProductIDs() {
        #expect(ProductCatalog.tier(forEntitledProductIDs: []) == .free)
        #expect(ProductCatalog.tier(forEntitledProductIDs: [ProductCatalog.plusMonthly]) == .plus)
        #expect(ProductCatalog.tier(forEntitledProductIDs: [ProductCatalog.plusYearly, ProductCatalog.proMonthly]) == .pro)
        #expect(ProductCatalog.tier(forEntitledProductIDs: ["com.unknown"]) == .free)
    }

    @Test func freeTierLimits() {
        let free = EntitlementLimits.limits(for: .free)
        #expect(!free.chargeAndDiscover)
        #expect(free.remainingPhotoAllowance(usedThisMonth: 400) == 600)
        #expect(free.remainingPhotoAllowance(usedThisMonth: 5_000) == 0)
        #expect(free.canCreateDraft(activeDraftCount: 2))
        #expect(!free.canCreateDraft(activeDraftCount: 3))
    }

    @Test func paidTiersUnlockFeatures() {
        let plus = EntitlementLimits.limits(for: .plus), pro = EntitlementLimits.limits(for: .pro)
        #expect(plus.chargeAndDiscover && pro.chargeAndDiscover)
        #expect(plus.canCreateDraft(activeDraftCount: 500))
        #expect(pro.remainingPhotoAllowance(usedThisMonth: 1_000_000) == nil)
        #expect(pro.bulkListingTools && !plus.bulkListingTools)
    }

    @MainActor
    @Test func debugOverrideDrivesLimitsOnlyInDebug() {
        let service = EntitlementService()
        #expect(service.tier == .free)
        service.debugTierOverride = .plus
        #expect(service.limits.chargeAndDiscover)
    }
}

@Suite("Notifications & reports")
struct ReportTests {
    @Test func morningReportOnlyForOvernightWork() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        func date(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour))! }

        let late = try #require(NotificationService.morningDeliveryDate(after: date(23), calendar: calendar))
        #expect(calendar.component(.day, from: late) == 11)
        #expect(calendar.component(.hour, from: late) == 8)
        let early = try #require(NotificationService.morningDeliveryDate(after: date(3), calendar: calendar))
        #expect(calendar.component(.day, from: early) == 10)
        #expect(NotificationService.morningDeliveryDate(after: date(14), calendar: calendar) == nil)
    }

    @Test func greetingFollowsTimeOfDay() {
        let calendar = Calendar(identifier: .gregorian)
        let morning = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8))!
        #expect(DiscoveryReport.greeting(for: morning, calendar: calendar) == "Good morning")
    }

    @Test func photoAccessStatesMapFromPhotoKit() {
        #expect(PhotoKitAssetSource.map(.authorized) == .full)
        #expect(PhotoKitAssetSource.map(.limited) == .limited)
        #expect(PhotoKitAssetSource.map(.denied) == .denied)
        #expect(PhotoKitAssetSource.map(.restricted) == .restricted)
        #expect(PhotoKitAssetSource.map(.notDetermined) == .notDetermined)
        #expect(PhotoAccessLevel.limited.canRead && PhotoAccessLevel.full.canRead)
        #expect(!PhotoAccessLevel.denied.canRead && !PhotoAccessLevel.notDetermined.canRead && !PhotoAccessLevel.restricted.canRead)
    }
}
