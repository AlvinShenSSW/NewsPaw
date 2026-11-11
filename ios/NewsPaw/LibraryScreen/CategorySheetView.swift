import NewsPawKit
import SwiftUI

/// New category (name and icon) or Category settings (name, icon, delete).
/// What is typed lives in the category model, so the sheet survives a
/// container switch with its text.
struct CategorySheetView: View {
    let sheet: CategorySheet
    @Environment(CategoryModel.self) private var categories
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        @Bindable var categories = categories
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $categories.draftName)
                        .focused($isNameFocused)
                        // The field is drawn 22 pt tall in its row; the 44 pt
                        // around it focuses it too, so its tap target is at
                        // least 44 pt (ux section 6).
                        .frame(minHeight: Theme.minimumTapTarget)
                        .background {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { isNameFocused = true }
                        }
                        .accessibilityIdentifier(AccessibilityID.nameField)
                        .submitLabel(.done)
                    if categories.draftNameProblem == .tooLong {
                        Label {
                            Text("Use at most \(Library.maximumCategoryNameLength) characters.")
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
                Section {
                    IconGrid(selection: $categories.draftIcon)
                } header: {
                    Text("Icon")
                        .foregroundStyle(Theme.secondaryText)
                }
                .listRowBackground(Theme.surface)
                if case .settings(let id) = sheet {
                    Section {
                        Button("Delete Category", role: .destructive) {
                            categories.requestDeletion(id)
                        }
                        .frame(minHeight: Theme.minimumTapTarget)
                        .accessibilityIdentifier(AccessibilityID.deleteCategoryButton)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.groupedBackground)
            .foregroundStyle(Theme.text)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Plain bar buttons: a confirmation-action button would be
                // filled with the accent under a white label.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        categories.cancelSheet()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.cancelButton)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await categories.saveSheet()
                            isSaving = false
                        }
                    }
                    .disabled(categories.draftNameProblem != nil || isSaving)
                    .accessibilityIdentifier(AccessibilityID.saveButton)
                }
            }
        }
    }

    private var title: Text {
        switch sheet {
        case .newCategory: Text("New Category")
        case .settings: Text("Category Settings")
        }
    }
}

/// The fixed set of category icons. The selected icon has a ring and a
/// check mark, not only a colour, and the selected trait for VoiceOver.
struct IconGrid: View {
    @Binding var selection: CategoryIcon
    @ScaledMetric private var cellSize = Theme.minimumTapTarget

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize), spacing: Theme.Spacing.small)], spacing: Theme.Spacing.small) {
            ForEach(CategoryIcon.allCases, id: \.self) { icon in
                let isSelected = icon == selection
                Button {
                    selection = icon
                } label: {
                    Image(systemName: icon.rawValue)
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.accent : Theme.text)
                        .frame(width: cellSize, height: cellSize)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Theme.Radius.thumbnail)
                                    .strokeBorder(Theme.accent, lineWidth: 2)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Theme.onAccent, Theme.accent)
                                    .font(.caption)
                                    .offset(x: Theme.Spacing.tight, y: -Theme.Spacing.tight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon.accessibilityName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier(AccessibilityID.iconButton(icon.rawValue))
            }
        }
        .padding(.vertical, Theme.Spacing.small)
    }
}

extension CategoryIcon {
    /// What VoiceOver says for the icon.
    var accessibilityName: Text {
        switch self {
        case .folder: Text("Folder")
        case .globe: Text("Globe")
        case .globeAsia: Text("Globe showing Asia and Australia")
        case .globeAmericas: Text("Globe showing the Americas")
        case .globeEurope: Text("Globe showing Europe and Africa")
        case .newspaper: Text("Newspaper")
        case .building: Text("Building with columns")
        case .briefcase: Text("Briefcase")
        case .chart: Text("Rising chart")
        case .cpu: Text("Chip")
        case .laptop: Text("Laptop")
        case .sparkles: Text("Sparkles")
        case .flask: Text("Flask")
        case .leaf: Text("Leaf")
        case .heart: Text("Heart")
        case .book: Text("Book")
        case .film: Text("Film")
        case .musicNote: Text("Music note")
        case .gameController: Text("Game controller")
        case .paintPalette: Text("Paint palette")
        case .forkKnife: Text("Fork and knife")
        case .airplane: Text("Airplane")
        case .star: Text("Star")
        }
    }
}
