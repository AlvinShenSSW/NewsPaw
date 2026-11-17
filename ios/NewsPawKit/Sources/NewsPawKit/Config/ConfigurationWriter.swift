import Foundation

/// Writes the configuration file (spec section 5; RD20 decision 1): UTF-8
/// JSON, one object, `schema_version` 1, sorted keys, pretty printed,
/// slashes unescaped, times in ISO 8601 UTC with whole seconds. Every
/// member of decision 1 is written for every entity. There is no member for
/// a key, a key reference, a Test result, a device setting or any state:
/// the wire types have none.
enum ConfigurationWriter {
    /// The file for the global settings and the partitions' snapshots
    /// (the normal partition first). The adult partition is in the file
    /// exactly when its snapshot is given.
    static func data(
        settings: ConfigurationSettings, normal: ConfigurationSnapshot, adult: ConfigurationSnapshot?, appVersion: String,
        exportedAt: Date
    ) throws -> Data {
        var categories: [ConfigurationWire.Category] = []
        var sources: [ConfigurationWire.Source] = []
        var partitionSettings: [ConfigurationPartitionSettings] = []
        var slots: [ConfigurationWire.Slot] = []
        for snapshot in [normal] + (adult.map { [$0] } ?? []) {
            let partition = snapshot.partition.rawValue
            for (index, category) in snapshot.categories.enumerated() {
                categories.append(ConfigurationWire.Category(
                    id: category.id.databaseKey, name: category.name, partition: partition, sortOrder: index,
                    icon: category.iconName, overview: category.overview.rawValue
                ))
            }
            for source in snapshot.sources {
                // A web page's `paused` is written as false (section 5's
                // sample); the options of the other kind at their defaults.
                let options = source.options.applying(to: source.kind)
                sources.append(ConfigurationWire.Source(
                    id: source.id.databaseKey, categoryID: source.categoryID.databaseKey, kind: source.kind.rawValue,
                    name: source.name, url: source.address, paused: options.paused, autoTranslate: options.autoTranslate.rawValue,
                    bodyMode: options.bodyMode.rawValue, translatePage: options.translatePage
                ))
            }
            var settings = snapshot.settings
            settings.partition = partition
            partitionSettings.append(settings)
            for role in ModelRole.allCases {
                guard let slot = snapshot.slots[role] else { continue }
                slots.append(ConfigurationWire.Slot(
                    partition: partition, role: role.rawValue, preset: slot.preset.rawValue, baseURL: slot.baseURL, model: slot.model
                ))
            }
        }
        let wire = ConfigurationWire(
            schemaVersion: ConfigurationFile.version, exportedAt: timestamp(exportedAt), appVersion: appVersion,
            includesAdult: adult != nil, settings: settings, categories: categories, sources: sources,
            partitionSettings: partitionSettings, modelSlots: slots
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(wire)
    }

    /// ISO 8601 in UTC with whole seconds.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }
}
