import Foundation

struct ClassifiedLabel: Sendable, Hashable {
    let identifier: String
    let confidence: Double
}

/// Result of mapping general-purpose image labels to a resale category.
struct CategoryMatch: Sendable, Equatable {
    let category: ResaleCategory
    /// Calibrated score in 0...1 used for thresholds and confidence badges.
    let score: Double
    /// The classifier label that produced the match.
    let label: String
    /// A generic noun for the object (e.g. "Backpack"), never a brand or model.
    let suggestedName: String
}

/// Maps Vision's built-in image-classification taxonomy to resale categories.
///
/// Vision's general classifier recognises object *types* ("sneaker",
/// "backpack", "camera"), not brands or models. This mapping uses identifiers
/// verified against `ClassifyImageRequest.supportedIdentifiers`, and never
/// claims more than the label supports.
struct CategoryClassifier: Sendable {
    struct Rule: Sendable {
        let category: ResaleCategory
        /// Weight < 1 for broad labels ("clothing") that are weaker evidence.
        let weight: Double
        let name: String
    }

    var minimumScore: Double = 0.4
    var personPenalty: Double = 0.75

    func match(_ labels: [ClassifiedLabel], enabledCategories: Set<ResaleCategory>) -> CategoryMatch? {
        let confidence = Dictionary(labels.map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max)

        // Screenshots and documents aren't possessions.
        if (confidence["screenshot"] ?? 0) >= 0.5 { return nil }
        for label in Self.documentLabels where (confidence[label] ?? 0) >= 0.6 { return nil }

        let personScore = Self.personScore(in: labels)

        var best: CategoryMatch?
        for label in labels {
            guard let rule = Self.rules[label.identifier], enabledCategories.contains(rule.category) else { continue }
            var score = label.confidence * rule.weight
            // Clothing worn by a person is weaker evidence of a resellable item.
            if personScore >= Self.personThreshold, rule.category == .clothing || rule.category == .accessories {
                score *= personPenalty
            }
            if score > (best?.score ?? 0) {
                best = CategoryMatch(category: rule.category, score: score, label: label.identifier, suggestedName: rule.name)
            }
        }
        guard let best, best.score >= minimumScore else { return nil }

        // Prefer a more specific label in the same category for the name when
        // it is nearly as strong (e.g. "Backpack" over "Bag").
        if let specific = labels
            .compactMap({ label -> (ClassifiedLabel, Rule)? in
                guard let rule = Self.rules[label.identifier], rule.category == best.category, rule.weight == 1 else { return nil }
                return (label, rule)
            })
            .max(by: { $0.0.confidence < $1.0.confidence }),
           specific.0.confidence >= best.score * 0.8 {
            return CategoryMatch(category: best.category, score: best.score, label: specific.0.identifier, suggestedName: specific.1.name)
        }
        return best
    }

    static let personLabels = ["people", "adult", "child", "teen", "baby"]
    /// Person-label confidence at which a photo counts as showing a person.
    static let personThreshold = 0.6

    /// The strongest person label, 0 when there is none.
    static func personScore(in labels: [ClassifiedLabel]) -> Double {
        labels.filter { personLabels.contains($0.identifier) }.map(\.confidence).max() ?? 0
    }
    static let documentLabels = ["document", "printed_page", "receipt", "handwriting", "diagram", "chart"]

