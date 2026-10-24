import Foundation

/// The resale categories Rakful can discover. Mapping from on-device
/// classifier labels lives in `CategoryClassifier`.
enum ResaleCategory: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case clothing
    case trainers
    case electronics
    case cameras
    case furniture
    case watches
    case bags
    case accessories
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clothing: "Clothing"
        case .trainers: "Trainers & Shoes"
        case .electronics: "Electronics"
        case .cameras: "Cameras"
        case .furniture: "Furniture"
        case .watches: "Watches"
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
        case .cameras: "Camera Equipment"
        case .furniture: "Furniture"
        case .watches: "Watch"
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
        case .cameras: "camera"
        case .furniture: "sofa"
        case .watches: "watch.analog"
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
        case .watches: ["Face", "Back of the case", "Strap and clasp", "Any scratches"]
        case .accessories: ["Front", "Back or underside", "Label or maker's mark", "Any marks or wear"]
        case .electronics: ["Front", "Back", "Ports and buttons", "Any marks or wear"]
        case .cameras: ["Front, with the lens", "Back and screen", "Top controls", "Any marks or wear"]
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
