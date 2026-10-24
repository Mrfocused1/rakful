import SwiftUI

/// Shown for a moment at launch, before onboarding or Home. The logo and
/// background match the launch screen (LaunchLogo centred on
/// LaunchBackground) so the hand-off is seamless; the tagline then blurs in
/// below the logo without moving it.
struct SplashView: View {
    @State private var showsTagline = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
            Image("LaunchLogo")
                .overlay(alignment: .bottom) {
                    Text("The easy way to resell.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 300)
                        .blur(radius: showsTagline ? 0 : 10)
                        .opacity(showsTagline ? 1 : 0)
                        .alignmentGuide(.bottom) { $0[.top] - 14 }
                }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rakful. The easy way to resell.")
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(0.1)) { showsTagline = true }
        }
    }
}
