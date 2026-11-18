import Foundation
@testable import NewsPawKit
import Testing

/// RD20 criterion 3 and decision 3: the reader checks a file as a whole and
/// refuses it with its reason; criterion 15: a member this version does not
/// read is ignored. The size and depth cases are in
/// `ConfigurationHeavyTests`.
@Suite("Configuration file reader")
struct ConfigurationFileTests {
    typealias J = ConfigurationJSON

    static func refusal(_ data: Data) -> ConfigurationRefusal? {
        if case .failure(let refusal) = ConfigurationFile.read(data) {
            return refusal
        }
        return nil
    }

    static func refusal(_ mutate: (inout [String: Any]) -> Void) -> ConfigurationRefusal? {
        refusal(J.with(mutate))
    }

    // MARK: - Accepted

    @Test("the base file is read into both partitions, typed and in order")
    func baseFile() throws {
        let document = try readDocument(J.data(J.base()))
        #expect(document.version == 1)
        #expect(document.appVersion == "0.1.0 (1)")
        #expect(document.exportedAt == Date(timeIntervalSince1970: 1_794_819_600))
        #expect(document.settings.refreshMinutes == 15)
        #expect(document.normal.categories.map(\.name) == ["News", "Tech"])
        #expect(document.normal.sources.map(\.address) == ["https://alpha.example/feed", "https://beta.example/"])
        #expect(document.normal.sources.map(\.categoryIndex) == [0, 1])
        #expect(document.normal.slots.map(\.role) == [.primary])
        #expect(document.normal.settings.dailyAutoLimit == 50)
        let adult = try #require(document.adult)
        #expect(adult.categories.map(\.name) == ["Private"])
        #expect(adult.sources.map(\.name) == ["Gamma"])
        #expect(adult.slots.map(\.baseURL) == ["https://adult.models.example/v1"])
        #expect(adult.settings.dailyAutoLimit == 10)
    }

    @Test("withoutAdult leaves no adult entry, and the rest as it was")
    func withoutAdult() throws {
        let document = try readDocument(J.data(J.base()))
        let normal = document.withoutAdult
        #expect(normal.adult == nil)
        #expect(!normal.includesAdult)
        #expect(normal.part(.adult) == nil)
        #expect(normal.normal == document.normal)
        #expect(normal.settings == document.settings)
    }

    @Test("criterion 3: \"schema_version\": 1.0 is read as 1")
    func versionOnePointZero() throws {
        var object = J.base()
        object["schema_version"] = 777_001
        let document = try readDocument(J.replacing(777_001, with: "1.0", in: object))
        #expect(document.version == 1)
    }

