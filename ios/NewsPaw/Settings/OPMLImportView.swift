import NewsPawKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// The OPML import of one entry point (RD08 decision 5): the file
    /// picker, the alert for a refused file, and the preview sheet with its
    /// own navigation stack. Only the import started on `origin` is
    /// presented here.
    func opmlImport(from origin: OPMLImportOrigin) -> some View {
        modifier(OPMLImportPresenter(origin: origin))
    }
}

private struct OPMLImportPresenter: ViewModifier {
    let origin: OPMLImportOrigin
    @Environment(SourceModel.self) private var sources
    @Environment(CategoryModel.self) private var categories
    @Environment(\.accent) private var accent

    private var model: OPMLImportModel? {
        guard let model = sources.opmlImport, model.origin == origin else { return nil }
        return model
    }

    func body(content: Content) -> some View {
        let model = model
        content
            .fileImporter(
                isPresented: Binding {
                    model?.isPickingFile ?? false
                } set: { presented in
                    if !presented {
                        model?.isPickingFile = false
                    }
                },
                allowedContentTypes: [.opml, .xml],
                allowsMultipleSelection: false
            ) { result in
                guard let model else { return }
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        model.fileChosen(url)
                    } else {
                        sources.opmlImportEnded(model)
                    }
                case .failure: model.alert = .refused(.unreadable)
                }
            } onCancellation: {
                if let model {
                    sources.opmlImportEnded(model)
                }
            }
            .alert(
                Text("Could not import this file"),
                isPresented: Binding {
                    model?.alert != nil
                } set: { presented in
                    if !presented, let model {
                        model.alert = nil
                        sources.opmlImportEnded(model)
                    }
                },
                presenting: model?.alert
            ) { _ in
                Button("OK") {}
            } message: { alert in
                OPMLWording.alert(alert)
            }
            .sheet(
                isPresented: Binding {
                    model?.isShowingPreview ?? false
                } set: { presented in
                    if !presented {
                        model?.isShowingPreview = false
                    }
                },
                onDismiss: {
                    // Cancel, Done or a swipe: leaving the summary starts the
                    // refresh.
                    if let model {
                        sources.opmlImportEnded(model)
                    }
                }
            ) {
                if let model {
                    OPMLImportSheet(model: model)
                        .environment(sources)
                        .environment(categories)
                        .tint(accent)
                }
            }
    }
}

/// The preview, then the summary, in one sheet.
private struct OPMLImportSheet: View {
    @Bindable var model: OPMLImportModel

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                if case .done(let summary) = model.stage {
                    OPMLSummaryView(model: model, summary: summary)
                } else {
                    OPMLPreviewView(model: model)
                }
            }
            .navigationDestination(for: OPMLImportRoute.self) { route in
                switch route {
                case .categoryPicker: OPMLCategoryPickerView(model: model)
                case .newCategory: OPMLNewCategoryView(model: model)
                case .skipped: OPMLSkippedView(entries: skipped)
                }
            }
        }
        .interactiveDismissDisabled(model.stage == .importing)
        .foregroundStyle(Theme.text)
    }

    private var skipped: [OPMLSkippedEntry] {
        if case .done(let summary) = model.stage {
            return summary.skipped
        }
        return model.plan?.skipped ?? []
    }
}

/// What the file would do: the numbers, the folders, the category for the
/// feeds outside any folder, the skipped entries; Cancel and Import.
private struct OPMLPreviewView: View {
    @Bindable var model: OPMLImportModel
    @Environment(CategoryModel.self) private var categories

