import NewsPawKit
import SwiftUI

/// Step 1 (decision 4): the NewsPaw logo, then RD14's reading languages as
/// an inline picker whose options are rows, preselected from the system's
/// languages.
struct FirstRunLanguageStep: View {
    @Binding var language: ReadingLocale

    var body: some View {
        List {
            FirstRunHeader(step: .language, text: Text("Titles and summaries are translated into this language.")) {
                Image(decorative: "Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.bottom, Theme.Spacing.small)
            }
            Section {
                Picker("Reading Language", selection: $language) {
                    ForEach(ReadingLocale.allCases, id: \.self) { locale in
                        Text(verbatim: TranslationWording.language(locale)).tag(locale)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.firstRunLanguagePicker)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

/// Step 2 (decision 5): what is sent to the service, and one row for the
/// primary model with its state, which pushes RD13's form unchanged on the
/// Settings path; Save or Cancel returns here.
struct FirstRunModelStep: View {
    @Environment(ModelSettingsModel.self) private var models

    var body: some View {
        List {
            FirstRunHeader(
                step: .model,
                text: Text("Titles, excerpts and article text, and the text of pages you translate, are sent to this service. The key stays on this device. You can skip this and set it up later in Settings.")
            )
            Section {
                NavigationLink(value: SettingsRoute.modelSlot(.primary)) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        ModelWording.role(.primary)
                            .foregroundStyle(Theme.text)
                        if let status = models.statuses[.primary] {
                            Text(verbatim: status.slot.model)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryText)
                            ModelWording.state(status)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryText)
                        } else {
                            Text("Not set up")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .frame(minHeight: Theme.minimumTapTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier(AccessibilityID.firstRunPrimaryModel)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .task { await models.reload() }
    }
}

/// Step 3 (decision 6): the six suggested categories, all off, each with
/// its icon; one that exists already by its name shows "Added" and cannot
/// be unticked. Then "Add a Source…", which opens Add source with its
/// suggested sources. The ticked categories are created by the first run
/// when "Add a Source…" or Done is tapped.
struct FirstRunSourcesStep: View {
    @Environment(\.accent) private var accent
    @Environment(CategoryModel.self) private var categories
    @Binding var ticked: Set<SuggestedSourceGroup>
    let isCreating: Bool
    let addSource: () -> Void

    var body: some View {
        List {
            FirstRunHeader(step: .sources, text: Text("Choose categories to start with, then add your sources."))
            Section {
                ForEach(SuggestedSourceGroup.allCases, id: \.self) { group in
                    row(group)
                }
            } header: {
                Text("Suggested Categories")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("Ticked categories are added when you add a source or tap Done. You can rename them later.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
            Section {
                Button(action: addSource) {
                    Label("Add a Source…", systemImage: "plus")
                        .foregroundStyle(accent)
                        .frame(minHeight: Theme.minimumTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(isCreating)
                .accessibilityIdentifier(AccessibilityID.firstRunAddSource)
            } header: {
                Text("Add Your Own")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ group: SuggestedSourceGroup) -> some View {
        let isAdded = categories.summaries.contains { $0.category.name == SourceWording.groupName(group) }
        let isTicked = isAdded || ticked.contains(group)
        return Button {
            if ticked.contains(group) {
                ticked.remove(group)
            } else {
                ticked.insert(group)
            }
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: group.icon.rawValue)
                    .foregroundStyle(accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                SourceWording.group(group)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isAdded {
                    Text("Added")
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isTicked ? accent : Theme.secondaryText)
                        .font(.title3)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: Theme.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded || isCreating)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isTicked ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.firstRunCategory(group.rawValue))
    }
}
