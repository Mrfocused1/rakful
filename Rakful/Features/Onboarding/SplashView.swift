import SwiftUI

/// Shown for a moment at launch, before onboarding or Home. The launch
/// screen is plain LaunchBackground, so the hand-off is seamless. The name
/// and tagline blur in together, then the mark's three cards settle into
/// place beside the name, one after another. The mark's space is reserved
/// from the start, so the text never moves. With Reduce Motion on,
/// everything simply fades in.
struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lilac: CGFloat = 0
    @State private var blue: CGFloat = 0
    @State private var frost: CGFloat = 0
    @State private var showsText = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
            VStack(spacing: 6) {
                // The logo lockup: the mark beside the name.
                HStack(spacing: 0) {
                    RakfulMark(blue: blue, lilac: lilac, frost: frost)
                        .frame(width: 76, height: 76)
                        // The cards sit inside the mark's square; trim its
                        // empty margins so the name and tagline sit close.
                        .padding(.trailing, -8)
                        .padding(.vertical, -14)
                    // The Rakful wordmark, as in the brand logo.
                    Image("RakfulWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 40)
                        .foregroundStyle(Theme.ink)
                        .blur(radius: showsText ? 0 : 8)
                        .opacity(showsText ? 1 : 0)
                }
                Text("The easy way to resell.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .blur(radius: showsText ? 0 : 8)
                    .opacity(showsText ? 1 : 0)
            }
            .offset(y: -12)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rakful. The easy way to resell.")
        .onAppear(perform: animate)
    }

    private func animate() {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.4)) {
                lilac = 1; blue = 1; frost = 1; showsText = true
            }
            return
        }
        withAnimation(.easeOut(duration: 0.55).delay(0.1)) { showsText = true }
        let settle = Animation.spring(response: 0.55, dampingFraction: 0.78)
        withAnimation(settle.delay(0.7)) { lilac = 1 }
        withAnimation(settle.delay(0.82)) { blue = 1 }
        withAnimation(settle.delay(0.97)) { frost = 1 }
    }
}
