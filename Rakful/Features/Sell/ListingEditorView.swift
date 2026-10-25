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
    @Environment(SaveFailureCenter.self) private var saves
    @Environment(ListingPhotoReviewer.self) private var reviewer

    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var showsApproval = false
    @State private var showsHandoff = false
    @State private var showsConfirmListed = false
    @State private var showsDeleteConfirmation = false
    @State private var undoError: String?
    @State private var approvalWasCleared = false
    @State private var feedback = 0
    @State private var readyPulse = 0
    @State private var showsReadyToast = false
    @State private var showsListedCelebration = false

    private let validator = ListingValidator()

    private var issues: [ListingIssue] { validator.validate(draft.validationInput()) }
    private var isReady: Bool { !issues.contains { $0.severity == .error } }
    /// A listing the seller confirmed is live is a record; it's not edited in place.
    private var isLocked: Bool { draft.status == .listed || draft.status == .published }

    private var generator: any ListingGenerator {
        ListingGeneratorFactory.best(useAppleIntelligence: preferences.useAppleIntelligence)
    }

    var body: some View {
        Form {
            itemSection
            ListingPhotosSection(draft: draft)
                .disabled(isLocked)
            if let item = draft.item, !item.isDemo, !isLocked, item.hasPhotosOfPeople, item.listingPhotos.count < validator.recommendedPhotoCount {
                ShotListSection(item: item, recommendedCount: validator.recommendedPhotoCount) { added in
                    draft.selectedPhotoIDs += added.map(\.id)
                    draft.touch()
                }
            }

            Group {
                assistantSection
                detailsSection
                conditionSection
                descriptionSection
                priceSection
                marketplaceSection
            }
            .disabled(isLocked)
            if draft.status == .draft { reviewSection }
            statusSection
        }
        .clearsDock()
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
                Menu {
                    Button("Delete Draft", systemImage: "trash", role: .destructive) { showsDeleteConfirmation = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsApproval) {
            ListingApprovalView(draft: draft)
        }
        .sheet(isPresented: $showsHandoff) {
            HandoffSheet(draft: draft)
        }
        .sheet(isPresented: $showsConfirmListed) {
            ConfirmListedSheet(draft: draft)
        }
        .confirmationDialog("Delete this draft?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Draft", role: .destructive) { deleteDraft() }
        }
        .alert("Couldn't Update the Listing", isPresented: Binding(get: { undoError != nil }, set: { if !$0 { undoError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(undoError ?? "")
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
            guard ready, !wasReady, draft.status == .draft else { return }
            readyPulse += 1
            showsReadyToast = true
            AccessibilityNotification.Announcement("Ready to approve").post()
            Task {
                try? await Task.sleep(for: .seconds(2))
                showsReadyToast = false
            }
        }
        // Any material edit after approval clears it; exports then refuse
        // until the seller approves the new version.
        .onChange(of: draft.content) {
            if draft.invalidateApprovalIfNeeded() {
                approvalWasCleared = true
                saves.save(context, "Saving your listing")
            }
        }
        .onChange(of: draft.status) { previous, status in
            if status == .listed, previous != .listed { showsListedCelebration = true }
            if status != .draft { approvalWasCleared = false }
        }
        .celebration(
            isPresented: $showsListedCelebration,
            title: "Marked as Listed",
            message: "You confirmed \(draft.displayTitle) is listed on \(draft.marketplace.displayName). Good luck with the sale."
        )
        .onChange(of: draft.title) { draft.touch() }
        .task {
            if let item = draft.item, !item.isDemo { reviewer.checkUnchecked(item.photos, in: context) }
        }
        .onDisappear { saves.save(context, "Saving your listing") }
    }

    // MARK: - Sections

    private var itemSection: some View {
        Section {
            if let item = draft.item {
                HStack(spacing: 12) {
                    ItemThumbnail(item: item, cornerRadius: 10).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayName).font(.headline)
                        Text(item.category.displayName).font(.footnote).foregroundStyle(.secondary)
                    }
                    if item.isDemo { Spacer(); SampleBadge() }
                }
            }
            if draft.status == .draft {
                Toggle(isOn: Binding(get: { draft.sellerDeclaredOwnership }, set: { draft.sellerDeclaredOwnership = $0; draft.touch() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("I own this and want to sell it")
                        Text("Required before you approve the listing").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("listing.ownershipDeclaration")
            } else {
                Label("You confirmed you own this and want to sell it", systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
                Text("Written at \(generatedAt.formatted(date: .omitted, time: .shortened)) by \(name), using only the details you've confirmed. Condition and defects are added from your answers below.")
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
            field("Brand", text: $draft.brand, field: .brand, prompt: "Optional")
            field("Model", text: $draft.model, field: .model, prompt: "Optional")
            field("Colour", text: $draft.colour, field: .colour, prompt: "Optional")
            field("Size", text: $draft.size, field: .size, prompt: "Optional")
            field("Material", text: $draft.material, field: .material, prompt: "Optional")
            field("Measurements", text: $draft.measurements, field: .measurements, prompt: "Optional")
        } header: {
            Text("Details")
        } footer: {
            Text("Add only what you know is correct and leave the rest blank. Fields marked \(Image(systemName: "exclamationmark.triangle.fill")) were suggested: tap the icon once you've checked them, or clear them.")
        }
    }

    private var conditionSection: some View {
        Section {
            Picker(selection: Binding(get: { draft.condition }, set: { draft.condition = $0; draft.markConfirmed(.condition); draft.touch() })) {
                Text("Select").tag(ItemCondition?.none)
                ForEach(ItemCondition.allCases) { Text($0.displayName).tag(Optional($0)) }
            } label: {
                HStack {
                    Text("Condition")
                    uncertaintyButton(.condition)
                }
            }
            Picker("Wear or Defects", selection: Binding(get: { draft.defectsAssessment }, set: { draft.defectsAssessment = $0; draft.touch() })) {
                Text("Select").tag(DefectsAssessment?.none)
                ForEach(DefectsAssessment.allCases) { Text($0.displayName).tag(Optional($0)) }
            }
            .accessibilityIdentifier("listing.defects")
            if draft.defectsAssessment == .described {
                TextField("Describe any marks, wear or faults", text: $draft.defects, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("listing.defectsText")
            }
        } header: {
            Text("Condition")
        } footer: {
            Text("Look the item over before answering. Anything you record here always appears in the listing, even if you add it after writing the description.")
        }
    }

    private var descriptionSection: some View {
        Section("Description") {
            TextField("Description", text: $draft.descriptionText, axis: .vertical)
                .lineLimit(5...14)
                .onChange(of: draft.descriptionText) { draft.touch() }
            TextField("Keywords, separated by commas", text: Binding(
                get: { draft.keywords.joined(separator: ", ") },
                set: { draft.keywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
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
            Text("Rakful prepares your listing; you post it yourself on \(draft.marketplace.displayName). It never signs in or posts on your behalf.")
        }
    }

    private var reviewSection: some View {
        Section("Before You Approve") {
            if isReady {
                Label {
                    Text("Ready to approve").font(.headline)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Brand.accent)
                        .symbolEffect(.bounce, value: readyPulse)
                }
            }
            if !issues.isEmpty {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(issue.message)
                        } icon: {
                            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                        }
                        .font(.subheadline)
                        if !issue.actions.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(issue.actions, id: \.self) { issueAction($0) }
                            }
                            .padding(.leading, 30)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func issueAction(_ action: ListingIssue.Action) -> some View {
        switch action {
        case .reviewPhotos:
            NavigationLink("Review Photos") { ListingPhotosView(draft: draft) }
                .font(.footnote)
        default:
            Button(title(for: action)) {
                withAnimation { perform(action) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var statusSection: some View {
        Section {
            switch draft.status {
            case .draft:
                if let invalidation = draft.approvalInvalidation {
                    Label(invalidation.message, systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("listing.approvalInvalidated")
                } else if approvalWasCleared {
                    Label("You changed the listing after approving it, so it needs approving again.", systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                Button {
                    showsApproval = true
                } label: {
                    Label("Review & Approve", systemImage: "checkmark.rectangle")
                }
                .disabled(!isReady)
                .accessibilityIdentifier("listing.reviewAndApprove")
            case .approved, .exported:
                ListingStatusRow(draft: draft)
                Button {
                    showsHandoff = true
                } label: {
                    Label("Export Listing", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("listing.export")
                Button {
                    showsConfirmListed = true
                } label: {
                    Label("I've Posted It", systemImage: "storefront")
                }
                .accessibilityIdentifier("listing.confirmListed")
            case .listed, .published:
                ListingStatusRow(draft: draft)
                if let link = draft.externalListingURL, let url = URL(string: link) {
                    Link(destination: url) { Label("Open Your Listing", systemImage: "arrow.up.right.square") }
                }
                if draft.status == .listed {
                    Button("Mark as Not Listed") { undoListed() }
                }
            }
        } header: {
            Text("Status")
        } footer: {
            Text(statusFooter)
        }
    }

    private var statusFooter: String {
        let marketplace = draft.marketplace.displayName
        switch draft.status {
        case .draft:
            return "Approving saves this exact version. If you change anything afterwards, you'll approve it again."
        case .approved:
            return "Export copies exactly the version you approved. Copying the text or opening \(marketplace) doesn't mark it as listed."
        case .exported:
            return "Rakful can't see \(marketplace), so tell it once your listing is live."
        case .listed:
            return "This is your own confirmation. Rakful can't check marketplaces, so it hasn't verified the listing. To make changes, mark it as not listed."
        case .published:
            return "Published through eBay."
        }
    }

    // MARK: - Helpers

    private func field(_ label: LocalizedStringKey, text: Binding<String>, field: ListingField, prompt: LocalizedStringKey? = nil) -> some View {
        LabeledContent {
            HStack {
                TextField(prompt ?? label, text: Binding(get: { text.wrappedValue }, set: {
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

    private func title(for action: ListingIssue.Action) -> LocalizedStringKey {
        switch action {
        case .confirmField: "Confirm"
        case .clearField: "Remove"
        case .confirmClaim: "It's Accurate"
        case .useAsBrand: "Use as Brand"
        case .addMaterial: "Add to Material"
        case .reviewPhotos: "Review Photos"
        }
    }

    private func perform(_ action: ListingIssue.Action) {
        switch action {
        case .confirmField(let field):
            draft.markConfirmed(field)
        case .clearField(let field):
            clear(field)
            draft.markConfirmed(field)
        case .confirmClaim(let claim):
            draft.confirmedClaims.insert(claim.id)
        case .useAsBrand(let brand):
            draft.brand = brand
            draft.markConfirmed(.brand)
        case .addMaterial(let material):
            let existing = draft.material.trimmingCharacters(in: .whitespaces)
            draft.material = existing.isEmpty ? material.capitalizedFirst : "\(existing), \(material)"
            draft.markConfirmed(.material)
        case .reviewPhotos:
            break
        }
        draft.touch()
    }

    private func clear(_ field: ListingField) {
        switch field {
        case .category: draft.categoryText = ""
        case .brand: draft.brand = ""
        case .model: draft.model = ""
        case .colour: draft.colour = ""
        case .size: draft.size = ""
        case .material: draft.material = ""
        case .measurements: draft.measurements = ""
        default: break
        }
    }

    private func generate() {
        isGenerating = true
        generationError = nil
        let facts = draft.listingFacts
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
                if saves.save(context, "Saving the generated listing") { feedback += 1 }
            } catch {
                generationError = "The listing couldn't be generated. \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    private func undoListed() {
        do {
            try ListingExporter.undoListed(draft, in: context)
        } catch {
            undoError = error.localizedDescription
        }
    }

    private func deleteDraft() {
        let id = draft.id
        AppEnvironment.shared.notifications.cancelListingReminder(draftID: id)
        dismiss()
        context.delete(draft)
        if saves.save(context, "Deleting the draft") { ApprovedPhotoStore.standard.removeAll(draftID: id) }
    }
}

/// The listing's workflow state in plain words.
struct ListingStatusRow: View {
    let draft: ListingDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("\(draft.status.displayName) · \(draft.status.detail)").font(.headline)
            } icon: {
                Image(systemName: symbol).foregroundStyle(Brand.accent)
            }
            Group {
                if let approvedAt = draft.approvedAt {
                    Text("Version \(draft.approvalVersion) approved \(approvedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                if let handedOffAt = draft.handedOffAt {
                    Text("Handed off \(handedOffAt.formatted(date: .abbreviated, time: .shortened))")
                }
                if let listedAt = draft.sellerConfirmedListedAt {
                    Text("You confirmed it was listed \(listedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("listing.status")
    }

    private var symbol: String {
        switch draft.status {
        case .draft: "square.and.pencil"
        case .approved: "checkmark.rectangle"
        case .exported: "arrow.up.forward.app"
        case .listed, .published: "storefront"
        }
    }
}

/// Brief confirmation shown when a draft first passes validation.
private struct ReadyToast: View {
    var body: some View {
        Label("Ready to approve", systemImage: "checkmark.seal.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Brand.accent, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .accessibilityAddTraits(.isStaticText)
    }
}
