import Foundation

// MARK: - The document

/// A source's options, as the file gives them for its kind (spec N03):
/// `paused`, `autoTranslate` and `bodyMode` for a feed-like kind,
/// `translatePage` for a web page; the members of the other kind hold their
/// defaults.
public struct ConfigurationSourceOptions: Sendable, Hashable {
    public let paused: Bool
    public let autoTranslate: AutoTranslate
    public let bodyMode: BodyMode
    public let translatePage: Bool

    public static let defaults = ConfigurationSourceOptions(paused: false, autoTranslate: .inherit, bodyMode: .auto, translatePage: false)

    public init(paused: Bool, autoTranslate: AutoTranslate, bodyMode: BodyMode, translatePage: Bool) {
        self.paused = paused
        self.autoTranslate = autoTranslate
        self.bodyMode = bodyMode
        self.translatePage = translatePage
    }

    /// The options that apply to `kind`, the others at their defaults.
    func applying(to kind: SourceKind) -> ConfigurationSourceOptions {
        if kind == .webpage {
            ConfigurationSourceOptions(paused: false, autoTranslate: .inherit, bodyMode: .auto, translatePage: translatePage)
        } else {
            ConfigurationSourceOptions(paused: paused, autoTranslate: autoTranslate, bodyMode: bodyMode, translatePage: false)
        }
    }
}

/// A category of the file, validated and cleaned.
public struct ConfigurationCategory: Sendable, Hashable {
    public let name: String
    /// The icon's name as given: a name this version does not know is kept
    /// as text and shows as `folder` (RD02).
    public let iconName: String
    public let overview: OverviewMode
}

/// A source of the file, validated, with its address in normal form.
public struct ConfigurationSource: Sendable, Hashable {
    /// `SourceAddress`'s normal form.
    public let address: String
    public let name: String
    public let kind: SourceKind
    /// The index of its category in its partition's `categories`.
    public let categoryIndex: Int
    public let options: ConfigurationSourceOptions
}

/// A model slot of the file: the non-secret part only (spec N08, N10).
public struct ConfigurationSlot: Sendable, Hashable {
    public let role: ModelRole
    public let preset: ModelPreset
    /// `ModelAddress`'s normal form.
    public let baseURL: String
    public let model: String
}

/// One partition of the file.
public struct ConfigurationPartition: Sendable, Hashable {
    public let partition: Partition
    /// In the file's order: by `sort_order`, then by position.
    public let categories: [ConfigurationCategory]
    /// In file order.
    public let sources: [ConfigurationSource]
    /// The primary first.
    public let slots: [ConfigurationSlot]
    public let settings: ConfigurationPartitionSettings
}

/// A configuration file that passed every check (RD20 decision 3): typed
/// and normalised. Nothing in it is a key, and nothing in it is ever
/// followed, fetched or executed.
public struct ConfigurationDocument: Sendable, Hashable {
    public let version: Int
    public let exportedAt: Date
    public let appVersion: String
    public let settings: ConfigurationSettings
    public let normal: ConfigurationPartition
    /// Present exactly when the file says `includes_adult: true`.
    public let adult: ConfigurationPartition?

    public var includesAdult: Bool {
        adult != nil
    }

    /// The same document without its adult part.
    public var withoutAdult: ConfigurationDocument {
        ConfigurationDocument(
            version: version, exportedAt: exportedAt, appVersion: appVersion, settings: settings, normal: normal, adult: nil
        )
    }

    /// The document's part for `partition`.
    public func part(_ partition: Partition) -> ConfigurationPartition? {
        partition == .normal ? normal : adult
    }
}

// MARK: - Refusals

/// Where in the file a refused value is: which list and which position
/// (1-based), never its text.
public enum ConfigurationPosition: Sendable, Hashable {
    case category(Int)
    case source(Int)
    case model(Int)
    /// `settings` or an entry of `partition_settings`.
    case settings
}

/// What is wrong with an entry.
public enum ConfigurationProblem: Sendable, Hashable {
    /// A name, or a model name, empty after cleaning or over its limit.
    case name
    /// A source address that is not an http or https address with a host
    /// and no user name, or over its limit.
    case address
    /// A model service address that is not https, has a query, or cannot
    /// be read.
    case modelAddress
    /// A value of the wrong type, or outside its closed set.
    case unknownValue
    /// A source names a category the file does not have.
    case missingCategory
    /// One address twice in one partition.
    case duplicateAddress
    /// A backup slot without a primary of its partition.
    case backupWithoutPrimary
}

