import Foundation
@testable import NewsPawKit
import Testing

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
/// RD08 criterion 10: a name or address from the file is bounded in bytes
/// before any character-level operation, comparison or hash. These names
/// are one `Character` of 160 or 320 kB; Swift compares and hashes such a
/// name in time growing with the square of its length. In the serialized
/// group, because a time bound measured beside the heavy suites measured
/// their load instead (3.1 s for a 25 ms read, once).
@Suite("OPML length bounds", .serialized)
struct OPMLLengthBoundTests {
    @Test("a name of 160 kB of combining marks is cut in bytes and read within a time bound")
    func combiningMarks() async throws {
        let marks = "a" + String(repeating: "\u{0301}\u{0316}", count: 40_000)
        let data = OPMLReaderTests.opml(#"""
            <outline text="\#(marks)"><outline title="\#(marks)" xmlUrl="https://a.example/feed"/></outline>
            <outline text="\#(marks)z"><outline title="\#(marks)z" xmlUrl="https://b.example/feed"/></outline>
            """#)
        let start = ContinuousClock.now
        let document = try await Task.detached { try OPMLReader.read(data).get() }.value
        let elapsed = ContinuousClock.now - start
        print("RD08 criterion 10 | reader, two folders and two feeds named with 160 kB of marks | \(elapsed)")

        #expect(document.entries.count == 2)
        for entry in document.entries {
            guard case .folder(let name, let feeds) = entry else {
                Issue.record("expected a folder")
                continue
            }
            #expect(name.utf8.count <= OPMLReader.maximumValueBytes)
            #expect(feeds.allSatisfy { $0.name.utf8.count <= OPMLReader.maximumValueBytes })
        }
        // About 25 ms on the Mac. The reader does nothing quadratic on a
        // name; the bound is for the whole read of such a file.
        #expect(elapsed < .seconds(5))
    }

    @Test("folders named with 320 kB of combining marks are read and planned within a time bound")
    func combiningMarksPlan() async throws {
        let fixture = try await LibraryOPMLTests.Fixture.make()
        defer { fixture.close() }
        let marks = "a" + String(repeating: "\u{0301}\u{0316}", count: 80_000)
        let reordered = "a" + String(repeating: "\u{0316}\u{0301}", count: 80_000)
        let folders = [marks, reordered, marks + "z", reordered + "z"].enumerated().map { index, name in
            #"<outline text="\#(name)"><outline text="F\#(index)" xmlUrl="https://\#(index).example/feed"/></outline>"#
        }
        let text = #"<opml version="2.0"><body>\#(folders.joined())</body></opml>"#
        _ = try await fixture.library.createCategory(name: "a\u{0301}", icon: .folder)

        let start = ContinuousClock.now
        let document = try OPMLReader.read(Data(text.utf8)).get()
        let plan = try await fixture.library.opmlImportPlan(document)
        let elapsed = ContinuousClock.now - start
        print("RD08 criterion 10 | read and plan, four folders named with 320 kB of marks | \(elapsed)")

        #expect(plan.addedFeeds == 4)
        // About 0.015 s with the byte bound; 45 s without it (planted, see
        // the RD08 evidence): the plan hashes and compares these names.
        #expect(elapsed < .seconds(5))
    }
}
}
