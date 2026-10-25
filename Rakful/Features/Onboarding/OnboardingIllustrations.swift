import SwiftUI

// Onboarding illustrations: the sample clothing photos (the same ones used for
// demo items) plus shapes and SF Symbols in the brand palette.
// Decorative only: hidden from VoiceOver, still with Reduce Motion.

/// Gentle up-and-down drift for illustration elements.
private struct Drift: ViewModifier {
    var distance: CGFloat = 6
    var duration: Double = 1.8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isUp = false

    func body(content: Content) -> some View {
        content
            .offset(y: isUp ? -distance : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) { isUp = true }
            }
    }
}

private extension View {
    func drift(_ distance: CGFloat = 6, duration: Double = 1.8) -> some View {
        modifier(Drift(distance: distance, duration: duration))
    }
}

private struct Backdrop: View {
    var body: some View {
        Circle()
            .fill(Brand.accent.opacity(0.1))
            .frame(width: 210, height: 210)
    }
}

/// A small photo card showing one of the sample clothing photos.
private struct PhotoCard: View {
    let image: String
    /// Landscape, matching the sample photos' 1.2:1 crop.
    var size = CGSize(width: 112, height: 94)

    var body: some View {
        Brand.photoGround
            .overlay { Image(image).resizable().scaledToFill() }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white, lineWidth: 3) }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

/// Four corner brackets, like a camera viewfinder.
private struct ViewfinderCorners: Shape {
    var length: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (point, dx, dy) in corners {
            path.move(to: CGPoint(x: point.x, y: point.y + dy * length))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x + dx * length, y: point.y))
        }
        return path
    }
}

/// A simple phone outline that hosts content on its screen.
private struct PhoneFrame<Screen: View>: View {
    var size = CGSize(width: 116, height: 196)
    @ViewBuilder var screen: Screen

    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .overlay { screen.padding(12).padding(.top, 8) }
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 5)
            }
            .overlay(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.18)).frame(width: 34, height: 6).padding(.top, 9)
            }
            .frame(width: size.width, height: size.height)
    }
}

struct WelcomeIllustration: View {
    var body: some View {
        ZStack {
            Backdrop()
            PhotoCard(image: "SampleTrainers")
                .rotationEffect(.degrees(-14))
                .offset(x: -78, y: 18)
            PhotoCard(image: "SampleLeatherHandbag")
                .rotationEffect(.degrees(13))
                .offset(x: 78, y: 22)
            PhotoCard(image: "SampleDenimJacket", size: CGSize(width: 132, height: 110))
                .overlay {
                    ViewfinderCorners()
                        .stroke(Brand.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .padding(-12)
                }
        }
        .frame(height: 210)
        .accessibilityHidden(true)
    }
}

struct PrivacyIllustration: View {
    private let tiles: [ResaleCategory] = [.trainers, .electronics, .clothing, .accessories, .bags, .clothing, .trainers, .furniture, .other]

    var body: some View {
        ZStack {
            Backdrop()
            PhoneFrame {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { _, category in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(category.brandTint.opacity(0.75))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            LockBadge()
                .offset(x: 60, y: 60)
                .drift(4, duration: 2.2)
        }
        .frame(height: 210)
        .accessibilityHidden(true)
    }
}

/// A raised disc that hosts an illustration badge.
private struct BadgeDisc<Content: View>: View {
    var size: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Brand.surface, Brand.adaptive(light: UIColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 1), dark: .tertiarySystemBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay { Circle().strokeBorder(Brand.adaptive(light: .white, dark: UIColor.white.withAlphaComponent(0.08)), lineWidth: 1.5) }
                .shadow(color: Brand.accent.opacity(0.18), radius: size * 0.16, y: size * 0.09)
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            content
        }
        .frame(width: size, height: size)
    }
}

/// A glass magnifier: glossy blue rim, pale glass with a glint, and a handle.
private struct MagnifierGlyph: View {
    var body: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Brand.accent, Color(red: 0.02, green: 0.24, blue: 0.72)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 7.5, height: 15)
                .rotationEffect(.degrees(-45))
                .offset(x: 11, y: 11)
            Circle()
                .fill(RadialGradient(colors: [.white, Color(red: 0.84, green: 0.9, blue: 1)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 16))
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [Color(red: 0.36, green: 0.6, blue: 1), Brand.accent], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 4.5
                    )
                }
                .overlay {
                    Circle()
                        .trim(from: 0.56, to: 0.7)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .padding(8)
                }
                .frame(width: 28, height: 28)
                .shadow(color: Brand.accent.opacity(0.3), radius: 4, y: 2)
                .offset(x: -3, y: -3)
        }
    }
}

