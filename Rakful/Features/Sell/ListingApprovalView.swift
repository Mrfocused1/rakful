import SwiftData
import SwiftUI
import UIKit

/// One screen showing the exact package that will be exported — photos in
/// order, text, details, condition, price and marketplace — approved with a
/// single action.
struct ListingApprovalView: View {
    @Bindable var draft: ListingDraft

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private enum Phase {
        case preparing
        case ready(ApprovalPreview)
        case failed(ApprovalError)
    }

    @State private var phase = Phase.preparing
    @State private var isApproving = false
    @State private var approveError: String?
    @State private var approved = 0

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Review Listing")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                .safeAreaInset(edge: .bottom) {
                    if case .ready(let preview) = phase { approveBar(preview) }
                }
        }
        .task { await prepare() }
        .sensoryFeedback(.success, trigger: approved)
        .alert("Couldn't Approve", isPresented: Binding(get: { approveError != nil }, set: { if !$0 { approveError = nil } })) {
            Button("Try Again") { if case .ready(let preview) = phase { approve(preview) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(approveError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            ProgressView("Preparing your listing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            failure(error)
        case .ready(let preview):
            package(preview)
        }
    }

    private func package(_ preview: ApprovalPreview) -> some View {
        let content = preview.content
        return List {
            Section {
                if preview.photoURLs.isEmpty {
                    Text("Sample listing: no photos.").foregroundStyle(.secondary)
                }
                ForEach(Array(preview.photoURLs.enumerated()), id: \.offset) { index, url in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(index == 0 ? "Photo 1 · Main" : "Photo \(index + 1)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ApprovedFileImage(url: url)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityLabel("Photo \(index + 1)")
                    }
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text(preview.photoURLs.count == 1 ? "1 Photo" : "\(preview.photoURLs.count) Photos, in Order")
            } footer: {
                if !preview.photoURLs.isEmpty {
                    Text("Check every photo shows only the item: no people, faces, reflections or personal details. Rakful's automatic check can miss things.")
                }
            }

            Section("Title") {
                Text(content.title).font(.headline).accessibilityIdentifier("approval.title")
            }
            Section("Description") {
                Text(content.description)
            }

            Section("Details") {
                let details = [
                    ("Category", content.category), ("Brand", content.brand), ("Model", content.model),
                    ("Colour", content.colour), ("Size", content.size), ("Material", content.material),
                    ("Measurements", content.measurements), ("Keywords", content.keywords.joined(separator: ", ")),
                ].filter { !$0.1.isEmpty }
                ForEach(details, id: \.0) { LabeledContent($0.0, value: $0.1) }
                if details.isEmpty { Text("No extra details").foregroundStyle(.secondary) }
            }

            Section("Condition") {
                LabeledContent("Condition", value: content.condition?.displayName ?? "")
                LabeledContent("Wear and defects", value: content.defectsAssessment == .noneFound ? "None found" : content.defects)
            }

            Section("Price") {
                LabeledContent("Asking price", value: content.askingPrice.map { Formatting.currency($0, code: content.currencyCode, fractionDigits: 2) } ?? "")
                LabeledContent("Currency", value: content.currencyCode)
            }

            Section {
                LabeledContent("Marketplace", value: content.marketplace.displayName)
            } footer: {
                Text("You'll post it yourself. Rakful doesn't publish listings or sign in to \(content.marketplace.displayName).")
            }

            Section {
                DisclosureGroup("Exact Text to Be Copied") {
                    Text(preview.text)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("approval.text")
                }
            }
        }
    }

    private func approveBar(_ preview: ApprovalPreview) -> some View {
        VStack(spacing: 8) {
            Button {
                approve(preview)
            } label: {
                Text(isApproving ? "Approving…" : "Approve Listing").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isApproving)
            .accessibilityIdentifier("approval.approve")
            Text("By approving, you confirm you own this item, intend to sell it, and have checked these photos and details. Any change will need approving again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private func failure(_ error: ApprovalError) -> some View {
        switch error {
        case .notReady(let issues):
            List {
                Section {
                    ForEach(issues) { Label($0.message, systemImage: "xmark.octagon.fill").foregroundStyle(.primary) }
                } header: {
                    Text("Finish These First")
                }
                Section { Button("Back to Editing") { dismiss() } }
            }
        case .photosUnavailable(let failures):
            List {
                Section {
                    ForEach(failures) { failure in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Photo \(failure.position)").font(.headline)
                            PhotoProblemButton(problem: failure.problem) {
                                Task { await prepare() }
                            } remove: {
                                draft.deselectPhotos([failure.photoID])
                                Task { await prepare() }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Some Photos Aren't Available")
                } footer: {
                    Text("Your draft hasn't changed. Fix or remove these photos, then try again.")
                }
                Section { Button("Try Again") { Task { await prepare() } } }
            }
        case .changedDuringReview, .couldNotSave:
            ContentUnavailableView {
                Label("Couldn't Prepare the Listing", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error == .changedDuringReview ? "The listing changed while it was being prepared." : "Rakful couldn't save copies of your photos. Check your iPhone has free storage.")
            } actions: {
                Button("Try Again") { Task { await prepare() } }
            }
        }
    }

    private func prepare() async {
        phase = .preparing
        do {
            phase = .ready(try await ListingApproval().prepare(draft))
        } catch let error as ApprovalError {
            phase = .failed(error)
        } catch {
            // Cancelled because the sheet closed.
        }
    }

    private func approve(_ preview: ApprovalPreview) {
        isApproving = true
        defer { isApproving = false }
        do {
            try ListingApproval().approve(draft, preview: preview, in: context)
            approved += 1
            dismiss()
        } catch ApprovalError.changedDuringReview {
            Task { await prepare() }
        } catch ApprovalError.couldNotSave(let message) {
            approveError = "Your approval wasn't saved, so nothing has changed. \(message)"
        } catch {
            Task { await prepare() }
        }
    }
}

// MARK: - Handoff

/// Copy, share and open the marketplace using only the approved snapshot.
/// None of these mark the listing as listed.
struct HandoffSheet: View {
    @Bindable var draft: ListingDraft

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(SaveFailureCenter.self) private var saves

    @State private var package: ListingExportPackage?
    @State private var exportError: String?
    @State private var didCopy = false
    @State private var sharing: ShareRequest?
    @State private var showsConfirmListed = false

    private struct ShareRequest: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let package {
                    steps(package)
                } else if let exportError {
                    ContentUnavailableView {
                        Label("Can't Export", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("\(exportError) Your draft hasn't changed.")
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Export Listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .task { load() }
        .sheet(item: $sharing) { request in
            ActivityShareSheet(items: request.items) { completed in
                sharing = nil
                if completed { recordHandoff() }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsConfirmListed) {
            ConfirmListedSheet(draft: draft) { dismiss() }
        }
        .saveFailureAlert(saves)
    }

    private func steps(_ package: ListingExportPackage) -> some View {
        let marketplace = package.marketplace.displayName
        return List {
            Section {
                ListingStatusRow(draft: draft)
            } footer: {
                Text("Everything here is exactly the version you approved.")
            }

            Section("1. Copy the Text") {
                Button {
                    UIPasteboard.general.string = package.text
                    withAnimation { didCopy = true }
                    recordHandoff()
                } label: {
                    Label(didCopy ? "Copied" : "Copy Listing Text", systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .sensoryFeedback(.success, trigger: didCopy)
                .accessibilityIdentifier("handoff.copy")
                Button {
                    sharing = ShareRequest(items: [package.text])
                } label: {
                    Label("Share Listing Text…", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                if package.photoURLs.isEmpty {
                    Text("This listing has no photos.").foregroundStyle(.secondary)
                } else {
                    Button {
                        sharing = ShareRequest(items: package.photoURLs)
                    } label: {
                        Label(package.photoURLs.count == 1 ? "Save or Share Photo…" : "Save or Share \(package.photoURLs.count) Photos…", systemImage: "square.and.arrow.down")
                    }
                    Text("Choose “Save Images” to add them to your Photos library in order, then pick them when you create the listing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("2. Add the Photos")
            }

            Section {
                if let url = package.marketplace.createListingURL {
                    Button {
                        openURL(url) { accepted in if accepted { recordHandoff() } }
                    } label: {
                        Label("Open \(marketplace)", systemImage: "arrow.up.forward.app")
                    }
                } else {
                    Text("Paste the listing into the marketplace of your choice.").foregroundStyle(.secondary)
                }
            } header: {
                Text("3. Create the Listing")
            } footer: {
                Text("You sign in and post the listing yourself. Rakful never accesses your marketplace account.")
            }

            Section {
                Button("I've Posted It") { showsConfirmListed = true }
                    .accessibilityIdentifier("handoff.confirmListed")
            } footer: {
                Text("Copying, sharing or opening \(marketplace) doesn't mark this as listed. Once it's live, tell Rakful here.")
            }

            Section("Text Preview") {
                Text(package.text).font(.footnote).textSelection(.enabled)
            }
        }
    }

    private func load() {
        do {
            package = try ListingExporter.package(for: draft)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Only completed actions count; a cancelled share changes nothing.
    private func recordHandoff() {
        let draft = draft, context = context
        let operation: @MainActor () throws -> Void = { try ListingExporter.recordHandoff(draft, in: context) }
        if saves.attempt("Saving that you've exported this listing", operation) {
            AppEnvironment.shared.notifications.cancelListingReminder(draftID: draft.id)
        }
    }
}

/// The seller's confirmation that the listing is live, with an optional link.
struct ConfirmListedSheet: View {
    @Bindable var draft: ListingDraft
    var onConfirmed: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var link = ""
    @State private var errorMessage: String?

    private var hasLink: Bool { !link.trimmingCharacters(in: .whitespaces).isEmpty }
    private var linkIsValid: Bool { !hasLink || ListingExporter.listingURL(from: link) != nil }

    var body: some View {
        let marketplace = draft.marketplace.displayName
        NavigationStack {
            Form {
                Section {
                    Text("Is “\(draft.displayTitle)” live on \(marketplace)?").font(.headline)
                    Text("Confirm only once you've posted it and can see it on \(marketplace).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("https://", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("confirmListed.link")
                } header: {
                    Text("Listing Link (Optional)")
                } footer: {
                    if linkIsValid {
                        Text("Kept for your reference. Rakful doesn't open or check it.")
                    } else {
                        Text("Enter a web address, such as the link from \(marketplace)'s Share button.").foregroundStyle(.red)
                    }
                }
                Section {
                    Button("Confirm It's Listed") { confirm() }
                        .disabled(!linkIsValid)
                        .accessibilityIdentifier("confirmListed.confirm")
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("This records your own confirmation. Rakful can't see \(marketplace), so it doesn't verify the listing.")
                }
            }
            .navigationTitle("Confirm Listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func confirm() {
        do {
            try ListingExporter.confirmListed(draft, url: hasLink ? ListingExporter.listingURL(from: link) : nil, in: context)
            AppEnvironment.shared.notifications.cancelListingReminder(draftID: draft.id)
            dismiss()
            onConfirmed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The system share sheet, reporting whether the person completed an action.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let onComplete = onComplete
        controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
