import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Rakful

// MARK: - Test doubles

/// Serves listing photos from memory, or fails with a given problem.
struct MockListingPhotoLoader: ListingPhotoLoading {
    var problems: [UUID: ListingPhotoProblem] = [:]

    static func bytes(for id: UUID) -> Data { Data("jpeg-\(id.uuidString)".utf8) }

    func image(for photo: PhotoRef, maxPixel: CGFloat) async throws -> CGImage {
        if let problem = problems[photo.id] { throw problem }
        return Fixtures.pixel
    }

    func listingData(for photo: PhotoRef) async throws -> Data {
        if let problem = problems[photo.id] { throw problem }
        return Self.bytes(for: photo.id)
    }
}

struct MockPersonChecker: PersonChecking {
    var result: PersonCheck
    func check(_ image: CGImage) async -> PersonCheck { result }
}

struct TestSaveError: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

/// A complete, approvable clothing listing with checked photos.
@MainActor
struct ListingFixture {
    let container: ModelContainer
    let context: ModelContext
    let item: CandidateItem
    let draft: ListingDraft
    let store: ApprovedPhotoStore
    var loader = MockListingPhotoLoader()

    init(photoChecks: [PersonCheck] = [.noPersonDetected, .noPersonDetected, .noPersonDetected], container: ModelContainer? = nil) throws {
        self.container = try container ?? Fixtures.makeContainer()
        context = self.container.mainContext
        store = ApprovedPhotoStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("rakful-tests-\(UUID().uuidString)"))
        item = CandidateItem(category: .clothing, suggestedName: "Denim Jacket", confidence: 0.9)
        context.insert(item)
        item.setOwnership(.owned)
        for (index, check) in photoChecks.enumerated() {
            item.photos.append(ItemPhoto(importedFileName: "photo\(index).jpg", source: .camera, isPrimary: index == 0, sortIndex: index, personCheck: check))
        }
        draft = ListingDraft(item: item, currencyCode: "GBP", marketplace: .vinted)
        context.insert(draft)
        draft.title = "Denim Jacket Blue Size M"
        draft.descriptionText = "Denim jacket.\nPlease see photos for full details."
        draft.colour = "Blue"
        draft.size = "M"
        draft.condition = .good
        draft.defectsAssessment = .noneFound
        draft.askingPrice = 25
        draft.sellerDeclaredOwnership = true
        draft.selectedPhotoIDs = item.sortedPhotos.map(\.id)
        try context.save()
    }

    var approval: ListingApproval { ListingApproval(store: store, loader: loader) }

    @discardableResult
    func approve() async throws -> ListingSnapshot {
        let preview = try await approval.prepare(draft)
        return try approval.approve(draft, preview: preview, in: context)
    }

    func events(_ kind: ActivityKind) throws -> [ActivityEvent] {
        let raw = kind.rawValue
        return try context.fetch(FetchDescriptor<ActivityEvent>(predicate: #Predicate { $0.kindRaw == raw }))
    }
}

// MARK: - Photos

@MainActor
@Suite("Listing photos")
struct ListingPhotoTests {
    @Test func nothingIsEligibleWithoutACheckOrAReview() {
        for source in [PhotoSource.camera, .imported, .library] {
            #expect(ItemPhoto(importedFileName: "x.jpg", source: source).listingEligibility == .unchecked, "New \(source) photos start unchecked")
        }
        let failed = ItemPhoto(source: .camera, personCheck: .failed)
        #expect(failed.listingEligibility == .needsReview, "A failed check never means suitable")
        failed.userReview = .confirmedNoPerson
        #expect(failed.listingEligibility == .eligible, "The seller can review it themselves")

        let person = ItemPhoto(source: .library, personCheck: .personDetected)
        person.userReview = .confirmedNoPerson
        #expect(person.listingEligibility == .showsPerson, "A detected person always excludes the photo")
        #expect(person.showsPerson)

        let clear = ItemPhoto(source: .camera, personCheck: .noPersonDetected)
        #expect(clear.listingEligibility == .eligible)
        clear.userReview = .markedShowsPerson
        #expect(clear.listingEligibility == .showsPerson, "The seller can exclude a photo the check missed")
        #expect(clear.showsPerson)
    }

    @Test func uncheckedFailedAndExcludedPhotosCannotBeApproved() async throws {
        let fixture = try ListingFixture(photoChecks: [.unchecked, .failed, .personDetected])
        await #expect {
            try await fixture.approval.prepare(fixture.draft)
        } throws: { error in
            guard case ApprovalError.notReady(let issues) = error else { return false }
            let messages = issues.map(\.message)
            return messages.contains("Photo 1 is still being checked for people.")
                && messages.contains { $0.hasPrefix("Photo 2 couldn't be checked automatically") }
                && messages.contains("Photo 3 shows a person. Remove it from the listing.")
        }
        #expect(fixture.draft.status == .draft)
        #expect(fixture.draft.approvedSnapshot == nil)

        // The seller reviews the failed one and removes the others.
        fixture.item.sortedPhotos[1].userReview = .confirmedNoPerson
        fixture.draft.selectedPhotoIDs = [fixture.item.sortedPhotos[1].id]
        let snapshot = try await fixture.approve()
        #expect(snapshot.photos.map(\.photoID) == [fixture.item.sortedPhotos[1].id])
    }

    @Test func reviewerChecksNewPhotosAndExcludesPeople() async throws {
        let fixture = try ListingFixture(photoChecks: [.noPersonDetected, .unchecked])
        let added = fixture.item.sortedPhotos[1]
        let reviewer = ListingPhotoReviewer(saves: SaveFailureCenter(), loader: MockListingPhotoLoader(), checker: MockPersonChecker(result: .personDetected))
        await reviewer.check(added, in: fixture.context)
        #expect(added.personCheck == .personDetected)
        #expect(added.listingEligibility == .showsPerson)
        #expect(!fixture.draft.selectedPhotoIDs.contains(added.id), "A photo showing a person leaves the listing")
    }

    @Test func checksThatCantRunNeedTheSellersReview() async throws {
        let fixture = try ListingFixture(photoChecks: [.unchecked, .unchecked])
        let (first, second) = (fixture.item.sortedPhotos[0], fixture.item.sortedPhotos[1])

        let unavailableModel = ListingPhotoReviewer(saves: SaveFailureCenter(), loader: MockListingPhotoLoader(), checker: MockPersonChecker(result: .failed))
        await unavailableModel.check(first, in: fixture.context)
        #expect(first.listingEligibility == .needsReview)

        let missingFile = ListingPhotoReviewer(saves: SaveFailureCenter(), loader: MockListingPhotoLoader(problems: [second.id: .missing]), checker: MockPersonChecker(result: .noPersonDetected))
        await missingFile.check(second, in: fixture.context)
        #expect(second.listingEligibility == .needsReview)
        #expect(missingFile.problem(for: second) == .missing)
        #expect(missingFile.problem(for: second)?.recovery == .remove)
    }

    @Test func unavailablePhotosBlockApprovalWithARecovery() async throws {
        var fixture = try ListingFixture()
        let photos = fixture.item.sortedPhotos
        fixture.loader = MockListingPhotoLoader(problems: [photos[0].id: .notShared, photos[2].id: .couldNotLoad])
        await #expect(throws: ApprovalError.photosUnavailable([
            PhotoPreparationFailure(photoID: photos[0].id, position: 1, problem: .notShared),
            PhotoPreparationFailure(photoID: photos[2].id, position: 3, problem: .couldNotLoad),
        ])) {
            try await fixture.approval.prepare(fixture.draft)
        }
        #expect(ListingPhotoProblem.notShared.recovery == .changeSharedPhotos)
        #expect(ListingPhotoProblem.accessDenied.recovery == .openSettings)
        #expect(ListingPhotoProblem.couldNotLoad.recovery == .tryAgain)
        #expect(fixture.draft.status == .draft, "The draft is untouched")
    }

    @Test func markingAnApprovedPhotoAsShowingAPersonClearsTheApproval() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        let reviewer = ListingPhotoReviewer(saves: SaveFailureCenter(), loader: MockListingPhotoLoader(), checker: MockPersonChecker(result: .noPersonDetected))
        reviewer.markShowsPerson(fixture.item.sortedPhotos[0], in: fixture.context)
        #expect(fixture.draft.status == .draft)
        #expect(fixture.draft.approvedSnapshot == nil)
        #expect(throws: ListingExportError.notApproved) { try ListingExporter.package(for: fixture.draft, store: fixture.store) }
    }
}

