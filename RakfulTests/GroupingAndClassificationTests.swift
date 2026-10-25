import Foundation
import Testing
@testable import Rakful

@Suite("Feature vectors")
struct FeatureVectorTests {
    @Test func normalisesAndRoundTripsThroughData() throws {
        let vector = try #require(FeatureVector(values: [3, 4]))
        #expect(abs(vector.values[0] - 0.6) < 0.0001)
        #expect(abs(vector.values[1] - 0.8) < 0.0001)
        let decoded = try #require(FeatureVector(data: vector.data))
        #expect(decoded == vector)
    }

    @Test func rejectsEmptyAndZeroVectors() {
        #expect(FeatureVector(values: []) == nil)
        #expect(FeatureVector(values: [0, 0, 0]) == nil)
        #expect(FeatureVector(data: Data([1, 2, 3])) == nil)
    }

    @Test func cosineDistanceBehaves() {
        let a = Fixtures.vector(axis: 0), b = Fixtures.vector(axis: 1)
        #expect(a.cosineDistance(to: a) < 0.0001)
        #expect(abs(a.cosineDistance(to: b) - 1) < 0.0001)
    }

    @Test func convertsDoubleFeaturePrints() throws {
        let doubles: [Double] = [1, 0, 0]
        let data = doubles.withUnsafeBufferPointer { Data(buffer: $0) }
        let vector = try #require(FeatureVector(rawData: data, elementIsDouble: true))
        #expect(vector.values == [1, 0, 0])
    }
}

