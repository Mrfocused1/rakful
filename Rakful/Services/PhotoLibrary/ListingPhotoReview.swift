import CoreGraphics
import Foundation
import Observation
import SwiftData

/// Why a photo can't be loaded for checking or for a listing, with the
/// action that fixes it.
enum ListingPhotoProblem: Error, Equatable, Sendable {
    /// Deleted from the library, or the file is gone.
    case missing
    /// Limited access is on and this photo isn't in the shared selection.
    case notShared
    /// Rakful has no photo access.
    case accessDenied
    /// Photos couldn't provide it, e.g. an iCloud original that won't download.
    case couldNotLoad

    enum Recovery: Sendable { case openSettings, changeSharedPhotos, tryAgain, remove }

    var message: String {
        switch self {
        case .missing: "This photo is no longer on your iPhone."
        case .notShared: "This photo isn't in the photos you've shared with Rakful."
        case .accessDenied: "Rakful no longer has access to your photos."
        case .couldNotLoad: "This photo couldn't be loaded. If it's stored in iCloud, check you're online and try again."
        }
    }

    var recovery: Recovery {
        switch self {
        case .missing: .remove
        case .notShared: .changeSharedPhotos
        case .accessDenied: .openSettings
        case .couldNotLoad: .tryAgain
        }
    }
}

/// Checks an image for people.
protocol PersonChecking: Sendable {
    func check(_ image: CGImage) async -> PersonCheck
}

/// Vision-based check, the same one discovery uses. Reports `.failed` when
/// the model isn't usable (as in Simulator) rather than "no person".
struct VisionPersonChecker: PersonChecking {
    var analyzer = VisionPhotoAnalyzer()

    func check(_ image: CGImage) async -> PersonCheck {
        guard await analyzer.verifyAvailability() else { return .failed }
        return await VisionPhotoAnalyzer.personCheck(in: image, labels: nil)
    }
}

/// Loads a photo — from the library or Rakful's own storage — for checking
/// and for approval.
protocol ListingPhotoLoading: Sendable {
    func image(for photo: PhotoRef, maxPixel: CGFloat) async throws -> CGImage
    /// JPEG bytes for the listing. Imported photos return their stored file unchanged.
    func listingData(for photo: PhotoRef) async throws -> Data
}

struct DefaultListingPhotoLoader: ListingPhotoLoading {
    var source: any PhotoAssetSource = PhotoKitAssetSource()
    static let listingPixelSize: CGFloat = ImportedImageStore.maxPixelDimension

    func image(for photo: PhotoRef, maxPixel: CGFloat) async throws -> CGImage {
        if let name = photo.importedFileName {
            guard let image = ImportedImageStore.downsample(url: ImportedImageStore.url(for: name), maxPixel: maxPixel)?.cgImage else {
                throw ListingPhotoProblem.missing
            }
            return image
        }
        guard let identifier = photo.assetLocalIdentifier else { throw ListingPhotoProblem.missing }
        let access = source.accessLevel()
        guard access.canRead else { throw ListingPhotoProblem.accessDenied }
        do {
            return try await source.loadAnalysisImage(for: identifier, maxDimension: maxPixel, allowNetworkAccess: true).cgImage
        } catch PhotoLoadError.assetNotFound {
            throw access == .limited ? ListingPhotoProblem.notShared : .missing
        } catch PhotoLoadError.cancelled {
            throw CancellationError()
        } catch {
            throw ListingPhotoProblem.couldNotLoad
        }
    }

    func listingData(for photo: PhotoRef) async throws -> Data {
        if let name = photo.importedFileName {
            guard let data = try? Data(contentsOf: ImportedImageStore.url(for: name)) else { throw ListingPhotoProblem.missing }
            return data
        }
        let image = try await image(for: photo, maxPixel: Self.listingPixelSize)
        guard let data = ImportedImageStore.jpegData(image) else { throw ListingPhotoProblem.couldNotLoad }
        return data
    }
}

/// Runs the same person check on every photo — discovered, imported or
/// taken with the camera — and records the seller's own review. Results
/// are saved on the photo; load problems are kept for the UI's recovery
/// actions.
@MainActor
@Observable
final class ListingPhotoReviewer {
    private(set) var checking: Set<UUID> = []
    private(set) var problems: [UUID: ListingPhotoProblem] = [:]

    @ObservationIgnored let saves: SaveFailureCenter
    @ObservationIgnored let loader: any ListingPhotoLoading
    @ObservationIgnored let checker: any PersonChecking

    init(saves: SaveFailureCenter, loader: any ListingPhotoLoading = DefaultListingPhotoLoader(), checker: any PersonChecking = VisionPersonChecker()) {
        self.saves = saves
        self.loader = loader
        self.checker = checker
    }

    /// Starts checks for photos that haven't had one.
    func checkUnchecked(_ photos: [ItemPhoto], in context: ModelContext) {
        for photo in photos where photo.personCheck == .unchecked && !checking.contains(photo.id) {
            Task { await check(photo, in: context) }
        }
    }

    /// Checks (or re-checks) one photo and saves the result.
    func check(_ photo: ItemPhoto, in context: ModelContext) async {
        let id = photo.id
        guard !checking.contains(id) else { return }
        checking.insert(id)
        defer { checking.remove(id) }

        let result: PersonCheck
        do {
            let image = try await loader.image(for: photo.reference, maxPixel: 1024)
            problems[id] = nil
            result = await checker.check(image)
        } catch is CancellationError {
            return
        } catch {
            problems[id] = error as? ListingPhotoProblem ?? .couldNotLoad
            result = .failed
        }
        // The photo may have been removed while the check ran.
        guard photo.modelContext != nil, !photo.isDeleted else { return }
        photo.personCheck = result
        if result == .personDetected { Self.excludeFromListings(photo) }
        saves.save(context, "Saving the photo check")
    }

    /// The seller looked and found no people. Doesn't override a detected person.
    @discardableResult
    func confirmNoPerson(_ photo: ItemPhoto, in context: ModelContext) -> Bool {
        guard photo.personCheck != .personDetected else { return false }
        photo.userReview = .confirmedNoPerson
        return saves.save(context, "Saving your photo review")
    }

    @discardableResult
    func markShowsPerson(_ photo: ItemPhoto, in context: ModelContext) -> Bool {
        photo.userReview = .markedShowsPerson
        Self.excludeFromListings(photo)
        return saves.save(context, "Saving your photo review")
    }

    func problem(for photo: ItemPhoto) -> ListingPhotoProblem? { problems[photo.id] }

    func clearProblem(for photo: ItemPhoto) { problems[photo.id] = nil }

    /// Takes a photo out of every listing still being prepared, which
    /// invalidates any approval that included it.
    static func excludeFromListings(_ photo: ItemPhoto) {
        for draft in photo.item?.drafts ?? [] where draft.status.isActive {
            draft.deselectPhotos([photo.id])
            draft.invalidateApprovalIfNeeded()
        }
    }
}
