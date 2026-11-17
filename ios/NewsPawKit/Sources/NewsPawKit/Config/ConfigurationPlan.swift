import Foundation

/// How an import treats what already exists (spec N10).
public enum ConfigurationImportMode: Sendable, Hashable {
    /// Adds what is new; changes and deletes nothing.
    case merge
    /// Makes each partition of the file exactly the file's.
    case replace
}

/// One read of a library: what planning compares the file with (RD20
/// decision 4).
struct ConfigurationSnapshot: Sendable {
    struct SourceRow: Sendable, Hashable {
        let id: UUID
        let categoryID: UUID
        let kind: SourceKind
        let address: String
        let name: String
        let options: ConfigurationSourceOptions
        let articleCount: Int
        let starredCount: Int
    }

    let partition: Partition
    /// In the owner's order.
    let categories: [Category]
    let sources: [SourceRow]
    let slots: [ModelRole: ModelSlot]
    /// The values in effect.
    let settings: ConfigurationPartitionSettings
}

/// What differs between a source of the file and the source here at the
/// same address.
public enum ConfigurationSourceDifference: Sendable, Hashable, CaseIterable {
    case name
    case category
    case kind
    case options
}

/// What differs between a slot of the file and the slot here of the same
/// role.
public enum ConfigurationSlotDifference: Sendable, Hashable, CaseIterable {
    case preset
    case address
    case model
}

/// A source as the preview lists it.
public struct ConfigurationPlannedSource: Sendable, Hashable {
    public let name: String
    public let address: String
    /// For a conflict, what differs; empty otherwise.
    public let differences: [ConfigurationSourceDifference]
}

/// A source Replace deletes, with what goes with it.
public struct ConfigurationDeletedSource: Sendable, Hashable {
    public let name: String
    public let address: String
    public let articleCount: Int
    public let starredCount: Int
}

/// A slot as the preview lists it.
public struct ConfigurationPlannedSlot: Sendable, Hashable {
    public let role: ModelRole
    public let preset: ModelPreset
    public let model: String
    /// For a conflict, what differs; empty otherwise.
    public let differences: [ConfigurationSlotDifference]
}

/// What importing one partition of a file does to one library (RD20
/// decision 4): the preview, the review before replacing and the summary
/// are all made by `make`, the import inside its own write transaction
/// over a fresh snapshot, so that the summary is what the transaction did.
public struct ConfigurationPlan: Sendable {
    public let partition: Partition
    public let mode: ConfigurationImportMode
    /// The file's own numbers for this partition.
    public let fileCategoryCount: Int
    public let fileSourceCount: Int

    public let newCategories: [String]
    public let categoriesAlreadyHere: [String]
    /// Replace: matched categories whose icon or overview changes.
    public let changedCategories: [String]
    /// Replace: categories not in the file.
    public let deletedCategories: [String]

    public let newSources: [ConfigurationPlannedSource]
    public let sourcesAlreadyHere: [ConfigurationPlannedSource]
    public let sourceConflicts: [ConfigurationPlannedSource]
    /// Replace: matched sources whose name, category or options change.
    public let changedSources: [ConfigurationPlannedSource]
    /// Replace: sources not in the file.
    public let deletedSources: [ConfigurationDeletedSource]

    public let newSlots: [ConfigurationPlannedSlot]
    public let slotsAlreadyHere: [ConfigurationPlannedSlot]
    public let slotConflicts: [ConfigurationPlannedSlot]
    /// Replace: slots the file does not have.
    public let removedSlots: [ModelRole]
    /// Replace: slots whose stored key is removed — the address changed, or
    /// the slot is removed.
    public let removedKeys: [ModelRole]

    /// Partition settings the file has with another value.
    public let settingDifferences: [ConfigurationSettingDifference]

    // What the transaction writes.
    struct CategoryCreation: Sendable {
        let id: UUID
        let category: ConfigurationCategory
        let sortOrder: Int
    }

    struct CategoryUpdate: Sendable {
        let id: UUID
        let iconName: String
        let overview: OverviewMode
    }

    struct SourceInsertion: Sendable {
        let source: ConfigurationSource
        let categoryID: UUID
    }

    struct SourceUpdate: Sendable {
        let id: UUID
        let name: String
        let categoryID: UUID
        let options: ConfigurationSourceOptions
    }

    let categoryCreations: [CategoryCreation]
    let categoryUpdates: [CategoryUpdate]
    /// Replace: every category of the partition afterwards, in order.
    let finalOrder: [UUID]?
    let deletedCategoryIDs: [UUID]
    let sourceInsertions: [SourceInsertion]
    let sourceUpdates: [SourceUpdate]
    let deletedSourceIDs: [UUID]
    /// Primary before backup.
    let slotWrites: [ModelSlot]
    /// Backup before primary.
    let slotDeletions: [ModelRole]
    /// Keychain references no row names once the transaction commits.
    let releasedKeyReferences: [String]
    /// Replace: the settings members the file has.
    let settingsToApply: ConfigurationPartitionSettings?

