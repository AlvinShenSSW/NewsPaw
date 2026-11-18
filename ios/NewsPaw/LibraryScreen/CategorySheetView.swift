import NewsPawKit
import SwiftUI

/// New category (name and icon) or Category settings (name, icon, moving
/// to the other partition, delete). What is typed lives in the category
/// model, so the sheet survives a container switch with its text.
struct CategorySheetView: View {
    let sheet: CategorySheet
    @Environment(CategoryModel.self) private var categories
    @Environment(AppModel.self) private var model
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        @Bindable var categories = categories
        // While a save is queued or running the editor is locked, so
        // nothing entered then is lost when the sheet closes (RD03 C5).
        let locked = isSaving || categories.isBusy
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
                        .disabled(locked)
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
                        .disabled(locked)
                } header: {
                    Text("Icon")
                        .foregroundStyle(Theme.secondaryText)
                }
                .listRowBackground(Theme.surface)
                if case .settings = sheet {
                    overviewSection(locked: locked)
                }
                if case .settings(let id) = sheet, model.showsPartitionSwitch {
                    moveSection(id, locked: locked)
                }
                if case .settings(let id) = sheet {
                    Section {
                        Button("Delete Category", role: .destructive) {
                            categories.requestDeletion(id)
                        }
                        .frame(minHeight: Theme.minimumTapTarget)
                        .disabled(locked)
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
                    .disabled(locked)
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
                    .disabled(categories.draftNameProblem != nil || locked)
                    .accessibilityIdentifier(AccessibilityID.saveButton)
                }
            }
        }
        .interactiveDismissDisabled(locked)
    }

    /// "Overviews": Automatic, Manual or Off (ux S13; RD23 decision 13),
    /// saved with Save.
    private func overviewSection(locked: Bool) -> some View {
        @Bindable var categories = categories
        return Section {
            Picker("Overviews", selection: $categories.draftOverview) {
                Text("Automatic").tag(OverviewMode.auto)
                Text("Manual").tag(OverviewMode.manual)
                // A key of its own: RD14's "Off" reads 关, and Today says
                // 概览已关闭 (review round 1, R6).
                Text("Off, for overviews", comment: "Overviews option in Category Settings: no overview is written; the English reads Off.")
                    .tag(OverviewMode.off)
            }
            .pickerStyle(.menu)
            .frame(minHeight: Theme.minimumTapTarget)
            .disabled(locked)
            .accessibilityIdentifier(AccessibilityID.overviewModePicker)
        } footer: {
            Text("Automatic: written after the day's first refresh that brings new articles. Manual: written when you tap Write Overview.")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    /// "Move to Adult Partition…" or "Move to Normal Partition…" (ux S13;
    /// RD19 decision 11), while the partition is on. In the normal
    /// partition it unlocks and switches first, carrying the move across;
    /// in the adult partition it begins the move. Not while the sheet has
    /// unsaved changes, a save runs, the system's authentication is asked
    /// for, or a partition operation runs anywhere in the app — a move, a
    /// clear or Turn Off (RD19 review rounds 2 to 4).
    private func moveSection(_ id: UUID, locked: Bool) -> some View {
        Section {
            Button {
                if categories.partition == .normal {
                    // The sheet closes first: what the unlock has to say is
                    // shown at the root.
                    categories.cancelSheet()
                    Task { await model.chooseAdult(pending: .move(categoryID: id)) }
                } else {
                    categories.beginMove(id, from: .adult)
                }
            } label: {
                Group {
                    if categories.partition == .normal {
                        Text("Move to Adult Partition…")
                    } else {
                        Text("Move to Normal Partition…")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(
                locked || categories.isMoving || model.operations.running != nil || model.isAuthenticating
                    || categories.sheetHasChanges(id)
            )
            .accessibilityIdentifier(AccessibilityID.moveCategoryButton)
        }
        .listRowBackground(Theme.surface)
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
    @Environment(\.accent) private var accent
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
                        .foregroundStyle(isSelected ? accent : Theme.text)
                        .frame(width: cellSize, height: cellSize)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Theme.Radius.thumbnail)
                                    .strokeBorder(accent, lineWidth: 2)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Theme.onAccent, accent)
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
