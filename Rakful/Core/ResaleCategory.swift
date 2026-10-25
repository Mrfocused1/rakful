import Foundation

/// The resale categories Rakful can discover. Mapping from on-device
/// classifier labels lives in `CategoryClassifier`.
enum ResaleCategory: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case clothing
    case trainers
    case electronics
    case furniture
    case bags
    case accessories
    case other

    var id: String { rawValue }

    /// Reads a stored value, including categories that were merged: cameras
    /// are now electronics and watches are accessories. `DataMigration`
    /// rewrites old records; this keeps anything not yet migrated readable.
    static func stored(_ rawValue: String) -> ResaleCategory? {
        if let merged = mergedRawValues[rawValue] { return ResaleCategory(rawValue: merged) }
        return ResaleCategory(rawValue: rawValue)
    }

    static let mergedRawValues = ["cameras": "electronics", "watches": "accessories"]

    var displayName: String {
        switch self {
        case .clothing: "Clothing"
        case .trainers: "Footwear"
        case .electronics: "Electronics"
        case .furniture: "Furniture"
        case .bags: "Bags"
        case .accessories: "Accessories"
        case .other: "Other"
        }
    }

    /// A generic noun used to name a newly discovered item before the user
    /// confirms anything more specific.
    var itemNoun: String {
        switch self {
        case .clothing: "Clothing"
        case .trainers: "Footwear"
        case .electronics: "Electronics"
        case .furniture: "Furniture"
        case .bags: "Bag"
        case .accessories: "Accessory"
        case .other: "Item"
        }
    }

    var systemImage: String {
        switch self {
        case .clothing: "tshirt"
        case .trainers: "shoe"
        case .electronics: "laptopcomputer"
        case .furniture: "sofa"
        case .bags: "handbag"
        case .accessories: "eyeglasses"
        case .other: "shippingbox"
        }
    }

    /// The photos a buyer expects, suggested when the item has none of its own.
    var listingShots: [LocalizedStringResource] {
        switch self {
        case .clothing: ["Front, laid flat or on a hanger", "Back", "Size and care label", "Close-up of the fabric and any marks"]
        case .trainers: ["Both shoes from the side", "Soles", "Size label inside the tongue", "Any creases or marks"]
        case .bags: ["Front and back", "Inside", "Straps and hardware", "Any marks or wear"]
        case .accessories: ["Front", "Back, underside or case back", "Label, maker's mark or clasp", "Any marks or wear"]
        case .electronics: ["Front", "Back", "Ports, buttons or lens", "Any marks or wear"]
        case .furniture: ["The whole piece", "Another angle", "Close-up of the material", "Any marks or wear"]
        case .other: ["Front", "Back", "Any labels", "Any marks or wear"]
        }
    }

    static var allEnabledByDefault: Set<ResaleCategory> { Set(allCases) }
}

/// Whether the user still owns a discovered item. Only `.owned` items can
/// progress to listing preparation.
enum OwnershipStatus: String, Codable, Sendable, CaseIterable {
    case unconfirmed
    case owned
    case notOwned
    case unsure

    var displayName: String {
        switch self {
        case .unconfirmed: "Needs Review"
        case .owned: "Owned"
        case .notOwned: "Not Owned"
        case .unsure: "Not Sure"
        }
    }

    var systemImage: String {
        switch self {
        case .unconfirmed: "circle.dashed"
        case .owned: "checkmark.circle.fill"
        case .notOwned: "xmark.circle"
        case .unsure: "questionmark.circle"
        }
    }

    var canPrepareListing: Bool { self == .owned }
}

enum ItemCondition: String, Codable, Sendable, CaseIterable, Identifiable {
    case newWithTags
    case newWithoutTags
    case likeNew
    case good
    case fair
    case forParts

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newWithTags: "New with Tags"
        case .newWithoutTags: "New without Tags"
        case .likeNew: "Like New"
        case .good: "Good"
        case .fair: "Fair"
        case .forParts: "For Parts or Not Working"
        }
    }

    /// Conditions where buyers expect defects to be described.
    var expectsDefectDescription: Bool {
        switch self {
        case .fair, .forParts: true
        default: false
        }
    }
}

/// Coarse confidence buckets shown to people. Raw scores stay internal.
enum ConfidenceLevel: String, Codable, Sendable, Comparable {
    case low, medium, high

    init(score: Double) {
        switch score {
        case 0.75...: self = .high
        case 0.55..<0.75: self = .medium
        default: self = .low
        }
    }

    var displayName: String {
        switch self {
        case .low: "Low Confidence"
        case .medium: "Medium Confidence"
        case .high: "High Confidence"
        }
    }

    var shortName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// 0...1 value used for variable SF Symbol rendering.
    var meterValue: Double {
        switch self {
        case .low: 0.33
        case .medium: 0.66
        case .high: 1.0
        }
    }

    private var order: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func < (lhs: ConfidenceLevel, rhs: ConfidenceLevel) -> Bool { lhs.order < rhs.order }
}