/// A crescent moon in indigo and lilac, with two small stars.
private struct MoonGlyph: View {
    private let indigo = Color(red: 0.38, green: 0.34, blue: 0.93)

    var body: some View {
        ZStack {
            Crescent()
                .fill(LinearGradient(colors: [Brand.lilac, indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .topLeading, endPoint: .center)
                        .clipShape(Crescent())
                }
                .shadow(color: indigo.opacity(0.35), radius: 5, y: 3)
                .frame(width: 30, height: 30)
                .offset(x: -3, y: 1)
            Circle().fill(indigo.opacity(0.8)).frame(width: 4.5, height: 4.5).offset(x: 12, y: -11)
            Circle().fill(Brand.lilac).frame(width: 3, height: 3).offset(x: 16, y: 1)
        }
    }
}

/// A crescent: a circle with an offset circle cut away towards the top right.
private struct Crescent: Shape {
    func path(in rect: CGRect) -> Path {
        let cut = rect.offsetBy(dx: rect.width * 0.36, dy: -rect.height * 0.18)
        return Path(ellipseIn: rect).subtracting(Path(ellipseIn: cut))
    }
}

/// A padlock made from the logo mark: a glossy blue body under a silver
/// shackle, on a white disc.
private struct LockBadge: View {
    var body: some View {
        BadgeDisc(size: 86) {
            Shackle(rightLegTrim: 2.5)
                .stroke(
                    LinearGradient(colors: [Color(white: 0.9), Color(white: 0.55)], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 5.5, lineCap: .butt)
                )
                .overlay {
                    Shackle(rightLegTrim: 2.5)
                        .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .butt))
                        .offset(x: -0.8, y: -0.8)
                }
                // Narrow enough to sit on the mark's flat top edge. The right
                // leg stops at that edge so it never shows through the cut.
                .frame(width: 16, height: 19)
                .offset(y: -18)
            lockBody
                .frame(width: 42, height: 43)
                .offset(y: 10)
        }
    }

    private var lockBody: some View {
        let mark = Image("RakfulMark").resizable().scaledToFit()
        return ZStack {
            LinearGradient(colors: [Color(red: 0.27, green: 0.52, blue: 1), Brand.accent], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
        }
        .mask(mark)
        .shadow(color: Brand.accent.opacity(0.25), radius: 5, y: 3)
    }
}

/// A padlock shackle: two legs joined by a half circle. The right leg can
/// stop short of the bottom.
private struct Shackle: Shape {
    var rightLegTrim: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addRelativeArc(center: CGPoint(x: rect.midX, y: rect.minY + radius), radius: radius, startAngle: .degrees(180), delta: .degrees(180))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rightLegTrim))
        return path
    }
}

struct CategoriesIllustration: View {
    var body: some View {
        ZStack {
            Backdrop()
            selectedCard("SampleWoolJumper", badge: .topLeading)
                .rotationEffect(.degrees(-12))
                .offset(x: -80, y: 16)
            selectedCard("SampleLeatherHandbag")
                .rotationEffect(.degrees(12))
                .offset(x: 80, y: 20)
            selectedCard("SampleTrainers", size: CGSize(width: 132, height: 110))
        }
        .frame(height: 210)
        .accessibilityHidden(true)
    }

    /// A clothing photo ticked as a chosen category.
    private func selectedCard(_ image: String, size: CGSize = CGSize(width: 112, height: 94), badge: Alignment = .topTrailing) -> some View {
        PhotoCard(image: image, size: size)
            .overlay(alignment: badge) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Brand.accent)
                    .background(Circle().fill(.white).padding(2))
                    .offset(x: badge == .topLeading ? -8 : 8, y: -8)
            }
    }
}

struct ReadyIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCharging = false

    var body: some View {
        ZStack {
            Backdrop()
            PhoneFrame(size: CGSize(width: 108, height: 182)) {
                ZStack {
                    Circle()
                        .stroke(Brand.accent.opacity(0.2), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: isCharging ? 0.85 : 0.35)
                        .stroke(Brand.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Brand.accent)
                }
                .frame(width: 64, height: 64)
                .frame(maxHeight: .infinity)
            }
            BadgeDisc(size: 62) { MoonGlyph() }
                .offset(x: -82, y: -66)
                .drift(5, duration: 2.4)
            BadgeDisc(size: 72) { MagnifierGlyph() }
                .offset(x: 64, y: 62)
                .drift(4, duration: 2)
        }
        .frame(height: 210)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { isCharging = true }
        }
    }
}