    var body: some View {
        let importing = model.stage == .importing
        Form {
            if let plan = model.plan {
                Section {
                    LabeledContent {
                        Text(plan.addedFeeds, format: .number)
                            .foregroundStyle(Theme.secondaryText)
                    } label: {
                        Text("Feeds to Add")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.opmlFeedsToAdd)
                    if !plan.changesSomething {
                        Text("Everything in this file is already in the library.")
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier(AccessibilityID.opmlNothingToAdd)
                    }
                }
                .listRowBackground(Theme.surface)
                if !plan.categories.isEmpty {
                    Section {
                        OPMLCategoryRows(categories: plan.categories)
                    } header: {
                        Text("Folders")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                }
                if plan.needsOutsideCategory {
                    Section {
                        LabeledContent {
                            Text(plan.outsideFeeds, format: .number)
                                .foregroundStyle(Theme.secondaryText)
                        } label: {
                            Text("Feeds")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AccessibilityID.opmlOutsideFeeds)
                        NavigationLink(value: OPMLImportRoute.categoryPicker) {
                            LabeledContent {
                                if let name = model.choiceName(in: categories.summaries) {
                                    Text(verbatim: name)
                                        .foregroundStyle(Theme.secondaryText)
                                } else {
                                    Text("Required")
                                        .foregroundStyle(Theme.secondaryText)
                                }
                            } label: {
                                Text("Category")
                            }
                        }
                        .frame(minHeight: Theme.minimumTapTarget)
                        .disabled(importing)
                        .accessibilityIdentifier(AccessibilityID.opmlCategoryRow)
                    } header: {
                        Text("Outside Any Folder")
                            .foregroundStyle(Theme.secondaryText)
                    } footer: {
                        Text("Choose the category for the feeds that are not in a folder.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                }
                if !plan.skipped.isEmpty {
                    OPMLSkippedRow(count: plan.skipped.count)
                }
                if let failure = model.failure {
                    Section {
                        Label {
                            OPMLWording.failure(failure)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                        }
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.opmlFailure)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Import OPML")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    model.isShowingPreview = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(importing)
                .accessibilityIdentifier(AccessibilityID.opmlCancelButton)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if importing {
                    ProgressView()
                        .accessibilityLabel(Text("Importing…"))
                } else {
                    // A plain bar button, as Add source's Continue.
                    Button("Import") {
                        model.importTapped()
                    }
                    .disabled(!model.canImport)
                    .accessibilityIdentifier(AccessibilityID.opmlImportButton)
                }
            }
        }
    }
}

/// The categories of a plan or a summary: name, new or existing, and the
/// feeds added to each.
private struct OPMLCategoryRows: View {
    let categories: [OPMLCategoryResult]

    var body: some View {
        ForEach(Array(categories.enumerated()), id: \.offset) { _, category in
            LabeledContent {
                Text(category.addedFeeds, format: .number)
                    .foregroundStyle(Theme.secondaryText)
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(verbatim: category.name)
                    Group {
                        if category.isNew {
                            Text("New Category")
                        } else {
                            Text("Existing Category")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(minHeight: Theme.minimumTapTarget)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.opmlFolder(category.name))
        }
    }
}

private struct OPMLSkippedRow: View {
    let count: Int

    var body: some View {
        Section {
            NavigationLink(value: OPMLImportRoute.skipped) {
                LabeledContent {
                    Text(count, format: .number)
                        .foregroundStyle(Theme.secondaryText)
                } label: {
                    Text("Skipped")
                }
            }
            .frame(minHeight: Theme.minimumTapTarget)
            .accessibilityIdentifier(AccessibilityID.opmlSkippedRow)
        } footer: {
            Text("Entries already in the library, listed twice, or not an http or https address are not imported.")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }
}

/// The category for the feeds outside any folder: the library's categories
/// and "New Category…".
private struct OPMLCategoryPickerView: View {
    @Bindable var model: OPMLImportModel
    @Environment(CategoryModel.self) private var categories
    @Environment(\.accent) private var accent

    var body: some View {
        List {
            Section {
                ForEach(categories.summaries) { summary in
                    let selected = model.choice == .existing(summary.id)
                    Button {
                        model.choice = .existing(summary.id)
                        model.path.removeAll { $0 == .categoryPicker }
                    } label: {
                        HStack {
                            Label(summary.category.name, systemImage: summary.category.icon.rawValue)
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: Theme.Spacing.small)
                            if selected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: Theme.minimumTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier(AccessibilityID.opmlCategoryChoice(summary.category.name))
                }
                Button {
                    if case .named(let name) = model.choice {
                        model.newCategoryName = name
                    }
                    model.path.append(.newCategory)
                } label: {
                    Label("New Category…", systemImage: "folder.badge.plus")
                        .frame(minHeight: Theme.minimumTapTarget)
                }
                .accessibilityIdentifier(AccessibilityID.opmlNewCategoryButton)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Category")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "New Category…" in the import: a name only. Nothing is created until
/// Import; a name of an existing category or of a folder of the file
/// takes that category.
private struct OPMLNewCategoryView: View {
    @Bindable var model: OPMLImportModel
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $model.newCategoryName)
                    .focused($isNameFocused)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .submitLabel(.done)
                    .onSubmit { model.useNewCategoryName() }
                    .accessibilityIdentifier(AccessibilityID.opmlNewCategoryField)
                if Library.categoryNameProblem(model.newCategoryName) == .tooLong {
                    Label {
                        Text("Use at most \(Library.maximumCategoryNameLength) characters.")
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                }
            } header: {
                Text("Name")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("The category is created when you import. If a category or a folder of the file has this name, the feeds go there.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("New Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    isNameFocused = false
                    model.useNewCategoryName()
                }
                .disabled(Library.categoryNameProblem(model.newCategoryName) != nil)
                .accessibilityIdentifier(AccessibilityID.opmlUseNameButton)
            }
        }
        .onAppear { isNameFocused = true }
    }
}

/// The entries that are not imported, with their reasons. Up to 2,000
/// plain rows in a lazy list.
private struct OPMLSkippedView: View {
    let entries: [OPMLSkippedEntry]

    var body: some View {
        List {
            Section {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        Text(verbatim: entry.name.isEmpty ? entry.address : entry.name)
                        if !entry.name.isEmpty {
                            Text(verbatim: entry.address)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        OPMLWording.reason(entry.reason)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, Theme.Spacing.tight)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.opmlSkipped(index))
                }
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Skipped")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What the import did. Leaving it, by Done or a swipe, starts the refresh.
private struct OPMLSummaryView: View {
    @Bindable var model: OPMLImportModel
    let summary: OPMLImportSummary

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(summary.addedFeeds, format: .number)
                        .foregroundStyle(Theme.secondaryText)
                } label: {
                    Text("Feeds Added")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.opmlFeedsAdded)
            } footer: {
                if summary.addedFeeds > 0 {
                    Text("The new feeds are updated when you close this screen.")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .listRowBackground(Theme.surface)
            if !summary.categories.isEmpty {
                Section {
                    OPMLCategoryRows(categories: summary.categories)
                } header: {
                    Text("Categories")
                        .foregroundStyle(Theme.secondaryText)
                }
                .listRowBackground(Theme.surface)
            }
            if !summary.skipped.isEmpty {
                OPMLSkippedRow(count: summary.skipped.count)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Import Complete")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    model.isShowingPreview = false
                }
                .accessibilityIdentifier(AccessibilityID.opmlDoneButton)
            }
        }
    }
}

/// The interface's sentences for an import.
enum OPMLWording {
    static func alert(_ alert: OPMLImportModel.Alert) -> Text {
        switch alert {
        case .refused(let refusal): refused(refusal)
        case .storage: Text("The library could not be read.")
        }
    }

    static func refused(_ refusal: OPMLRefusal) -> Text {
        switch refusal {
        case .tooLarge: Text("The file is larger than 5 MB.")
        case .unreadable: Text("The file could not be read.")
        case .hasDocumentType: Text("The file declares a document type (<!DOCTYPE>), which is not accepted.")
        case .notWellFormed(let line) where line > 0: Text("The file is not well-formed XML (line \(line)).")
        case .notWellFormed: Text("The file is not well-formed XML.")
        case .notOPML: Text("The file is not an OPML file.")
        case .tooManyFeeds: Text("The file lists more than \(OPMLReader.maximumFeeds) feeds.")
        case .tooManyFolders: Text("The file has more than \(OPMLReader.maximumFolders) folders.")
        case .empty: Text("The file lists no feeds and no folders.")
        }
    }

    static func failure(_ failure: OPMLImportModel.Failure) -> Text {
        switch failure {
        case .storage: Text("The import could not be saved. Nothing was added.")
        case .categoryGone: Text("That category no longer exists. Choose another.")
        }
    }

    static func reason(_ reason: OPMLSkipReason) -> Text {
        switch reason {
        case .invalidAddress: Text("Not an http or https address")
        case .alreadyInLibrary(let category): Text("Already in \(category)")
        case .repeatedInFile: Text("Listed earlier in this file")
        }
    }
}
