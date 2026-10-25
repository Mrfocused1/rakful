import SwiftUI

// The approved Rakful look: a pale grey canvas, softly raised white cards,
// frosted folders with preview cards tucked behind their fronts, and
// layered pastel glass icons with small white outline symbols. Colour lives
// in the icons; text stays crisp and dark.

enum Theme {
    static let canvas = Color(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF5 / 255)
    static let card = Color.white
    static let ink = Color(red: 0x15 / 255, green: 0x15 / 255, blue: 0x18 / 255)
    static let secondaryInk = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x78 / 255)
    /// Unselected pills and quiet fills.
    static let quietFill = Color(red: 0xE9 / 255, green: 0xE9 / 255, blue: 0xEE / 255)
    static let actionBlack = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x15 / 255)

    static let pagePadding: CGFloat = 20
    static let cardGap: CGFloat = 14
    static let sectionGap: CGFloat = 26
    static let cardRadius: CGFloat = 24
    static let rowRadius: CGFloat = 20

    /// Room kept below scrolling content for the floating dock.
    static let dockClearance: CGFloat = 76

    /// The active dock icon: lavender into powder blue.
    static let activeGradient = LinearGradient(colors: [Pastel.lavender.deep, Pastel.powder.deep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A pastel pair for layered glass icons: a light front and a deeper rear.
struct Pastel: Equatable, Sendable {
    let front: Color
    let deep: Color

    static let lavender = Pastel(front: Color(red: 0xAC / 255, green: 0x98 / 255, blue: 1), deep: Color(red: 0x8B / 255, green: 0x6F / 255, blue: 0xF5 / 255))
    static let powder = Pastel(front: Color(red: 0x81 / 255, green: 0xBC / 255, blue: 1), deep: Color(red: 0x4C / 255, green: 0x93 / 255, blue: 0xF7 / 255))
    static let blush = Pastel(front: Color(red: 1, green: 0x9E / 255, blue: 0xC6 / 255), deep: Color(red: 0xF7 / 255, green: 0x6F / 255, blue: 0xA8 / 255))
    static let apricot = Pastel(front: Color(red: 1, green: 0xC0 / 255, blue: 0x8D / 255), deep: Color(red: 0xF9 / 255, green: 0x99 / 255, blue: 0x55 / 255))
    static let mint = Pastel(front: Color(red: 0x9D / 255, green: 0xE6 / 255, blue: 0xC2 / 255), deep: Color(red: 0x52 / 255, green: 0xC9 / 255, blue: 0x92 / 255))
}

extension ResaleCategory {
    var pastel: Pastel {
        switch self {
        case .trainers, .clothing: .blush
        case .electronics: .powder
        case .accessories: .lavender
        case .bags, .furniture: .apricot
        case .other: .mint
        }
    }

    /// Outline symbol for glass icons.
    var glyph: String {
        switch self {
        case .bags: "bag"
        default: systemImage
        }
    }
}

// MARK: - Layered glass icon

/// Two overlapping rounded pastel tiles — a deeper rear tile offset up and to
/// the left, a translucent front tile with a fine white rim — and a small
/// white outline symbol. Decorative: it shows a category, never a product.
struct GlassIcon: View {
    let symbol: String
    let pastel: Pastel
    var size: CGFloat = 56

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let tile = size * 0.76
        let radius = tile * 0.3
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(colors: [pastel.deep.opacity(0.9), pastel.front], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: tile, height: tile)
                .rotationEffect(.degrees(-7))
                .offset(x: -size * 0.1, y: -size * 0.09)
            ZStack {
                if reduceTransparency {
                    shape.fill(pastel.front.mix(with: .white, by: 0.25))
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(LinearGradient(colors: [pastel.front.opacity(0.55), pastel.deep.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                shape.fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .topLeading, startRadius: 0, endRadius: tile * 0.9))
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(0.75, size * 0.018))
                Image(systemName: symbol)
                    .symbolVariant(.none)
                    .font(.system(size: tile * 0.44, weight: size < 40 ? .semibold : .medium))
                    .foregroundStyle(.white)
                    .shadow(color: pastel.deep.opacity(0.35), radius: size * 0.02, y: size * 0.01)
            }
            .frame(width: tile, height: tile)
            .offset(x: size * 0.08, y: size * 0.08)
            .shadow(color: pastel.deep.opacity(0.32), radius: size * 0.12, y: size * 0.07)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension GlassIcon {
    init(category: ResaleCategory, size: CGFloat = 56) {
        self.init(symbol: category.glyph, pastel: category.pastel, size: size)
    }
}

/// An item's decorative icon. Real photos stay in the item and listing screens.
struct ItemGlassIcon: View {
    let item: CandidateItem
    var size: CGFloat = 52

    var body: some View {
        GlassIcon(category: item.category, size: size)
    }
}

// MARK: - Folder

/// The front of a folder: a raised tab across the left, a soft S-curve,
/// then a lower edge to the right.
struct FolderFrontShape: Shape {
    var tabFraction: CGFloat = 0.44
    var tabDrop: CGFloat = 22
    var cornerRadius: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.height / 3)
        let drop = min(tabDrop, rect.height / 4)
        let tabEnd = rect.minX + rect.width * tabFraction
        let run = min(46, rect.width * 0.16)
        let low = rect.minY + drop
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.addLine(to: CGPoint(x: tabEnd - run / 2, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: tabEnd + run / 2, y: low),
            control1: CGPoint(x: tabEnd, y: rect.minY),
            control2: CGPoint(x: tabEnd, y: low)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: low))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: low), tangent2End: CGPoint(x: rect.maxX, y: low + radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - radius, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// One card peeking out of a folder.
struct FolderPreview: Identifiable, Equatable {
    let id: String
    let symbol: String
    let pastel: Pastel

    init(category: ResaleCategory) {
        id = category.rawValue
        symbol = category.glyph
        pastel = category.pastel
    }

    init(id: String, symbol: String, pastel: Pastel) {
        self.id = id
        self.symbol = symbol
        self.pastel = pastel
    }

    /// Distinct categories, most recent first, for a folder's preview cards.
    static func categories(of items: [CandidateItem], limit: Int = 3) -> [FolderPreview] {
        var seen = Set<ResaleCategory>()
        return items.compactMap { seen.insert($0.category).inserted ? FolderPreview(category: $0.category) : nil }.prefix(limit).map { $0 }
    }
}

/// A frosted folder: a rear panel, staggered preview cards rising from
/// behind, and a milky front holding the label and an optional black action.
struct FrostedFolder<Label: View>: View {
    var previews: [FolderPreview]
    /// Height of the area above the front where preview cards show.
    var rise: CGFloat = 108
    var frontHeight: CGFloat = 160
    var compact = false
    var action: FolderAction?
    @ViewBuilder var label: Label

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isShown = false

    var body: some View {
        VStack(spacing: 0) {
            // Cards rise from behind the front; it's drawn after them, so it
            // covers their lower edges.
            GeometryReader { proxy in previewCards(width: proxy.size.width) }
                .frame(height: rise)
            front
        }
        .background {
            GeometryReader { proxy in
                let inset: CGFloat = compact ? 6 : 8
                // Rear panel, visible above the front's lower edge.
                RoundedRectangle(cornerRadius: compact ? 20 : 26, style: .continuous)
                    .fill(reduceTransparency ? AnyShapeStyle(Color(white: 0.97)) : AnyShapeStyle(.white.opacity(0.55)))
                    .overlay { RoundedRectangle(cornerRadius: compact ? 20 : 26, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1) }
                    .frame(width: proxy.size.width - inset * 2, height: max(0, proxy.size.height - rise + (compact ? 10 : 14)))
                    .offset(x: inset, y: rise - (compact ? 10 : 14))
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
            }
        }
        .onAppear {
            guard !isShown else { return }
            if reduceMotion { isShown = true } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(0.05)) { isShown = true }
            }
        }
    }

    private func previewCards(width: CGFloat) -> some View {
        let shown = Array(previews.prefix(3))
        let count = max(shown.count, 1)
        let card: CGFloat = compact
            ? min(width * 0.56, rise * 1.2)
            : min(width * (count <= 2 ? 0.4 : 0.31), rise * 1.18)
        let inset = width * (compact ? 0.08 : 0.05)
        let step: CGFloat = compact
            ? card * 0.36
            : (count > 1 ? (width - inset * 2 - card) / CGFloat(count - 1) : 0)
        let rotations: [Double] = compact ? [-7, 6, 12] : (count <= 2 ? [-8, 6] : [-9, 1, 8])
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, preview in
                FolderPreviewCard(preview: preview, size: card)
                    .rotationEffect(.degrees(rotations[index % rotations.count]))
                    .offset(
                        x: inset + CGFloat(index) * step,
                        y: (compact ? 6 : 8) + CGFloat(index % 2) * -6 + (isShown ? 0 : 22)
                    )
                    .opacity(isShown ? 1 : 0)
                    .zIndex(Double(index))
            }
        }
        .frame(width: width, height: rise, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// The milky front. It grows with its label at large text sizes.
    private var front: some View {
        let tabDrop: CGFloat = compact ? 16 : 24
        let shape = FolderFrontShape(tabFraction: compact ? 0.5 : 0.44, tabDrop: tabDrop, cornerRadius: compact ? 22 : 28)
        // At accessibility sizes the action sits under the label so the
        // label keeps the full width.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))
        return layout {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                BlackSquareButton(systemImage: action.systemImage, size: compact ? 44 : 54, accessibilityLabel: action.accessibilityLabel, action: action.perform)
                    .accessibilityIdentifier(action.identifier ?? "")
            }
        }
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.top, tabDrop + (compact ? 12 : 18))
        .padding(.bottom, compact ? 14 : 20)
        .frame(maxWidth: .infinity, minHeight: frontHeight, alignment: .bottomLeading)
        .background {
            ZStack {
                if reduceTransparency {
                    shape.fill(Color(white: 0.985))
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                }
                shape.stroke(LinearGradient(colors: [.white, .white.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.07), radius: 22, y: 12)
        }
    }
}

struct FolderAction {
    let systemImage: String
    let accessibilityLabel: String
    var identifier: String?
    let perform: () -> Void
}

/// A frosted white card holding one glass icon.
struct FolderPreviewCard: View {
    let preview: FolderPreview
    let size: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(Color(white: 0.96))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(LinearGradient(colors: [.white.opacity(0.75), preview.pastel.front.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            shape.strokeBorder(.white.opacity(0.95), lineWidth: 1)
            GlassIcon(symbol: preview.symbol, pastel: preview.pastel, size: size * 0.74)
                .offset(y: -size * 0.04)
        }
        .frame(width: size, height: size)
        .shadow(color: preview.pastel.deep.opacity(0.14), radius: 14, y: 6)
    }
}

// MARK: - Buttons

/// A small, tactile near-black rounded square with a white symbol.
struct BlackSquareButton: View {
    let systemImage: String
    var size: CGFloat = 54
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.22), Theme.actionBlack], startPoint: .top, endPoint: .bottom))
                        .overlay { RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                }
                .shadow(color: .black.opacity(0.22), radius: 8, y: 5)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Compresses slightly while pressed.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// The black capsule used for the main action on a screen.