    @Test("a byte-order mark before the object is accepted")
    func byteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + J.data(J.base())
        #expect(try readDocument(data).normal.categories.count == 2)
    }

    @Test("criterion 15: members this version does not read — a key among them — are ignored and change nothing")
    func ignoredMembers() throws {
        let plain = try readDocument(J.data(J.base()))
        let data = J.with { object in
            object["key"] = "sk-from-the-file-0123456789"
            object["future_member"] = ["anything": [1, 2, 3]]
            J.change(&object, "model_slots", at: 0) { slot in
                slot["key"] = "sk-from-the-file-0123456789"
                slot["key_ref"] = "reference"
                slot["test_outcome"] = "passed"
            }
            J.change(&object, "sources", at: 0) { source in
                source["site_url"] = "https://alpha.example/"
                source["last_error"] = "gone"
            }
            var settings = object["settings"] as! [String: Any]
            // RD15's member, not yet one of this version (RD24's
            // `background_refresh` is one since batch 2).
            settings["translate_body_on_open"] = true
            settings["reading_text_size"] = 5
            object["settings"] = settings
        }
        #expect(try readDocument(data) == plain)
    }

    @Test("criterion 15: a setting member that is absent is absent from the document")
    func absentSetting() throws {
        let document = try readDocument(J.with { object in
            object["settings"] = ["refresh_minutes": 60]
            object["partition_settings"] = [["partition": "normal"], ["partition": "adult", "list_thumbnails": false]]
        })
        #expect(document.settings == ConfigurationSettings(refreshMinutes: 60))
        #expect(document.normal.settings.isEmpty)
        #expect(document.adult?.settings.dailyAutoLimit == nil)
        #expect(document.adult?.settings.listThumbnails == false)
    }

    @Test("optional members take their defaults; a web page's feed options and a feed's page option are ignored")
    func defaults() throws {
        let document = try readDocument(J.with { object in
            J.change(&object, "categories", at: 0) { category in
                category["icon"] = nil
                category["overview"] = nil
                category["sort_order"] = nil
            }
            J.change(&object, "sources", at: 0) { source in
                for member in ["paused", "auto_translate", "body_mode"] {
                    source[member] = nil
                }
                source["translate_page"] = true
            }
            J.change(&object, "sources", at: 1) { source in
                source["paused"] = true
                source["auto_translate"] = "sometimes"
                source["body_mode"] = "never"
                source["translate_page"] = true
            }
        })
        let news = try #require(document.normal.categories.first { $0.name == "News" })
        #expect(news.iconName == "folder")
        #expect(news.overview == .auto)
        #expect(document.normal.sources[0].options == .defaults)
        #expect(document.normal.sources[1].options == ConfigurationSourceOptions(paused: false, autoTranslate: .inherit, bodyMode: .auto, translatePage: true))
    }

    @Test("a missing sort order is the entry's position; categories are ordered by sort order, then position")
    func categoryOrder() throws {
        let document = try readDocument(J.with { object in
            J.change(&object, "categories", at: 0) { $0["sort_order"] = 5 }
            J.change(&object, "categories", at: 1) { $0["sort_order"] = nil }
        })
        // "Tech" has position 1, "News" sort order 5.
        #expect(document.normal.categories.map(\.name) == ["Tech", "News"])
        #expect(document.normal.sources.map(\.categoryIndex) == [1, 0])
    }

    @Test("an icon this version does not know is kept as text")
    func unknownIcon() throws {
        let document = try readDocument(J.with { object in
            J.change(&object, "categories", at: 0) { $0["icon"] = "rocket.fill2" }
        })
        #expect(document.normal.categories[0].iconName == "rocket.fill2")
    }

    @Test("control characters are removed from names, then they are trimmed")
    func cleanedNames() throws {
        let document = try readDocument(J.with { object in
            J.change(&object, "categories", at: 0) { $0["name"] = " \u{0007}Wor\u{0000}ld\u{001B} \t" }
            J.change(&object, "sources", at: 0) { $0["name"] = "\nAl\u{0085}pha\r" }
        })
        #expect(document.normal.categories[0].name == "World")
        #expect(document.normal.sources[0].name == "Alpha")
    }

    @Test("addresses are kept in their normal form; the same address may be in both partitions")
    func normalForms() throws {
        let document = try readDocument(J.with { object in
            J.change(&object, "sources", at: 0) { $0["url"] = "HTTPS://Alpha.Example:443/feed#top" }
            J.change(&object, "sources", at: 2) { $0["url"] = "https://alpha.example/feed" }
            J.change(&object, "model_slots", at: 0) { $0["base_url"] = "  HTTPS://api.openai.com/v1/ " }
        })
        #expect(document.normal.sources[0].address == "https://alpha.example/feed")
        #expect(document.adult?.sources[0].address == "https://alpha.example/feed")
        #expect(document.normal.slots[0].baseURL == "https://api.openai.com/v1")
    }

    @Test("a duplicate member name is read with its first value (measured, decision 3)")
    func duplicateMember() throws {
        var object = J.base()
        object["app_version"] = "MARKER-VERSION"
        let text = J.text(object).replacingOccurrences(of: #""app_version":"MARKER-VERSION""#, with: #""app_version":"9.9","app_version":"8.8""#)
        #expect(try readDocument(Data(text.utf8)).appVersion == "9.9")
    }

    @Test("a file with an empty normal partition, and an empty adult partition, is accepted")
    func emptyPartitions() throws {
        let document = try readDocument(J.with { object in
            object["categories"] = [[String: Any]]()
            object["sources"] = [[String: Any]]()
            object["model_slots"] = [[String: Any]]()
            object["partition_settings"] = [[String: Any]]()
        })
        #expect(document.normal.categories.isEmpty)
        #expect(document.adult?.categories.isEmpty == true)
    }

    @Test("criterion 3: exactly 500 categories and 5,000 sources are accepted; one more is refused")
    func countLimits() throws {
        func file(categories: Int, sources: Int) -> Data {
            J.with { object in
                object["categories"] = (0..<categories).map { index in
                    J.category(UUID().uuidString, "C\(index)", partition: "normal", order: index)
                }
                let first = (object["categories"] as! [[String: Any]]).first?["id"] as? String ?? J.normalCategory
                object["sources"] = (0..<sources).map { index in
                    J.source(category: first, kind: "feed", name: "S\(index)", url: "https://s\(index).example/feed")
                }
                object["includes_adult"] = false
                object["partition_settings"] = [["partition": "normal"]]
                object["model_slots"] = [[String: Any]]()
            }
        }
        let accepted = try readDocument(file(categories: 500, sources: 5_000))
        #expect(accepted.normal.categories.count == 500)
        #expect(accepted.normal.sources.count == 5_000)
        #expect(Self.refusal(file(categories: 501, sources: 1)) == .tooManyCategories)
        #expect(Self.refusal(file(categories: 1, sources: 5_001)) == .tooManySources)
    }

    // MARK: - Refused: not a configuration file

    @Test("criterion 3: not JSON, or a top-level value that is not an object, is not a configuration file", arguments: [
        "not json", "", "[]", "[1, 2]", "1", "\"text\"", "null", "true", "{\"schema_version\": 1} trailing",
        "{\"name\": \"\\ud800\"}",
    ])
    func notAnObject(_ text: String) {
        #expect(Self.refusal(Data(text.utf8)) == .notAConfiguration)
    }

    @Test("criterion 3: schema_version missing, 1.5, \"1\" or 0 is not a configuration file; 2 asks to update")
    func versions() {
        #expect(Self.refusal { $0["schema_version"] = nil } == .notAConfiguration)
        #expect(Self.refusal { $0["schema_version"] = "1" } == .notAConfiguration)
        #expect(Self.refusal { $0["schema_version"] = 0 } == .notAConfiguration)
        #expect(Self.refusal { $0["schema_version"] = -3 } == .notAConfiguration)
        var object = J.base()
        object["schema_version"] = 777_002
        #expect(Self.refusal(J.replacing(777_002, with: "1.5", in: object)) == .notAConfiguration)
        #expect(Self.refusal { $0["schema_version"] = 2 } == .newerVersion)
    }

    @Test("criterion 3: 1.5 or 2^63 in an integer member is not a configuration file, as the decoder reports it")
    func integers() {
        for replacement in ["1.5", "9223372036854775808", "123456789012345678901234567890"] {
            var object = J.base()
            J.change(&object, "categories", at: 0) { $0["sort_order"] = 777_003 }
            #expect(Self.refusal(J.replacing(777_003, with: replacement, in: object)) == .notAConfiguration, "\(replacement)")
        }
    }

    @Test("a required member missing is not a configuration file", arguments: [
        "exported_at", "app_version", "includes_adult", "settings", "categories", "sources", "partition_settings", "model_slots",
    ])
    func requiredMember(_ member: String) {
        #expect(Self.refusal { $0[member] = nil } == .notAConfiguration)
    }

    @Test("a header member of the wrong type or out of its rule is not a configuration file")
    func header() {
        #expect(Self.refusal { $0["includes_adult"] = "yes" } == .notAConfiguration)
        #expect(Self.refusal { $0["exported_at"] = "yesterday" } == .notAConfiguration)
        #expect(Self.refusal { $0["exported_at"] = "2026-11-16T09:00:00Z" + String(repeating: " ", count: 60) } == .notAConfiguration)
        #expect(Self.refusal { $0["app_version"] = "" } == .notAConfiguration)
        #expect(Self.refusal { $0["app_version"] = String(repeating: "1", count: 65) } == .notAConfiguration)
        #expect(Self.refusal { $0["app_version"] = "1.0\u{0007}" } == .notAConfiguration)
        #expect(Self.refusal { $0["app_version"] = "版本" } == .notAConfiguration)
        // A list member that is not a list is the header's structure.
        #expect(Self.refusal { $0["categories"] = ["not": "an array"] } == .notAConfiguration)
        #expect(Self.refusal { $0["model_slots"] = "none" } == .notAConfiguration)
    }

    @Test("two categories with one identifier, two slots for one role, or one partition's settings twice are not a configuration file")
    func duplicates() {
        #expect(Self.refusal { object in
            J.change(&object, "categories", at: 1) { $0["id"] = J.normalCategory.uppercased() }
        } == .notAConfiguration)
        #expect(Self.refusal { object in
            object["model_slots"] = [J.slot(partition: "normal", role: "primary"), J.slot(partition: "normal", role: "primary")]
        } == .notAConfiguration)
        #expect(Self.refusal { object in
            object["partition_settings"] = [["partition": "normal"], ["partition": "normal"]]
        } == .notAConfiguration)
        #expect(Self.refusal { object in
            object["partition_settings"] = [["partition": "normal"], ["partition": "adult"], ["partition": "adult"]]
        } == .notAConfiguration)
        #expect(Self.refusal { object in
            object["model_slots"] = (0..<5).map { _ in J.slot(partition: "normal", role: "primary") }
        } == .notAConfiguration)
    }

    // MARK: - Refused: an entry

    @Test("criterion 3: a name empty after cleaning, or over its byte or character limit, is refused with its position")
    func names() {
        #expect(Self.refusal { J.change(&$0, "categories", at: 1) { $0["name"] = " \u{0007}\u{0000} " } } == .invalid(.name, at: .category(2)))
        #expect(Self.refusal { J.change(&$0, "categories", at: 0) { $0["name"] = String(repeating: "a", count: 101) } } == .invalid(.name, at: .category(1)))
        #expect(Self.refusal { J.change(&$0, "categories", at: 0) { $0["name"] = String(repeating: "\u{0007}", count: 4_097) + "a" } } == .invalid(.name, at: .category(1)))
        #expect(Self.refusal { J.change(&$0, "categories", at: 0) { $0["name"] = nil } } == .invalid(.name, at: .category(1)))
        #expect(Self.refusal { J.change(&$0, "sources", at: 2) { $0["name"] = String(repeating: "名", count: 201) } } == .invalid(.name, at: .source(3)))
        #expect(Self.refusal { J.change(&$0, "sources", at: 0) { $0["name"] = "" } } == .invalid(.name, at: .source(1)))
        // 100 characters within 4,096 bytes are accepted.
        #expect(Self.refusal { J.change(&$0, "categories", at: 0) { $0["name"] = String(repeating: "名", count: 100) } } == nil)
    }

    @Test("criterion 3: a source address over its limit, not http or https, with a user name, or without a host is refused", arguments: [
        "https://a.example/" + String(repeating: "a", count: 8_200), "https://a.example/" + String(repeating: "a", count: 2_100),
        "ftp://a.example/feed", "feed://a.example/feed", "javascript:alert(1)", "file:///etc/hosts", "https://user@a.example/feed",
        "https://user:pass@a.example/feed", "https://", "a.example/feed", "", "   ",
    ])
    func sourceAddresses(_ address: String) {
        #expect(Self.refusal { J.change(&$0, "sources", at: 0) { $0["url"] = address } } == .invalid(.address, at: .source(1)))
    }

    @Test("a source without an address is refused")
    func missingAddress() {
        #expect(Self.refusal { J.change(&$0, "sources", at: 0) { $0["url"] = nil } } == .invalid(.address, at: .source(1)))
    }

    @Test("criterion 3: a model address that is http — also to loopback, in every build — has a query, or is malformed is refused", arguments: [
        "http://api.example/v1", "http://127.0.0.1:8080/v1", "http://localhost/v1", "http://[::1]/v1", "https://api.example/v1?key=1",
        "https://api.example/v1#x", "https://", "not an address", "https://user@api.example/v1",
        "https://api.example/" + String(repeating: "a", count: 8_200),
    ])
    func modelAddresses(_ address: String) {
        #expect(Self.refusal { J.change(&$0, "model_slots", at: 0) { $0["base_url"] = address } } == .invalid(.modelAddress, at: .model(1)))
    }

    @Test("criterion 3: a model name over its limit, empty, or with a control character is refused")
    func modelNames() {
        #expect(Self.refusal { J.change(&$0, "model_slots", at: 1) { $0["model"] = String(repeating: "m", count: 201) } } == .invalid(.name, at: .model(2)))
        #expect(Self.refusal { J.change(&$0, "model_slots", at: 0) { $0["model"] = String(repeating: "m", count: 1_025) } } == .invalid(.name, at: .model(1)))
        #expect(Self.refusal { J.change(&$0, "model_slots", at: 0) { $0["model"] = " " } } == .invalid(.name, at: .model(1)))
        #expect(Self.refusal { J.change(&$0, "model_slots", at: 0) { $0["model"] = "gpt\u{0007}" } } == .invalid(.name, at: .model(1)))
    }

    @Test("criterion 3: an unknown kind, overview, option value, preset, role or partition is refused")
    func closedSets() {
        let cases: [(String, Int, String, Any?, ConfigurationPosition)] = [
            ("sources", 0, "kind", "podcast", .source(1)),
            ("sources", 0, "kind", nil, .source(1)),
            ("categories", 0, "overview", "weekly", .category(1)),
            ("categories", 0, "icon", "Folder", .category(1)),
            ("categories", 0, "icon", "", .category(1)),
            ("categories", 0, "id", "not-a-uuid", .category(1)),
            ("sources", 0, "auto_translate", "sometimes", .source(1)),
            ("sources", 0, "body_mode", "always", .source(1)),
            ("sources", 0, "id", "not-a-uuid", .source(1)),
            ("model_slots", 0, "preset", "anthropic", .model(1)),
            ("model_slots", 0, "role", "tertiary", .model(1)),
            ("model_slots", 0, "partition", "secret", .model(1)),
            ("categories", 0, "partition", "Normal", .category(1)),
            ("categories", 0, "partition", nil, .category(1)),
        ]
        for (member, index, key, value, position) in cases {
            let refusal = Self.refusal { J.change(&$0, member, at: index) { $0[key] = value } }
            #expect(refusal == .invalid(.unknownValue, at: position), "\(member)[\(index)].\(key) = \(String(describing: value))")
        }
    }

    @Test("a value of the wrong type in an entry is refused with its position")
    func wrongTypes() {
        // A1: `1` where a Boolean is read, `true` where an integer is read.
        #expect(Self.refusal { J.change(&$0, "sources", at: 0) { $0["paused"] = 1 } } == .invalid(.unknownValue, at: .source(1)))
        #expect(Self.refusal { J.change(&$0, "categories", at: 1) { $0["sort_order"] = true } } == .invalid(.unknownValue, at: .category(2)))
        #expect(Self.refusal { $0["partition_settings"] = [["partition": "normal", "daily_auto_limit": false]] } == .invalid(.unknownValue, at: .settings))
        #expect(Self.refusal { J.change(&$0, "sources", at: 0) { $0["paused"] = "true" } } == .invalid(.unknownValue, at: .source(1)))
        #expect(Self.refusal { J.change(&$0, "categories", at: 0) { $0["name"] = 12 } } == .invalid(.unknownValue, at: .category(1)))
        #expect(Self.refusal { J.change(&$0, "model_slots", at: 0) { $0["model"] = ["gpt"] } } == .invalid(.unknownValue, at: .model(1)))
        #expect(Self.refusal { $0["settings"] = ["auto_translate_titles": 1] } == .invalid(.unknownValue, at: .settings))
        #expect(Self.refusal { $0["settings"] = [1, 2] } == .invalid(.unknownValue, at: .settings))
        #expect(Self.refusal { $0["partition_settings"] = [["partition": "normal", "list_thumbnails": "yes"]] } == .invalid(.unknownValue, at: .settings))
        #expect(Self.refusal { $0["sources"] = [NSNull()] } == .invalid(.unknownValue, at: .source(1)))
    }

    @Test("criterion 3: a known setting with a value outside its set is refused")
    func settingValues() {
        let global: [(String, Any)] = [
            ("refresh_minutes", 45), ("refresh_minutes", -1), ("retention_days", 14), ("reading_locale", "fr"),
            ("reading_locale", "zh-hans"),
        ]
        for (member, value) in global {
            #expect(Self.refusal { $0["settings"] = [member: value] } == .invalid(.unknownValue, at: .settings), "\(member)")
        }
        for value in [-1, 100_001] {
            #expect(Self.refusal { $0["partition_settings"] = [["partition": "normal", "daily_auto_limit": value]] } == .invalid(.unknownValue, at: .settings))
        }
        #expect(Self.refusal { $0["partition_settings"] = [["partition": "normal", "daily_auto_limit": 100_000]] } == nil)
        #expect(Self.refusal { $0["partition_settings"] = [["daily_auto_limit": 1]] } == .invalid(.unknownValue, at: .settings))
    }

    @Test("criterion 3: a source naming a category that is not in the file is refused")
    func missingCategory() {
        #expect(Self.refusal { J.change(&$0, "sources", at: 1) { $0["category_id"] = UUID().uuidString } } == .invalid(.missingCategory, at: .source(2)))
        #expect(Self.refusal { J.change(&$0, "sources", at: 1) { $0["category_id"] = nil } } == .invalid(.missingCategory, at: .source(2)))
        #expect(Self.refusal { J.change(&$0, "sources", at: 1) { $0["category_id"] = "nope" } } == .invalid(.missingCategory, at: .source(2)))
    }

    @Test("criterion 3: one address twice in one partition is refused, also when written differently")
    func duplicateAddress() {
        #expect(Self.refusal { J.change(&$0, "sources", at: 1) { $0["url"] = "HTTPS://ALPHA.example/feed#x" } } == .invalid(.duplicateAddress, at: .source(2)))
    }

    @Test("criterion 3: a backup without a primary is refused; with one it is read")
    func backupWithoutPrimary() throws {
        #expect(Self.refusal { object in
            object["model_slots"] = [J.slot(partition: "normal", role: "primary"), J.slot(partition: "adult", role: "backup")]
        } == .invalid(.backupWithoutPrimary, at: .model(2)))
        let document = try readDocument(J.with { object in
            object["model_slots"] = [J.slot(partition: "normal", role: "backup", model: "b"), J.slot(partition: "normal", role: "primary")]
        })
        #expect(document.normal.slots.map(\.role) == [.primary, .backup])
    }

    @Test("criterion 3: an adult entry while includes_adult is false is refused")
    func adultMismatch() throws {
        #expect(Self.refusal { $0["includes_adult"] = false } == .adultMismatch)
        let normalOnly: (inout [String: Any]) -> Void = { object in
            object["includes_adult"] = false
            object["categories"] = Array((object["categories"] as! [[String: Any]]).prefix(2))
            object["sources"] = Array((object["sources"] as! [[String: Any]]).prefix(2))
            object["partition_settings"] = [["partition": "normal"]]
            object["model_slots"] = [J.slot(partition: "normal", role: "primary")]
        }
        #expect(try readDocument(J.with(normalOnly)).adult == nil)
        #expect(Self.refusal { normalOnly(&$0); $0["partition_settings"] = [["partition": "adult"]] } == .adultMismatch)
        #expect(Self.refusal { normalOnly(&$0); $0["model_slots"] = [J.slot(partition: "adult", role: "primary")] } == .adultMismatch)
        #expect(Self.refusal { normalOnly(&$0); J.change(&$0, "categories", at: 1) { $0["partition"] = "adult" } } == .adultMismatch)
    }

    @Test("a name of 4,096 bytes of combining marks is read within a time bound")
    func combiningMarks() throws {
        let marks = "a" + String(repeating: "\u{0301}", count: 2_047)
        #expect(marks.utf8.count == 4_095)
        let data = J.with { object in
            J.change(&object, "categories", at: 0) { $0["name"] = marks }
        }
        let start = ContinuousClock.now
        let refusal = Self.refusal(data)
        let elapsed = ContinuousClock.now - start
        // One character: within the character limit.
        #expect(refusal == nil)
        #expect(elapsed < .seconds(10))
    }
}