/// Why a configuration file is refused (RD20 criterion 3). A refusal never
/// carries part of the file.
public enum ConfigurationRefusal: Error, Sendable, Hashable {
    /// Larger than `ConfigurationFile.maximumBytes`.
    case tooLarge
    /// The file could not be read.
    case unreadable
    /// Not a NewsPaw configuration file: not JSON, not an object, too
    /// deeply nested, a required member missing, a version below 1, or a
    /// structure this app never writes (two categories with one identifier,
    /// two slots for one role, a partition's settings twice).
    case notAConfiguration
    /// Made by a newer version of NewsPaw.
    case newerVersion
    case tooManyCategories
    case tooManySources
    /// An entry breaks a rule.
    case invalid(ConfigurationProblem, at: ConfigurationPosition)
    /// An adult entry while `includes_adult` is false.
    case adultMismatch
}

// MARK: - The wire

/// The file as JSON (spec section 5): every member optional, so that what
/// is missing is found by the reader and not by the decoder.
struct ConfigurationWire: Codable {
    var schemaVersion: Int?
    var exportedAt: String?
    var appVersion: String?
    var includesAdult: Bool?
    var settings: ConfigurationSettings?
    var categories: [Category]?
    var sources: [Source]?
    var partitionSettings: [ConfigurationPartitionSettings]?
    var modelSlots: [Slot]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case appVersion = "app_version"
        case includesAdult = "includes_adult"
        case settings
        case categories
        case sources
        case partitionSettings = "partition_settings"
        case modelSlots = "model_slots"
    }

    struct Category: Codable {
        var id: String?
        var name: String?
        var partition: String?
        var sortOrder: Int?
        var icon: String?
        var overview: String?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case partition
            case sortOrder = "sort_order"
            case icon
            case overview
        }
    }

    struct Source: Codable {
        var id: String?
        var categoryID: String?
        var kind: String?
        var name: String?
        var url: String?
        var paused: Bool?
        var autoTranslate: String?
        var bodyMode: String?
        var translatePage: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case categoryID = "category_id"
            case kind
            case name
            case url
            case paused
            case autoTranslate = "auto_translate"
            case bodyMode = "body_mode"
            case translatePage = "translate_page"
        }
    }

    /// The non-secret part of a slot. There is no member for a key, a key
    /// reference or a Test result, so none can be written; one in a file is
    /// ignored by the decoder.
    struct Slot: Codable {
        var partition: String?
        var role: String?
        var preset: String?
        var baseURL: String?
        var model: String?

        enum CodingKeys: String, CodingKey {
            case partition
            case role
            case preset
            case baseURL = "base_url"
            case model
        }
    }
}

// MARK: - The reader

/// The configuration file (spec section 5, N10, N12; RD20 decisions 1 and
/// 3): its limits, and the reader that checks a file as a whole before
/// anything else looks at it. The reader uses no store and no network.
public enum ConfigurationFile {
    /// The version this app writes and reads.
    ///
    /// Version policy: a new optional member keeps version 1; removing or
    /// renaming a member, changing its type or meaning, or moving a setting
    /// between kinds raises it. A closed-set value an older version does
    /// not know is refused by that version and needs no new version. The
    /// version that defines 2 adds the step that upgrades a version-1
    /// document before validation.
    public static let version = 1
    /// The largest file read: 5 MB.
    public static let maximumBytes = 5 * 1024 * 1024
    /// Per file, both partitions together (decision 13).
    public static let maximumCategories = 500
    public static let maximumSources = 5_000
    static let maximumPartitionSettings = 2
    static let maximumSlots = 4
    /// Byte limits, checked before any operation on characters.
    static let maximumNameBytes = 4_096
    static let maximumAddressBytes = 8_192
    static let maximumModelNameBytes = 1_024
    /// `exported_at`, `app_version`, identifiers, icons and closed-set
    /// values.
    static let maximumShortValueBytes = 64

    /// Reads and checks the file at `url`: its size before reading, then
    /// the bounded read, then `read(_:)`.
    public static func read(contentsOf url: URL) -> Result<ConfigurationDocument, ConfigurationRefusal> {
        switch BoundedFileRead.read(contentsOf: url, maximumBytes: maximumBytes) {
        case .success(let data): read(data)
        case .failure(.tooLarge): .failure(.tooLarge)
        case .failure(.unreadable): .failure(.unreadable)
        }
    }

