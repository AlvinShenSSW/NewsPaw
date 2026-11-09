import Foundation
import Testing
@testable import NewsPaw

@Test func eachLanguageNamesTheFiveRedesignedPagesDistinctly() {
    #expect(Page.allCases.map(\.rawValue) == ["overview", "digests", "xAccounts", "connect", "settings"])
    for language in AppLanguage.allCases {
        let titles = Page.allCases.map { $0.title(language) }
        #expect(Set(titles).count == 5)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(L10n.Shell.quitWindow(language) != L10n.Shell.stopBackend(language))
        #expect(L10n.Shell.notRunning(language) != L10n.Shell.running(language))
    }
}

@Test @MainActor func savingALanguageKeepsUnknownConfigFields() async throws {
    var stored: [String: Any] = ["ui_locale": "zh-Hans", "news_output_locale": "en", "future": ["enabled": true]]
    let editor = EditorState(
        load: { (7, stored) },
        store: { document, revision in
            #expect(revision == 7)
            stored = document
        }
    )
    #expect(await editor.apply { var d = $0; d["news_output_locale"] = "ja"; return d })
    #expect(stored["ui_locale"] as? String == "zh-Hans")
    #expect(stored["news_output_locale"] as? String == "ja")
    #expect((stored["future"] as? [String: Bool])?["enabled"] == true)
}

@Test func missingSocketDoesNotLookConnected() async {
    let client = LocalSocket(path: "/tmp/np-missing-\(UUID().uuidString).sock", timeoutMilliseconds: 100)
    await #expect(throws: SocketFailure.disconnected) {
        _ = try await client.request(Data(#"{"op":"service.status"}"#.utf8))
    }
}

@Test func categorySchedulePrefersTheFirstEnabledSubscription() throws {
    let data = Data("""
        {"ui_locale":"en","news_output_locale":"ja","categories":[],"sources":[],"accounts":[],
         "model_profiles":[],"subscriptions":[
          {"id":"early","category_id":"world","timezone":"UTC","enabled":false,"times":["06:00"]},
          {"id":"active","category_id":"world","timezone":"Asia/Tokyo","enabled":true,"times":["08:00"]},
          {"id":"later","category_id":"world","timezone":"UTC","enabled":true,"times":["11:00"]},
          {"id":"paused","category_id":"ai","timezone":"UTC","enabled":false,"times":["09:00"]}
         ]}
        """.utf8)
    let config: AppConfig = try BackendRPC.decode(data)
    let schedule = try #require(config.displaySubscription(for: "world"))
    #expect(schedule.enabled)
    #expect(schedule.times == ["08:00"])
    #expect(schedule.timezone == "Asia/Tokyo")
    #expect(config.displaySubscription(for: "ai")?.id == "paused")
    #expect(config.displaySubscription(for: "japan") == nil)
}
