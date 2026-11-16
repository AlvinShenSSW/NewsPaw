import NewsPawKit
import SwiftUI

/// Settings → Models & Translation (ux S8; RD13 decision 14; RD14 decision
/// 12): the reading language, the two translation switches, then the
/// primary and backup model, each with its name and state. The settings are
/// global; the models are the normal library's, in either partition.
struct ModelsView: View {
    @Environment(ModelSettingsModel.self) private var models
    @Environment(TranslationSettings.self) private var translation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var translation = translation
        List {
            // An inline picker whose options are rows: at the largest text
            // size each wraps instead of being cut, as on Refresh.
            Section {
                Picker("Reading Language", selection: $translation.readingLocale) {
                    ForEach(ReadingLocale.allCases, id: \.self) { locale in
                        Text(verbatim: TranslationWording.language(locale)).tag(locale)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.readingLanguagePicker)
            } header: {
                Text("Reading Language")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("Titles and summaries are translated into this language.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
            Section {
                Toggle("Translate Titles Automatically", isOn: $translation.translatesTitlesAutomatically)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .accessibilityIdentifier(AccessibilityID.autoTranslateToggle)
                Toggle("Show Original Titles in Lists", isOn: $translation.showsOriginalTitles)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .accessibilityIdentifier(AccessibilityID.showOriginalTitlesToggle)
            } header: {
                Text("Translation")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
            Section {
                row(.primary)
                    .accessibilityIdentifier(AccessibilityID.primaryModelRow)
                row(.backup)
                    .disabled(!models.hasPrimary)
                    .accessibilityIdentifier(AccessibilityID.backupModelRow)
            } header: {
                Text("Models")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                if !models.hasPrimary {
                    Text("Set up the primary model first")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.backupNeedsPrimary)
                }
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Models & Translation")
        // At the accessibility sizes the large title is cut on iPhone
        // ("Models & Tra…"); the inline title is not enlarged and fits.
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .automatic)
        .task { await models.reload() }
    }

    private func row(_ role: ModelRole) -> some View {
        NavigationLink(value: SettingsRoute.modelSlot(role)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                // An explicit colour is not dimmed by `disabled`: the
                // backup's title is secondary while it cannot be set up.
                ModelWording.role(role)
                    .foregroundStyle(role == .primary || models.hasPrimary ? Theme.text : Theme.secondaryText)
                if let status = models.statuses[role] {
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
    }
}
