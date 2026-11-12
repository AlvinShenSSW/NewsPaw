import NewsPawKit
import SwiftUI

/// Add source (ux S6): one sheet with its own navigation stack. The address
/// step is its root; the confirm step, the category picker, the inline new
/// category and the suggested list are pushed.
struct AddSourceView: View {
    @Environment(SourceModel.self) private var sources

    var body: some View {
        if let model = sources.addSource {
            AddSourceStack(model: model)
        }
    }
}

private struct AddSourceStack: View {
    @Bindable var model: AddSourceModel
    @Environment(SourceModel.self) private var sources

    var body: some View {
        NavigationStack(path: $model.path) {
            AddressStepView(model: model)
                .navigationDestination(for: AddSourceRoute.self) { route in
                    switch route {
                    case .confirm: ConfirmStepView(model: model)
                    case .suggested: SuggestedSourcesView(model: model)
                    case .categoryPicker: CategoryPickerView(model: model)
                    case .newCategory: NewCategoryInSheetView(model: model)
                    }
                }
        }
        .interactiveDismissDisabled(model.isSaving)
        // A duplicate found at Save: the address was taken after detection.
        .alert(
            model.duplicateAtSave.map(SourceWording.duplicate) ?? Text(verbatim: ""),
            isPresented: Binding {
                model.duplicateAtSave != nil
            } set: { presented in
                if !presented {
                    model.duplicateAtSave = nil
                }
            }
        ) {
            Button("OK") {}
        }
    }
}

/// The first step: the address, Paste, Continue, the suggested sources, and
/// the outcomes that stay on this step.
struct AddressStepView: View {
    @Bindable var model: AddSourceModel
    @Environment(SourceModel.self) private var sources
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $model.addressText, prompt: Text(verbatim: "https://"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit { continueTapped() }
                    .focused($isFieldFocused)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .disabled(model.isDetecting)
                    .accessibilityIdentifier(AccessibilityID.addressField)
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.first ?? ""
                    Task { @MainActor in model.addressText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                // The system draws the label; the fill is the neutral token,
                // never the accent (RD05 decision 21).
                .tint(Theme.neutralFill)
                .disabled(model.isDetecting)
                .accessibilityIdentifier(AccessibilityID.pasteButton)
                if model.showsOutcome, case .invalidAddress(let problem) = model.detection {
                    message(SourceWording.addressProblem(problem))
                        .accessibilityIdentifier(AccessibilityID.addressProblem)
                }
                if model.isDetecting {
                    HStack(spacing: Theme.Spacing.small) {
                        ProgressView()
                        Text("Looking for a feed…")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.detecting)
                }
            }
            .listRowBackground(Theme.surface)
            if !model.isDetecting, model.showsOutcome {
                outcome
            }
            if !sources.library.suggestedSources.isEmpty {
                Section {
                    NavigationLink(value: AddSourceRoute.suggested) {
                        Label("Suggested Sources", systemImage: "star.square.on.square")
                    }
                    .disabled(model.isDetecting)
                    .accessibilityIdentifier(AccessibilityID.suggestedSourcesRow)
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .foregroundStyle(Theme.text)
        .navigationTitle("Add Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    sources.addSourceClosed()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSaving)
                .accessibilityIdentifier(AccessibilityID.cancelButton)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // A plain bar button: a confirmation-action button would be
                // filled with the accent under a white label.
                Button("Continue") {
                    continueTapped()
                }
                .disabled(model.addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isDetecting)
                .accessibilityIdentifier(AccessibilityID.continueButton)
            }
        }
    }

    private func continueTapped() {
        guard !model.addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.isDetecting else { return }
        isFieldFocused = false
        model.continueTapped()
    }

    /// No feed, a duplicate, or a failure: a section under the field.
    @ViewBuilder
    private var outcome: some View {
        switch model.detection {
        case .page(let page) where page.candidates.isEmpty:
            Section {
                Text("No feed was found at this address")
                    .accessibilityIdentifier(AccessibilityID.noFeedMessage)
                actionButton(Text("Save as a Web Page"), AccessibilityID.saveAsWebPageButton) { model.saveAsWebPage() }
                actionButton(Text("Try Another Address"), AccessibilityID.tryAnotherAddressButton) {
                    model.tryAnotherAddress()
                    isFieldFocused = true
                }
            }
            .listRowBackground(Theme.surface)
        case .duplicate(let existing):
            Section {
                SourceWording.duplicate(existing)
                    .accessibilityIdentifier(AccessibilityID.duplicateMessage)
                actionButton(Text("Show in Library"), AccessibilityID.showInLibraryButton) {
                    sources.showInLibrary(existing)
                }
            }
            .listRowBackground(Theme.surface)
        case .failed(let failure):
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Could not read this address · \(SourceWording.reason(failure.reason))")
                    if failure.addedScheme, failure.reason == .unreachable || failure.reason == .timedOut {
                        Text("If this site only supports http, type http:// in front of the address.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.failureMessage)
                actionButton(Text("Try Again"), AccessibilityID.tryAgainButton) { model.detect() }
                if failure.offersWebPage {
                    actionButton(Text("Save as a Web Page"), AccessibilityID.saveAsWebPageButton) { model.saveAsWebPage() }
                }
            }
            .listRowBackground(Theme.surface)
        case .page, .feed, .invalidAddress, nil:
            EmptyView()
        }
    }

    private func actionButton(_ title: Text, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .foregroundStyle(.tint)
        }
        .frame(minHeight: Theme.minimumTapTarget)
        .accessibilityIdentifier(identifier)
    }

    private func message(_ text: Text) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.footnote)
        .foregroundStyle(Theme.secondaryText)
    }
}
