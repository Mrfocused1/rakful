import SwiftData
import SwiftUI

struct ListingEditorView: View {
    @Query private var results: [ListingDraft]

    init(draftID: UUID) {
        _results = Query(filter: #Predicate<ListingDraft> { $0.id == draftID })
    }

    var body: some View {
        if let draft = results.first {
            ListingEditorContent(draft: draft)
        } else {
            ContentUnavailableView("Draft Deleted", systemImage: "tag.slash", description: Text("This listing draft no longer exists."))
        }
    }
}

private struct ListingEditorContent: View {
    @Bindable var draft: ListingDraft

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(PreferencesStore.self) private var preferences

    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var showsHandoff = false
    @State private var showsDeleteConfirmation = false
    @State private var publishMessage: String?
    @State private var feedback = 0
    @State private var readyPulse = 0
    @State private var showsReadyToast = false
    @State private var showsListedCelebration = false

    private let validator = ListingValidator()

    private var photoCount: Int {
        guard let item = draft.item else { return 0 }
        return item.isDemo ? 1 : item.listingPhotos.count
    }

    private var validationInput: ListingValidationInput {
        ListingValidationInput(
            ownership: draft.item?.ownership ?? .owned,
            title: draft.title,
            description: draft.descriptionText,
            condition: draft.condition,
            defects: draft.defects,
            askingPrice: draft.askingPrice,
            photoCount: photoCount,
            hasOnlyPhotosOfPeople: draft.item?.isOnlySeenWorn ?? false,
            marketplace: draft.marketplace,
            uncertainFields: draft.uncertainFields
        )
    }

    private var issues: [ListingIssue] { validator.validate(validationInput) }
    private var isReady: Bool { !issues.contains { $0.severity == .error } }

    private var generator: any ListingGenerator {
        ListingGeneratorFactory.best(useAppleIntelligence: preferences.useAppleIntelligence)
    }

    var body: some View {
        Form {
            if let item = draft.item {
                Section {
                    HStack(spacing: 12) {
                        ItemThumbnail(item: item, cornerRadius: 10).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayName).font(.headline)
                            Text("\(photoCount) \(photoCount == 1 ? "photo" : "photos") · \(item.category.displayName)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if item.isDemo { Spacer(); SampleBadge() }
                    }
                    NavigationLink("Manage Photos") {
                        List { ItemPhotosSection(item: item) }.navigationTitle("Photos")
                    }
                    .disabled(item.isDemo)
                }
                if !item.isDemo, item.hasPhotosOfPeople, item.listingPhotos.count < validator.recommendedPhotoCount {
                    ShotListSection(item: item, recommendedCount: validator.recommendedPhotoCount)
                }
            }

            assistantSection
            detailsSection
            descriptionSection
            priceSection
            marketplaceSection
            reviewSection
            actionsSection
        }
        .navigationTitle(draft.title.nilIfBlank == nil ? "New Listing" : "Edit Listing")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // The price field's decimal pad has no return key.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: ManualHandoff.text(for: payload)) {
                    Label("Share Listing Text", systemImage: "square.and.arrow.up")
                }
                .disabled(draft.title.nilIfBlank == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete Draft", systemImage: "trash", role: .destructive) { showsDeleteConfirmation = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsHandoff) {
            HandoffSheet(draft: draft, text: ManualHandoff.text(for: payload))
        }
        .confirmationDialog("Delete this draft?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Draft", role: .destructive) {
                AppEnvironment.shared.notifications.cancelListingReminder(draftID: draft.id)
                dismiss()
                context.delete(draft)
                try? context.save()
            }
        }
        .sensoryFeedback(.success, trigger: feedback)
        .sensoryFeedback(.success, trigger: readyPulse)
        .overlay(alignment: .top) {
            if showsReadyToast {
                ReadyToast()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showsReadyToast)
        .onChange(of: isReady) { wasReady, ready in
            guard ready, !wasReady else { return }
            readyPulse += 1
            showsReadyToast = true
            AccessibilityNotification.Announcement("Ready to list").post()
            Task {
                try? await Task.sleep(for: .seconds(2))
                showsReadyToast = false
            }
        }
        .onChange(of: draft.status) { previous, status in
            if previous == .draft, status != .draft { showsListedCelebration = true }
        }
        .celebration(
            isPresented: $showsListedCelebration,
            title: draft.status == .published ? "Published!" : "Listed!",
            message: "\(draft.displayTitle) is on \(draft.marketplace.displayName). Good luck with the sale."
        )
        .onChange(of: draft.title) { draft.touch() }
        .onDisappear { try? context.save() }
    }

