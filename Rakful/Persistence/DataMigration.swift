import Foundation
import SwiftData

/// Explicit upgrades for records created before listing approvals.
///
/// SwiftData migrates the schema itself: every property added for approvals
/// has a default, so existing stores open as before. This step then fixes
/// up values whose meaning changed. It's idempotent and runs at each launch;
/// the predicates only match records that still need it.
@MainActor
enum DataMigration {
    /// `ListingDraft.dataVersion` once a draft has been upgraded.
    nonisolated static let currentDraftVersion = 1

    struct Report: Equatable {
        var listedDrafts = 0
        var photos = 0
        var drafts = 0
    }

    @discardableResult
    static func run(in context: ModelContext) throws -> Report {
        var report = Report()

        // Photos: before checks were tracked, `showsPerson == false` could mean
        // "no person" or "the check failed". Treat it as unchecked so it's
        // checked again; never as suitable for a listing.
        for photo in try context.fetch(FetchDescriptor<ItemPhoto>(predicate: #Predicate { $0.personCheckRaw == nil })) {
            photo.personCheckRaw = (photo.showsPerson ? PersonCheck.personDetected : .unchecked).rawValue
            report.photos += 1
        }

        let legacyHandedOff = ListingStatus.legacyHandedOffRawValue
        let version = currentDraftVersion
        for draft in try context.fetch(FetchDescriptor<ListingDraft>(predicate: #Predicate { $0.dataVersion < version || $0.statusRaw == legacyHandedOff })) {
            // "handedOff" was set only by the seller tapping "Mark as Listed".
            if draft.statusRaw == legacyHandedOff {
                draft.statusRaw = ListingStatus.listed.rawValue
                draft.sellerConfirmedListedAt = draft.handedOffAt ?? draft.updatedAt
                report.listedDrafts += 1
            }
            // Defects typed before the question existed were a description;
            // an empty field stays unanswered rather than "none found".
            if draft.defectsAssessmentRaw == nil, draft.defects.nilIfBlank != nil {
                draft.defectsAssessment = .described
            }
            // Previously every photo not showing a person was used; keep that
            // choice as the selection. Each still has to pass a check.
            if draft.status.isActive, draft.selectedPhotoIDsRaw.isEmpty, let item = draft.item {
                draft.selectedPhotoIDs = item.distinctPhotos.filter { !$0.showsPerson }.map(\.id)
            }
            draft.dataVersion = version
            report.drafts += 1
        }

        if context.hasChanges { try context.save() }
        return report
    }
}
