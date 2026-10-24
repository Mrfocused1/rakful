import SwiftData
import SwiftUI

/// Walks through items awaiting confirmation as a swipeable card stack:
/// right for I Own It, left for Not Mine, up for Not Sure. Buttons and
/// VoiceOver actions do the same. The app never assumes a photographed item
/// belongs to the user.
struct ReviewQueueView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(filter: #Predicate<CandidateItem> { $0.ownershipRaw == "unconfirmed" }, sort: \CandidateItem.confidence, order: .reverse)
    private var queue: [CandidateItem]

    @State private var reviewedCount = 0
    @State private var keptCount = 0
    @State private var feedbackTrigger = 0
    @State private var dragOffset: CGSize = .zero
    @State private var flying: FlyingCard?
    @State private var lastDecision: Decision?
    @State private var celebration = 0

    private static let commitDistance: CGFloat = 110

    private struct FlyingCard {
        let item: CandidateItem
        var offset: CGSize
    }

    private struct Decision {
        let itemID: UUID
        let status: OwnershipStatus
        let previousUpdatedAt: Date?
        let activityEvent: ActivityEvent?
    }

    var body: some View {
        NavigationStack {
            Group {
                if queue.isEmpty {
                    completion
                } else {
                    reviewer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(queue.isEmpty ? "" : "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if lastDecision != nil {
                        Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !queue.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Text("\(queue.count) to review")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: feedbackTrigger)
        }
    }

    // MARK: - Reviewing

    private var reviewer: some View {
        VStack(spacing: 16) {
            Text("Do you still own this item?")
                .font(.title3.weight(.bold))
                .padding(.top, 8)
            cardStack
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
                .frame(maxHeight: .infinity)
            decisionButtons
            Text("Swipe right if it's yours, left if it isn't. Only items you own can be prepared for sale.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.bottom, 12)
    }

    private var dragProgress: CGFloat {
        min(1, hypot(dragOffset.width, dragOffset.height) / Self.commitDistance)
    }

    private var cardStack: some View {
        let visible = Array(queue.prefix(3))
        return ZStack {
            ForEach(Array(visible.enumerated().reversed()), id: \.element.id) { index, item in
                let depth = max(0, CGFloat(index) - (index > 0 ? dragProgress : 0))
                SwipeCard(item: item, offset: index == 0 ? dragOffset : .zero, isTop: index == 0)
                    .scaleEffect(1 - depth * 0.05, anchor: .bottom)
                    .offset(y: depth * 14)
                    .zIndex(Double(visible.count - index))
                    .allowsHitTesting(index == 0 && flying == nil)
                    .gesture(dragGesture, including: index == 0 ? .all : .subviews)
                    .accessibilityHidden(index > 0)
                    .accessibilityAction(named: "I Own It") { commit(.owned) }
                    .accessibilityAction(named: "Not Mine") { commit(.notOwned) }
                    .accessibilityAction(named: "Not Sure") { commit(.unsure) }
            }
            if let flying {
                SwipeCard(item: flying.item, offset: flying.offset, isTop: true)
                    .zIndex(100)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard flying == nil else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                let t = value.translation
                let predicted = value.predictedEndTranslation
                let isVertical = abs(t.height) > abs(t.width)
                if !isVertical, t.width > Self.commitDistance || predicted.width > 280 {
                    commit(.owned)
                } else if !isVertical, t.width < -Self.commitDistance || predicted.width < -280 {
                    commit(.notOwned)
                } else if isVertical, t.height < -Self.commitDistance || predicted.height < -320 {
                    commit(.unsure)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragOffset = .zero }
                }
            }
    }

    private var decisionButtons: some View {
        HStack(alignment: .top, spacing: 28) {
            DecisionButton(title: "Not Mine", systemImage: "xmark", tint: .red, diameter: 60) { commit(.notOwned) }
            DecisionButton(title: "Not Sure", systemImage: "questionmark", tint: .orange, diameter: 52) { commit(.unsure) }
            DecisionButton(title: "I Own It", systemImage: "checkmark", tint: Brand.accent, diameter: 72, isProminent: true) { commit(.owned) }
        }
        .disabled(flying != nil)
    }

    // MARK: - Completion

    private var completion: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Brand.accent.opacity(0.12)).frame(width: 150, height: 150)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(Brand.accent)
                    .symbolEffect(.bounce, value: celebration)
            }
            .accessibilityHidden(true)
            Text("All Caught Up").font(.title.weight(.bold))
            Text(completionMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            VStack(spacing: 10) {
                if keptCount > 0 {
                    Button {
                        router.selectedTab = .sell
                        dismiss()
                    } label: {
                        Text("Go to Sell").frame(maxWidth: 260)
                    }
                    .prominentActionStyle()
                    Button("Done") { dismiss() }
                        .secondaryActionStyle()
                } else {
                    Button { dismiss() } label: {
                        Text("Done").frame(maxWidth: 260)
                    }
                    .prominentActionStyle()
                }
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .overlay { ConfettiBurst(trigger: celebration).ignoresSafeArea() }
        .sensoryFeedback(.success, trigger: celebration)
        .onAppear { if keptCount > 0 { celebration += 1 } }
    }

    private var completionMessage: String {
        guard reviewedCount > 0 else { return "There's nothing waiting for review." }
        let reviewed = "You've reviewed \(reviewedCount) \(reviewedCount == 1 ? "item" : "items")."
        switch keptCount {
        case 0: return reviewed
        case 1: return "\(reviewed) The item you own is ready to list in Sell."
        default: return "\(reviewed) The \(keptCount) items you own are ready to list in Sell."
        }
    }

    // MARK: - Decisions

    private func commit(_ status: OwnershipStatus) {
        guard flying == nil, let item = queue.first else { return }
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.25)) { decide(status, for: item) }
            return
        }
        let exit: CGSize = switch status {
        case .owned: CGSize(width: 650, height: dragOffset.height + 60)
        case .notOwned: CGSize(width: -650, height: dragOffset.height + 60)
        default: CGSize(width: dragOffset.width, height: -1000)
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            flying = FlyingCard(item: item, offset: dragOffset)
            dragOffset = .zero
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { decide(status, for: item) }
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.28)) {
                flying?.offset = exit
            } completion: {
                flying = nil
            }
        }
    }

    private func decide(_ status: OwnershipStatus, for item: CandidateItem) {
        let previousUpdatedAt = item.ownershipUpdatedAt
        item.setOwnership(status)
        var event: ActivityEvent?
        if status == .owned {
            event = context.logActivity(.ownershipConfirmed, title: "Ownership confirmed", detail: item.displayName, itemID: item.id, isDemo: item.isDemo)
            keptCount += 1
        }
        try? context.save()
        lastDecision = Decision(itemID: item.id, status: status, previousUpdatedAt: previousUpdatedAt, activityEvent: event)
        reviewedCount += 1
        feedbackTrigger += 1
    }

    /// Restores the last reviewed item to the queue, removing its history entry.
    private func undo() {
        guard let decision = lastDecision else { return }
        let id = decision.itemID
        guard let item = try? context.fetch(FetchDescriptor<CandidateItem>(predicate: #Predicate { $0.id == id })).first else {
            lastDecision = nil
            return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            item.ownership = .unconfirmed
            item.ownershipUpdatedAt = decision.previousUpdatedAt
            if !item.ownershipHistory.isEmpty { item.ownershipHistory.removeLast() }
            if let event = decision.activityEvent { context.delete(event) }
            try? context.save()
        }
        reviewedCount -= 1
        if decision.status == .owned { keptCount -= 1 }
        lastDecision = nil
        feedbackTrigger += 1
    }
}

