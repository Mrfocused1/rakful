import os
import Photos
import UIKit

/// PhotoKit-backed asset source. Never loads full-resolution originals: it
/// asks Photos for a small rendition, which Photos can usually serve from its
/// own cache without decoding or downloading the original.
final class PhotoKitAssetSource: PhotoAssetSource {
    func accessLevel() -> PhotoAccessLevel {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> PhotoAccessLevel {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func fetchImageAssets(includeScreenshots: Bool) -> [PhotoAssetDescriptor] {
        guard accessLevel().canRead else { return [] }
        let result = PHAsset.fetchAssets(with: Self.fetchOptions(includeScreenshots: includeScreenshots))
        var descriptors: [PhotoAssetDescriptor] = []
        descriptors.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            descriptors.append(PhotoAssetDescriptor(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
            ))
        }
        return descriptors
    }

    func authorizedImageCount(includeScreenshots: Bool) -> Int {
        guard accessLevel().canRead else { return 0 }
        return PHAsset.fetchAssets(with: Self.fetchOptions(includeScreenshots: includeScreenshots)).count
    }

    func loadAnalysisImage(for localIdentifier: String, maxDimension: CGFloat, allowNetworkAccess: Bool) async throws -> AnalysisImage {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw PhotoLoadError.assetNotFound
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetworkAccess
        options.isSynchronous = false
        options.version = .current

        let requestID = OSAllocatedUnfairLock<PHImageRequestID?>(initialState: nil)
        let manager = PHImageManager.default()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AnalysisImage, Error>) in
                let once = ResumeOnce(continuation)
                let id = manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: maxDimension, height: maxDimension),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        once.resume(throwing: PhotoLoadError.cancelled)
                        return
                    }
                    guard let image else {
                        if (info?[PHImageResultIsInCloudKey] as? Bool) == true, !allowNetworkAccess {
                            once.resume(throwing: PhotoLoadError.iCloudOnly)
                        } else {
                            let message = (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "Photo could not be loaded"
                            once.resume(throwing: PhotoLoadError.unavailable(message))
                        }
                        return
                    }
                    guard let upright = Self.upright(image) else {
                        once.resume(throwing: PhotoLoadError.unavailable("Photo could not be decoded"))
                        return
                    }
                    once.resume(returning: AnalysisImage(cgImage: upright, sourceIdentifier: localIdentifier))
                }
                requestID.withLock { $0 = id }
            }
        } onCancel: {
            if let id = requestID.withLock({ $0 }) {
                PHImageManager.default().cancelImageRequest(id)
            }
        }
    }

    // MARK: - Helpers

    static func map(_ status: PHAuthorizationStatus) -> PhotoAccessLevel {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .limited: .limited
        case .authorized: .full
        @unknown default: .denied
        }
    }

    private static func fetchOptions(includeScreenshots: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        if includeScreenshots {
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        } else {
            options.predicate = NSPredicate(
                format: "mediaType == %d AND NOT ((mediaSubtypes & %d) != 0)",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
        }
        return options
    }

    /// Returns a `CGImage` with orientation applied, so Vision coordinates and
    /// crops line up with what people see.
    private static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }.cgImage
    }
}

/// Guards a continuation against PhotoKit calling back more than once.
final class ResumeOnce<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<Value, Error>?>

    init(_ continuation: CheckedContinuation<Value, Error>) {
        state = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(returning value: Value) {
        state.withLock { continuation in
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func resume(throwing error: Error) {
        state.withLock { continuation in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
