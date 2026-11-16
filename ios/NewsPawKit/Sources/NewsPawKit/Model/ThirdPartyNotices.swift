import Foundation

/// One bundled library's licence as About shows it (RD21 decision 9).
public struct ThirdPartyNotice: Sendable, Hashable, Identifiable {
    /// The pin identity in `Package.resolved`, or `readability` for the
    /// vendored script.
    public let id: String
    /// The project's name; a proper noun, not localised.
    public let name: String
    /// The licence's name; not localised.
    public let licence: String
    /// The project's address, shown as text.
    public let address: String
    /// The whole licence text, in English.
    public let text: String
}

/// The licences of every library bundled into the app (spec 6.1; RD21
/// decision 9): the two Swift packages the lock files pin and the vendored
/// Readability script. The texts are package resources, copied verbatim:
///
/// | Resource | Source | Revision or tag | SHA-256 |
/// | --- | --- | --- | --- |
/// | `Notices/GRDB.swift-LICENSE` | `LICENSE` of https://github.com/groue/GRDB.swift | `92a554cd0d5e8d67cb18993c6054e73fe42c066c` (7.12.0) | `9853f9dce81365fcc1d9b46004633354450164b8d17904e92e80c444545f7e87` |
/// | `Notices/SwiftSoup-LICENSE` | `LICENSE` of https://github.com/scinfu/SwiftSoup | `e7f85f4d3dd91ca9a1e94d3328aa1ed5120a8c0f` (2.14.3) | `6d9f121428f5571c4e20362fa91186c552f82648c0161dacc12e239b1544d49d` |
/// | `LICENSE` (`Reading/Resources/LICENSE`) | `LICENSE.md` of https://github.com/mozilla/readability | tag `0.6.0` | `a5b1e8181751ce05b85b7bfaa832b785e87086250a5148e679d17ca9bdcfa958` |
/// | `Notices/Apache-2.0.txt` | https://www.apache.org/licenses/LICENSE-2.0.txt | fetched 2026-11-17 | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
///
/// Readability's `LICENSE.md` is only the project's Apache header, so its
/// notice is followed by the whole Apache License 2.0 (§4(a)). Readability
/// ships no `NOTICE` file at that tag. A new dependency needs its notice
/// here: a package test fails for a pin without one.
public enum ThirdPartyNotices {
    /// The notices in About's order: the pins of `Package.resolved`, then
    /// Readability.
    public static let all: [ThirdPartyNotice] = [
        ThirdPartyNotice(
            id: "grdb.swift", name: "GRDB.swift", licence: "MIT License",
            address: "https://github.com/groue/GRDB.swift", text: text("Notices/GRDB.swift-LICENSE")
        ),
        ThirdPartyNotice(
            id: "swiftsoup", name: "SwiftSoup", licence: "MIT License",
            address: "https://github.com/scinfu/SwiftSoup", text: text("Notices/SwiftSoup-LICENSE")
        ),
        ThirdPartyNotice(
            id: "readability", name: "Readability", licence: "Apache License 2.0",
            address: "https://github.com/mozilla/readability",
            text: joined(text("LICENSE"), text("Notices/Apache-2.0.txt"))
        ),
    ]

    /// The SHA-256 of each bundled file, as recorded in the table above.
    static let recordedDigests: [(String, String)] = [
        ("Notices/GRDB.swift-LICENSE", "9853f9dce81365fcc1d9b46004633354450164b8d17904e92e80c444545f7e87"),
        ("Notices/SwiftSoup-LICENSE", "6d9f121428f5571c4e20362fa91186c552f82648c0161dacc12e239b1544d49d"),
        ("LICENSE", "a5b1e8181751ce05b85b7bfaa832b785e87086250a5148e679d17ca9bdcfa958"),
        ("Notices/Apache-2.0.txt", "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
    ]

    enum NoticeError: Error {
        case missingResource(String)
        case notALockFile
    }

    /// A bundled file's bytes, by its path in the resource bundle.
    static func resource(_ path: String) throws -> Data {
        guard let url = Bundle.module.resourceURL?.appending(path: path), let data = try? Data(contentsOf: url) else {
            throw NoticeError.missingResource(path)
        }
        return data
    }

    /// A bundled file's text, or nothing when it is missing: the package
    /// tests catch a missing or empty text.
    private static func text(_ path: String) -> String {
        (try? resource(path)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// A notice, one blank line, then the licence it names.
    private static func joined(_ notice: String, _ licence: String) -> String {
        let end = notice.lastIndex { !$0.isNewline }.map { notice.index(after: $0) } ?? notice.startIndex
        let start = licence.firstIndex { !$0.isNewline } ?? licence.endIndex
        return notice[..<end] + "\n\n" + licence[start...]
    }

    /// The pin identities of a `Package.resolved` file's contents, in its
    /// order.
    static func pinIdentities(inResolved data: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = object["pins"] as? [[String: Any]]
        else { throw NoticeError.notALockFile }
        return try pins.map { pin in
            guard let identity = pin["identity"] as? String else { throw NoticeError.notALockFile }
            return identity
        }
    }

    /// The pins of a `Package.resolved` file's contents that have no
    /// notice in `notices`.
    static func pinsWithoutNotice(inResolved data: Data, notices: [ThirdPartyNotice] = all) throws -> [String] {
        let listed = Set(notices.map(\.id))
        return try pinIdentities(inResolved: data).filter { !listed.contains($0) }
    }
}