// MARK: - Content accuracy

@Suite("Listing claims")
struct ListingClaimTests {
    let evidence = ClaimEvidence(brand: "Levi's", colour: "Blue", size: "UK 10", itemName: "Denim Jacket", category: "Clothing", condition: .good, defectsAssessment: .described)

    func claims(_ text: String, _ evidence: ClaimEvidence? = nil, generated: Bool = false) -> [String] {
        ListingClaimChecker.unsupportedClaims(in: text, evidence: evidence ?? self.evidence, includeAmbiguousBrands: generated).map(\.id)
    }

    @Test func supportedFactsAreNotClaims() {
        #expect(claims("Levi's denim jacket in blue, size UK 10. Good condition.").isEmpty)
        #expect(claims("Levis Denim Jacket UK10").isEmpty)
    }

    @Test func unsupportedBrandMaterialSizeAndMeasurementsAreFlagged() {
        #expect(claims("Like Nike but better") == ["brand:nike"])
        #expect(claims("Soft wool lining, faux leather collar") == ["material:wool", "material:faux leather"])
        #expect(claims("Size 12, fits UK 12") == ["size:size 12", "size:uk 12"])
        #expect(claims("Pit to pit 56, length 70cm") == ["measurement:70cm", "measurement:pit to pit 56"])
        #expect(claims("Waist 32\"") == ["measurement:32\""])
    }

