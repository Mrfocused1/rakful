import CryptoKit
import Foundation
import SwiftData

/// Copies of the exact photos a seller approved. Exports read only these,
/// so what's shared is byte-for-byte what was reviewed, and later changes to
/// the library or its permissions can't alter an approved listing.
struct ApprovedPhotoStore: Sendable {
    let baseDirectory: URL

    static var standard: ApprovedPhotoStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ApprovedPhotoStore(baseDirectory: base.appendingPathComponent("ApprovedListings", isDirectory: true))
    }

    func directory(draftID: UUID, version: Int) -> URL {
        baseDirectory.appendingPathComponent(draftID.uuidString, isDirectory: true).appendingPathComponent("v\(version)", isDirectory: true)
    }

    func url(for photo: ListingSnapshot.Photo, draftID: UUID, version: Int) -> URL {
        directory(draftID: draftID, version: version).appendingPathComponent(photo.fileName)
    }

    /// Writes the photos for an approval, replacing an earlier attempt at the same version.
    func write(_ images: [(photoID: UUID, data: Data)], draftID: UUID, version: Int) throws -> [ListingSnapshot.Photo] {
        let directory = directory(draftID: draftID, version: version)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try images.enumerated().map { index, image in
            let photo = ListingSnapshot.Photo(photoID: image.photoID, fileName: "photo-\(index + 1).jpg", sha256: Self.digest(image.data), byteCount: image.data.count)
            try image.data.write(to: directory.appendingPathComponent(photo.fileName), options: .atomic)
            return photo
        }
    }

    /// The snapshot's photo files in order, after checking none is missing or changed.
    func verifiedURLs(for snapshot: ListingSnapshot, draftID: UUID) throws -> [URL] {
        try snapshot.photos.map { photo in
            let url = url(for: photo, draftID: draftID, version: snapshot.version)
            guard let data = try? Data(contentsOf: url), Self.digest(data) == photo.sha256 else {
                throw ListingExportError.photosUnavailable
            }
            return url
        }
    }

    func removeAll(draftID: UUID) {
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(draftID.uuidString, isDirectory: true))
    }

    /// Deletes earlier approvals' photos for a draft.
    func remove(draftID: UUID, except version: Int) {
        let folder = baseDirectory.appendingPathComponent(draftID.uuidString, isDirectory: true)
        let keep = "v\(version)"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name != keep {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the approval screen shows: the draft's content, the exact text, and
/// freshly prepared copies of the selected photos, in order.
struct ApprovalPreview: Sendable, Equatable {
    let draftID: UUID
    let version: Int
    let content: ListingContent
    let text: String
    let photos: [ListingSnapshot.Photo]
    let photoURLs: [URL]
}

struct PhotoPreparationFailure: Identifiable, Sendable, Equatable {
    let photoID: UUID
    /// 1-based position in the listing.
    let position: Int
    let problem: ListingPhotoProblem
    var id: UUID { photoID }
}

enum ApprovalError: Error, Equatable {
    case notReady([ListingIssue])
    case photosUnavailable([PhotoPreparationFailure])
    /// The draft changed after the approval screen was prepared.
    case changedDuringReview
    case couldNotSave(String)
}

/// Prepares and records the seller's approval of one exact package.
@MainActor
struct ListingApproval {
    var store: ApprovedPhotoStore = .standard
    var loader: any ListingPhotoLoading = DefaultListingPhotoLoader()
    var validator = ListingValidator()

    func prepare(_ draft: ListingDraft) async throws -> ApprovalPreview {
        let errors = validator.validate(draft.validationInput()).filter { $0.severity == .error }
        guard errors.isEmpty else { throw ApprovalError.notReady(errors) }

        let content = draft.content
        let version = draft.approvalVersion + 1
        var images: [(photoID: UUID, data: Data)] = []
        var failures: [PhotoPreparationFailure] = []
        for (index, photo) in draft.selectedPhotos.enumerated() {
            guard let photo else {
                failures.append(PhotoPreparationFailure(photoID: content.photoIDs[index], position: index + 1, problem: .missing))
                continue
            }
            do {
                images.append((photo.id, try await loader.listingData(for: photo.reference)))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(PhotoPreparationFailure(photoID: photo.id, position: index + 1, problem: error as? ListingPhotoProblem ?? .couldNotLoad))
            }
        }
        guard failures.isEmpty else { throw ApprovalError.photosUnavailable(failures) }
        guard draft.content == content else { throw ApprovalError.changedDuringReview }

        let photos: [ListingSnapshot.Photo]
        do {
            photos = try store.write(images, draftID: draft.id, version: version)
        } catch {
            throw ApprovalError.couldNotSave(error.localizedDescription)
        }
        return ApprovalPreview(
            draftID: draft.id,
            version: version,
            content: content,
            text: content.exportText,
            photos: photos,
            photoURLs: photos.map { store.url(for: $0, draftID: draft.id, version: version) }
        )
    }

    /// Records the approval. If saving fails, the draft is left exactly as it was.
    @discardableResult
    func approve(_ draft: ListingDraft, preview: ApprovalPreview, in context: ModelContext, save: (() throws -> Void)? = nil) throws -> ListingSnapshot {
        guard draft.id == preview.draftID, draft.content == preview.content, draft.approvalVersion + 1 == preview.version else {
            throw ApprovalError.changedDuringReview
        }
        let errors = validator.validate(draft.validationInput()).filter { $0.severity == .error }
        guard errors.isEmpty else { throw ApprovalError.notReady(errors) }

        let snapshot = ListingSnapshot(format: ListingSnapshot.currentFormat, version: preview.version, approvedAt: .now, content: preview.content, text: preview.text, photos: preview.photos)
        let data: Data
        do { data = try snapshot.encoded() } catch { throw ApprovalError.couldNotSave(error.localizedDescription) }

        let previous = draft.workflowState
        draft.approvedSnapshotData = data
        draft.approvalVersion = snapshot.version
        draft.approvedAt = snapshot.approvedAt
        draft.handedOffAt = nil
        draft.sellerConfirmedListedAt = nil
        draft.status = .approved
        let event = context.logActivity(.listingApproved, title: "Listing approved", detail: "\(draft.displayTitle) · version \(snapshot.version)", itemID: draft.item?.id, isDemo: draft.isDemo)
        do {
            try (save ?? { try context.save() })()
        } catch {
            draft.restore(previous)
            context.delete(event)
            throw ApprovalError.couldNotSave(error.localizedDescription)
        }
        store.remove(draftID: draft.id, except: snapshot.version)
        return snapshot
    }
}

enum ListingExportError: LocalizedError, Equatable {
    case notApproved
    case approvalOutdated
    case photosUnavailable
    case couldNotSave(String)

    var errorDescription: String? {
        switch self {
        case .notApproved: "Approve the listing before exporting it."
        case .approvalOutdated: "The listing changed after you approved it. Review and approve it again."
        case .photosUnavailable: "The approved photos are missing or changed. Review and approve the listing again."
        case .couldNotSave(let message): "Your progress couldn't be saved. \(message)"
        }
    }
}

/// The approved snapshot, ready to copy and share.
struct ListingExportPackage: Sendable, Equatable {
    let version: Int
    let text: String
    let photoURLs: [URL]
    let marketplace: Marketplace
}

/// Manual handoff of an approved listing, and the seller's own
/// confirmation that it's live. Nothing here publishes anything or marks a
/// listing as listed on the seller's behalf.
@MainActor
enum ListingExporter {
    /// Only the approved snapshot is ever exported, never the live draft.
    static func package(for draft: ListingDraft, store: ApprovedPhotoStore = .standard) throws -> ListingExportPackage {
        guard [.approved, .exported, .listed].contains(draft.status), let snapshot = draft.approvedSnapshot else {
            throw ListingExportError.notApproved
        }
        guard draft.approvalProblem == nil else { throw ListingExportError.approvalOutdated }
        let urls = try store.verifiedURLs(for: snapshot, draftID: draft.id)
        return ListingExportPackage(version: snapshot.version, text: snapshot.text, photoURLs: urls, marketplace: snapshot.content.marketplace)
    }

    /// Call after a copy, a completed share, or opening the marketplace —
    /// not after a cancelled or failed one. Moves an approved listing to
    /// "handed off"; never to "listed".
    static func recordHandoff(_ draft: ListingDraft, in context: ModelContext, save: (() throws -> Void)? = nil) throws {
        guard draft.status != .listed else { return }
        let previous = draft.workflowState
        let isFirst = draft.status == .approved
        guard draft.recordHandoff() else { throw ListingExportError.approvalOutdated }
        let event = isFirst
            ? context.logActivity(.listingHandedOff, title: "Ready to post on \(draft.marketplace.displayName)", detail: "\(draft.displayTitle) · not confirmed as listed", itemID: draft.item?.id, isDemo: draft.isDemo)
            : nil
        do {
            try (save ?? { try context.save() })()
        } catch {
            draft.restore(previous)
            if let event { context.delete(event) }
            throw ListingExportError.couldNotSave(error.localizedDescription)
        }
    }

    /// Records the seller's confirmation that the listing is live, with an
    /// optional link. Rakful can't verify either.
    static func confirmListed(_ draft: ListingDraft, url: URL?, in context: ModelContext, save: (() throws -> Void)? = nil) throws {
        let previous = draft.workflowState
        guard draft.confirmListed(url: url) else { throw ListingExportError.approvalOutdated }
        let event = context.logActivity(.listingConfirmedListed, title: "Listed on \(draft.marketplace.displayName)", detail: "\(draft.displayTitle) · confirmed by you", itemID: draft.item?.id, isDemo: draft.isDemo)
        do {
            try (save ?? { try context.save() })()
        } catch {
            draft.restore(previous)
            context.delete(event)
            throw ListingExportError.couldNotSave(error.localizedDescription)
        }
    }

    static func undoListed(_ draft: ListingDraft, in context: ModelContext, save: (() throws -> Void)? = nil) throws {
        let previous = draft.workflowState
        draft.undoListed()
        do {
            try (save ?? { try context.save() })()
        } catch {
            draft.restore(previous)
            throw ListingExportError.couldNotSave(error.localizedDescription)
        }
    }

    /// Parses the optional listing link a seller types. Adds `https://` if
    /// it's missing; returns nil for anything that isn't a web address.
    static func listingURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return url
    }
}
