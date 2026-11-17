import NewsPawKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// The configuration import of the workspace shown (RD20 decision 8):
    /// the file picker, the refusal, and the adult question, at the root,
    /// so that an import begun on Add source or Settings › Data, or handed
    /// over by an unlock, is presented the same way. The preview is the
    /// root's sheet (`AppSheet.configurationImport`).
    func configurationImport() -> some View {
        modifier(ConfigurationImportPresenter())
    }
}

private struct ConfigurationImportPresenter: ViewModifier {
    @Environment(ConfigurationModel.self) private var model
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .fileImporter(
                isPresented: $model.isPickingFile,
                allowedContentTypes: [.newsPawConfiguration, .json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        model.fileChosen(url)
                    } else {
                        model.pickerCancelled()
                    }
                case .failure:
                    model.fileCouldNotBeChosen()
                }
            } onCancellation: {
                model.pickerCancelled()
            }
            .alert(
                Text("Could not import this file"),
                isPresented: Binding {
                    model.alert != nil
                } set: { presented in
                    if !presented, model.alert != nil {
                        model.endImport()
                    }
                },
                presenting: model.alert
            ) { _ in
                Button("OK") {}
            } message: { alert in
                ConfigurationWording.alert(alert)
            }
            .alert(
                Text("This file also contains the adult partition."),
                isPresented: Binding {
                    model.stage == .asking
                } set: { _ in }
            ) {
                Button {
                    model.unlockChosen()
                } label: {
                    model.gateIsOff ? Text("Turn On and Unlock") : Text("Unlock")
                }
                Button("Normal Partition Only") {
                    model.normalOnlyChosen()
                }
                Button("Cancel", role: .cancel) {
                    model.endImport()
                }
            } message: {
                Text("Unlock the adult partition to compare and import that part. Otherwise only the normal partition is imported.")
            }
            .onChange(of: app.notice == nil) { _, dismissed in
                if dismissed {
                    model.noticeDismissed()
                }
            }
    }
}

