import Foundation

/// An L2-normalised image embedding (from Vision's feature print) used for
/// grouping photos of the same item and detecting near-duplicates.
///
/// Distances are cosine distances in `0...2` (0 = identical direction), which
/// keeps thresholds independent of the feature print revision's raw scale.
struct FeatureVector: Sendable, Hashable {
    let values: [Float]

    init?(values raw: [Float]) {
        guard !raw.isEmpty else { return nil }
        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > .ulpOfOne, norm.isFinite else { return nil }
        values = raw.map { $0 / norm }
    }

    init?(data: Data) {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.stride == 0 else { return nil }
        let floats: [Float] = data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
        self.init(values: floats)
    }

    /// Converts Vision feature print bytes, which may be `Float` or `Double`.
    init?(rawData: Data, elementIsDouble: Bool) {
        if elementIsDouble {
            guard rawData.count % MemoryLayout<Double>.stride == 0 else { return nil }
            let doubles: [Double] = rawData.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
            self.init(values: doubles.map(Float.init))
        } else {
            self.init(data: rawData)
        }
    }

    var data: Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func cosineDistance(to other: FeatureVector) -> Float {
        guard values.count == other.values.count else { return 2 }
        var dot: Float = 0
        for index in values.indices {
            dot += values[index] * other.values[index]
        }
        return max(0, 1 - dot)
    }
}
