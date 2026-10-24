import Photos
import UIKit

/// Loads and caches small thumbnails for the UI. Uses PhotoKit's caching
/// image manager for library photos and downsampled decoding for imported
/// images, so grids stay smooth with large libraries.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 400
        manager.allowsCachingHighQualityImages = false
    }

    func thumbnail(for photo: ItemPhoto, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        if let id = photo.assetLocalIdentifier {
            return await libraryImage(id, pixelSize: CGSize(width: pointSize.width * scale, height: pointSize.height * scale))
        }
        if let name = photo.importedFileName {
            return await importedImage(name, maxPixel: max(pointSize.width, pointSize.height) * scale)
        }
        return nil
    }

    func libraryImage(_ localIdentifier: String, pixelSize: CGSize) async -> UIImage? {
        let key = "\(localIdentifier)#\(Int(pixelSize.width))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        let image: UIImage? = await withCheckedContinuation { continuation in
            let once = ResumeOnceOptional(continuation)
            manager.requestImage(for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                once.resume(image)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func importedImage(_ fileName: String, maxPixel: CGFloat) async -> UIImage? {
        let key = "file:\(fileName)#\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = ImportedImageStore.url(for: fileName)
        let image = await Task.detached(priority: .userInitiated) {
            ImportedImageStore.downsample(url: url, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func purge() { cache.removeAllObjects() }
}

private final class ResumeOnceOptional: @unchecked Sendable {
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private let lock = NSLock()
    init(_ continuation: CheckedContinuation<UIImage?, Never>) { self.continuation = continuation }
    func resume(_ image: UIImage?) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(returning: image)
        continuation = nil
    }
}