    // MARK: - Sections

    private var assistantSection: some View {
        Section {
            Button {
                generate()
            } label: {
                HStack {
                    Label(draft.generatedAt == nil ? "Generate Listing" : "Regenerate Listing", systemImage: "sparkles")
                    Spacer()
                    if isGenerating { ProgressView() }
                }
            }
            .disabled(isGenerating || draft.item?.ownership != .owned)
            if let generationError {
                Text(generationError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Listing Assistant")
        } footer: {
            if let generatedAt = draft.generatedAt, let name = draft.generatorName {
                Text("Written at \(generatedAt.formatted(date: .omitted, time: .shortened)) by \(name), using only the details you've confirmed. Review every field before listing.")
            } else {
                Text(generator is TemplateListingGenerator
                     ? "Creates a title, description and keywords from the details you've confirmed. Nothing is invented."
                     : "Uses Apple Intelligence on this iPhone to write from the details you've confirmed. Nothing is uploaded, and nothing is invented.")
            }
        }
    }

    private var detailsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Title", text: $draft.title, axis: .vertical)
                        .font(.body.weight(.medium))
                        .accessibilityIdentifier("listing.title")
                    uncertaintyButton(.title)
                }
                if let limit = draft.marketplace.titleCharacterLimit {
                    Text("\(draft.title.count)/\(limit)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(draft.title.count > limit ? .red : .secondary)
                }
            }
            field("Category", text: $draft.categoryText, field: .category)
            field("Brand", text: $draft.brand, field: .brand)
            field("Model", text: $draft.model, field: .model)
            field("Colour", text: $draft.colour, field: .colour)
            field("Size", text: $draft.size, field: .size)
            Picker(selection: Binding(get: { draft.condition }, set: { draft.condition = $0; draft.markConfirmed(.condition); draft.touch() })) {
                Text("Select").tag(ItemCondition?.none)
                ForEach(ItemCondition.allCases) { Text($0.displayName).tag(Optional($0)) }
            } label: {
                HStack {
                    Text("Condition")
                    uncertaintyButton(.condition)
                }
            }
            TextField("Describe any wear or defects", text: $draft.defects, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text("Details")
        } footer: {
            Text("Fields marked \(Image(systemName: "exclamationmark.triangle.fill")) need your confirmation. Tap the icon once you've checked them.")
        }
    }

