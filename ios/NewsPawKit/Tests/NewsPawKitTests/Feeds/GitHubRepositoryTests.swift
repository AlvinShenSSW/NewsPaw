import Foundation
@testable import NewsPawKit
import Testing

/// RD07 criterion 1: which typed addresses are a repository, and the
/// addresses built from one. Pure: no request.
@Suite("GitHub repository addresses")
struct GitHubRepositoryTests {
    /// The repository of `text` after the normal form, or `nil`.
    private func repository(_ text: String) -> GitHubRepository? {
        guard let normal = SourceAddress.normalForm(of: text) else { return nil }
        return GitHubRepository(normalForm: normal)
    }

    static let recognised: [(String, String, String)] = [
        ("github.com/o/r", "o", "r"),
        ("https://github.com/o/r", "o", "r"),
        ("https://github.com/o/r/", "o", "r"),
        ("http://github.com/o/r", "o", "r"),
        ("https://www.github.com/o/r", "o", "r"),
        ("HTTPS://GitHub.COM/o/r", "o", "r"),
        ("https://github.com:443/o/r", "o", "r"),
        ("https://github.com/o/r.git", "o", "r"),
        ("https://github.com/o/r?tab=readme-ov-file", "o", "r"),
        ("https://github.com/o/r#readme", "o", "r"),
        ("https://github.com/o/r/releases", "o", "r"),
        ("https://github.com/o/r/issues/3", "o", "r"),
        ("https://github.com/o/r/tree/main", "o", "r"),
        ("https://github.com/o/r/blob/main/README.md", "o", "r"),
        ("https://github.com/groue/GRDB.swift", "groue", "GRDB.swift"),
        ("https://github.com/Some-Owner/my_repo-2.0", "Some-Owner", "my_repo-2.0"),
        ("https://github.com/o/r.git.git", "o", "r.git"),
        ("https://github.com/o/..r", "o", "..r"),
        ("https://github.com/\(String(repeating: "a", count: 39))/\(String(repeating: "b", count: 100))",
         String(repeating: "a", count: 39), String(repeating: "b", count: 100)),
    ]

    @Test("each recognised form gives the owner and the name as typed", arguments: recognised)
    func recognisedForms(text: String, owner: String, name: String) throws {
        let found = try #require(repository(text), "\(text)")
        #expect(found.owner == owner)
        #expect(found.name == name)
    }

    static let refused: [String] = [
        // Other hosts.
        "https://gist.github.com/o/r",
        "https://raw.githubusercontent.com/o/r/main/README.md",
        "https://example.com/o/r",
        "https://api.github.com/o/r",
        "https://github.com.example.com/o/r",
        // A port other than the scheme's default.
        "https://github.com:8443/o/r",
        "http://github.com:443/o/r",
        // Fewer than two segments.
        "https://github.com/",
        "https://github.com/o",
        "https://github.com/o/",
        // An owner outside the rules.
        "https://github.com/o_x/r",
        "https://github.com/o.x/r",
        "https://github.com/\(String(repeating: "a", count: 40))/r",
        // A name outside the rules.
        "https://github.com/o/r+x",
        "https://github.com/o/.",
        "https://github.com/o/..",
        "https://github.com/o/.git",
        "https://github.com/o/\(String(repeating: "b", count: 101))",
        // A percent-escape in either.
        "https://github.com/o%41/r",
        "https://github.com/o/r%41",
        "https://github.com/o/r%20x",
        "https://github.com/ö/r",
        // A last segment ending in .atom: a feed address.
        "https://github.com/o/r/releases.atom",
        "https://github.com/o/r/commits/main.atom",
        "https://github.com/o/r.atom",
    ]

    @Test("each form that is not a repository is refused", arguments: refused)
    func refusedForms(text: String) {
        #expect(repository(text) == nil, "\(text)")
    }

    @Test("the feed addresses: https, lower case, no user name or password, in the order Releases, Tags, Commits")
    func feedAddresses() throws {
        for typed in ["http://www.GitHub.com/Groue/GRDB.swift.git", "github.com/groue/grdb.swift/tree/Main?x=1"] {
            let found = try #require(repository(typed))
            #expect(GitHubFeed.allCases.map(found.feedAddress) == [
                "https://github.com/groue/grdb.swift/releases.atom",
                "https://github.com/groue/grdb.swift/tags.atom",
                "https://github.com/groue/grdb.swift/commits.atom",
            ])
            for feed in GitHubFeed.allCases {
                let url = try #require(URL(string: found.feedAddress(feed)))
                #expect(url.scheme == "https")
                #expect(url.user == nil)
                #expect(url.password == nil)
                // Already a normal form: stored as built.
                #expect(SourceAddress.normalForm(of: found.feedAddress(feed)) == found.feedAddress(feed))
            }
        }
    }

    @Test("the page address keeps the typed case, without www., .git or a deeper path")
    func pageAddress() throws {
        #expect(try #require(repository("http://www.github.com/Groue/GRDB.swift.git")).pageAddress
            == "https://github.com/Groue/GRDB.swift")
        #expect(try #require(repository("https://github.com/Groue/GRDB.swift/issues/3?q=1")).pageAddress
            == "https://github.com/Groue/GRDB.swift")
        #expect(try #require(repository("github.com/o/r/")).pageAddress == "https://github.com/o/r")
    }

    @Test("the name shown: owner/name as typed")
    func displayName() throws {
        #expect(try #require(repository("https://github.com/Groue/GRDB.swift.git")).displayName == "Groue/GRDB.swift")
    }
}
