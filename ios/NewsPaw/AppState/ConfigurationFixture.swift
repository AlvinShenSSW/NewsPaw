#if DEBUG
import Foundation
import NewsPawKit

/// The configuration files a debug build reads under the UI tests in place
/// of a file chosen in the picker, which XCUITest cannot drive (RD20
/// decision 10). Release builds contain none of this.
enum ConfigurationFixture: String {
    /// Both partitions: a category and a feed the fixture transport answers
    /// in each, a model on the fixture model host in each, and settings
    /// that differ from the defaults.
    case both
    /// The normal partition only, with the same normal content.
    case normal
    /// A model service address that is http: refused.
    case refused
    /// The normal partition only: RD12's full-text feed in "World", its
    /// body "Always Fetch the Page"; no setting and no model (RD20 review
    /// round 2).
    case fullText

    static let normalCategory = "Imported News"
    static let normalSource = "Imported Feed"
    static let adultCategory = "Imported Private"
    static let adultSource = "Imported Hidden"

    var text: String {
        if self == .fullText {
            return """
                {
                  "schema_version": 1,
                  "exported_at": "2026-11-16T09:00:00Z",
                  "app_version": "0.1.0 (1)",
                  "includes_adult": false,
                  "settings": {},
                  "categories": [{"id": "6c0de3a4-1d1a-4c2e-9d0e-6a8f0f9a0021", "name": "World", "partition": "normal", "sort_order": 0, "icon": "newspaper", "overview": "auto"}],
                  "sources": [{"id": "6c0de3a4-1d1a-4c2e-9d0e-6a8f0f9a0031", "category_id": "6c0de3a4-1d1a-4c2e-9d0e-6a8f0f9a0021", "kind": "feed", "name": "Full Text Feed", "url": "\(FixtureTransport.Address.fullText)", "paused": false, "auto_translate": "inherit", "body_mode": "page", "translate_page": false}],
                  "partition_settings": [],
                  "model_slots": []
                }
                """
        }
        let normalCategory = """
            {"id": "6c0de3a4-1d1a-4c2e-9d0e-6a8f0f9a0001", "name": "\(Self.normalCategory)", "partition": "normal", "sort_order": 0, "icon": "newspaper", "overview": "auto"}
            """
        let adultCategory = """
            {"id": "6c0de3a4-1d1a-4c2e-9d0e-6a8f0f9a0002", "name": "\(Self.adultCategory)", "partition": "adult", "sort_order": 0, "icon": "heart", "overview": "off"}
            """
        let normalSource = """
            {"id": "6c0de3a4-1d1a-4c2e-9d0e-6a8f0f9a0011", "category_id": "6c0de3a4-1d1a-4c2e-9d0e-6a8f0f9a0001", "kind": "feed", "name": "\(Self.normalSource)", "url": "\(FixtureTransport.Address.feed)", "paused": false, "auto_translate": "inherit", "body_mode": "auto", "translate_page": false}
            """
        let adultSource = """
            {"id": "6c0de3a4-1d1a-4c2e-9d0e-6a8f0f9a0012", "category_id": "6c0de3a4-1d1a-4c2e-9d0e-6a8f0f9a0002", "kind": "feed", "name": "\(Self.adultSource)", "url": "\(FixtureTransport.Address.articles)", "paused": false, "auto_translate": "off", "body_mode": "auto", "translate_page": false}
            """
        let normalModelAddress = self == .refused ? "http://models.example.invalid/v1" : FixtureModelHTTP.Address.passed
        let normalSlot = """
            {"partition": "normal", "role": "primary", "preset": "custom", "base_url": "\(normalModelAddress)", "model": "fixture-model"}
            """
        let adultSlot = """
            {"partition": "adult", "role": "primary", "preset": "custom", "base_url": "\(FixtureModelHTTP.Address.passed)", "model": "fixture-adult-model"}
            """
        let adult = self == .both
        return """
            {
              "schema_version": 1,
              "exported_at": "2026-11-16T09:00:00Z",
              "app_version": "0.1.0 (1)",
              "includes_adult": \(adult),
              "settings": {"refresh_minutes": 60, "retention_days": 90, "reading_locale": "ja", "auto_translate_titles": false, "show_original_titles": true, "background_refresh": false, "translate_body_on_open": false},
              "categories": [\(normalCategory)\(adult ? ", " + adultCategory : "")],
              "sources": [\(normalSource)\(adult ? ", " + adultSource : "")],
              "partition_settings": [{"partition": "normal", "daily_auto_limit": 150, "list_thumbnails": false}\(adult ? #", {"partition": "adult", "daily_auto_limit": 20, "list_thumbnails": false}"# : "")],
              "model_slots": [\(normalSlot)\(adult ? ", " + adultSlot : "")]
            }
            """
    }

    /// Writes the file to a file of its own in the temporary directory and
    /// returns it, so that it goes through the same bounded read as a
    /// chosen file.
    func writeToTemporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Configuration Fixture", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(rawValue).newspaw")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}
#endif
