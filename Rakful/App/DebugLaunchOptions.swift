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
///     -RRTab items                 select a tab
///     -RRShowFirstItem             open the first item's detail
///     -RRShowFirstDraft            create/open a listing for the first owned item
///     -RRMarkDraftListed           then mark it listed (shows the celebration)
///     -RRShowReview                present the review queue
///     -RRAutoDiscover              start a manual discovery
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
            jacket.photos.append(ItemPhoto(assetLocalIdentifier: "debug-worn", source: .library, isPrimary: true, showsPerson: true))
            jacket.setOwnership(.owned)
            try? context.save()
        }

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
                    draft.status = .handedOff
                    draft.handedOffAt = .now
                }
            }
        }
        if arguments.contains("-RRShowReview") { router.isReviewQueuePresented = true }
        if arguments.contains("-RRAutoDiscover") {
            Task { await environment.discovery.start(mode: .manual, canPromptForAccess: true) }
        }
    }
}
#endif