    static let rules: [String: Rule] = {
        var rules: [String: Rule] = [:]
        func add(_ category: ResaleCategory, _ weight: Double, _ entries: [(String, String)]) {
            for (identifier, name) in entries { rules[identifier] = Rule(category: category, weight: weight, name: name) }
        }
        add(.clothing, 0.85, [("clothing", "Clothing"), ("textile", "Textile")])
        add(.clothing, 1, [
            ("jacket", "Jacket"), ("jeans", "Jeans"), ("hoodie", "Hoodie"), ("gown", "Gown"), ("suit", "Suit"),
            ("tuxedo", "Tuxedo"), ("kimono", "Kimono"), ("sari", "Sari"), ("kilt", "Kilt"), ("bathrobe", "Bathrobe"),
            ("poncho", "Poncho"), ("cloak", "Cloak"), ("leotard", "Leotard"), ("swimsuit", "Swimwear"),
            ("wetsuit", "Wetsuit"), ("wedding_dress", "Wedding Dress"), ("costume", "Costume"), ("scarf", "Scarf"),
            ("sock", "Socks"),
        ])
        add(.trainers, 0.9, [("footwear", "Footwear"), ("shoes", "Shoes")])
        add(.trainers, 1, [
            ("sneaker", "Trainers"), ("boot", "Boots"), ("high_heel", "Heels"), ("loafer", "Loafers"),
            ("moccasin", "Moccasins"), ("sandal", "Sandals"), ("ski_boot", "Ski Boots"), ("ice_skates", "Ice Skates"),
            ("rollerskates", "Roller Skates"),
        ])
        add(.electronics, 0.85, [("consumer_electronics", "Electronics"), ("computer", "Computer")])
        add(.electronics, 1, [
            ("laptop", "Laptop"), ("computer_keyboard", "Keyboard"), ("computer_monitor", "Monitor"),
            ("computer_mouse", "Computer Mouse"), ("computer_tower", "Desktop Computer"), ("phone", "Phone"),
            ("headphones", "Headphones"), ("television", "Television"), ("gamepad", "Game Controller"),
            ("joystick", "Joystick"), ("videogame", "Video Game"), ("speakers_music", "Speakers"), ("stereo", "Stereo"),
            ("turntable", "Turntable"), ("microphone", "Microphone"), ("drone_machine", "Drone"), ("printer", "Printer"),
        ])
        add(.electronics, 1, [
            ("camera", "Camera"), ("tripod", "Tripod"), ("binoculars", "Binoculars"), ("telescope", "Telescope"),
        ])
        add(.electronics, 0.8, [("optical_equipment", "Optical Equipment")])
        add(.furniture, 0.85, [("furniture", "Furniture")])
        add(.furniture, 1, [
            ("chair", "Chair"), ("armchair", "Armchair"), ("sofa", "Sofa"), ("table", "Table"), ("desk", "Desk"),
            ("cabinet", "Cabinet"), ("bookshelf", "Bookshelf"), ("stool", "Stool"), ("swivel_chair", "Office Chair"),
            ("chaise", "Chaise"), ("high_chair", "High Chair"), ("crib", "Cot"), ("lamp", "Lamp"),
            ("chandelier", "Chandelier"), ("folding_chair", "Folding Chair"),
        ])
        add(.accessories, 0.85, [("timepiece", "Watch")])
        add(.accessories, 1, [("watch", "Watch")])
        add(.bags, 0.9, [("bag", "Bag")])
        add(.bags, 1, [
            ("backpack", "Backpack"), ("purse", "Handbag"), ("briefcase", "Briefcase"), ("luggage", "Luggage"),
            ("suitcase", "Suitcase"),
        ])
        add(.accessories, 0.85, [("jewelry", "Jewellery"), ("headgear", "Headwear")])
        add(.accessories, 1, [
            ("sunglasses", "Sunglasses"), ("eyeglasses", "Glasses"), ("hat", "Hat"), ("beanie", "Beanie"),
            ("baseball_hat", "Cap"), ("fedora", "Fedora"), ("cowboy_hat", "Cowboy Hat"), ("sunhat", "Sun Hat"),
            ("glove", "Gloves"), ("mitten", "Mittens"), ("necktie", "Tie"), ("bowtie", "Bow Tie"), ("wallet", "Wallet"),
            ("umbrella", "Umbrella"), ("tiara", "Tiara"),
        ])
        add(.other, 1, [
            ("bicycle", "Bicycle"), ("guitar", "Guitar"), ("violin", "Violin"), ("ukulele", "Ukulele"),
            ("piano", "Piano"), ("drum", "Drum"), ("saxophone", "Saxophone"), ("trumpet", "Trumpet"),
            ("skateboard", "Skateboard"), ("surfboard", "Surfboard"), ("snowboard", "Snowboard"),
            ("golf_club", "Golf Club"), ("scooter", "Scooter"), ("stroller", "Pushchair"), ("car_seat", "Car Seat"),
            ("board_game", "Board Game"), ("stuffed_animals", "Soft Toy"), ("doll", "Doll"), ("tent", "Tent"),
            ("blender", "Blender"), ("toaster", "Toaster"), ("vacuum", "Vacuum Cleaner"), ("juicer", "Juicer"),
            ("treadmill", "Treadmill"), ("dumbbell", "Dumbbell"), ("vase", "Vase"), ("typewriter", "Typewriter"),
        ])
        add(.other, 0.85, [("musical_instrument", "Musical Instrument"), ("string_instrument", "String Instrument"), ("sports_equipment", "Sports Equipment"), ("toy", "Toy")])
        return rules
    }()
}
