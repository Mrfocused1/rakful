import SwiftUI

// MARK: - Liquid Glass with graceful fallback

extension View {
    /// Liquid Glass prominent button on iOS 26+, standard prominent otherwise.
    @ViewBuilder
    func prominentActionStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Liquid Glass secondary button on iOS 26+, bordered otherwise.
    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func minimizingTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

enum Metrics {
    /// Matches the corner radius of inset-grouped lists on the running OS.
    static var groupedCornerRadius: CGFloat {
        if #available(iOS 26.0, *) { 26 } else { 12 }
    }
}

// MARK: - Grouped containers (match inset-grouped List styling in ScrollViews)

struct GroupedSection<Content: View>: View {
    var title: LocalizedStringKey?
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 0) { content }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Metrics.groupedCornerRadius, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

struct GroupedRow<Trailing: View>: View {
    var title: LocalizedStringKey
    var systemImage: String?
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }
                Text(title)
                Spacer(minLength: 8)
                trailing
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            if showsDivider {
                Divider().padding(.leading, systemImage == nil ? 16 : 52)
            }
        }
    }
}

// MARK: - Settings-style icon

struct SettingsIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Badges & indicators

struct SampleBadge: View {
    var body: some View {
        // Uppercased in the string, not with textCase, which would also
        // uppercase the spoken label.
        Text(String(localized: "Sample").localizedUppercase)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("Sample item, not from your photos")
    }
}

struct ConfidenceIndicator: View {
    let level: ConfidenceLevel
    var showsLabel = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill", variableValue: level.meterValue)
                .imageScale(.small)
            if showsLabel { Text(level.shortName) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.displayName)
    }
}

struct OwnershipBadge: View {
    let status: OwnershipStatus
    var showsLabel = true

    var tint: Color {
        switch status {
        case .owned: .green
        case .unconfirmed: .orange
        case .unsure: .yellow
        case .notOwned: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage).foregroundStyle(tint)
            if showsLabel { Text(status.displayName).lineLimit(1) }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ownership: \(status.displayName)")
    }
}

struct PriceText: View {
    let item: CandidateItem

    var body: some View {
        if let estimate = item.latestEstimate {
            Text(estimate.range.formatted)
                .monospacedDigit()
        } else {
            Text("No price data")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Thumbnails

/// Square thumbnail for an item. Sample items show category artwork rather
/// than a photo, so they can never be mistaken for the user's own pictures.
struct ItemThumbnail: View {
    let item: CandidateItem
    var photo: ItemPhoto?
    var cornerRadius: CGFloat = 10

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if item.isDemo {
                    CategoryArtwork(category: item.category, symbol: item.demoSymbol)
                } else {
                    PhotoImage(photo: photo ?? item.primaryPhoto)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel(item.displayName)
    }
}

struct PhotoImage: View {
    let photo: ItemPhoto?
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .transition(.opacity)
                } else if didFail {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Photo unavailable")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: photo?.id) {
                guard let photo else { didFail = true; return }
                let loaded = await ThumbnailLoader.shared.thumbnail(for: photo, pointSize: proxy.size, scale: displayScale)
                withAnimation(.easeOut(duration: 0.2)) {
                    image = loaded
                    didFail = loaded == nil
                }
            }
        }
    }
}

// MARK: - Checklist row

struct ChecklistRow: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    let isComplete: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? Color.green : Color.secondary)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isComplete ? "Complete" : "Incomplete")
    }
}