/// The preview, the lists it pushes, the review before replacing and the
/// summary, in the root's one sheet with its own navigation stack.
struct ConfigurationImportSheet: View {
    @Environment(ConfigurationModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            Group {
                if model.stage == .summary, let result = model.result {
                    ConfigurationSummaryView(result: result)
                } else {
                    ConfigurationPreviewView()
                }
            }
            .navigationDestination(for: ConfigurationImportRoute.self) { route in
                switch route {
                case .group(let group, let partition): ConfigurationGroupView(group: group, partition: partition)
                case .settings: ConfigurationSettingsDifferencesView()
                case .review: ConfigurationReviewView()
                case .deletedSources(let partition): ConfigurationDeletedSourcesView(partition: partition)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .foregroundStyle(Theme.text)
    }

    private var isImporting: Bool {
        if case .importing = model.stage { true } else { false }
    }
}

// MARK: - Preview

private struct ConfigurationPreviewView: View {
    @Environment(ConfigurationModel.self) private var model

    var body: some View {
        let importing: Bool = if case .importing = model.stage { true } else { false }
        Form {
            if model.writeFailed {
                Section {
                    Label {
                        Text("The import could not be completed. Nothing was changed.")
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.configurationFailure)
                }
                .listRowBackground(Theme.surface)
            }
            if let document = model.document {
                Section {
                    Text("Exported \(document.exportedAt.formatted(date: .abbreviated, time: .shortened)) by NewsPaw \(document.appVersion)")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.configurationHeader)
                    ConfigurationAdultLine()
                }
                .listRowBackground(Theme.surface)
            }
            if let preview = model.preview {
                ForEach(preview.partitions, id: \.partition) { part in
                    ConfigurationPartitionSection(part: part)
                }
                let differences = settingDifferences(preview)
                if differences > 0 {
                    Section {
                        NavigationLink(value: ConfigurationImportRoute.settings) {
                            LabeledContent {
                                Text(differences, format: .number)
                                    .foregroundStyle(Theme.secondaryText)
                            } label: {
                                Text("Settings")
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.configurationSettingsRow)
                    } footer: {
                        Text("To take the file's settings, use Replace Everything.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                }
                Section {
                    Button {
                        model.mergeTapped()
                    } label: {
                        HStack {
                            Text("Merge")
                            if model.stage == .importing(.merge) {
                                Spacer(minLength: Theme.Spacing.small)
                                ProgressView()
                            }
                        }
                        .frame(minHeight: Theme.minimumTapTarget)
                    }
                    .disabled(!model.canMerge)
                    .accessibilityIdentifier(AccessibilityID.configurationMergeButton)
                    NavigationLink(value: ConfigurationImportRoute.review) {
                        Text("Replace Everything")
                            .frame(minHeight: Theme.minimumTapTarget)
                    }
                    .disabled(!model.canReplace)
                    .accessibilityIdentifier(AccessibilityID.configurationReplaceEverythingButton)
                } footer: {
                    if !preview.mergeWritesSomething {
                        Text("Everything in this file is already here.")
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier(AccessibilityID.configurationNothingNew)
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Import Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    model.endImport()
                }
                .disabled(importing)
                .accessibilityIdentifier(AccessibilityID.configurationCancelButton)
            }
        }
    }

    /// Every setting the file has with another value: global and per
    /// partition.
    private func settingDifferences(_ preview: ConfigurationPreview) -> Int {
        preview.settingDifferences.count + preview.partitions.reduce(0) { $0 + $1.merge.settingDifferences.count }
    }
}

/// "The adult partition in this file was skipped.", or the first run's line.
private struct ConfigurationAdultLine: View {
    @Environment(ConfigurationModel.self) private var model

    var body: some View {
        if model.adultNotImported {
            Text("The file's adult partition was not imported. You can import it from Settings › Data.")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier(AccessibilityID.configurationAdultSkipped)
        } else if model.adultSkipped {
            Text("The adult partition in this file was skipped.")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier(AccessibilityID.configurationAdultSkipped)
        }
    }
}

/// One partition of the preview: its numbers, then New, Already Here and
/// Conflicts.
private struct ConfigurationPartitionSection: View {
    let part: ConfigurationPartitionPreview

    var body: some View {
        let merge = part.merge
        Section {
            Text("\(merge.fileCategoryCount) categories · \(merge.fileSourceCount) sources")
                .accessibilityIdentifier(AccessibilityID.configurationCounts(part.partition.rawValue))
            row(.new, count: merge.newCategories.count + merge.newSources.count + merge.newSlots.count) {
                Text("New")
            }
            row(.alreadyHere, count: merge.categoriesAlreadyHere.count + merge.sourcesAlreadyHere.count + merge.slotsAlreadyHere.count) {
                Text("Already Here")
            }
            row(.conflicts, count: merge.sourceConflicts.count + merge.slotConflicts.count) {
                Text("Conflicts")
            }
        } header: {
            ConfigurationWording.partition(part.partition)
                .foregroundStyle(Theme.secondaryText)
        } footer: {
            if !merge.sourceConflicts.isEmpty || !merge.slotConflicts.isEmpty {
                Text("Merge keeps these as they are on this device.")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .listRowBackground(Theme.surface)
    }

    private func row(_ group: ConfigurationPreviewGroup, count: Int, label: () -> Text) -> some View {
        NavigationLink(value: ConfigurationImportRoute.group(group, part.partition)) {
            LabeledContent {
                Text(count, format: .number)
                    .foregroundStyle(Theme.secondaryText)
            } label: {
                label()
            }
        }
        .disabled(count == 0)
        .accessibilityIdentifier(AccessibilityID.configurationGroup(group.identifier, part.partition.rawValue))
    }
}

/// A plain lazy list of the categories, sources and models of one group.
private struct ConfigurationGroupView: View {
    let group: ConfigurationPreviewGroup
    let partition: Partition
    @Environment(ConfigurationModel.self) private var model

    var body: some View {
        let plan = model.preview?.partitions.first { $0.partition == partition }?.merge
        List {
            if let plan {
                let categories = categories(plan)
                if !categories.isEmpty {
                    Section {
                        ForEach(Array(categories.enumerated()), id: \.offset) { _, name in
                            Text(verbatim: name)
                        }
                    } header: {
                        Text("Categories")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                }
                let sources = sources(plan)
                if !sources.isEmpty {
                    Section {
                        ForEach(sources, id: \.address) { source in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: source.name)
                                Text(verbatim: source.address)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                                if !source.differences.isEmpty {
                                    ConfigurationWording.differences(source.differences)
                                        .font(.footnote)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Sources")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                }
                let slots = slots(plan)
                if !slots.isEmpty {
                    Section {
                        ForEach(slots, id: \.role) { slot in
                            VStack(alignment: .leading, spacing: 2) {
                                ModelWording.role(slot.role)
                                Text(verbatim: slot.model)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                                if !slot.differences.isEmpty {
                                    ConfigurationWording.differences(slot.differences)
                                        .font(.footnote)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Models")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: Text {
        switch group {
        case .new: Text("New")
        case .alreadyHere: Text("Already Here")
        case .conflicts: Text("Conflicts")
        }
    }

    private func categories(_ plan: ConfigurationPlan) -> [String] {
        switch group {
        case .new: plan.newCategories
        case .alreadyHere: plan.categoriesAlreadyHere
        case .conflicts: []
        }
    }

    private func sources(_ plan: ConfigurationPlan) -> [ConfigurationPlannedSource] {
        switch group {
        case .new: plan.newSources
        case .alreadyHere: plan.sourcesAlreadyHere
        case .conflicts: plan.sourceConflicts
        }
    }

    private func slots(_ plan: ConfigurationPlan) -> [ConfigurationPlannedSlot] {
        switch group {
        case .new: plan.newSlots
        case .alreadyHere: plan.slotsAlreadyHere
        case .conflicts: plan.slotConflicts
        }
    }
}

/// The settings that differ, with this device's value and the file's.
private struct ConfigurationSettingsDifferencesView: View {
    @Environment(ConfigurationModel.self) private var model

    var body: some View {
        List {
            if let preview = model.preview {
                if !preview.settingDifferences.isEmpty {
                    section(preview.settingDifferences, header: nil)
                }
                ForEach(preview.partitions, id: \.partition) { part in
                    if !part.merge.settingDifferences.isEmpty {
                        section(part.merge.settingDifferences, header: ConfigurationWording.partition(part.partition))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ differences: [ConfigurationSettingDifference], header: Text?) -> some View {
        Section {
            ForEach(differences, id: \.setting) { difference in
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ConfigurationWording.setting(difference.setting)
                    LabeledContent {
                        ConfigurationWording.value(difference.here)
                    } label: {
                        Text("On This Device")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    LabeledContent {
                        ConfigurationWording.value(difference.file)
                    } label: {
                        Text("In the File")
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            if let header {
                header.foregroundStyle(Theme.secondaryText)
            }
        } footer: {
            Text("To take the file's settings, use Replace Everything.")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }
}

// MARK: - Review before replacing

private struct ConfigurationReviewView: View {
    @Environment(ConfigurationModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let importing = model.stage == .importing(.replace)
        Form {
            if model.writeFailed {
                Section {
                    Text("The import could not be completed. Nothing was changed.")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.configurationFailure)
                }
                .listRowBackground(Theme.surface)
            }
            if let preview = model.preview {
                ForEach(preview.partitions, id: \.partition) { part in
                    ConfigurationReviewPartition(plan: part.replace, globalSettings: part.partition == .normal ? preview.settingDifferences : [])
                }
                if !(preview.partitions.contains { $0.partition == .adult }) {
                    Section {
                        Text("Only the normal partition is replaced.")
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier(AccessibilityID.configurationOnlyNormal)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            Section {
                Button(role: .destructive) {
                    model.replaceTapped()
                } label: {
                    HStack {
                        Text("Replace")
                        if importing {
                            Spacer(minLength: Theme.Spacing.small)
                            ProgressView()
                        }
                    }
                    .frame(minHeight: Theme.minimumTapTarget)
                }
                .disabled(!model.canReplace)
                .accessibilityIdentifier(AccessibilityID.configurationReplaceButton)
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Before Replacing")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(importing)
        .alert(Text("Replace now?"), isPresented: $model.isConfirmingReplace) {
            Button("Replace", role: .destructive) {
                model.replaceConfirmed()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

/// Every effect of Replace on one partition.
private struct ConfigurationReviewPartition: View {
    let plan: ConfigurationPlan
    let globalSettings: [ConfigurationSettingDifference]

    var body: some View {
        Section {
            ForEach(Array(plan.deletedCategories.enumerated()), id: \.offset) { _, name in
                Label {
                    Text(verbatim: name)
                } icon: {
                    Image(systemName: "folder")
                }
            }
            NavigationLink(value: ConfigurationImportRoute.deletedSources(plan.partition)) {
                LabeledContent {
                    Text(plan.deletedSources.count, format: .number)
                        .foregroundStyle(Theme.secondaryText)
                } label: {
                    Text("Sources")
                }
            }
            .disabled(plan.deletedSources.isEmpty)
            .accessibilityIdentifier(AccessibilityID.configurationDeletedSources(plan.partition.rawValue))
            Text("\(plan.deletedArticleCount) articles, \(plan.deletedStarredCount) of them starred")
                .accessibilityIdentifier(AccessibilityID.configurationDeletedArticles(plan.partition.rawValue))
        } header: {
            Text("\(ConfigurationWording.partition(plan.partition)) · \(Text("Deleted"))")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
        if !plan.changedSources.isEmpty {
            Section {
                ForEach(plan.changedSources, id: \.address) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: source.name)
                        ConfigurationWording.differences(source.differences.filter { $0 != .kind })
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Changed")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        if !plan.removedSlots.isEmpty {
            Section {
                ForEach(plan.removedSlots, id: \.self) { role in
                    ModelWording.role(role)
                }
            } header: {
                Text("Models removed")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        if !plan.removedKeys.isEmpty {
            Section {
                ForEach(plan.removedKeys, id: \.self) { role in
                    ModelWording.role(role)
                        .accessibilityIdentifier(AccessibilityID.configurationRemovedKey(plan.partition.rawValue, role.rawValue))
                }
            } header: {
                Text("Keys removed")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        let settings = globalSettings + plan.settingDifferences
        if !settings.isEmpty {
            Section {
                ForEach(settings, id: \.setting) { difference in
                    LabeledContent {
                        ConfigurationWording.value(difference.file)
                    } label: {
                        ConfigurationWording.setting(difference.setting)
                    }
                }
            } header: {
                Text("Settings replaced")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
    }
}

private struct ConfigurationDeletedSourcesView: View {
    let partition: Partition
    @Environment(ConfigurationModel.self) private var model

    var body: some View {
        let sources = model.preview?.partitions.first { $0.partition == partition }?.replace.deletedSources ?? []
        List {
            Section {
                ForEach(sources, id: \.address) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: source.name)
                        Text(verbatim: source.address)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                        Text("\(source.articleCount) articles, \(source.starredCount) of them starred")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Deleted")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Summary

private struct ConfigurationSummaryView: View {
    let result: ConfigurationImportResult
    @Environment(ConfigurationModel.self) private var model
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        Form {
            if result.isPartial {
                Section {
                    Text("The adult partition was imported. The normal partition and the settings could not be, and are unchanged.")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.configurationPartial)
                }
                .listRowBackground(Theme.surface)
            }
            if model.adultSkipped || model.adultNotImported {
                Section {
                    ConfigurationAdultLine()
                }
                .listRowBackground(Theme.surface)
            }
            ForEach(outcomes, id: \.0) { partition, outcome in
                if case .imported(let plan, let keysNeeded) = outcome {
                    Section {
                        row(Text("Added"), "added", partition, categories: plan.newCategories.count, sources: plan.newSources.count)
                        // Criterion 4: what was already here (review round 1, R1).
                        row(
                            Text("Already Here"), "alreadyHere", partition,
                            categories: plan.categoriesAlreadyHere.count, sources: plan.sourcesAlreadyHere.count
                        )
                        // Keys of their own: the review's "Changed" and
                        // "Deleted" say what will happen, these what did.
                        row(
                            Text(LocalizedStringResource("summary.changed", defaultValue: "Changed", comment: "Configuration import summary row: what was changed.")),
                            "changed", partition, categories: plan.changedCategories.count, sources: plan.changedSources.count
                        )
                        row(
                            Text(LocalizedStringResource("summary.deleted", defaultValue: "Deleted", comment: "Configuration import summary row: what was deleted.")),
                            "deleted", partition, categories: plan.deletedCategories.count, sources: plan.deletedSources.count
                        )
                        if keysNeeded > 0 {
                            Text("\(keysNeeded) models need a key.")
                                .accessibilityIdentifier(AccessibilityID.configurationKeysNeeded(partition.rawValue))
                            Button("Set Up Keys") {
                                navigation.openSettings(partition == .normal ? .models : .adultPartition)
                            }
                            .frame(minHeight: Theme.minimumTapTarget)
                            .accessibilityIdentifier(AccessibilityID.configurationSetUpKeys(partition.rawValue))
                        }
                    } header: {
                        ConfigurationWording.partition(partition)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Imported")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    navigation.sheet = nil
                }
                .accessibilityIdentifier(AccessibilityID.configurationDoneButton)
            }
        }
    }

    private var outcomes: [(Partition, ConfigurationPartitionOutcome)] {
        [(Partition.normal, result.normal)] + (result.adult.map { [(Partition.adult, $0)] } ?? [])
    }

    private func row(_ label: Text, _ name: String, _ partition: Partition, categories: Int, sources: Int) -> some View {
        LabeledContent {
            Text("\(categories) categories · \(sources) sources")
                .foregroundStyle(Theme.secondaryText)
        } label: {
            label
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.configurationSummaryRow(name, partition.rawValue))
    }
}

// MARK: - Wording

/// The wording of the configuration screens (RD20 decision 11).
enum ConfigurationWording {
    static func partition(_ partition: Partition) -> Text {
        switch partition {
        case .normal: Text("Normal")
        case .adult: Text("Adult")
        }
    }

    static func alert(_ alert: ConfigurationModel.Alert) -> Text {
        switch alert {
        case .storage: Text("The import could not be completed. Nothing was changed.")
        case .refused(let refusal): Self.refusal(refusal)
        }
    }

    /// The reason sentence of a refused file. Positions name a list and a
    /// number, never the file's text.
    static func refusal(_ refusal: ConfigurationRefusal) -> Text {
        switch refusal {
        case .tooLarge: Text("It is larger than 5 MB.")
        case .unreadable: Text("The file could not be read.")
        case .notAConfiguration: Text("It is not a NewsPaw configuration file.")
        case .newerVersion: Text("It was made by a newer version of NewsPaw. Update the app to import it.")
        case .tooManyCategories: Text("It has more than 500 categories.")
        case .tooManySources: Text("It has more than 5,000 sources.")
        case .adultMismatch: Text("The file's adult partition entries do not match its header.")
        case .invalid(let problem, let position):
            invalid(problem, at: position)
        }
    }

    private static func invalid(_ problem: ConfigurationProblem, at position: ConfigurationPosition) -> Text {
        let place = Self.position(position)
        return switch problem {
        case .name: Text("A name is empty or too long (\(place)).")
        case .address: Text("An address is not an http or https address (\(place)).")
        case .modelAddress: Text("A model service address is not https (\(place)).")
        case .unknownValue: Text("A value is not one this version of NewsPaw knows (\(place)).")
        case .missingCategory: Text("An entry refers to a category that is not in the file (\(place)).")
        case .duplicateAddress: Text("An address is listed twice in one partition (\(place)).")
        case .backupWithoutPrimary: Text("A backup model has no primary model (\(place)).")
        }
    }

    static func position(_ position: ConfigurationPosition) -> String {
        switch position {
        case .category(let number): String(localized: "category \(number)")
        case .source(let number): String(localized: "source \(number)")
        case .model(let number): String(localized: "model \(number)")
        case .settings: String(localized: "settings")
        }
    }

    static func differences(_ differences: [ConfigurationSourceDifference]) -> Text {
        joined(differences.map { difference in
            switch difference {
            case .name: Text("Name differs")
            case .category: Text("Category differs")
            case .kind: Text("Kind differs")
            case .options: Text("Options differ")
            }
        })
    }

    static func differences(_ differences: [ConfigurationSlotDifference]) -> Text {
        joined(differences.map { difference in
            switch difference {
            case .preset: Text("Value differs")
            case .address: Text("Address differs")
            case .model: Text("Model differs")
            }
        })
    }

    private static func joined(_ texts: [Text]) -> Text {
        texts.dropFirst().reduce(texts.first ?? Text(verbatim: "")) { result, text in
            Text("\(result) · \(text)")
        }
    }

    /// A setting's own row title.
    static func setting(_ setting: ConfigurationSettingName) -> Text {
        switch setting {
        case .refreshMinutes: Text("Refresh Interval")
        case .retentionDays: Text("Keep Articles")
        case .readingLocale: Text("Reading Language")
        case .autoTranslateTitles: Text("Translate Titles Automatically")
        case .showOriginalTitles: Text("Show Original Titles in Lists")
        case .dailyAutoLimit: Text("Daily Automatic Limit")
        case .listThumbnails: Text("Show Thumbnails in Lists")
        }
    }

    static func value(_ value: ConfigurationSettingValue) -> Text {
        switch value {
        case .refreshInterval(let interval):
            switch interval {
            case .fifteenMinutes: Text("Every 15 Minutes")
            case .thirtyMinutes: Text("Every 30 Minutes")
            case .sixtyMinutes: Text("Every Hour")
            case .manualOnly: Text("Manual Only")
            }
        case .retention(let retention):
            switch retention {
            case .sevenDays: Text("7 Days")
            case .thirtyDays: Text("30 Days")
            case .ninetyDays: Text("90 Days")
            case .forever: Text("Forever")
            }
        case .readingLocale(let locale):
            switch locale {
            case .simplifiedChinese: Text("Simplified Chinese")
            case .english: Text("English")
            case .japanese: Text("Japanese")
            }
        case .flag(let on): on ? Text("On") : Text("Off")
        case .number(let number): Text(number, format: .number)
        }
    }
}