struct BlackPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .frame(minHeight: 54)
            .background {
                Capsule().fill(LinearGradient(colors: [Color(white: 0.2), Theme.actionBlack], startPoint: .top, endPoint: .bottom))
                    .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
            }
            .shadow(color: .black.opacity(0.22), radius: 12, y: 7)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// A white capsule for secondary actions.
struct WhitePillStyle: ButtonStyle {
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? Font.subheadline : .body).weight(.semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, compact ? 16 : 24)
            .frame(minHeight: compact ? 40 : 52)
            .background(Capsule().fill(compact ? Theme.canvas : Theme.card))
            .overlay { Capsule().strokeBorder(.black.opacity(0.06), lineWidth: 1) }
            .shadow(color: .black.opacity(compact ? 0 : 0.06), radius: 10, y: 4)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// A white circle holding a header symbol (settings, search…).
struct CircleIconLabel: View {
    let systemImage: String
    var isActive = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(isActive ? .white : Theme.ink)
            .frame(width: 44, height: 44)
            .background(Circle().fill(isActive ? Theme.actionBlack : Theme.card))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
            .contentShape(Circle())
    }
}

// MARK: - Cards and layout

extension View {
    /// A softly raised white card.
    func raisedCard(radius: CGFloat = Theme.cardRadius, padding: CGFloat? = 16) -> some View {
        self
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white, lineWidth: 1) }
            .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
    }

    /// Canvas background and room for the floating dock.
    func glassPage() -> some View {
        self
            .clearsDock()
            .background(Theme.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
    }

    /// Ends scrolling content above the floating dock. The dock's own inset
    /// doesn't reach inside navigation stacks, so each scrolling screen in a
    /// tab applies this.
    func clearsDock() -> some View {
        safeAreaPadding(.bottom, Theme.dockClearance)
    }
}

