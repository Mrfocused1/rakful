import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Stores photos the user takes or imports for a listing. Images are saved as
/// downsampled JPEGs in Application Support — never full-resolution originals.
enum ImportedImageStore {
    static let maxPixelDimension: CGFloat = 2048

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("ImportedImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Downsamples and saves image data. Returns the stored file name.
    static func save(imageData: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = downsample(source: source, maxPixel: maxPixelDimension)?.cgImage
        else { throw CocoaError(.fileReadCorruptFile) }
        return try write(image)
    }

    static func save(image: UIImage) throws -> String {
        let longest = max(image.size.width, image.size.height) * image.scale
        let scale = min(1, maxPixelDimension / max(longest, 1))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = rendered.cgImage else { throw CocoaError(.fileWriteUnknown) }
        return try write(cgImage)
    }

    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func downsample(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return downsample(source: source, maxPixel: maxPixel)
    }

    private static func downsample(source: CGImageSource, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func write(_ image: CGImage) throws -> String {
        let name = UUID().uuidString + ".jpg"
        let url = url(for: name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return name
    }
}
