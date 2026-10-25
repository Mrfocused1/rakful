import SwiftData
import SwiftUI

/// Four-step introduction. Photo access is never requested here before the
/// person understands why; the system prompt appears only when they choose
/// Start Discovery.
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(PreferencesStore.self) private var preferences
    @Environment(EntitlementService.self) private var entitlements
    @Environment(DiscoveryCoordinator.self) private var discovery
    @Environment(BackgroundDiscoveryManager.self) private var background

    @State private var step = 0
    @State private var categories: Set<ResaleCategory> = ResaleCategory.allEnabledByDefault
    @State private var showsPlans = false

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                WelcomeStep().tag(0)
                PrivacyStep().tag(1)
                CategoriesStep(selection: $categories).tag(2)
                ReadyStep(
                    isChargeAndDiscoverIncluded: entitlements.limits.chargeAndDiscover,
                    onStart: startDiscovery,
                    onEnableCharging: enableChargeAndDiscover,
                    onExploreSamples: exploreSamples,
                    onSkip: finish
                )
                .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.smooth, value: step)

            if step < stepCount - 1 {
                VStack(spacing: 14) {
                    PageDots(count: stepCount, current: step)
                    Button {
                        withAnimation(.smooth) { step += 1 }
                    } label: {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .prominentActionStyle()
                    .controlSize(.large)
                    .disabled(step == 2 && categories.isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .background(Color(.systemBackground))
        .sensoryFeedback(.selection, trigger: step)
        // When replayed from Settings, start from the categories already chosen.
        .onAppear { categories = preferences.enabledCategories }
        .sheet(isPresented: $showsPlans, onDismiss: {
            if entitlements.limits.chargeAndDiscover { enableChargeAndDiscover() }
        }) {
            PlansView()
        }
    }

    private func finish() {
        preferences.enabledCategories = categories.isEmpty ? ResaleCategory.allEnabledByDefault : categories
        preferences.hasCompletedOnboarding = true
    }

    private func startDiscovery() {
        finish()
        Task { await discovery.start(mode: .manual, canPromptForAccess: true) }
    }

    private func enableChargeAndDiscover() {
        guard entitlements.limits.chargeAndDiscover else {
            showsPlans = true
            return
        }
        preferences.chargeAndDiscoverEnabled = true
        startDiscovery()
    }

    private func exploreSamples() {
        try? SampleData.insert(into: context)
        finish()
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

private struct StepHeader<Illustration: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var illustration: Illustration

    var body: some View {
        VStack(spacing: 16) {
            illustration
                .padding(.bottom, 8)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                StepHeader(
                    title: "Find things to sell in your photos.",
                    subtitle: "Rakful finds things you own in your photos — like jackets, footwear and bags — and helps you sell them."
                ) {
                    WelcomeIllustration()
                }
                VStack(alignment: .leading, spacing: 24) {
                    FeatureRow(systemImage: "viewfinder", title: "Discover", detail: "Spots resellable items across the photos you choose.")
                    FeatureRow(systemImage: "checkmark.circle", title: "Confirm", detail: "You decide which items you still own.")
                    FeatureRow(systemImage: "tag", title: "Sell", detail: "Prepare listings in moments, ready for your marketplace.")
                }
                .padding(.horizontal, 32)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
    }
}

private struct PrivacyStep: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                StepHeader(
                    title: "Your photos stay under your control.",
                    subtitle: "Discovery runs on your phone. Nothing is uploaded unless you choose to."
                ) {
                    PrivacyIllustration()
                }
                VStack(alignment: .leading, spacing: 24) {
                    FeatureRow(systemImage: "iphone", title: "Analysed on your phone", detail: "On-device image recognition looks for items.")
                    FeatureRow(systemImage: "photo.on.rectangle", title: "You choose what to share", detail: "Allow all photos or just a selection, and change it at any time.")
                    FeatureRow(systemImage: "icloud.slash", title: "Cloud is optional", detail: "Cloud features stay off unless you turn them on and agree first.")
                    FeatureRow(systemImage: "lock.shield", title: "Your library is never changed", detail: "Rakful never deletes, edits or moves your photos.")
                }
                .padding(.horizontal, 32)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
    }
}

private struct CategoriesStep: View {
    @Binding var selection: Set<ResaleCategory>

    var body: some View {
        List {
            Section {
                StepHeader(
                    title: "Choose what to discover.",
                    subtitle: "You can change this later in Settings."
                ) {
                    CategoriesIllustration()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                CategorySelectionList(selection: $selection)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

private struct ReadyStep: View {
    let isChargeAndDiscoverIncluded: Bool
    let onStart: () -> Void
    let onEnableCharging: () -> Void
    let onExploreSamples: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 40) {
                    StepHeader(
                        title: "Ready when you are.",
                        subtitle: "Start a discovery now, or let Rakful work while your phone charges."
                    ) {
                        ReadyIllustration()
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        FeatureRow(systemImage: "hand.tap", title: "Start Discovery", detail: "Analyse your photos now. You'll be asked which photos to allow.")
                        FeatureRow(systemImage: "moon.stars", title: "Charge & Discover", detail: "While your phone charges, discovery can continue in the background. Progress is saved as it goes.")
                    }
                    .padding(.horizontal, 32)
                }
                .padding(.top, 32)
                .padding(.bottom, 24)
            }

            VStack(spacing: 12) {
                Button(action: onStart) {
                    Text("Start Discovery").frame(maxWidth: .infinity)
                }
                .prominentActionStyle()
                .controlSize(.large)

                Button(action: onEnableCharging) {
                    Text("Enable Charge & Discover").frame(maxWidth: .infinity)
                }
                .secondaryActionStyle()
                .controlSize(.large)

                if !isChargeAndDiscoverIncluded {
                    Text("Charge & Discover is included with Rakful Plus.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 24) {
                    Button("Explore Sample Items", action: onExploreSamples)
                        .accessibilityIdentifier("onboarding.exploreSamples")
                    Button("Not Now", action: onSkip)
                }
                .font(.subheadline)
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }
}
