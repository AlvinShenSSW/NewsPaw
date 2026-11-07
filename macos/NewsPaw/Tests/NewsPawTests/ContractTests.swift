import Foundation
import Testing
@testable import NewsPaw

@Test func eachLanguageContainsTheFiveApprovedSections() {
    #expect(SettingsPage.allCases.count == 5)
    for language in AppLanguage.allCases {
        let titles = SettingsPage.allCases.map { language.text($0.title) }
        #expect(Set(titles).count == 5)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(language.text(.quitSettings) != language.text(.stopBackend))
        #expect(language.text(.offline) != language.text(.connected))
    }
}

@Test func selectingNewsLanguagePreservesOtherConfigFields() throws {
    let reply = Data(#"{"revision":7,"document":{"ui_locale":"zh-Hans","news_output_locale":"en","future":{"enabled":true}}}"#.utf8)
    let request = try LocaleEdit.request(from: reply, field: .news, value: .ja)
    let value = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
    let document = try #require(value["document"] as? [String: Any])
    #expect(value["revision"] as? Int == 7)
    #expect(document["ui_locale"] as? String == "zh-Hans")
    #expect(document["news_output_locale"] as? String == "ja")
    #expect((document["future"] as? [String: Bool])?["enabled"] == true)
}

@Test func missingSocketDoesNotLookConnected() async {
    let client = LocalSocket(path: "/tmp/np-missing-\(UUID().uuidString).sock", timeoutMilliseconds: 100)
    await #expect(throws: SocketFailure.disconnected) {
        _ = try await client.request(Data(#"{"op":"service.status"}"#.utf8))
    }
}