    @Test func authenticityAndConditionClaimsAreFlagged() {
        #expect(claims("Genuine vintage piece, 100% real") == ["authenticity:genuine", "authenticity:100 real", "authenticity:vintage"])
        #expect(claims("Brand new, flawless, barely worn") == ["condition:brand new", "condition:flawless", "condition:barely worn"])
        var fair = evidence
        fair.condition = .fair
        #expect(claims("In good condition", fair) == ["condition:good condition"])
    }

    @Test func conditionClaimsMatchingTheAnswersAreSupported() {
        var new = evidence
        new.condition = .newWithTags
        new.defectsAssessment = .noneFound
        #expect(claims("Brand new with tags, no defects", new).isEmpty)
        var notes = evidence
        notes.notes = "Barely worn"
        #expect(claims("Barely worn", notes).isEmpty, "The seller's own notes support it")
    }

    @Test func everydayWordsOnlyCountAsBrandsInGeneratedText() {
        #expect(claims("Smart enough for a coach trip").isEmpty)
        #expect(claims("Smart enough for a coach trip", generated: true) == ["brand:coach"])
    }

    @MainActor
    @Test func suggestedFactsMustBeConfirmedOrCleared() throws {
        let fixture = try ListingFixture()
        fixture.draft.brand = "Nike"
        fixture.draft.uncertainFields = [.brand]
        let validator = ListingValidator()
        let issue = try #require(validator.validate(fixture.draft.validationInput()).first { $0.field == .brand })
        #expect(issue.severity == .error)
        #expect(issue.actions == [.confirmField(.brand), .clearField(.brand)])
        #expect(!fixture.draft.listingFacts.brand.isPresent, "Generators never see unconfirmed facts")

        fixture.draft.brand = ""
        #expect(validator.isReady(fixture.draft.validationInput()), "Clearing an unconfirmed suggestion resolves it")
        fixture.draft.brand = "Nike"
        fixture.draft.markConfirmed(.brand)
        #expect(validator.isReady(fixture.draft.validationInput()), "So does confirming it")
        #expect(fixture.draft.listingFacts.brand == "Nike")
    }

    @MainActor
    @Test func unsupportedClaimsMustBeConfirmedOrOmitted() throws {
        let fixture = try ListingFixture()
        let validator = ListingValidator()
        fixture.draft.descriptionText = "Genuine leather jacket."
        let errors = validator.validate(fixture.draft.validationInput()).filter { $0.severity == .error }
        #expect(errors.count == 2)
        #expect(errors.flatMap(\.actions).contains(.addMaterial("leather")))

        fixture.draft.material = "Leather"
        fixture.draft.confirmedClaims.insert("authenticity:genuine")
        #expect(validator.isReady(fixture.draft.validationInput()))

        fixture.draft.confirmedClaims = []
        fixture.draft.descriptionText = "Leather jacket."
        #expect(validator.isReady(fixture.draft.validationInput()), "Omitting the claim resolves it")
    }