/// Large screen title with trailing circular actions. At accessibility
/// text sizes the actions move below the title so it isn't truncated.
struct ScreenHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    titleText
                    HStack(spacing: 10) { trailing }
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    titleText
                    Spacer(minLength: 8)
                    trailing
                }
            }
        }
        .padding(.top, 8)
    }

    private var titleText: some View {
        Text(title)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// A section heading with an optional trailing link.
struct GlassSectionHeader: View {
    let title: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(minHeight: 44)
            }
        }
    }
}

/// A compact white row: glass icon, title, subtitle and trailing content.
struct GlassRow<Trailing: View>: View {
    let icon: GlassIcon
    let title: String
    var subtitle: String?
    var isSample = false
    @ViewBuilder var trailing: Trailing

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        icon
                        Spacer(minLength: 8)
                        trailing
                    }
                    text
                }
            } else {
                HStack(spacing: 14) {
                    icon
                    text
                    Spacer(minLength: 8)
                    trailing
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.card))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    titleText
                    if isSample { SampleBadge() }
                }
                VStack(alignment: .leading, spacing: 3) {
                    titleText
                    if isSample { SampleBadge() }
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.ink)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            .multilineTextAlignment(.leading)
    }
}

extension GlassRow where Trailing == EmptyView {
    init(icon: GlassIcon, title: String, subtitle: String? = nil, isSample: Bool = false) {
        self.init(icon: icon, title: title, subtitle: subtitle, isSample: isSample) { EmptyView() }
    }
}

