import NewsPawKit
import SwiftUI
import UIKit

/// Source settings (ux S13): a draft with Cancel and Save, in the form of
/// Category settings. Copy, Update Now and Delete act at once. A web-page
/// source shows only its name, address, category, "Translate when opened"
/// and Delete.
struct SourceSettingsView: View {
    let sourceID: UUID
    @Environment(SourceModel.self) private var sources
    @Environment(CategoryModel.self) private var categories
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        @Bindable var sources = sources
        let locked = isSaving || sources.isBusy
        NavigationStack {
            Form {
                if let source = sources.summary(sourceID) {
                    nameSection(locked: locked)
                    addressSection(source)
                    categorySection(locked: locked)
                    if source.isFeedLike {
                        Section {
                            Toggle("Paused", isOn: $sources.draftPaused)
                                .disabled(locked)
                                .accessibilityIdentifier(AccessibilityID.pausedToggle)
                            Picker("Translate Titles", selection: $sources.draftAutoTranslate) {
                                Text("Follow Global Setting").tag(AutoTranslate.inherit)
                                Text("On").tag(AutoTranslate.on)
                                Text("Off").tag(AutoTranslate.off)
                            }
                            .disabled(locked)
                            .accessibilityIdentifier(AccessibilityID.translateTitlesPicker)
                            Picker("Body", selection: $sources.draftBodyMode) {
                                Text("Automatic").tag(BodyMode.auto)
                                Text("Always Fetch the Page").tag(BodyMode.page)
                                Text("Feed Content Only").tag(BodyMode.feed)
                            }
                            .disabled(locked)
                            .accessibilityIdentifier(AccessibilityID.bodyModePicker)
                        } footer: {
                            footnote
                        }
                        .listRowBackground(Theme.surface)
                        statusSection(source)
                    } else {
                        Section {
                            Toggle("Translate When Opened", isOn: $sources.draftTranslatePage)
                                .disabled(locked)
                                .accessibilityIdentifier(AccessibilityID.translatePageToggle)
                        } footer: {
                            footnote
                        }
                        .listRowBackground(Theme.surface)
                    }
                    Section {
                        Button("Delete Source", role: .destructive) {
                            sources.requestDeletion(sourceID)
                        }
                        .frame(minHeight: Theme.minimumTapTarget)
                        .disabled(locked)
                        .accessibilityIdentifier(AccessibilityID.deleteSourceButton)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.groupedBackground)
            .foregroundStyle(Theme.text)
            .navigationTitle("Source Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        sources.cancelSettings()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(locked)
                    .accessibilityIdentifier(AccessibilityID.cancelButton)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await sources.saveSettings(sourceID)
                            isSaving = false
                        }
                    }
                    .disabled(sources.draftNameProblem != nil || locked)
                    .accessibilityIdentifier(AccessibilityID.saveButton)
                }
            }
        }
        .interactiveDismissDisabled(locked)
    }

    private var isUpdating: Bool {
        sources.updating.contains(sourceID)
    }

    private func nameSection(locked: Bool) -> some View {
        @Bindable var sources = sources
        return Section {
            TextField("Name", text: $sources.draftName)
                .focused($isNameFocused)
                .frame(minHeight: Theme.minimumTapTarget)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isNameFocused = true }
                }
                .accessibilityIdentifier(AccessibilityID.nameField)
                .submitLabel(.done)
                .disabled(locked)
            if sources.draftNameProblem == .tooLong {
                Label {
                    Text("Use at most \(Library.maximumSourceNameLength) characters.")
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier(AccessibilityID.nameTooLongMessage)
            }
        } header: {
            Text("Name")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    private func addressSection(_ source: SourceSummary) -> some View {
        Section {
            HStack {
                Text(verbatim: source.address)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(AccessibilityID.sourceAddress)
                Spacer(minLength: Theme.Spacing.small)
                Button("Copy") {
                    UIPasteboard.general.string = source.address
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .frame(minWidth: Theme.minimumTapTarget, minHeight: Theme.minimumTapTarget)
                .accessibilityIdentifier(AccessibilityID.copyAddressButton)
            }
        } header: {
            Text("Address")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    private func categorySection(locked: Bool) -> some View {
        @Bindable var sources = sources
        return Section {
            Picker("Category", selection: $sources.draftCategoryID) {
                ForEach(categories.summaries) { summary in
                    Text(verbatim: summary.category.name).tag(Optional(summary.id))
                }
            }
            .disabled(locked)
            .accessibilityIdentifier(AccessibilityID.sourceCategoryPicker)
        }
        .listRowBackground(Theme.surface)
    }

    private func statusSection(_ source: SourceSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                if isUpdating {
                    Text("Updating…")
                } else if let status = source.status {
                    SourceWording.status(status)
                }
                if let newest = source.newestItemAt, source.articleCount > 0 {
                    Text("Newest item \(SourceWording.relative(newest))")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.sourceStatus)
            if !source.paused {
                Button {
                    Task { await sources.updateNow(sourceID) }
                } label: {
                    Group {
                        if case .failing = source.status {
                            Text("Try Again")
                        } else {
                            Text("Update Now")
                        }
                    }
                    .foregroundStyle(.tint)
                }
                .frame(minHeight: Theme.minimumTapTarget)
                .disabled(isUpdating || isSaving)
                .accessibilityIdentifier(AccessibilityID.updateNowButton)
            }
        } header: {
            Text("Status")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    private var footnote: some View {
        Text("Saved now; used once translation and full-text reading are available.")
            .foregroundStyle(Theme.secondaryText)
    }
}
