import NewsPawKit
import SwiftUI

/// The category picker of Add source: this library's categories and "New
/// Category…".
struct CategoryPickerView: View {
    @Bindable var model: AddSourceModel
    @Environment(CategoryModel.self) private var categories

    var body: some View {
        List {
            Section {
                ForEach(categories.summaries) { summary in
                    let selected = model.categoryID == summary.id
                    Button {
                        model.categoryID = summary.id
                        model.path.removeAll { $0 == .categoryPicker }
                    } label: {
                        HStack {
                            Label(summary.category.name, systemImage: summary.category.icon.rawValue)
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: Theme.Spacing.small)
                            if selected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: Theme.minimumTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier(AccessibilityID.categoryChoice(summary.category.name))
                }
                Button {
                    model.beginNewCategory()
                } label: {
                    Label("New Category…", systemImage: "folder.badge.plus")
                        .frame(minHeight: Theme.minimumTapTarget)
                }
                .accessibilityIdentifier(AccessibilityID.newCategoryInSheetButton)
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

/// "New Category…" inside Add source: name and icon. The category is
/// written at once and stays if Add source is cancelled.
struct NewCategoryInSheetView: View {
    @Bindable var model: AddSourceModel
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $model.newCategoryName)
                    .focused($isNameFocused)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .submitLabel(.done)
                    .disabled(model.isCreatingCategory)
                    .accessibilityIdentifier(AccessibilityID.newCategoryNameField)
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
            }
            .listRowBackground(Theme.surface)
            Section {
                IconGrid(selection: $model.newCategoryIcon)
                    .disabled(model.isCreatingCategory)
            } header: {
                Text("Icon")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .foregroundStyle(Theme.text)
        .navigationTitle("New Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create") {
                    isNameFocused = false
                    Task { await model.createCategory() }
                }
                .disabled(Library.categoryNameProblem(model.newCategoryName) != nil || model.isCreatingCategory)
                .accessibilityIdentifier(AccessibilityID.createCategoryButton)
            }
        }
    }
}

/// The suggested sources, grouped (normal partition only). An entry
/// already in the library is marked "Added"; choosing another runs
/// detection on its address.
struct SuggestedSourcesView: View {
    @Bindable var model: AddSourceModel
    @Environment(SourceModel.self) private var sources

    var body: some View {
        let suggestions = sources.library.suggestedSources
        let added = Set(sources.summaries.map(\.address))
        List {
            ForEach(SuggestedSourceGroup.allCases, id: \.self) { group in
                let entries = suggestions.filter { $0.group == group }
                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { entry in
                            let isAdded = added.contains(entry.address)
                            Button {
                                model.chooseSuggested(entry)
                            } label: {
                                HStack {
                                    Text(verbatim: entry.name)
                                        .foregroundStyle(Theme.text)
                                    Spacer(minLength: Theme.Spacing.small)
                                    if isAdded {
                                        Text("Added")
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                }
                                .frame(minHeight: Theme.minimumTapTarget)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isAdded)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(AccessibilityID.suggestedSource(entry.name))
                        }
                    } header: {
                        SourceWording.group(group)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Suggested Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}
