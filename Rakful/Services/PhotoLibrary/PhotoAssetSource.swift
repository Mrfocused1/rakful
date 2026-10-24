import CoreGraphics
import Foundation

/// The user's photo-library authorisation, mapped from PhotoKit.
enum PhotoAccessLevel: String, Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case limited
    case full

    var canRead: Bool { self == .limited || self == .full }

    var displayName: String {
        switch self {
        case .notDetermined: "Not Set"
        case .restricted: "Restricted"
        case .denied: "None"
        case .limited: "Limited Access"
        case .full: "Full Access"
        }
    }

    var explanation: String {
        switch self {
        case .notDetermined:
            "Rakful will ask for access when you start your first discovery."
        case .restricted:
            "Photo access is restricted on this iPhone, for example by Screen Time or a device management profile."
        case .denied:
            "Rakful can't see your photos. Turn on access in Settings to discover items."
        case .limited:
            "Rakful can only see the photos you selected. You can change the selection at any time."
        case .full:
            "Rakful can analyse your photo library. Analysis happens on your phone."
        }
    }
}

/// Lightweight description of an image asset — never the image itself.
struct PhotoAssetDescriptor: Sendable, Hashable {
    let localIdentifier: String
    let creationDate: Date?
    let isScreenshot: Bool
}

/// An upright, downsampled image prepared for analysis.
struct AnalysisImage: @unchecked Sendable {
    let cgImage: CGImage
    /// The asset this image was rendered from (for tracing and test doubles).
    var sourceIdentifier: String?
}

enum PhotoLoadError: Error, Equatable, Sendable {
    case assetNotFound
    /// Only available from iCloud and network access isn't permitted for this run.
    case iCloudOnly
    case cancelled
    case unavailable(String)
}

/// Abstraction over PhotoKit so discovery can be tested with fixtures.
protocol PhotoAssetSource: Sendable {
    func accessLevel() -> PhotoAccessLevel
    func requestAccess() async -> PhotoAccessLevel
    /// Authorised image assets, newest first. With limited access this only
    /// includes the photos the user selected.
    func fetchImageAssets(includeScreenshots: Bool) -> [PhotoAssetDescriptor]
    func authorizedImageCount(includeScreenshots: Bool) -> Int
    func loadAnalysisImage(for localIdentifier: String, maxDimension: CGFloat, allowNetworkAccess: Bool) async throws -> AnalysisImage
}