    @MainActor
    @Test func unknownOptionalDetailsDontBlockAListing() throws {
        let fixture = try ListingFixture()
        let draft = fixture.draft
        draft.title = "Denim Jacket"
        draft.descriptionText = "Denim jacket."
        for field in [\ListingDraft.brand, \.model, \.colour, \.size, \.material, \.measurements] { draft[keyPath: field] = "" }
        draft.uncertainFields = [.size, .model]
        let issues = ListingValidator().validate(draft.validationInput())
        #expect(!issues.contains { $0.severity == .error }, "\(issues.map(\.message))")
        #expect(issues.map(\.message) == ["Add the size if you know it. Buyers often search by size."])
    }
}

@MainActor
final class Counter {
    var value = 0
}

private extension Optional {
    var isPresent: Bool { self != nil }
}

// MARK: - Approval and export

@MainActor
@Suite("Listing approval and export")
struct ListingApprovalTests {
    @Test func defectsAreRequiredAndAlwaysExported() async throws {
        let fixture = try ListingFixture()
        let draft = fixture.draft
        draft.defectsAssessment = nil
        #expect(ListingValidator().validate(draft.validationInput()).contains { $0.message == "Say whether you found any wear or defects." })
        draft.defectsAssessment = .described
        #expect(ListingValidator().validate(draft.validationInput()).contains { $0.message == "Describe the wear or defects you found." })

        // Text generated first, defects recorded afterwards.
        let generated = try await TemplateListingGenerator().generate(from: draft.listingFacts)
        draft.title = generated.title
        draft.descriptionText = generated.description
        draft.defects = "Small ink mark on the left cuff"
        try await fixture.approve()

        let package = try ListingExporter.package(for: draft, store: fixture.store)
        #expect(package.text.contains("Wear and defects: Small ink mark on the left cuff"))
        #expect(package.text.contains("Condition: Good"))
        #expect(!generated.description.contains("ink mark"), "It wasn't in the generated prose")
    }

    @Test func noDefectsFoundIsStatedExplicitly() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        #expect(try ListingExporter.package(for: fixture.draft, store: fixture.store).text.contains("Wear and defects: None found"))
    }

    @Test func exportsExactlyTheApprovedSnapshot() async throws {
        let fixture = try ListingFixture()
        let preview = try await fixture.approval.prepare(fixture.draft)
        let snapshot = try fixture.approval.approve(fixture.draft, preview: preview, in: fixture.context)

        #expect(fixture.draft.status == .approved)
        #expect(snapshot.version == 1)
        #expect(snapshot.text == preview.text)
        #expect(snapshot.content == fixture.draft.content)
        #expect(try fixture.events(.listingApproved).count == 1)

        let package = try ListingExporter.package(for: fixture.draft, store: fixture.store)
        #expect(package.text == snapshot.text)
        #expect(package.marketplace == .vinted)
        let exported = try package.photoURLs.map { try Data(contentsOf: $0) }
        #expect(exported == fixture.item.sortedPhotos.map { MockListingPhotoLoader.bytes(for: $0.id) }, "Same photos, same order, same bytes")

        // A tampered or missing file is refused rather than silently swapped.
        try Data("other".utf8).write(to: package.photoURLs[1])
        #expect(throws: ListingExportError.photosUnavailable) { try ListingExporter.package(for: fixture.draft, store: fixture.store) }
    }

    @Test func reapprovalIncrementsTheVersion() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        fixture.draft.askingPrice = 30
        fixture.draft.invalidateApprovalIfNeeded()
        let second = try await fixture.approve()
        #expect(second.version == 2)
        #expect(second.content.askingPrice == 30)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(draftID: fixture.draft.id, version: 1).path), "Old approval photos are removed")
    }

    nonisolated static let materialEdits: [(String, @MainActor (ListingDraft) -> Void)] = [
        ("title", { $0.title += " Vintage Wash" }),
        ("description", { $0.descriptionText = "Classic denim jacket." }),
        ("brand", { $0.brand = "Levi's" }),
        ("size", { $0.size = "L" }),
        ("material", { $0.material = "Cotton" }),
        ("condition", { $0.condition = .likeNew }),
        ("defects", { $0.defectsAssessment = .described; $0.defects = "Loose button" }),
        ("keywords", { $0.keywords = ["denim"] }),
        ("price", { $0.askingPrice = 26 }),
        ("currency", { $0.currencyCode = "EUR" }),
        ("marketplace", { $0.marketplace = .depop }),
        ("photo order", { $0.selectedPhotoIDs = $0.selectedPhotoIDs.reversed() }),
        ("photo removed", { $0.selectedPhotoIDs.removeLast() }),
    ]

    @Test(arguments: 0..<materialEdits.count)
    func materialEditsInvalidateApproval(index: Int) async throws {
        let (name, edit) = Self.materialEdits[index]
        let fixture = try ListingFixture()
        try await fixture.approve()
        edit(fixture.draft)

        #expect(fixture.draft.approvalProblem == .contentChanged, "Editing the \(name)")
        #expect(throws: ListingExportError.approvalOutdated) { try ListingExporter.package(for: fixture.draft, store: fixture.store) }
        #expect(fixture.draft.invalidateApprovalIfNeeded())
        #expect(fixture.draft.status == .draft)
        #expect(fixture.draft.approvedSnapshot == nil)
    }

    @Test func whitespaceAndNonMaterialChangesKeepTheApproval() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        fixture.draft.title += "  "
        fixture.draft.confirmedClaims.insert("authenticity:rare")
        fixture.draft.touch()
        #expect(fixture.draft.hasCurrentApproval)
        #expect(!fixture.draft.invalidateApprovalIfNeeded())
    }

    @Test func approvalIsRefusedIfTheDraftChangesDuringReview() async throws {
        let fixture = try ListingFixture()
        let preview = try await fixture.approval.prepare(fixture.draft)
        fixture.draft.askingPrice = 99
        #expect(throws: ApprovalError.changedDuringReview) {
            try fixture.approval.approve(fixture.draft, preview: preview, in: fixture.context)
        }
        #expect(fixture.draft.status == .draft)
    }
}

