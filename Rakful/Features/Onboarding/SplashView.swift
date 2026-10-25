import SwiftUI

/// Shown for a moment at launch, before onboarding or Home. The launch
/// screen is plain LaunchBackground, so the hand-off is seamless; the mark's
/// three cards then settle into place one after another, the name slides in
/// beside the mark, and the tagline appears underneath. With Reduce Motion
/// on, everything simply fades in.
struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lilac: CGFloat = 0
    @State private var blue: CGFloat = 0
    @State private var frost: CGFloat = 0
    @State private var showsName = false
    @State private var showsTagline = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
            VStack(spacing: 12) {
                // The logo lockup: the mark beside the name.
                HStack(spacing: 6) {
                    RakfulMark(blue: blue, lilac: lilac, frost: frost)
                        .frame(width: 76, height: 76)
                    Text("Rakful")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .blur(radius: showsName ? 0 : 6)
                        .opacity(showsName ? 1 : 0)
                        .offset(x: showsName || reduceMotion ? 0 : -10)
                }
                Text("The easy way to resell.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .blur(radius: showsTagline ? 0 : 8)
                    .opacity(showsTagline ? 1 : 0)
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
                lilac = 1; blue = 1; frost = 1; showsName = true; showsTagline = true
            }
            return
        }
        let settle = Animation.spring(response: 0.55, dampingFraction: 0.78)
        withAnimation(settle.delay(0.05)) { lilac = 1 }
        withAnimation(settle.delay(0.17)) { blue = 1 }
        withAnimation(settle.delay(0.32)) { frost = 1 }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.55)) { showsName = true }
        withAnimation(.easeOut(duration: 0.5).delay(0.9)) { showsTagline = true }
    }
}
