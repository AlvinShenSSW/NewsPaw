import NewsPawKit
import SwiftUI

/// The second step: what was found, the choice when there is more than
/// one, the name, the category, the kind and a preview; Save.
struct ConfirmStepView: View {
    @Bindable var model: AddSourceModel
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            Section {
                Text(verbatim: address)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.confirmAddress)
                if case .page(let page) = model.detection, !model.declaredCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        Text("Found \(page.declaredCount) feeds on this page")
                        if page.declaredCount > page.candidates.count {
                            Text("The first \(page.candidates.count) are shown.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Address")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)

            if !model.declaredCandidates.isEmpty {
                Section {
                    ForEach(model.declaredCandidates) { candidate in
                        candidateRow(candidate)
                    }
                    choiceRow(
                        Text("This page itself"), Text("Web page"),
                        selected: model.choice == .webPage, enabled: true, identifier: AccessibilityID.pageItselfChoice
                    ) {
                        model.choose(.webPage)
                    }
                } header: {
                    Text("Choose")
                        .foregroundStyle(Theme.secondaryText)
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                TextField("Name", text: $model.name)
                    .focused($isNameFocused)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .disabled(model.isSaving)
                    .accessibilityIdentifier(AccessibilityID.nameField)
                if model.nameProblem == .tooLong {
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

            Section {
                NavigationLink(value: AddSourceRoute.categoryPicker) {
                    LabeledContent {
                        if let category = model.chosenCategory {
                            Text(verbatim: category.name)
                        } else {
                            Text("Choose")
                        }
                    } label: {
                        Text("Category")
                    }
                }
                .disabled(model.isSaving)
                .accessibilityIdentifier(AccessibilityID.categoryChoiceRow)
                LabeledContent {
                    kind
                        .accessibilityIdentifier(AccessibilityID.kindValue)
                } label: {
                    Text("Kind")
                }
            }
            .listRowBackground(Theme.surface)

            if let feed = model.chosenFeed {
                Section {
                    if feed.latestItems.isEmpty {
                        Text("This feed has no items yet")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(Array(feed.latestItems.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title ?? "")
                                .lineLimit(2)
                            if let published = item.publishedAt {
                                SourceWording.relative(published)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AccessibilityID.previewItem)
                    }
                } header: {
                    Text("Preview")
                        .foregroundStyle(Theme.secondaryText)
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    isNameFocused = false
                    Task { await model.save() }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier(AccessibilityID.saveButton)
            }
        }
    }

    private var address: String {
        switch model.detection {
        case .feed(let candidate): candidate.address
        case .page(let page): page.address
        case .failed(let failure): failure.address
        case .duplicate, .invalidAddress, nil: model.addressText
        }
    }

    @ViewBuilder
    private var kind: some View {
        switch model.choice {
        case .feed:
            if let feed = model.chosenFeed {
                Text("Feed · \(SourceWording.format(feed.format))")
            }
        case .webPage:
            Text("Web page")
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: DeclaredCandidate) -> some View {
        switch candidate.state {
        case .usable(let feed):
            let detail = feed.newestItemAt.map { newest in
                Text("\(SourceWording.format(feed.format)) · latest item \(SourceWording.relative(newest))")
            } ?? Text(verbatim: SourceWording.format(feed.format))
            choiceRow(
                Text(verbatim: feed.title ?? candidate.declaredTitle ?? candidate.address), detail,
                selected: model.choice == .feed(candidate.address), enabled: true,
                identifier: AccessibilityID.candidateChoice(candidate.address)
            ) {
                model.choose(.feed(candidate.address))
            }
        case .notChecked:
            choiceRow(
                Text(verbatim: candidate.declaredTitle ?? candidate.address), Text("Could not check in time"),
                selected: false, enabled: true, identifier: AccessibilityID.candidateChoice(candidate.address)
            ) {
                model.choose(.feed(candidate.address))
            }
        case .failed(let reason):
            choiceRow(
                Text(verbatim: candidate.declaredTitle ?? candidate.address),
                Text("Could not read this address · \(SourceWording.reason(reason))"),
                selected: false, enabled: false, identifier: AccessibilityID.candidateChoice(candidate.address)
            ) {}
        case .alreadyAdded(let existing):
            choiceRow(
                Text(verbatim: candidate.declaredTitle ?? candidate.address), Text("Already in “\(existing.categoryName)”"),
                selected: false, enabled: false, identifier: AccessibilityID.candidateChoice(candidate.address)
            ) {}
        }
    }

    /// A row of the choice list: a title and a second line; the chosen one
    /// has a check mark and the selected trait.
    private func choiceRow(
        _ title: Text, _ detail: Text, selected: Bool, enabled: Bool, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .foregroundStyle(Theme.text)
                    detail
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
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
        .buttonStyle(ChoiceRowStyle())
        .disabled(!enabled || model.isSaving)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// A row that cannot be chosen keeps legible colours, since its second line
/// says why.
private struct ChoiceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