// MARK: - Handoff

@MainActor
@Suite("Manual handoff")
struct HandoffTests {
    @Test func copyingSharingOrOpeningNeverMarksListed() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()

        try ListingExporter.recordHandoff(fixture.draft, in: fixture.context)
        #expect(fixture.draft.status == .exported)
        #expect(fixture.draft.status.displayName == "Handed Off")
        #expect(fixture.draft.sellerConfirmedListedAt == nil)
        try ListingExporter.recordHandoff(fixture.draft, in: fixture.context)
        #expect(fixture.draft.status == .exported, "Repeating a handoff still isn't a listing")
        #expect(try fixture.events(.listingHandedOff).count == 1)
        #expect(try fixture.events(.listingConfirmedListed).isEmpty)
    }

    @Test func handoffRequiresACurrentApproval() async throws {
        let fixture = try ListingFixture()
        #expect(throws: ListingExportError.approvalOutdated) { try ListingExporter.recordHandoff(fixture.draft, in: fixture.context) }
        #expect(fixture.draft.status == .draft)
    }

    @Test func sellerConfirmsListingWithAnOptionalLink() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        try ListingExporter.recordHandoff(fixture.draft, in: fixture.context)
        let url = try #require(ListingExporter.listingURL(from: "vinted.co.uk/items/123-denim"))
        try ListingExporter.confirmListed(fixture.draft, url: url, in: fixture.context)
        #expect(fixture.draft.status == .listed)
        #expect(fixture.draft.externalListingURL == "https://vinted.co.uk/items/123-denim")
        #expect(fixture.draft.status.detail == "Confirmed by you")
        #expect(try fixture.events(.listingConfirmedListed).count == 1)

        try ListingExporter.undoListed(fixture.draft, in: fixture.context)
        #expect(fixture.draft.status == .exported)
        #expect(fixture.draft.externalListingURL == nil)
    }

    @Test func listingLinksMustBeWebAddresses() {
        #expect(ListingExporter.listingURL(from: "https://www.ebay.co.uk/itm/123")?.host() == "www.ebay.co.uk")
        #expect(ListingExporter.listingURL(from: "  depop.com/products/abc ")?.absoluteString == "https://depop.com/products/abc")
        #expect(ListingExporter.listingURL(from: "not a link") == nil)
        #expect(ListingExporter.listingURL(from: "ftp://example.com/x") == nil)
        #expect(ListingExporter.listingURL(from: "localhost") == nil)
        #expect(ListingExporter.listingURL(from: "") == nil)
    }

    @Test func failedExportLeavesTheDraftIntact() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        let before = (fixture.draft.workflowState.statusRaw, fixture.draft.approvedSnapshotData, fixture.draft.content)
        try FileManager.default.removeItem(at: fixture.store.directory(draftID: fixture.draft.id, version: 1))

        #expect(throws: ListingExportError.photosUnavailable) { try ListingExporter.package(for: fixture.draft, store: fixture.store) }
        #expect(fixture.draft.status == .approved)
        #expect(fixture.draft.workflowState.statusRaw == before.0)
        #expect(fixture.draft.approvedSnapshotData == before.1)
        #expect(fixture.draft.content == before.2)
    }

    @Test func aFailedSaveUndoesTheHandoff() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        #expect(throws: ListingExportError.couldNotSave("The disk is full.")) {
            try ListingExporter.recordHandoff(fixture.draft, in: fixture.context) { throw TestSaveError() }
        }
        #expect(fixture.draft.status == .approved, "Not shown as handed off when it wasn't saved")
        #expect(fixture.draft.handedOffAt == nil)
        #expect(try fixture.events(.listingHandedOff).isEmpty)

        #expect(throws: ListingExportError.self) {
            try ListingExporter.confirmListed(fixture.draft, url: nil, in: fixture.context) { throw TestSaveError() }
        }
        #expect(fixture.draft.status == .approved)
        #expect(fixture.draft.sellerConfirmedListedAt == nil)
    }
}