    private var descriptionSection: some View {
        Section {
            TextField("Description", text: $draft.descriptionText, axis: .vertical)
                .lineLimit(5...14)
                .onChange(of: draft.descriptionText) { draft.touch() }
            TextField("Keywords, separated by commas", text: Binding(
                get: { draft.keywords.joined(separator: ", ") },
                set: { draft.keywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
        } header: {
            HStack {
                Text("Description")
                Spacer()
                if draft.uncertainFields.contains(.description) {
                    Button("Mark Reviewed") { withAnimation { draft.markConfirmed(.description) } }
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        }
    }

    private var priceSection: some View {
        Section {
            if let url = Marketplace.soldListingsURL(for: [draft.brand, draft.model, draft.item?.displayName ?? draft.title]) {
                Link(destination: url) {
                    Label("See Sold Prices on eBay", systemImage: "arrow.up.right.square")
                }
            }
            LabeledContent("Asking Price") {
                TextField("Enter price", value: $draft.askingPrice, format: .currency(code: draft.currencyCode))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Price")
        } footer: {
            Text("Check what similar items sold for on eBay, then set your own price. Rakful doesn't estimate prices.")
        }
    }

    private var marketplaceSection: some View {
        Section {
            Picker("Marketplace", selection: $draft.marketplace) {
                ForEach(Marketplace.allCases) { Text($0.displayName).tag($0) }
            }
        } footer: {
            if canPublishDirectly {
                Text("eBay listings can be published through eBay's official seller API once your account is connected. You can also list manually.")
            } else {
                Text("Rakful prepares your listing; you post it yourself on \(draft.marketplace.displayName). It never signs in or posts on your behalf.")
            }
        }
    }

    private var reviewSection: some View {
        Section("Review") {
            if issues.isEmpty {
                Label {
                    Text("Ready to list").font(.headline)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Brand.accent)
                        .symbolEffect(.bounce, value: readyPulse)
                }
            } else {
                ForEach(issues) { issue in
                    Label {
                        Text(issue.message)
                    } icon: {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            if canPublishDirectly {
                Button {
                    publishToEbay()
                } label: {
                    Label("Publish to eBay", systemImage: "arrow.up.circle")
                }
                .disabled(!isReady || !ebayPublisher.isAvailable)
            }
            Button {
                showsHandoff = true
            } label: {
                Label(draft.marketplace == .other ? "Copy Listing" : "List Manually on \(draft.marketplace.displayName)", systemImage: "arrow.up.forward.app")
            }
            .disabled(!isReady)
            if let publishMessage {
                Text(publishMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            if canPublishDirectly, !ebayPublisher.isAvailable {
                Text("Connect your eBay account in Settings › Marketplace Connections to publish directly.")
            }
        }
    }

    // MARK: - Helpers

    private func field(_ label: LocalizedStringKey, text: Binding<String>, field: ListingField) -> some View {
        LabeledContent {
            HStack {
                TextField(label, text: Binding(get: { text.wrappedValue }, set: {
                    text.wrappedValue = $0
                    draft.markConfirmed(field)
                    draft.touch()
                }))
                .multilineTextAlignment(.trailing)
                uncertaintyButton(field)
            }
        } label: {
            Text(label)
        }
    }

    @ViewBuilder
    private func uncertaintyButton(_ field: ListingField) -> some View {
        if draft.uncertainFields.contains(field) {
            Button {
                withAnimation { draft.markConfirmed(field) }
            } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(field.displayName) needs confirmation")
            .accessibilityHint("Marks it as confirmed")
        }
    }

    private var payload: ListingPayload {
        ListingPayload(
            title: draft.title,
            description: draft.descriptionText,
            category: draft.categoryText,
            brand: draft.brand,
            model: draft.model,
            colour: draft.colour,
            size: draft.size,
            condition: draft.condition?.displayName ?? "",
            keywords: draft.keywords,
            price: draft.askingPrice ?? 0,
            currencyCode: draft.currencyCode
        )
    }

    private var ebayPublisher: EbayPublisher {
        EbayPublisher(client: AppEnvironment.shared.backendClient)
    }

    /// Direct publishing is offered only where a seller API exists and the
    /// Rakful server is available; otherwise every marketplace is manual.
    private var canPublishDirectly: Bool {
        draft.marketplace.publishingMethod == .sellerAPI && AppEnvironment.shared.backend.isConfigured
    }

    private var facts: ListingFacts {
        let item = draft.item
        let estimate = item?.latestEstimate
        return ListingFacts(
            category: item?.category ?? .other,
            itemNoun: item?.suggestedName ?? draft.categoryText,
            brand: draft.brand.nilIfBlank,
            brandConfirmed: !draft.uncertainFields.contains(.brand),
            model: draft.model.nilIfBlank,
            colour: draft.colour.nilIfBlank,
            size: draft.size.nilIfBlank,
            condition: draft.condition,
            defects: draft.defects.nilIfBlank,
            notes: item?.notes,
            marketplace: draft.marketplace,
            estimate: estimate?.range,
            estimateMedian: estimate?.median,
            estimateKind: estimate?.kind
        )
    }

    private func generate() {
        isGenerating = true
        generationError = nil
        let facts = facts
        let generator = generator
        Task {
            do {
                let listing = try await generator.generate(from: facts)
                withAnimation {
                    draft.title = listing.title
                    draft.descriptionText = listing.description
                    draft.categoryText = listing.category
                    draft.keywords = listing.keywords
                    draft.uncertainFields = draft.uncertainFields.union(listing.uncertainFields)
                    draft.generatorName = listing.generatorName
                    draft.generatedAt = .now
                    draft.touch()
                }
                try? context.save()
                feedback += 1
            } catch {
                generationError = "The listing couldn't be generated. \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    private func publishToEbay() {
        let payload = payload
        Task {
            do {
                let published = try await ebayPublisher.publish(payload, images: [])
                draft.status = .published
                draft.externalListingURL = published.url
                context.logActivity(.listingHandedOff, title: "Published to eBay", detail: draft.displayTitle, itemID: draft.item?.id)
                AppEnvironment.shared.notifications.cancelListingReminder(draftID: draft.id)
                try? context.save()
            } catch {
                publishMessage = error.localizedDescription
            }
        }
    }
}

/// Brief confirmation shown when a draft first passes validation.
private struct ReadyToast: View {
    var body: some View {
        Label("Ready to list", systemImage: "checkmark.seal.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Brand.accent, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Manual handoff for marketplaces without an authorised publishing API.
struct HandoffSheet: View {
    @Bindable var draft: ListingDraft
    let text: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var didCopy = false

    private var listingPhotos: [ItemPhoto] { draft.item?.listingPhotos ?? [] }

    /// Photos taken or imported in Rakful live in its own storage, so they
    /// have to be saved before a marketplace can use them.
    private var photosToSave: [URL] {
        listingPhotos.compactMap(\.importedFileName).map(ImportedImageStore.url(for:))
    }

    private var photoInstructions: LocalizedStringKey {
        let inLibrary = listingPhotos.contains { $0.source == .library }
        switch (photosToSave.isEmpty, inLibrary) {
        case (false, false): return "Save them to your Photos library, then choose them when you create the listing."
        case (false, true): return "Save the photos you took here, then choose them along with the others in your Photos library."
        case (true, true): return "Your photos are already in your Photos library. Choose them when you create the listing."
        case (true, false): return "Add photos of the item when you create the listing."
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        UIPasteboard.general.string = text
                        withAnimation { didCopy = true }
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Listing Text", systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    .sensoryFeedback(.success, trigger: didCopy)
                    ShareLink(item: text) { Label("Share Listing Text", systemImage: "square.and.arrow.up") }
                } header: {
                    Text("1. Copy Your Listing")
                }

                Section {
                    if !photosToSave.isEmpty {
                        ShareLink(items: photosToSave) {
                            Label(photosToSave.count == 1 ? "Save Photo" : "Save \(photosToSave.count) Photos", systemImage: "square.and.arrow.down")
                        }
                    }
                    Text(photoInstructions)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("2. Add Your Photos")
                } footer: {
                    if draft.item?.hasPhotosOfPeople == true {
                        Text("Photos that show a person stay private. Don't add them to the listing.")
                    }
                }

                Section {
                    if let url = draft.marketplace.createListingURL {
                        Link(destination: url) {
                            Label("Open \(draft.marketplace.displayName)", systemImage: "arrow.up.forward.app")
                        }
                    } else {
                        Text("Paste the listing into the marketplace of your choice.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("3. Create the Listing")
                } footer: {
                    Text("You sign in and post the listing yourself. Rakful never accesses your marketplace account.")
                }

                Section {
                    Button("Mark as Listed") {
                        draft.status = .handedOff
                        draft.handedOffAt = .now
                        draft.touch()
                        context.logActivity(.listingHandedOff, title: "Listed on \(draft.marketplace.displayName)", detail: draft.displayTitle, itemID: draft.item?.id, isDemo: draft.isDemo)
                        AppEnvironment.shared.notifications.cancelListingReminder(draftID: draft.id)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(draft.status != .draft)
                }

                Section("Preview") {
                    Text(text).font(.footnote).textSelection(.enabled)
                }
            }
            .navigationTitle("List on \(draft.marketplace.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}