    /// Whether the plan writes anything.
    public var writesSomething: Bool {
        !categoryCreations.isEmpty || !categoryUpdates.isEmpty || !deletedCategoryIDs.isEmpty || !sourceInsertions.isEmpty
            || !sourceUpdates.isEmpty || !deletedSourceIDs.isEmpty || !slotWrites.isEmpty || !slotDeletions.isEmpty
            || (settingsToApply.map { !$0.isEmpty } ?? false) || finalOrderChanges
    }

    /// Replace: whether the order of the categories that stay changes.
    let finalOrderChanges: Bool

    /// The articles Replace deletes with their sources.
    public var deletedArticleCount: Int {
        deletedSources.reduce(0) { $0 + $1.articleCount }
    }

    public var deletedStarredCount: Int {
        deletedSources.reduce(0) { $0 + $1.starredCount }
    }

    /// Plans `part` against `snapshot` (decision 4).
    static func make(_ part: ConfigurationPartition, snapshot: ConfigurationSnapshot, mode: ConfigurationImportMode, now: Date) -> ConfigurationPlan {
        // Categories: the identifier each file category maps to.
        var mapped: [UUID] = []
        var newCategories: [String] = []
        var categoriesAlreadyHere: [String] = []
        var changedCategories: [String] = []
        var creations: [CategoryCreation] = []
        var updates: [CategoryUpdate] = []
        var deletedCategories: [String] = []
        var deletedCategoryIDs: [UUID] = []
        var finalOrder: [UUID]?
        var finalOrderChanges = false

        switch mode {
        case .merge:
            var firstOfName: [String: UUID] = [:]
            for category in snapshot.categories where firstOfName[category.name] == nil {
                firstOfName[category.name] = category.id
            }
            var createdOfName: [String: UUID] = [:]
            var nextSortOrder = (snapshot.categories.map(\.sortOrder).max() ?? -1) + 1
            for category in part.categories {
                if let id = firstOfName[category.name] {
                    mapped.append(id)
                    if !categoriesAlreadyHere.contains(category.name) {
                        categoriesAlreadyHere.append(category.name)
                    }
                } else if let id = createdOfName[category.name] {
                    mapped.append(id)
                } else {
                    let id = UUID()
                    createdOfName[category.name] = id
                    creations.append(CategoryCreation(id: id, category: category, sortOrder: nextSortOrder))
                    nextSortOrder += 1
                    mapped.append(id)
                    newCategories.append(category.name)
                }
            }
        case .replace:
            var taken = Set<UUID>()
            for (index, category) in part.categories.enumerated() {
                if let existing = snapshot.categories.first(where: { $0.name == category.name && !taken.contains($0.id) }) {
                    taken.insert(existing.id)
                    mapped.append(existing.id)
                    categoriesAlreadyHere.append(category.name)
                    if existing.iconName != category.iconName || existing.overview != category.overview {
                        updates.append(CategoryUpdate(id: existing.id, iconName: category.iconName, overview: category.overview))
                        changedCategories.append(category.name)
                    }
                } else {
                    let id = UUID()
                    creations.append(CategoryCreation(id: id, category: category, sortOrder: index))
                    mapped.append(id)
                    newCategories.append(category.name)
                }
            }
            for category in snapshot.categories where !taken.contains(category.id) {
                deletedCategories.append(category.name)
                deletedCategoryIDs.append(category.id)
            }
            finalOrder = mapped
            // A kept category whose stored place is not its place in the
            // file.
            finalOrderChanges = snapshot.categories.contains { category in
                taken.contains(category.id) && mapped.firstIndex(of: category.id) != category.sortOrder
            }
        }

        // Sources, matched by normal form.
        var hereByAddress: [String: ConfigurationSnapshot.SourceRow] = [:]
        for source in snapshot.sources {
            hereByAddress[source.address] = source
        }
        var newSources: [ConfigurationPlannedSource] = []
        var sourcesAlreadyHere: [ConfigurationPlannedSource] = []
        var sourceConflicts: [ConfigurationPlannedSource] = []
        var changedSources: [ConfigurationPlannedSource] = []
        var insertions: [SourceInsertion] = []
        var sourceUpdates: [SourceUpdate] = []
        var inFile = Set<String>()
        for source in part.sources {
            inFile.insert(source.address)
            let categoryID = mapped[source.categoryIndex]
            guard let here = hereByAddress[source.address] else {
                newSources.append(ConfigurationPlannedSource(name: source.name, address: source.address, differences: []))
                insertions.append(SourceInsertion(source: source, categoryID: categoryID))
                continue
            }
            let options = source.options.applying(to: here.kind)
            var differences: [ConfigurationSourceDifference] = []
            if here.name != source.name {
                differences.append(.name)
            }
            if here.categoryID != categoryID {
                differences.append(.category)
            }
            if here.kind != source.kind {
                differences.append(.kind)
            }
            if here.options != options {
                differences.append(.options)
            }
            let planned = ConfigurationPlannedSource(name: source.name, address: source.address, differences: differences)
            if differences.isEmpty {
                sourcesAlreadyHere.append(planned)
            } else {
                sourceConflicts.append(planned)
            }
            if mode == .replace, differences.contains(where: { $0 != .kind }) {
                changedSources.append(planned)
                sourceUpdates.append(SourceUpdate(id: here.id, name: source.name, categoryID: categoryID, options: options))
            }
        }
        var deletedSources: [ConfigurationDeletedSource] = []
        var deletedSourceIDs: [UUID] = []
        if mode == .replace {
            for source in snapshot.sources where !inFile.contains(source.address) {
                deletedSources.append(ConfigurationDeletedSource(
                    name: source.name, address: source.address, articleCount: source.articleCount, starredCount: source.starredCount
                ))
                deletedSourceIDs.append(source.id)
            }
        }

        // Slots, per role.
        var newSlots: [ConfigurationPlannedSlot] = []
        var slotsAlreadyHere: [ConfigurationPlannedSlot] = []
        var slotConflicts: [ConfigurationPlannedSlot] = []
        var removedSlots: [ModelRole] = []
        var removedKeys: [ModelRole] = []
        var slotWrites: [ModelSlot] = []
        var slotDeletions: [ModelRole] = []
        var released: [String] = []
        let fileSlots = Dictionary(part.slots.map { ($0.role, $0) }, uniquingKeysWith: { first, _ in first })
        for role in ModelRole.allCases {
            let here = snapshot.slots[role]
            guard let file = fileSlots[role] else {
                if mode == .replace, let here {
                    removedSlots.append(role)
                    if let reference = here.keyRef {
                        removedKeys.append(role)
                        released.append(reference)
                    }
                }
                continue
            }
            guard let here else {
                newSlots.append(ConfigurationPlannedSlot(role: role, preset: file.preset, model: file.model, differences: []))
                slotWrites.append(ModelSlot(
                    role: role, preset: file.preset, baseURL: file.baseURL, model: file.model, keyRef: nil, testOutcome: nil, updatedAt: now
                ))
                continue
            }
            var differences: [ConfigurationSlotDifference] = []
            if here.preset != file.preset {
                differences.append(.preset)
            }
            if here.baseURL != file.baseURL {
                differences.append(.address)
            }
            if here.model != file.model {
                differences.append(.model)
            }
            let planned = ConfigurationPlannedSlot(role: role, preset: file.preset, model: file.model, differences: differences)
            if differences.isEmpty {
                slotsAlreadyHere.append(planned)
                continue
            }
            slotConflicts.append(planned)
            guard mode == .replace else { continue }
            // The key stays only when the address, in normal form, is equal
            // (decision 1); the Test result only when address, model and key
            // all stay.
            let keepsKey = here.baseURL == file.baseURL
            let keyRef = keepsKey ? here.keyRef : nil
            if !keepsKey, let reference = here.keyRef {
                removedKeys.append(role)
                released.append(reference)
            }
            let keepsTest = keepsKey && here.model == file.model && keyRef != nil
            slotWrites.append(ModelSlot(
                role: role, preset: file.preset, baseURL: file.baseURL, model: file.model, keyRef: keyRef,
                testOutcome: keepsTest ? here.testOutcome : nil, updatedAt: now
            ))
        }
        slotDeletions = removedSlots.sorted { first, _ in first == .backup }

        let settingDifferences = part.settings.differences(from: snapshot.settings)
        return ConfigurationPlan(
            partition: part.partition, mode: mode, fileCategoryCount: part.categories.count, fileSourceCount: part.sources.count,
            newCategories: newCategories, categoriesAlreadyHere: categoriesAlreadyHere, changedCategories: changedCategories,
            deletedCategories: deletedCategories,
            newSources: newSources, sourcesAlreadyHere: sourcesAlreadyHere, sourceConflicts: sourceConflicts,
            changedSources: changedSources, deletedSources: deletedSources,
            newSlots: newSlots, slotsAlreadyHere: slotsAlreadyHere, slotConflicts: slotConflicts,
            removedSlots: removedSlots, removedKeys: removedKeys, settingDifferences: settingDifferences,
            categoryCreations: creations, categoryUpdates: updates, finalOrder: finalOrder, deletedCategoryIDs: deletedCategoryIDs,
            sourceInsertions: insertions, sourceUpdates: sourceUpdates, deletedSourceIDs: deletedSourceIDs,
            slotWrites: slotWrites, slotDeletions: slotDeletions, releasedKeyReferences: released,
            settingsToApply: mode == .replace ? part.settings : nil, finalOrderChanges: finalOrderChanges
        )
    }
}