// MARK: - Persistence

@MainActor
@Suite("Persistence failures")
struct PersistenceFailureTests {
    @Test func failedApprovalSaveLeavesTheDraftUnapproved() async throws {
        let fixture = try ListingFixture()
        let preview = try await fixture.approval.prepare(fixture.draft)
        #expect(throws: ApprovalError.couldNotSave("The disk is full.")) {
            try fixture.approval.approve(fixture.draft, preview: preview, in: fixture.context) { throw TestSaveError() }
        }
        #expect(fixture.draft.status == .draft)
        #expect(fixture.draft.approvedSnapshot == nil)
        #expect(fixture.draft.approvalVersion == 0)
        #expect(try fixture.events(.listingApproved).isEmpty)

        // Retrying once saving works approves the same package.
        try fixture.approval.approve(fixture.draft, preview: preview, in: fixture.context)
        #expect(fixture.draft.status == .approved)
    }

    @Test func saveFailuresAreReportedWithARetry() {
        let saves = SaveFailureCenter()
        let attempts = Counter()
        let succeeded = saves.attempt("Saving your listing") {
            attempts.value += 1
            if attempts.value == 1 { throw TestSaveError() }
        }
        #expect(!succeeded, "Never reports success when the save failed")
        #expect(saves.current?.action == "Saving your listing")
        #expect(saves.current?.message == "The disk is full.")

        saves.retry()
        #expect(attempts.value == 2)
        #expect(saves.current == nil)
    }

    @Test func aReadOnlyStoreSurfacesItsSaveFailure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rakful-readonly-\(UUID().uuidString).store")
        _ = try PersistenceController.makeContainer(url: url)
        let configuration = ModelConfiguration(schema: PersistenceController.schema, url: url, allowsSave: false)
        let container = try ModelContainer(for: PersistenceController.schema, configurations: [configuration])
        let context = container.mainContext
        context.insert(CandidateItem(category: .clothing, suggestedName: "Jacket", confidence: 1))
        let saves = SaveFailureCenter()
        #expect(!saves.save(context, "Saving the item"))
        #expect(saves.current != nil)
    }

    @Test func anUnopenableStoreFallsBackVisibly() throws {
        struct Corrupt: LocalizedError { var errorDescription: String? { "The file is damaged." } }
        let (_, mode) = PersistenceController.loadContainer(open: { throw Corrupt() }, fallback: { try Fixtures.makeContainer() })
        #expect(mode == .temporary(reason: "The file is damaged."))
        #expect(mode.isTemporary)

        var attempts = 0
        let (_, recovered) = PersistenceController.loadContainer(open: {
            attempts += 1
            if attempts == 1 { throw Corrupt() }
            return try Fixtures.makeContainer()
        })
        #expect(recovered == .persistent, "A transient failure is retried before falling back")
    }
}