/// Short relative times for rows: "Just now", "5m ago", "2h ago", "3d ago".
enum ShortTime {
    static func string(for date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "Just now")
        case ..<3600: return String(localized: "\(Int(seconds / 60))m ago")
        case ..<86_400: return String(localized: "\(Int(seconds / 3600))h ago")
        case ..<(7 * 86_400): return String(localized: "\(Int(seconds / 86_400))d ago")
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

/// The chevron used at the end of tappable rows.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.secondaryInk.opacity(0.7))
            .accessibilityHidden(true)
    }
}

/// A filter capsule: raised white when selected, quiet grey otherwise.
struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.ink : Theme.secondaryInk)
                .padding(.horizontal, 18)
                .frame(minHeight: 38)
                .background(Capsule().fill(isSelected ? Theme.card : Theme.quietFill))
                .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 8, y: 3)
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Floating dock

/// The tab bar as a compact floating frosted pill with a raised white
/// capsule behind the selected tab. It drives the app's one TabView.
struct FloatingDock: View {
    @Binding var selection: AppTab
    var badges: [AppTab: Int] = [:]

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var namespace

    private let tabs: [(AppTab, String, String)] = [
        (.discover, "Home", "house"),
        (.items, "Wardrobe", "hanger"),
        (.sell, "Sell", "tag"),
        (.activity, "Activity", "chart.bar"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.0) { tab, title, symbol in
                let isSelected = selection == tab
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: symbol)
                            .symbolVariant(isSelected ? .fill : .none)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(isSelected ? AnyShapeStyle(Theme.activeGradient) : AnyShapeStyle(Theme.ink.opacity(0.75)))
                            .overlay(alignment: .topTrailing) {
                                if let count = badges[tab], count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 17, minHeight: 17)
                                        .background(Capsule().fill(Color.red))
                                        .offset(x: 12, y: -6)
                                }
                            }
                        Text(title)
                            .font(.caption2.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Theme.ink : Theme.secondaryInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.card)
                                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                                .matchedGeometryEffect(id: "active", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(badges[tab].map { $0 > 0 ? "\($0) to review" : "" } ?? "")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier("tab.\(title.lowercased())")
            }
        }
        .padding(5)
        .background {
            Capsule()
                .fill(reduceTransparency ? AnyShapeStyle(Color(white: 0.95)) : AnyShapeStyle(.ultraThinMaterial))
                .overlay { Capsule().fill(.white.opacity(reduceTransparency ? 0 : 0.68)) }
                .overlay { Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1) }
                .shadow(color: .black.opacity(0.1), radius: 18, y: 8)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.bottom, 4)
    }
}
