import Foundation

struct BrandMatch: Sendable, Equatable {
    let brand: String
    let matchedText: String
}

/// Matches text recognised in a photo against a curated brand list.
///
/// This only produces *suggestions* ("Text in the photo reads “NIKE”") that
/// the user must confirm. It never infers models, authenticity or anything
/// not literally visible. Brands are scoped to categories to avoid matching
/// common words (e.g. "Coach" is only considered for bags).
struct BrandTextMatcher: Sendable {
    struct Brand: Sendable {
        let name: String
        let aliases: [String]
        let categories: Set<ResaleCategory>
    }

    func matches(in texts: [String], category: ResaleCategory) -> [BrandMatch] {
        let tokens = texts.map(Self.normalise)
        var found: [BrandMatch] = []
        for brand in Self.brands where brand.categories.contains(category) {
            for alias in [brand.name] + brand.aliases {
                let needle = Self.normalise(alias)
                guard needle.count >= 2 else { continue }
                if let index = tokens.firstIndex(where: { Self.containsWord(needle, in: $0) }) {
                    found.append(BrandMatch(brand: brand.name, matchedText: texts[index]))
                    break
                }
            }
        }
        return found
    }

    static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).uppercased()
        let allowed = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(allowed).split(separator: " ").joined(separator: " ")
    }

    private static func containsWord(_ needle: String, in haystack: String) -> Bool {
        " \(haystack) ".contains(" \(needle) ")
    }

    static let brands: [Brand] = {
        let footwear: Set<ResaleCategory> = [.trainers, .clothing]
        let apparel: Set<ResaleCategory> = [.clothing, .trainers, .bags, .accessories]
        let tech: Set<ResaleCategory> = [.electronics, .cameras]
        let fashion: Set<ResaleCategory> = [.bags, .accessories, .clothing, .trainers, .watches]
        func b(_ name: String, _ categories: Set<ResaleCategory>, _ aliases: [String] = []) -> Brand {
            Brand(name: name, aliases: aliases, categories: categories)
        }
        return [
            b("Nike", footwear), b("Adidas", footwear), b("New Balance", footwear), b("ASICS", footwear),
            b("Puma", footwear), b("Reebok", footwear), b("Converse", footwear), b("Vans", [.trainers]),
            b("Salomon", footwear), b("Hoka", footwear), b("Dr. Martens", footwear, ["Dr Martens"]),
            b("Birkenstock", [.trainers]), b("UGG", [.trainers]), b("Timberland", footwear),
            b("The North Face", apparel, ["North Face"]), b("Patagonia", apparel), b("Arc'teryx", apparel, ["Arcteryx"]),
            b("Barbour", apparel), b("Levi's", apparel, ["Levis"]), b("Ralph Lauren", apparel), b("Stone Island", apparel),
            b("Carhartt", apparel), b("Canada Goose", apparel), b("Moncler", apparel), b("Burberry", fashion),
            b("Louis Vuitton", fashion), b("Gucci", fashion), b("Prada", fashion), b("Chanel", fashion),
            b("Hermès", fashion, ["Hermes"]), b("Coach", [.bags]), b("Michael Kors", fashion), b("Mulberry", [.bags]),
            b("Longchamp", [.bags]), b("Herschel", [.bags]), b("Fjällräven", [.bags, .clothing], ["Fjallraven"]),
            b("Samsonite", [.bags]), b("Ray-Ban", [.accessories], ["RayBan"]), b("Oakley", [.accessories]),
            b("Apple", tech), b("Samsung", tech), b("Sony", tech), b("Bose", [.electronics]), b("Beats", [.electronics]),
            b("Nintendo", [.electronics]), b("PlayStation", [.electronics]), b("Xbox", [.electronics]),
            b("Dyson", [.electronics, .other]), b("Bang & Olufsen", [.electronics], ["B&O"]), b("Sonos", [.electronics]),
            b("Microsoft", [.electronics]), b("Dell", [.electronics]), b("Lenovo", [.electronics]),
            b("DJI", tech), b("GoPro", tech), b("Canon", [.cameras]), b("Nikon", [.cameras]),
            b("Fujifilm", [.cameras], ["Fuji"]), b("Leica", [.cameras]), b("Olympus", [.cameras]),
            b("Panasonic", tech), b("Lumix", [.cameras]), b("Hasselblad", [.cameras]), b("Polaroid", [.cameras]),
            b("Rolex", [.watches]), b("Omega", [.watches]), b("Seiko", [.watches]), b("Casio", [.watches]),
            b("G-Shock", [.watches], ["GShock"]), b("Tissot", [.watches]), b("TAG Heuer", [.watches]),
            b("Citizen", [.watches]), b("Garmin", [.watches, .electronics]), b("Fossil", [.watches]),
            b("Tudor", [.watches]), b("Longines", [.watches]), b("Swatch", [.watches]),
            b("IKEA", [.furniture]), b("Herman Miller", [.furniture]), b("Vitra", [.furniture]),
            b("Fender", [.other]), b("Gibson", [.other]), b("Yamaha", [.other, .electronics]),
            b("Brompton", [.other]), b("LEGO", [.other]),
        ]
    }()
}
