import Foundation
@testable import NewsPawKit
import Testing

/// The synthetic Hub answers under `Fixtures/huggingface/` (RD26 decision
/// 11): invented names, shaped like the answers measured on 2026-11-17.
enum HubFixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/huggingface"),
            "Missing Hugging Face fixture \(name)"
        )
        return try Data(contentsOf: url)
    }
}

/// RD26 criteria 1 and 2: which typed addresses are an account, and the
/// addresses built from one. Pure: no request.
@Suite("Hugging Face account addresses")
struct HuggingFaceAccountTests {
    /// The account of `text` after the normal form, or `nil`.
    private func account(_ text: String) -> HuggingFaceAccount? {
        guard let normal = SourceAddress.normalForm(of: text) else { return nil }
        return HuggingFaceAccount(normalForm: normal)
    }

    static let recognised: [(String, String)] = [
        ("huggingface.co/Org-Name", "Org-Name"),
        ("https://huggingface.co/deepseek-ai", "deepseek-ai"),
        ("https://huggingface.co/deepseek-ai/", "deepseek-ai"),
        ("http://huggingface.co/julien-c", "julien-c"),
        ("https://www.huggingface.co/Qwen", "Qwen"),
        ("https://hf.co/Qwen", "Qwen"),
        ("hf.co/Qwen/", "Qwen"),
        ("HTTPS://HuggingFace.CO/Qwen", "Qwen"),
        ("https://huggingface.co:443/Qwen", "Qwen"),
        ("http://huggingface.co:80/Qwen", "Qwen"),
        ("https://huggingface.co/Qwen?sort_models=created#models", "Qwen"),
        ("https://huggingface.co/a_b.c-D9", "a_b.c-D9"),
        ("https://huggingface.co/..x", "..x"),
        ("https://huggingface.co/blog", "blog"),
        ("https://huggingface.co/\(String(repeating: "n", count: 96))", String(repeating: "n", count: 96)),
    ]

    @Test("each recognised form gives the name as typed", arguments: recognised)
    func recognisedForms(text: String, name: String) throws {
        let found = try #require(account(text), "\(text)")
        #expect(found.name == name)
    }

    static let refused: [String] = [
        // Other hosts.
        "https://hf.co.example.com/Qwen",
        "https://cdn-avatars.huggingface.co/Qwen",
        "https://huggingface.com/Qwen",
        "https://api.huggingface.co/Qwen",
        "https://huggingface.co.example.com/Qwen",
        "https://example.com/Qwen",
        // A port other than the scheme's default.
        "https://huggingface.co:8443/Qwen",
        "http://huggingface.co:443/Qwen",
        // Zero segments.
        "https://huggingface.co",
        "https://huggingface.co/",
        // Two or more segments.
        "https://huggingface.co/Qwen/Qwen3-8B",
        "https://huggingface.co/Qwen/Qwen3-8B/",
        "https://huggingface.co/api/models",
        "https://huggingface.co/datasets/Qwen/x",
        "https://huggingface.co//Qwen",
        "https://huggingface.co/Qwen//",
        // A name outside the rule.
        "https://huggingface.co/\(String(repeating: "n", count: 97))",
        "https://huggingface.co/.",
        "https://huggingface.co/..",
        "https://huggingface.co/a+b",
        "https://huggingface.co/a~b",
        "https://huggingface.co/a@b",
        "https://huggingface.co/名前",
        // A percent-escape.
        "https://huggingface.co/a%2Db",
        "https://huggingface.co/a%2Fb",
        "https://huggingface.co/%51wen",
    ]

    @Test("every other address is not an account", arguments: refused)
    func refusedForms(text: String) {
        #expect(account(text) == nil, "\(text)")
    }

    @Test("the built addresses: https on huggingface.co, no user name or password; the overviews with the typed name")
    func builtAddresses() throws {
        let typed = try #require(account("http://hf.co/Org-Name/"))
        #expect(typed.organizationOverviewAddress == "https://huggingface.co/api/organizations/Org-Name/overview")
        #expect(typed.userOverviewAddress == "https://huggingface.co/api/users/Org-Name/overview")
        let hub = try #require(HuggingFaceAccount(name: "org-name"))
        #expect(hub.pageAddress == "https://huggingface.co/org-name")
        #expect(hub.modelsAddress == "https://huggingface.co/api/models?author=org-name&sort=createdAt&direction=-1&limit=30&expand=createdAt")
        for address in [typed.organizationOverviewAddress, typed.userOverviewAddress, hub.pageAddress, hub.modelsAddress] {
            let components = try #require(URLComponents(string: address))
            #expect(components.scheme == "https", "\(address)")
            #expect(components.host == "huggingface.co", "\(address)")
            #expect(components.port == nil, "\(address)")
            #expect(components.user == nil && components.password == nil, "\(address)")
            #expect(try #require(URL(string: address)).isCollectableAddress, "\(address)")
        }
        // The page is its own normal form, and recognised as the same account.
        #expect(SourceAddress.normalForm(of: hub.pageAddress) == hub.pageAddress)
        #expect(HuggingFaceAccount(normalForm: hub.pageAddress) == hub)
    }

    @Test("a name given by the Hub passes the same rule")
    func names() {
        #expect(HuggingFaceAccount(name: "deepseek-ai")?.name == "deepseek-ai")
        for refused in ["", ".", "..", "a/b", "a b", "a?b", "https://x.example", String(repeating: "n", count: 97)] {
            #expect(HuggingFaceAccount(name: refused) == nil, "\(refused)")
        }
    }

    @Test("an overview's name: the member asked for, a name equal to the typed one ignoring ASCII case; nothing else")
    func overviewSpelling() throws {
        let organization = try HubFixture.data("organization-overview.json")
        let typed = try #require(HuggingFaceAccount(name: "Lamplight-LAB"))
        #expect(typed.spelling(inOverview: organization, member: "name") == "lamplight-lab")
        #expect(typed.spelling(inOverview: organization, member: "user") == nil)
        #expect(HuggingFaceAccount(name: "lamplight-labs")?.spelling(inOverview: organization, member: "name") == nil)

        // The large user overview, with 69 nested organisations each with a
        // `name`: only the top-level `user` is read.
        let user = try HubFixture.data("user-overview.json")
        #expect(user.count > 13_000)
        let keeper = try #require(HuggingFaceAccount(name: "Wick-Keeper"))
        #expect(keeper.spelling(inOverview: user, member: "user") == "wick-keeper")
        #expect(keeper.spelling(inOverview: user, member: "name") == nil)
        #expect(HuggingFaceAccount(name: "fixture-org-01")?.spelling(inOverview: user, member: "name") == nil)

        let name = try #require(HuggingFaceAccount(name: "a"))
        #expect(name.spelling(inOverview: Data(#"{"name":"A"}"#.utf8), member: "name") == "A")
        for body in [
            #"[{"name":"a"}]"#, #"{"name":1}"#, #"{"name":"a/b"}"#, #"{"name":"b"}"#, #"{"name":"ａ"}"#, "<html></html>", "",
            String(repeating: "[", count: 65) + String(repeating: "]", count: 65),
        ] {
            #expect(name.spelling(inOverview: Data(body.utf8), member: "name") == nil, "\(body)")
        }
    }
}