@Suite("Candidate grouping & duplicate detection")
struct CandidateGrouperTests {
    let grouper = CandidateGrouper()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func observation(_ id: String, _ category: ResaleCategory, _ vector: FeatureVector?, minutesAgo: Double) -> CandidateObservation {
        CandidateObservation(photoID: id, category: category, vector: vector, date: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func identicalPhotosAreGroupedAsDuplicates() {
        let v = Fixtures.vector(axis: 0)
        let result = grouper.assign([
            observation("a", .trainers, v, minutesAgo: 600),
            observation("b", .trainers, v, minutesAgo: 0),
        ], existing: [])
        #expect(result == [.new(group: 0, isDuplicate: false), .new(group: 0, isDuplicate: true)])
    }

    @Test func similarPhotosTakenTogetherJoinOneItem() {
        // Cosine distance ≈ 0.08: too far for "any time", close enough within the window.
        let a = Fixtures.vector(axis: 0), b = Fixtures.vector(axis: 0, wobble: 0.43)
        #expect(a.cosineDistance(to: b) > grouper.sameItemThreshold)
        #expect(a.cosineDistance(to: b) < grouper.temporalThreshold)

        let together = grouper.assign([observation("a", .electronics, a, minutesAgo: 3), observation("b", .electronics, b, minutesAgo: 0)], existing: [])
        #expect(together == [.new(group: 0, isDuplicate: false), .new(group: 0, isDuplicate: false)])

        let apart = grouper.assign([observation("a", .electronics, a, minutesAgo: 60 * 24), observation("b", .electronics, b, minutesAgo: 0)], existing: [])
        #expect(apart == [.new(group: 0, isDuplicate: false), .new(group: 1, isDuplicate: false)])
    }

    @Test func differentCategoriesNeverMerge() {
        let v = Fixtures.vector(axis: 0)
        let result = grouper.assign([observation("a", .bags, v, minutesAgo: 1), observation("b", .accessories, v, minutesAgo: 0)], existing: [])
        #expect(result == [.new(group: 0, isDuplicate: false), .new(group: 1, isDuplicate: false)])
    }

    @Test func distinctObjectsStaySeparate() {
        let result = grouper.assign([
            observation("a", .electronics, Fixtures.vector(axis: 0), minutesAgo: 1),
            observation("b", .electronics, Fixtures.vector(axis: 4), minutesAgo: 0),
        ], existing: [])
        #expect(result == [.new(group: 0, isDuplicate: false), .new(group: 1, isDuplicate: false)])
    }

    @Test func matchesExistingItemsAcrossSessions() {
        let id = UUID()
        let existing = ExistingCandidate(id: id, category: .accessories, vectors: [Fixtures.vector(axis: 2)], dates: [now.addingTimeInterval(-86_400 * 30)])
        let result = grouper.assign([observation("new", .accessories, Fixtures.vector(axis: 2, wobble: 0.1), minutesAgo: 0)], existing: [existing])
        #expect(result == [.existing(id, isDuplicate: true)])
    }

    @Test func photosWithoutFeaturePrintsBecomeSeparateItems() {
        let result = grouper.assign([observation("a", .furniture, nil, minutesAgo: 1), observation("b", .furniture, nil, minutesAgo: 0)], existing: [])
        #expect(result == [.new(group: 0, isDuplicate: false), .new(group: 1, isDuplicate: false)])
    }
}

@Suite("Category classification")
struct CategoryClassifierTests {
    let classifier = CategoryClassifier()
    let all = ResaleCategory.allEnabledByDefault

    func labels(_ pairs: [(String, Double)]) -> [ClassifiedLabel] {
        pairs.map { ClassifiedLabel(identifier: $0.0, confidence: $0.1) }
    }

    @Test func mapsSpecificLabels() throws {
        let match = try #require(classifier.match(labels([("sneaker", 0.82), ("footwear", 0.8)]), enabledCategories: all))
        #expect(match.category == .trainers)
        #expect(match.suggestedName == "Trainers")
    }

    @Test func prefersSpecificNameWithinCategory() throws {
        let match = try #require(classifier.match(labels([("bag", 0.9), ("backpack", 0.8)]), enabledCategories: all))
        #expect(match.category == .bags)
        #expect(match.suggestedName == "Backpack")
    }

    @Test func ignoresScreenshotsAndDocuments() {
        #expect(classifier.match(labels([("laptop", 0.9), ("screenshot", 0.7)]), enabledCategories: all) == nil)
        #expect(classifier.match(labels([("watch", 0.9), ("receipt", 0.8)]), enabledCategories: all) == nil)
    }

    @Test func respectsDisabledCategories() {
        #expect(classifier.match(labels([("camera", 0.9)]), enabledCategories: [.bags]) == nil)
    }

    @Test func belowThresholdIsNotACandidate() {
        #expect(classifier.match(labels([("sofa", 0.3)]), enabledCategories: all) == nil)
        #expect(classifier.match(labels([("waterfall", 0.95), ("sky", 0.9)]), enabledCategories: all) == nil)
    }

    @Test func clothingWornByPeopleIsWeakerEvidence() throws {
        let alone = try #require(classifier.match(labels([("jacket", 0.7)]), enabledCategories: all))
        let worn = classifier.match(labels([("jacket", 0.7), ("people", 0.9)]), enabledCategories: all)
        #expect((worn?.score ?? 0) < alone.score)
    }

    @Test func personScoreUsesTheStrongestPersonLabel() {
        #expect(CategoryClassifier.personScore(in: labels([("jacket", 0.9), ("adult", 0.7), ("people", 0.4)])) == 0.7)
        #expect(CategoryClassifier.personScore(in: labels([("jacket", 0.9)])) == 0)
    }

    @Test func everyCategorySuggestsListingShots() {
        for category in ResaleCategory.allCases {
            #expect(category.listingShots.count >= 3, "\(category) needs a shot list")
        }
    }

    @Test func confidenceBuckets() {
        #expect(ConfidenceLevel(score: 0.9) == .high)
        #expect(ConfidenceLevel(score: 0.6) == .medium)
        #expect(ConfidenceLevel(score: 0.41) == .low)
    }
}

@Suite("Brand text suggestions")
struct BrandTextMatcherTests {
    let matcher = BrandTextMatcher()

    @Test func matchesVisibleBrandInCategory() {
        let matches = matcher.matches(in: ["JUST DO IT", "NIKE AIR"], category: .trainers)
        #expect(matches.map(\.brand) == ["Nike"])
        #expect(matches.first?.matchedText == "NIKE AIR")
    }

    @Test func scopesAmbiguousBrandsToCategories() {
        #expect(matcher.matches(in: ["Coach"], category: .electronics).isEmpty)
        #expect(matcher.matches(in: ["COACH"], category: .bags).map(\.brand) == ["Coach"])
    }

    @Test func requiresWholeWords() {
        #expect(matcher.matches(in: ["SONYA"], category: .electronics).isEmpty)
        #expect(matcher.matches(in: ["the north face"], category: .clothing).map(\.brand) == ["The North Face"])
    }

    @Test func onDeviceIdentifierNeverSuggestsModels() async {
        let analysis = Fixtures.analysis(.electronics, label: "camera", name: "Camera", vector: nil, text: ["Canon EOS 5D"])
        let suggestions = await OnDeviceProductIdentifier().identify(analysis)
        #expect(suggestions.contains { $0.brand == "Canon" && $0.source == .onDeviceText })
        #expect(suggestions.allSatisfy { $0.model == nil })
    }
}

@Suite("Vision on device")
struct VisionDeviceTests {
    /// Discovery refuses to run when this probe fails, so it must pass on
    /// real iPhones. The Simulator's classifier is degenerate, so it's skipped there.
    @Test(.enabled(if: !runningInSimulator, "Vision's classifier is degenerate in the Simulator"))
    func classifierPassesTheAvailabilityProbe() async {
        #expect(await VisionPhotoAnalyzer().verifyAvailability())
    }
}

private let runningInSimulator: Bool = {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
}()