// MARK: - Ownership

@MainActor
@Suite("Ownership and approval")
struct OwnershipApprovalTests {
    static let message = "Ownership confirmation changed. Confirm you own this item and intend to sell it, then review and approve the listing again."

    func expectExportBlocked(_ fixture: ListingFixture, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: ListingExportError.ownershipChanged, sourceLocation: sourceLocation) {
            try ListingExporter.package(for: fixture.draft, store: fixture.store)
        }
        #expect(throws: ListingExportError.ownershipChanged, sourceLocation: sourceLocation) {
            try ListingExporter.recordHandoff(fixture.draft, in: fixture.context)
        }
        #expect(throws: ListingExportError.ownershipChanged, sourceLocation: sourceLocation) {
            try ListingExporter.confirmListed(fixture.draft, url: nil, in: fixture.context)
        }
    }

    @Test func withdrawingTheDeclarationBlocksExport() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        fixture.draft.sellerDeclaredOwnership = false

        #expect(fixture.draft.status == .draft)
        #expect(fixture.draft.approvedSnapshot == nil)
        #expect(fixture.draft.approvalInvalidation == .ownershipChanged)
        #expect(fixture.draft.approvalInvalidation?.message == Self.message)
        #expect(ListingExportError.ownershipChanged.errorDescription == Self.message)
        expectExportBlocked(fixture)
    }

    @Test(arguments: [OwnershipStatus.unsure, .notOwned, .unconfirmed])
    func changingOwnershipBlocksExport(to status: OwnershipStatus) async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        fixture.item.setOwnership(status)

        #expect(fixture.draft.status == .draft)
        #expect(fixture.draft.approvalInvalidation == .ownershipChanged)
        expectExportBlocked(fixture)
    }

    @Test func withdrawingAfterHandoffBlocksSellerConfirmation() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        try ListingExporter.recordHandoff(fixture.draft, in: fixture.context)
        #expect(fixture.draft.status == .exported)

        fixture.draft.sellerDeclaredOwnership = false
        #expect(throws: ListingExportError.ownershipChanged) {
            try ListingExporter.confirmListed(fixture.draft, url: ListingExporter.listingURL(from: "vinted.co.uk/items/1"), in: fixture.context)
        }
        #expect(fixture.draft.status == .draft)
        #expect(fixture.draft.sellerConfirmedListedAt == nil)
        #expect(try fixture.events(.listingConfirmedListed).isEmpty)
    }

    @Test func restoringOwnershipDoesNotRestoreTheOldApproval() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        fixture.item.setOwnership(.unsure)
        fixture.draft.sellerDeclaredOwnership = false
        fixture.item.setOwnership(.owned)
        fixture.draft.sellerDeclaredOwnership = true

        #expect(fixture.draft.meetsOwnershipRequirements)
        #expect(fixture.draft.status == .draft)
        #expect(fixture.draft.approvedSnapshot == nil)
        #expect(!fixture.draft.hasCurrentApproval)
        #expect(fixture.draft.approvalInvalidation == .ownershipChanged, "The reason stays until the seller approves again")
        expectExportBlocked(fixture)
    }

    @Test func reapprovingAfterRestoringOwnershipExports() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        fixture.item.setOwnership(.notOwned)
        fixture.item.setOwnership(.owned)

        let second = try await fixture.approve()
        #expect(second.version == 2)
        #expect(fixture.draft.approvalInvalidation == nil)
        #expect(try ListingExporter.package(for: fixture.draft, store: fixture.store).version == 2)
        try ListingExporter.recordHandoff(fixture.draft, in: fixture.context)
        try ListingExporter.confirmListed(fixture.draft, url: nil, in: fixture.context)
        #expect(fixture.draft.status == .listed)
    }

    @Test func aHandoffScreenOpenedEarlierCannotUseItsCachedPackage() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        let cached = try ListingExporter.package(for: fixture.draft, store: fixture.store)
        #expect(!cached.text.isEmpty)

        // Ownership changes elsewhere while the handoff screen is open. Each
        // action fetches the package again rather than reusing `cached`.
        fixture.item.ownership = .notOwned
        expectExportBlocked(fixture)
        #expect(fixture.draft.status == .draft)
        #expect(fixture.draft.handedOffAt == nil)
        #expect(try fixture.events(.listingHandedOff).isEmpty)
    }

    @Test func ownershipChangedOutsideTheEditorIsSavedWithTheItem() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        // The path Item Detail, Wardrobe and the review queue use.
        fixture.item.setOwnership(.unsure)
        try fixture.context.save()

        let id = fixture.draft.id
        let reloaded = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<ListingDraft>(predicate: #Predicate { $0.id == id })).first)
        #expect(reloaded.status == .draft)
        #expect(reloaded.approvedSnapshotData == nil)
        #expect(reloaded.approvalInvalidation == .ownershipChanged)
    }

    @Test func aFailedSaveOrAReloadNeverRestoresApproval() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rakful-ownership-\(UUID().uuidString).store")
        let fixture = try ListingFixture(container: try PersistenceController.makeContainer(url: url))
        try await fixture.approve()
        fixture.item.setOwnership(.notOwned)

        // A failed save is reported, and the withdrawal stays in effect.
        let saves = SaveFailureCenter()
        #expect(!saves.attempt("Saving your answer") { throw TestSaveError() })
        #expect(saves.current != nil)
        #expect(fixture.draft.status == .draft)
        expectExportBlocked(fixture)

        // Once saved, reopening the store keeps it withdrawn, even after
        // ownership is restored.
        try fixture.context.save()
        let reopenedContainer = try PersistenceController.makeContainer(url: url)
        let reopened = reopenedContainer.mainContext
        let id = fixture.draft.id
        let draft = try #require(try reopened.fetch(FetchDescriptor<ListingDraft>(predicate: #Predicate { $0.id == id })).first)
        #expect(draft.status == .draft)
        #expect(draft.approvedSnapshot == nil)
        #expect(draft.approvalInvalidation == .ownershipChanged)
        draft.item?.setOwnership(.owned)
        #expect(draft.approvalProblem == .notApproved)
        #expect(throws: ListingExportError.ownershipChanged) { try ListingExporter.package(for: draft, store: fixture.store) }
    }

    @Test func listedRecordsStayIntactButCannotBeExportedAgain() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        try ListingExporter.recordHandoff(fixture.draft, in: fixture.context)
        try ListingExporter.confirmListed(fixture.draft, url: ListingExporter.listingURL(from: "ebay.co.uk/itm/1"), in: fixture.context)
        let record = (fixture.draft.approvedSnapshotData, fixture.draft.sellerConfirmedListedAt, fixture.draft.handedOffAt, fixture.draft.externalListingURL)

        fixture.item.setOwnership(.notOwned)
        fixture.draft.sellerDeclaredOwnership = false

        #expect(fixture.draft.status == .listed, "Rakful doesn't imply the listing was taken down")
        #expect(fixture.draft.approvedSnapshotData == record.0)
        #expect(fixture.draft.sellerConfirmedListedAt == record.1)
        #expect(fixture.draft.handedOffAt == record.2)
        #expect(fixture.draft.externalListingURL == record.3)
        #expect(fixture.draft.approvalInvalidation == nil)
        #expect(try fixture.events(.listingConfirmedListed).count == 1)
        #expect(throws: ListingExportError.ownershipChanged) { try ListingExporter.package(for: fixture.draft, store: fixture.store) }
    }

    @Test func unchangedValidListingsExportNormally() async throws {
        let fixture = try ListingFixture()
        try await fixture.approve()
        let package = try ListingExporter.package(for: fixture.draft, store: fixture.store)
        #expect(package.photoURLs.count == 3)
        try ListingExporter.recordHandoff(fixture.draft, in: fixture.context)
        try ListingExporter.confirmListed(fixture.draft, url: nil, in: fixture.context)
        #expect(fixture.draft.status == .listed)
        #expect(fixture.draft.approvalInvalidation == nil)
        #expect(try ListingExporter.package(for: fixture.draft, store: fixture.store).text == package.text)
    }
}

