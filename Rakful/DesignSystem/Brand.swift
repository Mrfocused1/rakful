import SwiftUI

// Rakful's own visual layer: calm, native and restrained. Navigation, lists,
// forms and settings stay standard iOS; colour is reserved for actions and the
// summary card, both in the logo's blue.

enum Brand {
    /// The app's accent (AccentColor asset): the logo's blue.
    static let accent = Color.accentColor
    /// The icon's lilac, for soft accents such as shadows and confetti.
    static let lilac = Color(red: 0.74, green: 0.72, blue: 0.98)

    /// Very pale blue-grey page background.
    static let canvas = adaptive(light: UIColor(red: 0.953, green: 0.961, blue: 0.976, alpha: 1), dark: .systemBackground)
    /// Card surface on the canvas.
    static let surface = adaptive(light: .white, dark: .secondarySystemBackground)
    /// Pale neutral ground behind product photos.
    static let photoGround = adaptive(light: UIColor(white: 0.965, alpha: 1), dark: .tertiarySystemBackground)
    /// Fine border for cards.
    static let hairline = adaptive(
        light: UIColor(red: 0.85, green: 0.87, blue: 0.92, alpha: 0.7),
        dark: UIColor.white.withAlphaComponent(0.08)
    )

    /// Deep end of the logo blue, for the summary card and its shadow.
    static let deepBlue = Color(red: 0.03, green: 0.24, blue: 0.74)
    /// The summary card's fill: bright logo blue into deep blue.
    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.24, green: 0.48, blue: 1), Color(red: 0.03, green: 0.33, blue: 0.97), deepBlue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// A light/dark colour. Built outside any actor: UIKit resolves dynamic
    /// colours on SwiftUI's render thread, so the provider must not be
    /// main-actor isolated (that traps at runtime under Swift 6).
    nonisolated static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static let cardCornerRadius: CGFloat = 20
}

extension Font {
    /// The large valuation: New York, the system serif, for contrast with SF Pro.
    static func valuation(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .serif, weight: .regular)
    }
}

extension Font {
    /// Display face for money figures: SF Pro Expanded. Scales with Dynamic Type.
    static func money(_ style: Font.TextStyle = .largeTitle, weight: Font.Weight = .heavy) -> Font {
        .system(style, weight: weight).width(.expanded)
    }
}

extension ResaleCategory {
    /// Colour used for category artwork (sample items, illustrations).
    var brandTint: Color {
        switch self {
        case .clothing: Color(red: 0.27, green: 0.47, blue: 0.86)
        case .trainers: Color(red: 0.94, green: 0.44, blue: 0.31)
        case .electronics: Color(red: 0.44, green: 0.40, blue: 0.86)
        case .furniture: Color(red: 0.62, green: 0.45, blue: 0.31)
        case .bags: Color(red: 0.80, green: 0.53, blue: 0.20)
        case .accessories: Color(red: 0.86, green: 0.38, blue: 0.56)
        case .other: Color(red: 0.45, green: 0.50, blue: 0.53)
        }
    }
}

// MARK: - Category artwork

/// A symbol on a category-coloured gradient. Used for sample items, which
/// must never look like the user's own photos, and for illustrations.
struct CategoryArtwork: View {
    let category: ResaleCategory
    var symbol: String?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(
                    colors: [category.brandTint.mix(with: .white, by: 0.22), category.brandTint],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: symbol ?? category.systemImage)
                    .font(.system(size: side * 0.4, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.15), radius: side * 0.03, y: side * 0.02)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Celebration

/// A short confetti burst. Fires each time `trigger` changes; does nothing
/// with Reduce Motion on.
struct ConfettiBurst: View {
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @State private var pieces: [Piece] = (0..<80).map { _ in Piece.random() }

    private static let duration: TimeInterval = 2.2

