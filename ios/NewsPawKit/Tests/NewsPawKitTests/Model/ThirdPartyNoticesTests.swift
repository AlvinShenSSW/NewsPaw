import CryptoKit
import Foundation
@testable import NewsPawKit
import Testing

/// RD21 criterion 11 and decision 9: About's licences. Every library the
/// two lock files pin has a notice, Readability has one too, and each text
/// is the whole licence as shipped.
@Suite("Third-party notices")
struct ThirdPartyNoticesTests {
    /// `ios/` in the repository.
    private static var iosDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Model
            .deletingLastPathComponent() // NewsPawKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NewsPawKit
            .deletingLastPathComponent() // ios
    }

    /// The package's lock file and the app project's.
    static let lockFiles = [
        "NewsPawKit/Package.resolved",
        "NewsPaw.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ]

    private func lockFile(_ path: String) throws -> Data {
        try Data(contentsOf: Self.iosDirectory.appending(path: path))
    }

    @Test("the notices are the lock files' pins plus Readability, in that order")
    func identifiers() throws {
        for path in Self.lockFiles {
            let pins = try ThirdPartyNotices.pinIdentities(inResolved: try lockFile(path))
            #expect(!pins.isEmpty, "\(path)")
            #expect(ThirdPartyNotices.all.map(\.id) == pins + ["readability"], "\(path)")
        }
        #expect(ThirdPartyNotices.all.map(\.name) == ["GRDB.swift", "SwiftSoup", "Readability"])
        #expect(ThirdPartyNotices.all.map(\.licence) == ["MIT License", "MIT License", "Apache License 2.0"])
        #expect(Set(ThirdPartyNotices.all.map(\.id)).count == ThirdPartyNotices.all.count)
    }

    @Test("every pin of both lock files has a notice")
    func everyPinHasANotice() throws {
        for path in Self.lockFiles {
            #expect(try ThirdPartyNotices.pinsWithoutNotice(inResolved: try lockFile(path)) == [], "\(path)")
        }
    }

    @Test("a lock file with one more pin fails the check, naming the pin")
    func anExtraPinFails() throws {
        let data = try lockFile(Self.lockFiles[0])
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var pins = try #require(object["pins"] as? [[String: Any]])
        pins.append([
            "identity": "swift-extra",
            "kind": "remoteSourceControl",
            "location": "https://example.invalid/swift-extra.git",
            "state": ["revision": "0000000000000000000000000000000000000000", "version": "1.0.0"],
        ])
        object["pins"] = pins
        let copy = try JSONSerialization.data(withJSONObject: object)
        #expect(try ThirdPartyNotices.pinsWithoutNotice(inResolved: copy) == ["swift-extra"])
    }

    @Test("a file that is not a lock file is refused, not read as having no pins")
    func notALockFile() {
        #expect(throws: (any Error).self) {
            try ThirdPartyNotices.pinIdentities(inResolved: Data("{\"version\": 3}".utf8))
        }
        #expect(throws: (any Error).self) {
            try ThirdPartyNotices.pinIdentities(inResolved: Data("not json".utf8))
        }
    }

    @Test("each text is the whole licence: MIT's grant and holder, Arc90's notice and the full Apache License 2.0")
    func texts() throws {
        let notices = Dictionary(uniqueKeysWithValues: ThirdPartyNotices.all.map { ($0.id, $0) })
        let grdb = try #require(notices["grdb.swift"])
        let soup = try #require(notices["swiftsoup"])
        let readability = try #require(notices["readability"])
        for notice in [grdb, soup] {
            #expect(notice.text.contains("Permission is hereby granted, free of charge"), "\(notice.id)")
            #expect(notice.text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""), "\(notice.id)")
        }
        #expect(grdb.text.contains("Copyright (C) 2015-2025 Gwendal Roué"))
        #expect(soup.text.contains("Copyright (c) 2009-2025 Jonathan Hedley"))
        #expect(soup.text.contains("Copyright (c) 2016-2025 Nabil Chatbi"))
        #expect(readability.text.hasPrefix("Copyright (c) 2010 Arc90 Inc"))
        #expect(readability.text.contains("Version 2.0, January 2004"))
        #expect(readability.text.contains("END OF TERMS AND CONDITIONS"))
        #expect(readability.text.contains("APPENDIX: How to apply the Apache License to your work."))
        for notice in ThirdPartyNotices.all {
            #expect(!notice.address.isEmpty && notice.address.hasPrefix("https://github.com/"), "\(notice.id)")
        }
    }

    @Test("the bundled files are the recorded copies, byte for byte")
    func provenance() throws {
        for (name, digest) in ThirdPartyNotices.recordedDigests {
            let data = try ThirdPartyNotices.resource(name)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == digest, "\(name)")
        }
    }
}
