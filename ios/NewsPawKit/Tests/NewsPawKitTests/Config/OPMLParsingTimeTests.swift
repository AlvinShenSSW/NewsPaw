import Foundation
@testable import NewsPawKit
import Testing

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
/// RD08 decision 2 and assumption A3: the shapes the design measured inside
/// the reader's guards, read whole through `OPMLReader.read`. The bounds are
/// about ten times the Mac's times, wide enough for a loaded runner; each
/// time is printed for the hand-back.
@Suite("OPML parsing time", .serialized)
struct OPMLParsingTimeTests {
    static let head = #"<?xml version="1.0" encoding="UTF-8"?><opml version="2.0"><body><outline text="A" xmlUrl="https://a.example/feed"/>"#
    static let tail = "</body></opml>"

    /// Fills the body up to just under the size limit with `piece`.
    static func fill(share: Double = 1, _ piece: (Int) -> String, closing: (Int) -> String = { _ in "" }) -> Data {
        var text = head
        var count = 0
        let room = Int(Double(OPMLReader.maximumBytes - 64 * 1024) * share)
        while text.utf8.count < room {
            text += piece(count)
            count += 1
        }
        text += closing(count) + tail
        return Data(text.utf8)
    }

    static func time(_ label: String, _ data: Data, bound: Duration) async {
        #expect(data.count <= OPMLReader.maximumBytes)
        let start = ContinuousClock.now
        let result = await Task.detached { OPMLReader.read(data) }.value
        let elapsed = ContinuousClock.now - start
        print("RD08 A3 | \(label) | \(data.count) bytes | \(elapsed)")
        #expect((try? result.get())?.feedCount == 1, "\(label): \(result)")
        #expect(elapsed < bound, "\(label)")
    }

    @Test("256 distinct attribute names on every tag, 5 MB")
    func distinctAttributes() async {
        var name = 0
        let data = Self.fill { _ in
            var tag = "<x"
            for _ in 0..<StartTagScan.maximumAttributes {
                tag += " a\(String(name, radix: 36))=\"\""
                name += 1
            }
            return tag + "/>"
        }
        // 0.78 s on the Mac (RD08 table); A3 asks under 2 s on the simulator.
        await Self.time("256 distinct attribute names per tag", data, bound: .seconds(10))
    }

    @Test("the smallest elements, 5 MB")
    func smallestElements() async {
        await Self.time("smallest elements", Self.fill { _ in "<x/>" }, bound: .seconds(5))
    }

    @Test("elements nested deep, 5 MB")
    func deepNesting() async {
        // Three bytes to open, four to close.
        let data = Self.fill(share: 3.0 / 7.0, { _ in "<x>" }, closing: { count in String(repeating: "</x>", count: count) })
        await Self.time("nesting", data, bound: .seconds(5))
    }
}
}
