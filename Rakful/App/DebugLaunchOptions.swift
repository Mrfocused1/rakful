#if DEBUG
import SwiftData
import SwiftUI

/// Debug-only launch arguments for simulator verification and UI testing.
/// Compiled out of release builds.
///
///     -rr.onboardingComplete YES   (UserDefaults argument domain)
///     -RRResetData                 erase all Rakful data first
///     -RRSeedSamples               insert labelled sample items
///     -RRSeedWornItem              add an owned jacket seen only in a photo of a person
///     -RRSeedListingItem           add an owned denim jacket with two photos taken in Rakful
///     -RRTab items                 select a tab
///     -RRShowFirstItem             open the first item's detail
///     -RRShowFirstDraft            create/open a listing for the first owned item
///     -RRMarkDraftListed           then show it as seller-confirmed listed (celebration)
///     -RRShowReview                present the review queue
///     -RRAutoDiscover              start a manual discovery
///     -RRHoldSplash                keep the launch animation on screen
@MainActor
enum DebugLaunchOptions {
    static func apply(context: ModelContext, environment: AppEnvironment) {
        let arguments = ProcessInfo.processInfo.arguments
        let router = environment.router

        if arguments.contains("-RRResetData") {
            try? DataManagement.eraseAllData(in: context, preferences: environment.preferences)
        }
        if arguments.contains("-RRSeedSamples") { try? SampleData.insert(into: context) }
        if arguments.contains("-RRSeedWornItem") {
            let jacket = CandidateItem(category: .clothing, suggestedName: "Denim Jacket", classifierLabel: "jean_jacket", confidence: 0.8)
            context.insert(jacket)
            jacket.photos.append(ItemPhoto(assetLocalIdentifier: "debug-worn", source: .library, isPrimary: true, personCheck: .personDetected))
            jacket.setOwnership(.owned)
            try? context.save()
        }
        if arguments.contains("-RRSeedListingItem") { seedListingItem(in: context) }

        if let index = arguments.firstIndex(of: "-RRTab"), arguments.indices.contains(index + 1) {
            switch arguments[index + 1] {
            case "items": router.selectedTab = .items
            case "sell": router.selectedTab = .sell
            case "activity": router.selectedTab = .activity
            case "settings": router.isSettingsPresented = true
            default: router.selectedTab = .discover
            }
        }

        let items = (try? context.fetch(FetchDescriptor<CandidateItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        if arguments.contains("-RRShowFirstItem"), let first = items.first {
            router.showItem(first.id)
        }
        if arguments.contains("-RRShowFirstDraft"), let owned = items.first(where: { $0.ownership == .owned }),
           let draft = ItemActions.prepareDraft(for: owned, in: context, preferences: environment.preferences, limits: environment.entitlements.limits) {
            router.showDraft(draft.id)
            if arguments.contains("-RRMarkDraftListed") {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    draft.status = .listed
                    draft.sellerConfirmedListedAt = .now
                }
            }
        }
        if arguments.contains("-RRShowReview") { router.isReviewQueuePresented = true }
        if arguments.contains("-RRAutoDiscover") {
            Task { await environment.discovery.start(mode: .manual, canPromptForAccess: true) }
        }
    }

    /// A real (not sample) owned clothing item with two stored photos, so the
    /// listing journey can run without photo-library access. The photos start
    /// unchecked, like any new photo.
    private static func seedListingItem(in context: ModelContext) {
        let jacket = CandidateItem(category: .clothing, suggestedName: "Denim Jacket", classifierLabel: "jean_jacket", confidence: 0.9)
        context.insert(jacket)
        for (index, hue) in [0.6, 0.58].enumerated() {
            let size = CGSize(width: 900, height: 1200)
            let image = UIGraphicsImageRenderer(size: size).image { renderer in
                UIColor(hue: 0.6, saturation: 0.05, brightness: 0.97, alpha: 1).setFill()
                renderer.fill(CGRect(origin: .zero, size: size))
                UIColor(hue: hue, saturation: 0.55, brightness: 0.6, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: 180, y: 220, width: 540, height: 760), cornerRadius: 60).fill()
            }
            guard let name = try? ImportedImageStore.save(image: image) else { continue }
            jacket.photos.append(ItemPhoto(importedFileName: name, source: .camera, capturedAt: .now, isPrimary: index == 0, sortIndex: index))
        }
        jacket.setOwnership(.owned)
        try? context.save()
    }
}
#endif
