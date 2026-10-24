import CoreGraphics
import CoreML
import Foundation
import os
import Vision

/// Everything Rakful learns from one photo, as plain values.
struct PhotoAnalysis: Sendable {
    var labels: [ClassifiedLabel]
    var match: CategoryMatch?
    var featureVector: FeatureVector?
    /// Normalised (upper-left origin) bounds of the most salient object.
    var salientRegion: CGRect?
    var recognisedText: [String]
    /// A person is visible. Such photos identify the item but stay private:
    /// they're never used in a listing.
    var showsPerson = false

    static let empty = PhotoAnalysis(labels: [], match: nil, featureVector: nil, salientRegion: nil, recognisedText: [])
}

protocol PhotoAnalyzer: Sendable {
    func analyze(_ image: AnalysisImage, enabledCategories: Set<ResaleCategory>) async throws -> PhotoAnalysis
    /// Whether analysis produces meaningful results on this device. Checked
    /// before a run so a broken model never marks photos as "analysed".
    func verifyAvailability() async -> Bool
}

extension PhotoAnalyzer {
    func verifyAvailability() async -> Bool { true }
}

/// On-device analysis using Vision:
/// 1. Classify the whole image (general taxonomy).
/// 2. Map labels to a resale category; stop early if nothing relevant.
/// 3. Find the most salient object and crop to it.
/// 4. Generate a feature print of the crop for grouping and deduplication.
/// 5. Recognise text in the crop for brand suggestions.
/// 6. Check whether a person is visible.
struct VisionPhotoAnalyzer: PhotoAnalyzer {
    var classifier = CategoryClassifier()
    var maxLabels = 12

    func analyze(_ image: AnalysisImage, enabledCategories: Set<ResaleCategory>) async throws -> PhotoAnalysis {
        let cgImage = image.cgImage
        let observations = try await Self.configured(ClassifyImageRequest()).perform(on: cgImage)
        let labels = observations
            .filter { $0.confidence >= 0.1 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { ClassifiedLabel(identifier: $0.identifier, confidence: Double($0.confidence)) }

        guard let match = classifier.match(Array(labels), enabledCategories: enabledCategories) else {
            return PhotoAnalysis(labels: Array(labels), match: nil, featureVector: nil, salientRegion: nil, recognisedText: [])
        }
        try Task.checkCancellation()

        let region = try? await salientRegion(in: cgImage)
        let focus = region.flatMap { crop(cgImage, to: $0) } ?? cgImage

        let vector: FeatureVector?
        if let print = try? await Self.configured(GenerateImageFeaturePrintRequest()).perform(on: focus) {
            vector = FeatureVector(rawData: print.data, elementIsDouble: print.elementType == .double)
        } else {
            vector = nil
        }
        try Task.checkCancellation()

        var textRequest = Self.configured(RecognizeTextRequest())
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        let text = (try? await textRequest.perform(on: focus))?
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { $0.count >= 2 } ?? []

        let showsPerson = await Self.showsPerson(in: cgImage, labels: Array(labels))

        return PhotoAnalysis(labels: Array(labels), match: match, featureVector: vector, salientRegion: region, recognisedText: text, showsPerson: showsPerson)
    }

    /// Vision's person labels, or a detected upper body (which also catches
    /// mirror selfies where the face is hidden).
    private static func showsPerson(in image: CGImage, labels: [ClassifiedLabel]) async -> Bool {
        if CategoryClassifier.personScore(in: labels) >= CategoryClassifier.personThreshold { return true }
        let humans = (try? await configured(DetectHumanRectanglesRequest()).perform(on: image)) ?? []
        return humans.contains { $0.confidence >= 0.5 }
    }

    /// Classifies two very different synthetic probes. A working model gives
    /// different labels (e.g. "chess" vs "ping_pong"); a degenerate one — as
    /// in the iOS 18 Simulator, where every image is "outdoor/sky" — doesn't.
    func verifyAvailability() async -> Bool {
        if let cached = Self.availability.withLock({ $0 }) { return cached }
        let request = Self.configured(ClassifyImageRequest())
        func signature(_ image: CGImage) async -> [String: Float]? {
            guard let results = try? await request.perform(on: image) else { return nil }
            let top = results.sorted { $0.confidence > $1.confidence }.prefix(3)
            return Dictionary(top.map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max)
        }
        guard let checkerboard = Self.probe(checkerboard: true), let circle = Self.probe(checkerboard: false),
              let first = await signature(checkerboard), let second = await signature(circle), !first.isEmpty
        else {
            Self.availability.withLock { $0 = false }
            return false
        }
        // Compare label sets only: a degenerate model's confidences drift
        // slightly between inputs, but its labels don't change.
        let identical = Set(first.keys) == Set(second.keys)
        Self.availability.withLock { $0 = !identical }
        return !identical
    }

    private static let availability = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    private static func probe(checkerboard: Bool) -> CGImage? {
        let size = 224
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        if checkerboard {
            for x in 0..<8 {
                for y in 0..<8 {
                    context.setFillColor(gray: (x + y).isMultiple(of: 2) ? 0 : 1, alpha: 1)
                    context.fill(CGRect(x: x * 28, y: y * 28, width: 28, height: 28))
                }
            }
        } else {
            context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 40, y: 40, width: 144, height: 144))
        }
        return context.makeImage()
    }

    private func salientRegion(in image: CGImage) async throws -> CGRect? {
        let observation = try await Self.configured(GenerateObjectnessBasedSaliencyImageRequest()).perform(on: image)
        guard let object = observation.salientObjects.max(by: { $0.confidence < $1.confidence }) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let rect = object.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        let normalised = CGRect(x: rect.minX / size.width, y: rect.minY / size.height, width: rect.width / size.width, height: rect.height / size.height)
        // Ignore tiny regions; they're usually noise rather than the subject.
        guard normalised.width * normalised.height >= 0.04 else { return nil }
        return normalised
    }

    /// The Simulator has no GPU/Neural Engine path for Vision's neural
    /// networks ("Failed to create espresso context"), so requests run on
    /// the CPU there. On devices, Vision chooses the best hardware.
    static func configured<Request: VisionRequest>(_ request: Request) -> Request {
        #if targetEnvironment(simulator)
        var request = request
        for (stage, devices) in request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        return request
        #else
        return request
        #endif
    }

    private func crop(_ image: CGImage, to normalised: CGRect) -> CGImage? {
        let padded = normalised.insetBy(dx: -normalised.width * 0.08, dy: -normalised.height * 0.08)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rect = CGRect(
            x: padded.minX * CGFloat(image.width),
            y: padded.minY * CGFloat(image.height),
            width: padded.width * CGFloat(image.width),
            height: padded.height * CGFloat(image.height)
        ).integral
        guard rect.width >= 64, rect.height >= 64 else { return nil }
        return image.cropping(to: rect)
    }
}
