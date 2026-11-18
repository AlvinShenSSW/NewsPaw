import Foundation
@testable import NewsPawKit
import Testing

/// RD16 decision 2 and assumption A3: every call into a page is one-shot
/// with a deadline, against a stand-in for the call. The answers' shapes
/// and bounds.
@Suite("Page script bridge")
@MainActor
struct PageScriptBridgeTests {
    /// The calls the stand-in received, each with its `finish`, which the
    /// test calls when it wants the page to answer.
    final class StandIn {
        var calls: [(command: String, input: [String: Any], finish: PageScriptBridge.Finish)] = []

        func perform(_ command: String, _ input: [String: Any], _ finish: @escaping PageScriptBridge.Finish) {
            calls.append((command, input, finish))
        }
    }

    static func bridge(deadline: Duration) -> (PageScriptBridge, StandIn) {
        let standIn = StandIn()
        let bridge = PageScriptBridge(deadline: deadline) { command, input, finish in standIn.perform(command, input, finish) }
        return (bridge, standIn)
    }

    static let answer: [String: Any] = [
        "loaded": true, "state": "s1", "runs": [["id": 1, "block": 2, "text": "本文", "whole": true, "inView": true] as [String: Any]],
    ]

    @Test("an answer before the deadline resumes the caller with it; a second answer is ignored")
    func answer() async throws {
        let (bridge, standIn) = Self.bridge(deadline: .seconds(600))
        async let result = bridge.collect(period: "1", locale: .simplifiedChinese)
        while standIn.calls.isEmpty {
            await Task.yield()
        }
        standIn.calls[0].finish(.success(Self.answer))
        standIn.calls[0].finish(.success(["loaded": true, "unchanged": true, "state": "s1"]))
        #expect(await result == .success(.runs([PageRun(id: 1, block: 2, text: "本文", whole: true, inView: true)], loaded: true, state: "s1")))
        #expect(standIn.calls[0].command == "collect")
    }

    @Test("A3: a call the page never answers expires at the deadline; its late answer resumes nothing")
    func deadline() async throws {
        let (bridge, standIn) = Self.bridge(deadline: .milliseconds(50))
        let result = await bridge.collect(period: "1", locale: .simplifiedChinese)
        #expect(result == .failure(.timedOut))
        // The late answer: nothing is resumed twice (a second resume of a
        // checked continuation would trap).
        standIn.calls[0].finish(.success(Self.answer))
        standIn.calls[0].finish(.failure(PageCallFailure.failed))
        // A new call after it works.
        async let next = bridge.end(restore: true)
        while standIn.calls.count < 2 {
            await Task.yield()
        }
        #expect(standIn.calls[1].command == "end")
        #expect(standIn.calls[1].input["restore"] as? Bool == true)
        standIn.calls[1].finish(.success(["had": true, "restored": 3]))
        #expect(await next == .success(PageEnded(had: true, restored: 3)))
    }

    @Test("an error of the call is a failure; an answer of another shape is malformed")
    func failures() async throws {
        let (bridge, standIn) = Self.bridge(deadline: .seconds(600))
        async let failed = bridge.collect(period: "1", locale: .simplifiedChinese)
        while standIn.calls.isEmpty {
            await Task.yield()
        }
        standIn.calls[0].finish(.failure(PageCallFailure.failed))
        #expect(await failed == .failure(.failed))
        async let odd = bridge.apply(PageApplyRequest(writes: [PageWrite(id: 4, text: "译")], settle: [5], check: [6]))
        while standIn.calls.count < 2 {
            await Task.yield()
        }
        let input = standIn.calls[1].input
        #expect((input["writes"] as? [[Any]])?.first?.first as? Int == 4)
        #expect(input["settle"] as? [Int] == [5])
        standIn.calls[1].finish(.success("not an object"))
        #expect(await odd == .failure(.malformed))
    }

    @Test("collect answers are checked for shape and bounds")
    func shapes() {
        func run(_ changes: [String: Any]) -> [String: Any] {
            var run: [String: Any] = ["id": 1, "block": 1, "text": "本文", "whole": false, "inView": true]
            for (key, value) in changes {
                run[key] = value
            }
            return run
        }
        #expect(PageScriptBridge.collection(["loaded": false, "held": true, "state": "s"]) == .held(loaded: false, state: "s"))
        #expect(PageScriptBridge.collection(["loaded": true, "unchanged": true, "state": "s"]) == .unchanged(loaded: true, state: "s"))
        #expect(PageScriptBridge.collection(["loaded": true, "state": "s", "runs": [run([:])]]) != nil)
        #expect(PageScriptBridge.collection(["runs": [run([:])], "state": "s"]) == nil, "no loaded")
        #expect(PageScriptBridge.collection(["loaded": true, "runs": [run([:])]]) == nil, "no state")
        #expect(PageScriptBridge.collection(["loaded": true, "state": String(repeating: "s", count: 65), "runs": []]) == nil, "a state over 64")
        for bad: [String: Any] in [
            ["id": 0], ["id": -1], ["id": 1.5], ["id": "1"], ["id": true], ["block": 0], ["text": ""], ["text": 7],
            ["text": String(repeating: "x", count: 20_001)], ["whole": 1], ["inView": "yes"],
        ] {
            #expect(PageScriptBridge.collection(["loaded": true, "state": "s", "runs": [run(bad)]]) == nil, "\(bad)")
        }
        let many = Array(repeating: run([:]), count: 501)
        #expect(PageScriptBridge.collection(["loaded": true, "state": "s", "runs": many]) == nil, "more than 500 runs")
        let heavy = Array(repeating: run(["text": String(repeating: "x", count: 20_000)]), count: 11)
        #expect(PageScriptBridge.collection(["loaded": true, "state": "s", "runs": heavy]) == nil, "more than 200,000 units")
        #expect(PageScriptBridge.applied(["written": [1], "skipped": [], "holding": []]) == PageApplied(written: [1], skipped: [], holding: []))
        #expect(PageScriptBridge.applied(["written": ["1"], "skipped": [], "holding": []]) == nil)
        #expect(PageScriptBridge.ended(["had": true, "restored": 2]) == PageEnded(had: true, restored: 2))
        #expect(PageScriptBridge.ended(["had": 1, "restored": 2]) == nil)
    }
}
