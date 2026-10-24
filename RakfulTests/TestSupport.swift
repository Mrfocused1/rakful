import CoreGraphics
import Foundation
import os
import SwiftData
@testable import Rakful

/// Fixture-driven photo library. Configure before running; reads are thread-safe.
final class MockPhotoSource: PhotoAssetSource, @unchecked Sendable {
    var access: PhotoAccessLevel
    var assets: [PhotoAssetDescriptor]
    var iCloudOnly: Set<String> = []
    var failing: Set<String> = []
    /// Called after each successful load with the running count — lets tests
    /// simulate an expiration part-way through a run.
    var onLoad: (@Sendable (Int) -> Void)?
    private let loadCount = OSAllocatedUnfairLock(initialState: 0)

    init(access: PhotoAccessLevel = .full, assets: [PhotoAssetDescriptor]) {
        self.access = access
        self.assets = assets
    }

    var loads: Int { loadCount.withLock { $0 } }

    func accessLevel() -> PhotoAccessLevel { access }
    func requestAccess() async -> PhotoAccessLevel { access }
    func fetchImageAssets(includeScreenshots: Bool) -> [PhotoAssetDescriptor] {
        guard access.canRead else { return [] }
        return assets.filter { includeScreenshots || !$0.isScreenshot }
    }
    func authorizedImageCount(includeScreenshots: Bool) -> Int { fetchImageAssets(includeScreenshots: includeScreenshots).count }

    func loadAnalysisImage(for localIdentifier: String, maxDimension: CGFloat, allowNetworkAccess: Bool) async throws -> AnalysisImage {
        try Task.checkCancellation()
        if iCloudOnly.contains(localIdentifier), !allowNetworkAccess { throw PhotoLoadError.iCloudOnly }
        if failing.contains(localIdentifier) { throw PhotoLoadError.unavailable("Fixture failure") }
        guard assets.contains(where: { $0.localIdentifier == localIdentifier }) else { throw PhotoLoadError.assetNotFound }
        let count = loadCount.withLock { $0 += 1; return $0 }
        onLoad?(count)
        return AnalysisImage(cgImage: Fixtures.pixel, sourceIdentifier: localIdentifier)
    }
}

/// Returns canned analyses keyed by asset identifier.
struct MockAnalyzer: PhotoAnalyzer {
    var results: [String: PhotoAnalysis]
    var isAvailable = true

    func verifyAvailability() async -> Bool { isAvailable }

    func analyze(_ image: AnalysisImage, enabledCategories: Set<ResaleCategory>) async throws -> PhotoAnalysis {
        try Task.checkCancellation()
        guard let id = image.sourceIdentifier, var analysis = results[id] else { return .empty }
        if let match = analysis.match, !enabledCategories.contains(match.category) { analysis.match = nil }
        return analysis
    }
}

enum Fixtures {
    static let pixel: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    static func descriptor(_ id: String, minutesAgo: Double = 0, screenshot: Bool = false, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(localIdentifier: id, creationDate: now.addingTimeInterval(-minutesAgo * 60), isScreenshot: screenshot)
    }

    /// A unit vector along `axis` with an optional small perturbation on `axis + 1`.
    static func vector(axis: Int, wobble: Float = 0, dimensions: Int = 16) -> FeatureVector {
        var values = [Float](repeating: 0, count: dimensions)
        values[axis] = 1
        values[(axis + 1) % dimensions] = wobble
        return FeatureVector(values: values)!
    }

    static func analysis(_ category: ResaleCategory, label: String, name: String, score: Double = 0.9, vector: FeatureVector?, text: [String] = []) -> PhotoAnalysis {
        PhotoAnalysis(
            labels: [ClassifiedLabel(identifier: label, confidence: score)],
            match: CategoryMatch(category: category, score: score, label: label, suggestedName: name),
            featureVector: vector,
            salientRegion: nil,
            recognisedText: text
        )
    }

    static func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: PersistenceController.schema, configurations: [configuration])
    }

    static func makeStore(_ container: ModelContainer) async -> DiscoveryStore {
        await Task.detached { DiscoveryStore(modelContainer: container) }.value
    }

    static func configuration(mode: DiscoveryMode = .manual, allowance: Int? = nil, network: Bool = false, batchSize: Int = 4) -> DiscoveryConfiguration {
        var configuration = DiscoveryConfiguration(
            mode: mode,
            enabledCategories: ResaleCategory.allEnabledByDefault,
            includeScreenshots: false,
            allowNetworkAccess: network,
            photoAllowance: allowance
        )
        configuration.batchSize = batchSize
        return configuration
    }

    @MainActor
    static func makePreferences() -> PreferencesStore {
        PreferencesStore(defaults: UserDefaults(suiteName: "rr-tests-\(UUID().uuidString)")!)
    }
}

/// Captures progress callbacks.
final class ProgressRecorder: Sendable {
    private let values = OSAllocatedUnfairLock<[DiscoveryProgress]>(initialState: [])
    func record(_ progress: DiscoveryProgress) { values.withLock { $0.append(progress) } }
    var all: [DiscoveryProgress] { values.withLock { $0 } }
}
