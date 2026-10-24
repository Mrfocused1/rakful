import Foundation

/// A photo that looks like it contains a resellable item.
struct CandidateObservation: Sendable, Equatable {
    let photoID: String
    let category: ResaleCategory
    let vector: FeatureVector?
    let date: Date?
}

/// An already-known item, summarised for matching.
struct ExistingCandidate: Sendable, Equatable {
    let id: UUID
    let category: ResaleCategory
    var vectors: [FeatureVector]
    var dates: [Date]
}

enum GroupAssignment: Sendable, Equatable {
    /// Attach the photo to an existing item.
    case existing(UUID, isDuplicate: Bool)
    /// Start (or join) a new group created in this pass.
    case new(group: Int, isDuplicate: Bool)

    var isDuplicate: Bool {
        switch self {
        case .existing(_, let duplicate), .new(_, let duplicate): duplicate
        }
    }
}

/// Groups photos of the same physical item and flags near-duplicate photos.
///
/// Two photos join the same group when they share a category and either
/// their embeddings are very close, or they're close *and* taken within a
/// short window (people photograph an item several times in a row).
///
/// Thresholds are cosine distances on L2-normalised Vision feature prints.
/// Measured on product renders: an identical/mirrored image ≈ 0.001, a crop
/// of the same image ≈ 0.08, but two *different* laptops only ≈ 0.105 —
/// feature prints encode "kind of object" more than "this object". Wrongly
/// merging two possessions is worse than splitting one, so thresholds are
/// deliberately tight and users can combine or separate items afterwards.
struct CandidateGrouper: Sendable {
    var sameItemThreshold: Float = 0.07
    var temporalThreshold: Float = 0.095
    var temporalWindow: TimeInterval = 10 * 60
    var duplicateThreshold: Float = 0.03
    /// Bound comparisons per group for large libraries.
    var maxVectorsPerGroup = 8

    func assign(_ observations: [CandidateObservation], existing: [ExistingCandidate]) -> [GroupAssignment] {
        struct Group {
            var category: ResaleCategory
            var vectors: [FeatureVector]
            var dates: [Date]
            var target: Target
        }
        enum Target { case existing(UUID), new(Int) }

        var groups = existing.map { Group(category: $0.category, vectors: $0.vectors, dates: $0.dates, target: .existing($0.id)) }
        var newGroupCount = 0
        var assignments: [GroupAssignment] = []
        assignments.reserveCapacity(observations.count)

        for observation in observations {
            var best: (index: Int, distance: Float)?
            if let vector = observation.vector {
                for (index, group) in groups.enumerated() where group.category == observation.category {
                    guard let distance = group.vectors.map({ vector.cosineDistance(to: $0) }).min() else { continue }
                    let closeInTime = observation.date.map { date in
                        group.dates.contains { abs($0.timeIntervalSince(date)) <= temporalWindow }
                    } ?? false
                    let matches = distance < sameItemThreshold || (closeInTime && distance < temporalThreshold)
                    if matches, distance < (best?.distance ?? .infinity) {
                        best = (index, distance)
                    }
                }
            }

            if let best {
                let isDuplicate = best.distance < duplicateThreshold
                if !isDuplicate, let vector = observation.vector, groups[best.index].vectors.count < maxVectorsPerGroup {
                    groups[best.index].vectors.append(vector)
                }
                if let date = observation.date { groups[best.index].dates.append(date) }
                switch groups[best.index].target {
                case .existing(let id): assignments.append(.existing(id, isDuplicate: isDuplicate))
                case .new(let group): assignments.append(.new(group: group, isDuplicate: isDuplicate))
                }
            } else {
                groups.append(Group(
                    category: observation.category,
                    vectors: observation.vector.map { [$0] } ?? [],
                    dates: observation.date.map { [$0] } ?? [],
                    target: .new(newGroupCount)
                ))
                assignments.append(.new(group: newGroupCount, isDuplicate: false))
                newGroupCount += 1
            }
        }
        return assignments
    }
}