// MARK: - Card

private struct SwipeCard: View {
    let item: CandidateItem
    let offset: CGSize
    let isTop: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var photoIndex = 0

    private var photos: [ItemPhoto] {
        item.distinctPhotos.isEmpty ? item.sortedPhotos : item.distinctPhotos
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork
            LinearGradient(
                stops: [.init(color: .clear, location: 0.42), .init(color: .black.opacity(0.78), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            details.padding(20)
        }
        .overlay(alignment: .top) {
            if photos.count > 1 { photoIndicator.padding(10) }
        }
        .overlay { stamps }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(isTop ? 0.16 : 0.06), radius: 14, y: 8)
        .offset(offset)
        .rotationEffect(.degrees(reduceMotion ? 0 : Double(offset.width / 20)), anchor: .bottom)
        .onTapGesture(coordinateSpace: .local) { location in
            guard photos.count > 1 else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                photoIndex = location.x < 120 ? max(0, photoIndex - 1) : min(photos.count - 1, photoIndex + 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Swipe right if you own it, left if not, or use the actions.")
    }

    @ViewBuilder
    private var artwork: some View {
        if item.isDemo || photos.isEmpty {
            ItemThumbnail(item: item, cornerRadius: 0)
        } else {
            ItemThumbnail(item: item, photo: photos[min(photoIndex, photos.count - 1)], cornerRadius: 0)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(item.category.displayName, systemImage: item.category.systemImage)
                    .font(.subheadline.weight(.medium))
                if item.isDemo { SampleBadge().environment(\.colorScheme, .light) }
            }
            Text(item.displayName)
                .font(.title.weight(.bold))
                .lineLimit(2)
            HStack(spacing: 12) {
                let count = max(item.distinctPhotos.count, 1)
                Text(count == 1 ? "Found in 1 photo" : "Found in \(count) photos")
                ConfidenceIndicator(level: item.confidenceLevel)
            }
            .font(.footnote)
            if let suggestion = item.pendingBrandSuggestion, let brand = suggestion.brand {
                Label("Possibly \(brand) — \(suggestion.evidence.lowercased())", systemImage: "text.viewfinder")
                    .font(.footnote)
            }
        }
        .foregroundStyle(.white)
    }

    private var photoIndicator: some View {
        HStack(spacing: 4) {
            ForEach(photos.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(index == photoIndex ? 0.95 : 0.4))
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private var stamps: some View {
        ZStack {
            Stamp(title: "Mine", color: Brand.accent, angle: -12)
                .opacity(stampOpacity(offset.width))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Stamp(title: "Not Mine", color: .red, angle: 12)
                .opacity(stampOpacity(-offset.width))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            Stamp(title: "Not Sure", color: .orange, angle: 0)
                .opacity(abs(offset.height) > abs(offset.width) ? stampOpacity(-offset.height) : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .padding(24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func stampOpacity(_ distance: CGFloat) -> Double {
        Double(max(0, min(1, (distance - 20) / 80)))
    }
}

private struct Stamp: View {
    let title: LocalizedStringKey
    let color: Color
    let angle: Double

    var body: some View {
        Text(title)
            .font(.title2.weight(.black))
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color, lineWidth: 3) }
            .rotationEffect(.degrees(angle))
    }
}

private struct DecisionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let diameter: CGFloat
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: diameter * 0.38, weight: .bold))
                    .foregroundStyle(isProminent ? .white : tint)
                    .frame(width: diameter, height: diameter)
                    .background {
                        Circle()
                            .fill(isProminent ? AnyShapeStyle(tint) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Swipeable photos of an item (non-duplicate photos first).
struct PhotoCarousel: View {
    let item: CandidateItem
    @State private var selection: UUID?

    var body: some View {
        let photos = item.distinctPhotos.isEmpty ? item.sortedPhotos : item.distinctPhotos
        if item.isDemo || photos.isEmpty {
            ItemThumbnail(item: item, cornerRadius: 0)
        } else {
            TabView(selection: $selection) {
                ForEach(photos) { photo in
                    ItemThumbnail(item: item, photo: photo, cornerRadius: 0)
                        .tag(Optional(photo.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .accessibilityLabel("\(photos.count) photos of \(item.displayName)")
        }
    }
}
