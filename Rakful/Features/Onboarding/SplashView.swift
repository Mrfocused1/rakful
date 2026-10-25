import SwiftUI

/// Shown for a moment at launch, before onboarding or Home. The launch
/// screen is plain LaunchBackground, so the hand-off is seamless; the mark's
/// three cards then settle into place one after another, followed by the
/// name and tagline. With Reduce Motion on, everything simply fades in.
struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lilac: CGFloat = 0
    @State private var blue: CGFloat = 0
    @State private var frost: CGFloat = 0
    @State private var showsName = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
            VStack(spacing: 18) {
                RakfulMark(blue: blue, lilac: lilac, frost: frost)
                    .frame(width: 250, height: 250)
                VStack(spacing: 6) {
                    Text("Rakful")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.ink)
                    Text("The easy way to resell.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.secondaryInk)
                }
                .blur(radius: showsName ? 0 : 8)
                .opacity(showsName ? 1 : 0)
                .offset(y: showsName || reduceMotion ? 0 : 6)
            }
            .offset(y: -20)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rakful. The easy way to resell.")
        .onAppear(perform: animate)
    }

    private func animate() {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.4)) {
                lilac = 1; blue = 1; frost = 1; showsName = true
            }
            return
        }
        let settle = Animation.spring(response: 0.55, dampingFraction: 0.78)
        withAnimation(settle.delay(0.05)) { lilac = 1 }
        withAnimation(settle.delay(0.17)) { blue = 1 }
        withAnimation(settle.delay(0.32)) { frost = 1 }
        withAnimation(.easeOut(duration: 0.5).delay(0.7)) { showsName = true }
    }
}