    /// Checks `data` as a whole, in the order of decision 3, and returns the
    /// document or the first refusal.
    public static func read(_ data: Data) -> Result<ConfigurationDocument, ConfigurationRefusal> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        let wire: ConfigurationWire
        do {
            wire = try JSONDecoder().decode(ConfigurationWire.self, from: data)
        } catch let error as DecodingError {
            return .failure(refusal(for: error))
        } catch {
            return .failure(.notAConfiguration)
        }
        do {
            return .success(try Validation(wire).document())
        } catch let refusal as ConfigurationRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.notAConfiguration)
        }
    }

    /// Decision 3, step 2: a value of the wrong type at a member the reader
    /// reads names its entry; everything else — not JSON, too deep, a
    /// fractional or too large integer, a top-level value that is not an
    /// object, a header member of the wrong type — is not a configuration
    /// file.
    static func refusal(for error: DecodingError) -> ConfigurationRefusal {
        let path: [any CodingKey]
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            path = context.codingPath
        case .dataCorrupted, .keyNotFound:
            return .notAConfiguration
        @unknown default:
            return .notAConfiguration
        }
        guard let position = position(of: path) else { return .notAConfiguration }
        return .invalid(.unknownValue, at: position)
    }

    /// The entry a coding path points into; `nil` for the header.
    private static func position(of path: [any CodingKey]) -> ConfigurationPosition? {
        guard let first = path.first else { return nil }
        let index = path.count > 1 ? path[1].intValue.map { $0 + 1 } : nil
        switch first.stringValue {
        case ConfigurationWire.CodingKeys.settings.stringValue, ConfigurationWire.CodingKeys.partitionSettings.stringValue:
            return .settings
        case ConfigurationWire.CodingKeys.categories.stringValue:
            return index.map { .category($0) }
        case ConfigurationWire.CodingKeys.sources.stringValue:
            return index.map { .source($0) }
        case ConfigurationWire.CodingKeys.modelSlots.stringValue:
            return index.map { .model($0) }
        default:
            return nil
        }
    }

    /// Removes control characters (Unicode category Cc), then trims white
    /// space. Called only on text already within its byte limit.
    static func cleaned(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar.properties.generalCategory != .control {
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses `exported_at`: ISO 8601 with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// The checks after decoding (decision 3, steps 3 to 6).
private struct Validation {
    let wire: ConfigurationWire

    init(_ wire: ConfigurationWire) {
        self.wire = wire
    }

    func document() throws -> ConfigurationDocument {
        // Step 3: the version.
        guard let version = wire.schemaVersion, version >= 1 else { throw ConfigurationRefusal.notAConfiguration }
        guard version <= ConfigurationFile.version else { throw ConfigurationRefusal.newerVersion }
        // Required members.
        guard let exportedAtText = wire.exportedAt, let appVersionText = wire.appVersion, let includesAdult = wire.includesAdult,
              let settings = wire.settings, let categories = wire.categories, let sources = wire.sources,
              let partitionSettings = wire.partitionSettings, let slots = wire.modelSlots
        else { throw ConfigurationRefusal.notAConfiguration }
        // Step 4: counts, before any member is looked at.
        guard categories.count <= ConfigurationFile.maximumCategories else { throw ConfigurationRefusal.tooManyCategories }
        guard sources.count <= ConfigurationFile.maximumSources else { throw ConfigurationRefusal.tooManySources }
        guard partitionSettings.count <= ConfigurationFile.maximumPartitionSettings, slots.count <= ConfigurationFile.maximumSlots else {
            throw ConfigurationRefusal.notAConfiguration
        }
        // Step 5: the header.
        guard exportedAtText.utf8.count <= ConfigurationFile.maximumShortValueBytes,
              let exportedAt = ConfigurationFile.date(exportedAtText)
        else { throw ConfigurationRefusal.notAConfiguration }
        guard (1...ConfigurationFile.maximumShortValueBytes).contains(appVersionText.utf8.count),
              appVersionText.utf8.allSatisfy({ (0x20...0x7E).contains($0) })
        else { throw ConfigurationRefusal.notAConfiguration }
        if settings.invalidMember != nil {
            throw ConfigurationRefusal.invalid(.unknownValue, at: .settings)
        }
        let included: Set<Partition> = includesAdult ? [.normal, .adult] : [.normal]

        // Categories.
        var categoryEntries: [(partition: Partition, sortOrder: Int, position: Int, category: ConfigurationCategory)] = []
        var categoryOfID: [UUID: Int] = [:]
        for (index, entry) in categories.enumerated() {
            let position = ConfigurationPosition.category(index + 1)
            guard let idText = entry.id, idText.utf8.count <= ConfigurationFile.maximumShortValueBytes,
                  let id = UUID(uuidString: idText)
            else { throw ConfigurationRefusal.invalid(.unknownValue, at: position) }
            let partition = try self.partition(entry.partition, included: included, at: position)
            let name = try Self.name(entry.name, at: position, problem: Library.categoryNameProblem)
            let icon = try Self.icon(entry.icon, at: position)
            let overview = try Self.closed(entry.overview, OverviewMode.self, default: .auto, at: position)
            guard categoryOfID[id] == nil else { throw ConfigurationRefusal.notAConfiguration }
            categoryOfID[id] = index
            categoryEntries.append((partition, entry.sortOrder ?? index, index, ConfigurationCategory(name: name, iconName: icon, overview: overview)))
        }

        // Each partition's categories in the file's order, and where each
        // entry went.
        var ordered: [Partition: [ConfigurationCategory]] = [:]
        var placeOfEntry: [Int: Int] = [:]
        for entry in categoryEntries.sorted(by: { ($0.sortOrder, $0.position) < ($1.sortOrder, $1.position) }) {
            placeOfEntry[entry.position] = ordered[entry.partition, default: []].count
            ordered[entry.partition, default: []].append(entry.category)
        }

        // Sources.
        var partitionSources: [Partition: [ConfigurationSource]] = [:]
        var addresses: [Partition: Set<String>] = [:]
        for (index, entry) in sources.enumerated() {
            let position = ConfigurationPosition.source(index + 1)
            guard let idText = entry.id, idText.utf8.count <= ConfigurationFile.maximumShortValueBytes, UUID(uuidString: idText) != nil else {
                throw ConfigurationRefusal.invalid(.unknownValue, at: position)
            }
            let kind = try Self.closed(entry.kind, SourceKind.self, default: nil, at: position)
            let name = try Self.name(entry.name, at: position, problem: Library.sourceNameProblem)
            guard let url = entry.url else { throw ConfigurationRefusal.invalid(.address, at: position) }
            guard url.utf8.count <= ConfigurationFile.maximumAddressBytes,
                  case .success(let parsed) = SourceAddress.parse(url, addingScheme: false)
            else { throw ConfigurationRefusal.invalid(.address, at: position) }
            let options: ConfigurationSourceOptions
            if kind == .webpage {
                options = ConfigurationSourceOptions(paused: false, autoTranslate: .inherit, bodyMode: .auto, translatePage: entry.translatePage ?? false)
            } else {
                options = ConfigurationSourceOptions(
                    paused: entry.paused ?? false,
                    autoTranslate: try Self.closed(entry.autoTranslate, AutoTranslate.self, default: .inherit, at: position),
                    bodyMode: try Self.closed(entry.bodyMode, BodyMode.self, default: .auto, at: position),
                    translatePage: false
                )
            }
            guard let categoryText = entry.categoryID, categoryText.utf8.count <= ConfigurationFile.maximumShortValueBytes,
                  let categoryID = UUID(uuidString: categoryText), let categoryEntry = categoryOfID[categoryID],
                  let place = placeOfEntry[categoryEntry]
            else { throw ConfigurationRefusal.invalid(.missingCategory, at: position) }
            let partition = categoryEntries[categoryEntry].partition
            guard addresses[partition, default: []].insert(parsed.normalForm).inserted else {
                throw ConfigurationRefusal.invalid(.duplicateAddress, at: position)
            }
            partitionSources[partition, default: []].append(ConfigurationSource(
                address: parsed.normalForm, name: name, kind: kind, categoryIndex: place, options: options
            ))
        }

        // Partition settings.
        var settingsOf: [Partition: ConfigurationPartitionSettings] = [:]
        for entry in partitionSettings {
            let partition = try self.partition(entry.partition, included: included, at: .settings)
            guard settingsOf[partition] == nil else { throw ConfigurationRefusal.notAConfiguration }
            if entry.invalidMember != nil {
                throw ConfigurationRefusal.invalid(.unknownValue, at: .settings)
            }
            settingsOf[partition] = entry
        }

        // Model slots.
        var slotsOf: [Partition: [ModelRole: ConfigurationSlot]] = [:]
        var positionOfSlot: [Partition: [ModelRole: Int]] = [:]
        for (index, entry) in slots.enumerated() {
            let position = ConfigurationPosition.model(index + 1)
            let partition = try self.partition(entry.partition, included: included, at: position)
            let role = try Self.closed(entry.role, ModelRole.self, default: nil, at: position)
            let preset = try Self.closed(entry.preset, ModelPreset.self, default: nil, at: position)
            guard let address = entry.baseURL, address.utf8.count <= ConfigurationFile.maximumAddressBytes,
                  case .success(let baseURL) = ModelAddress.normalise(address, allowsLoopbackHTTP: false)
            else { throw ConfigurationRefusal.invalid(.modelAddress, at: position) }
            guard let modelText = entry.model, modelText.utf8.count <= ConfigurationFile.maximumModelNameBytes,
                  case .success(let model) = ModelName.validate(modelText)
            else { throw ConfigurationRefusal.invalid(.name, at: position) }
            guard slotsOf[partition]?[role] == nil else { throw ConfigurationRefusal.notAConfiguration }
            slotsOf[partition, default: [:]][role] = ConfigurationSlot(role: role, preset: preset, baseURL: baseURL, model: model)
            positionOfSlot[partition, default: [:]][role] = index + 1
        }
        for (partition, roles) in slotsOf where roles[.backup] != nil && roles[.primary] == nil {
            throw ConfigurationRefusal.invalid(.backupWithoutPrimary, at: .model(positionOfSlot[partition]?[.backup] ?? 1))
        }

        func part(_ partition: Partition) -> ConfigurationPartition {
            ConfigurationPartition(
                partition: partition,
                categories: ordered[partition] ?? [],
                sources: partitionSources[partition] ?? [],
                slots: ModelRole.allCases.compactMap { slotsOf[partition]?[$0] },
                settings: settingsOf[partition] ?? ConfigurationPartitionSettings(partition: partition.rawValue)
            )
        }
        return ConfigurationDocument(
            version: version, exportedAt: exportedAt, appVersion: appVersionText, settings: settings,
            normal: part(.normal), adult: includesAdult ? part(.adult) : nil
        )
    }

    /// A partition named by an entry: one of the closed set, and included.
    private func partition(_ text: String?, included: Set<Partition>, at position: ConfigurationPosition) throws -> Partition {
        let partition = try Self.closed(text, Partition.self, default: nil, at: position)
        guard included.contains(partition) else { throw ConfigurationRefusal.adultMismatch }
        return partition
    }

    /// A value of a closed set, or `fallback` when the member is absent.
    private static func closed<T: RawRepresentable>(
        _ text: String?, _ type: T.Type, default fallback: T?, at position: ConfigurationPosition
    ) throws -> T where T.RawValue == String {
        guard let text else {
            guard let fallback else { throw ConfigurationRefusal.invalid(.unknownValue, at: position) }
            return fallback
        }
        guard text.utf8.count <= ConfigurationFile.maximumShortValueBytes, let value = T(rawValue: text) else {
            throw ConfigurationRefusal.invalid(.unknownValue, at: position)
        }
        return value
    }

    /// A name: within its byte limit, then cleaned, then the app's rule.
    private static func name(
        _ text: String?, at position: ConfigurationPosition, problem: (String) -> CategoryNameProblem?
    ) throws -> String {
        guard let text, text.utf8.count <= ConfigurationFile.maximumNameBytes else {
            throw ConfigurationRefusal.invalid(.name, at: position)
        }
        let cleaned = ConfigurationFile.cleaned(text)
        guard problem(cleaned) == nil else { throw ConfigurationRefusal.invalid(.name, at: position) }
        return cleaned
    }

    /// An icon name: 1–64 characters of `a`–`z`, `0`–`9` and `.`; `folder`
    /// when absent.
    private static func icon(_ text: String?, at position: ConfigurationPosition) throws -> String {
        guard let text else { return CategoryIcon.folder.rawValue }
        let allowed = text.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E }
        guard (1...ConfigurationFile.maximumShortValueBytes).contains(text.utf8.count), allowed else {
            throw ConfigurationRefusal.invalid(.unknownValue, at: position)
        }
        return text
    }
}
