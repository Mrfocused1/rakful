import SwiftUI

/// Shown for a moment at launch, before onboarding or Home. The logo is the
/// same image, at the same size and position, as the launch screen
/// (LaunchLockup centred on LaunchBackground), so it doesn't move or
/// change. Only the tagline animates, blurring in below the logo.
struct SplashView: View {
    /// How long the intro stays before fading to the app.
    static let duration: Duration = .seconds(4)

    @State private var showsTagline = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
            Image("LaunchLockup")
                .overlay(alignment: .bottom) {
                    Text("The easy way to resell.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize()
                        .blur(radius: showsTagline ? 0 : 12)
                        .opacity(showsTagline ? 1 : 0)
                        // Just below the wordmark, without moving the logo.
                        .alignmentGuide(.bottom) { $0[.top] + 14 }
                }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rakful. The easy way to resell.")
        .onAppear {
            // A slow blur fade, starting just after the logo is on screen.
            // It doesn't move anything, so it stays with Reduce Motion on.
            withAnimation(.easeOut(duration: 0.9).delay(0.35)) { showsTagline = true }
        }
    }
}

extension AnyTransition {
    /// Blurs while fading, used when the intro gives way to the app.
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(isHidden: true), identity: BlurFade(isHidden: false))
    }
}

private struct BlurFade: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: isHidden ? 18 : 0)
            .opacity(isHidden ? 0 : 1)
    }
}