    var body: some View {
        TimelineView(.animation(paused: startedAt == nil)) { timeline in
            Canvas { context, size in
                guard let startedAt else { return }
                let t = timeline.date.timeIntervalSince(startedAt)
                guard t < Self.duration else { return }
                context.opacity = max(0, 1 - pow(t / Self.duration, 2))
                for piece in pieces {
                    let x = size.width * piece.originX + piece.velocity.dx * t
                    let y = size.height * 0.3 + piece.velocity.dy * t + 0.5 * 1100 * t * t
                    var layer = context
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .degrees(piece.spin * t))
                    let rect = CGRect(x: -piece.size.width / 2, y: -piece.size.height / 2, width: piece.size.width, height: piece.size.height)
                    layer.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(piece.color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) {
            guard !reduceMotion else { return }
            pieces = (0..<80).map { _ in Piece.random() }
            startedAt = .now
            Task {
                try? await Task.sleep(for: .seconds(Self.duration))
                startedAt = nil
            }
        }
    }

    struct Piece {
        var originX: Double
        var velocity: CGVector
        var spin: Double
        var size: CGSize
        var color: Color

        static let palette: [Color] = [Brand.accent, Brand.lilac, .cyan, .pink, .yellow, .white]

        static func random() -> Piece {
            Piece(
                originX: .random(in: 0.3...0.7),
                velocity: CGVector(dx: .random(in: -260...260), dy: .random(in: -820 ... -380)),
                spin: .random(in: -540...540),
                size: CGSize(width: .random(in: 6...10), height: .random(in: 10...16)),
                color: palette.randomElement() ?? .yellow
            )
        }
    }
}

extension View {
    /// Presents a brief celebration card with confetti, dismissing itself.
    func celebration(isPresented: Binding<Bool>, title: String, message: String) -> some View {
        overlay { CelebrationOverlay(isPresented: isPresented, title: title, message: message) }
    }
}

private struct CelebrationOverlay: View {
    @Binding var isPresented: Bool
    let title: String
    let message: String

    @State private var burst = 0

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }
                    .transition(.opacity)
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Brand.accent)
                        .symbolEffect(.bounce, value: burst)
                        .accessibilityHidden(true)
                    Text(title).font(.title2.weight(.bold))
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: 320)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
                .accessibilityElement(children: .combine)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .task {
                    burst += 1
                    AccessibilityNotification.Announcement("\(title) \(message)").post()
                    try? await Task.sleep(for: .seconds(2.6))
                    isPresented = false
                }
            }
            ConfettiBurst(trigger: burst).ignoresSafeArea()
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isPresented)
        .sensoryFeedback(.success, trigger: burst)
    }
}

// MARK: - Small brand pieces

/// The Rakful mark, rebuilt in code from the approved logo: three layered
/// glass cards — powder blue at the back left, lilac at the back right and a
/// frosted card in front — sheared into the logo's isometric tilt. Each card
/// is a separate layer so the launch animation can assemble them.
struct RakfulMark: View {
    /// 0 = cards apart and hidden, 1 = assembled.
    var blue: CGFloat = 1
    var lilac: CGFloat = 1
    var frost: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                card(fill: LinearGradient(colors: [Color(red: 0.84, green: 0.74, blue: 1), Color(red: 0.73, green: 0.55, blue: 0.98), Color(red: 0.86, green: 0.70, blue: 0.99)], startPoint: .topLeading, endPoint: .bottomTrailing),
                     edge: Color(red: 0.62, green: 0.45, blue: 0.93), side: side, width: 0.455, height: 0.39)
                    .offset(x: side * 0.109 + (1 - lilac) * side * 0.18, y: -side * 0.11 - (1 - lilac) * side * 0.1)
                    .opacity(Double(lilac))
                card(fill: LinearGradient(colors: [Color(red: 0.55, green: 0.78, blue: 1), Color(red: 0.25, green: 0.56, blue: 0.98), Color(red: 0.62, green: 0.76, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing),
                     edge: Color(red: 0.18, green: 0.45, blue: 0.9), side: side, width: 0.44, height: 0.42)
                    .offset(x: -side * 0.115 - (1 - blue) * side * 0.18, y: side * 0.064 + (1 - blue) * side * 0.06)
                    .opacity(Double(blue))
                frostedCard(side: side)
                    .offset(x: -side * 0.006, y: side * 0.002 + (1 - frost) * side * 0.2)
                    .opacity(Double(frost))
            }
            // Shear about the view's origin, then re-centre.
            .transformEffect(CGAffineTransform(a: 1, b: 0.3, c: 0.08, d: 1, tx: -side * 0.04, ty: -side * 0.15))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func card(fill: LinearGradient, edge: Color, side: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.085, style: .continuous)
        return ZStack {
            // Thickness: a deeper copy just below and to the right.
            shape.fill(edge.opacity(0.85)).offset(x: side * 0.012, y: side * 0.016)
            shape.fill(fill)
            shape.fill(RadialGradient(colors: [.white.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: side * 0.4))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: side * 0.008)
        }
        .frame(width: side * width, height: side * height)
        .shadow(color: edge.opacity(0.3), radius: side * 0.05, y: side * 0.04)
    }

    private func frostedCard(side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.08, style: .continuous)
        return ZStack {
            shape.fill(.white.opacity(0.5)).offset(x: side * 0.01, y: side * 0.014)
            shape.fill(.ultraThinMaterial)
            shape.fill(LinearGradient(colors: [.white.opacity(0.55), Color(red: 0.86, green: 0.86, blue: 1).opacity(0.55), Color(red: 0.93, green: 0.82, blue: 1).opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(RadialGradient(colors: [Color(red: 0.92, green: 0.8, blue: 1).opacity(0.7), .clear], center: UnitPoint(x: 0.62, y: 0.42), startRadius: 0, endRadius: side * 0.16))
            shape.strokeBorder(.white.opacity(0.95), lineWidth: side * 0.01)
        }
        .frame(width: side * 0.41, height: side * 0.345)
        .shadow(color: Color(red: 0.4, green: 0.45, blue: 0.9).opacity(0.18), radius: side * 0.04, y: side * 0.03)
    }
}

