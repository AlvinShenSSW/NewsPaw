import Foundation
import WebKit

/// Why a call into a page gave nothing (RD16 decision 2).
public enum PageCallFailure: Error, Sendable, Hashable {
    /// The deadline passed without an answer.
    case timedOut
    /// The call failed (the script threw, the page went, the web view is
    /// gone).
    case failed
    /// The answer was not of the shape or within the bounds expected.
    case malformed
}

/// What a `collect` found (decision 4). `written` says that the script
/// has written translations into this document: a page shown again from
/// the back-forward cache is translated already. `state` is the token of
/// the script state that answered: run numbers mean something only within
/// it, and every `apply` carries it back.
public enum PageCollection: Sendable, Hashable {
    /// Nothing changed since the last walk.
    case unchanged(loaded: Bool, written: Bool = false, state: String = "")
    /// A field has focus: nothing was collected (decision 3).
    case held(loaded: Bool, written: Bool = false, state: String = "")
    /// The runs of the blocks in the viewport, then of the rest of the
    /// band, each in document order.
    case runs([PageRun], loaded: Bool, written: Bool = false, state: String = "")

    /// Whether the document had loaded (`readyState` is `complete`).
    public var loaded: Bool {
        switch self {
        case .unchanged(let loaded, _, _), .held(let loaded, _, _), .runs(_, let loaded, _, _): loaded
        }
    }

    /// Whether the script had written translations into the document.
    public var written: Bool {
        switch self {
        case .unchanged(_, let written, _), .held(_, let written, _), .runs(_, _, let written, _): written
        }
    }

    /// The answering script state's token.
    public var state: String {
        switch self {
        case .unchanged(_, _, let state), .held(_, _, let state), .runs(_, _, _, let state): state
        }
    }

    public var isHeld: Bool {
        if case .held = self { true } else { false }
    }

    public var isUnchanged: Bool {
        if case .unchanged = self { true } else { false }
    }
}

/// What an `apply` is asked to do (decision 6).
public struct PageApplyRequest: Sendable, Hashable {
    /// Translations to write.
    public var writes: [PageWrite]
    /// Runs the app has settled (kept or failed): not collected again while
    /// they hold their original.
    public var settle: [Int]
    /// Runs to report on: which still hold their original.
    public var check: [Int]
    /// The token of the script state the runs belong to: a state with
    /// another token writes, settles and reports nothing.
    public var state: String?

    public init(writes: [PageWrite] = [], settle: [Int] = [], check: [Int] = [], state: String? = nil) {
        self.writes = writes
        self.settle = settle
        self.check = check
        self.state = state
    }

    public var isEmpty: Bool {
        writes.isEmpty && settle.isEmpty && check.isEmpty
    }
}

/// What an `apply` did.
public struct PageApplied: Sendable, Hashable {
    public var written: [Int]
    public var skipped: [Int]
    /// Of the runs to check, those that still hold their original.
    public var holding: [Int]
    /// The request named another script state: nothing was done.
    public var foreign: Bool

    public init(written: [Int], skipped: [Int], holding: [Int], foreign: Bool = false) {
        self.written = written
        self.skipped = skipped
        self.holding = holding
        self.foreign = foreign
    }
}

/// What an `end` did (decision 8).
public struct PageEnded: Sendable, Hashable {
    /// Whether the document had the script's state.
    public var had: Bool
    public var restored: Int

    public init(had: Bool, restored: Int) {
        self.had = had
        self.restored = restored
    }
}

/// The calls a page translation session makes into its page: the bridge,
/// or a stand-in in the session's tests.
@MainActor
public protocol PageScripting: AnyObject {
    /// The page's runs. `period` names the session's document generation:
    /// the first collect of a new one walks the page again and gives every
    /// run not written, also of a state kept from before (a page shown again
    /// from the back-forward cache). `locale` is the language the document
    /// is translated into: what the state wrote for another is put back
    /// and given again.
    func collect(period: String, locale: ReadingLocale) async -> Result<PageCollection, PageCallFailure>
    func apply(_ request: PageApplyRequest) async -> Result<PageApplied, PageCallFailure>
    func end(restore: Bool) async -> Result<PageEnded, PageCallFailure>
}

/// The one way the app's script reaches a page (spec N12; RD16 decision
/// 2): one call, in the app's own content world, in the main frame, with
/// the fixed body `PageTranslationScript.source` and data passed only as
/// arguments. No message handler, user script or scheme is involved.
///
/// Every call is one-shot with a deadline: the answer and the deadline
/// race, the first resumes the caller, and the other is ignored, so a late
/// answer (A3: a call pending when its document is left can answer tens of
/// seconds later, or into a later document) never resumes anything twice.
/// The session checks each result against the document it was made in.
///
/// The bridge keeps its content world object for its whole life: WebKit
/// keeps a named world's globals only while the app holds that world
/// (measured, A1), and `WKContentWorld.world(name:)` returns the held
/// object for the name.
@MainActor
public final class PageScriptBridge: PageScripting {
    /// The name of the content world: the app's own, distinct from the
    /// extractor's.
    public static let worldName = "NewsPawPageTranslation"
    /// How long a call may take.
    public static let standardDeadline = Duration.seconds(10)
    /// The most runs one `collect` may return, and their most UTF-16 code
    /// units (decision 4).
    nonisolated static let maximumRuns = 500
    nonisolated static let maximumUnits = 200_000

    typealias Finish = @MainActor @Sendable (Result<Any, any Error>) -> Void
    typealias Perform = @MainActor (_ command: String, _ input: [String: Any], _ finish: @escaping Finish) -> Void

    private weak var webView: WKWebView?
    /// Held so that the world's state lives between calls.
    let world: WKContentWorld
    let deadline: Duration
    /// A stand-in for the call, in the bridge's own tests.
    private let stand: Perform?

    public init(webView: WKWebView, deadline: Duration = PageScriptBridge.standardDeadline) {
        self.webView = webView
        self.deadline = deadline
        world = WKContentWorld.world(name: Self.worldName)
        stand = nil
    }

    init(deadline: Duration, perform: @escaping Perform) {
        self.deadline = deadline
        world = WKContentWorld.world(name: Self.worldName)
        stand = perform
    }

    // MARK: - The commands

    public func collect(period: String, locale: ReadingLocale) async -> Result<PageCollection, PageCallFailure> {
        await call("collect", ["period": period, "locale": locale.rawValue], read: { Self.collection($0) })
    }

    public func apply(_ request: PageApplyRequest) async -> Result<PageApplied, PageCallFailure> {
        let input: [String: Any] = [
            "writes": request.writes.map { [$0.id, $0.text] as [Any] },
            "settle": request.settle,
            "check": request.check,
            "state": request.state ?? "",
        ]
        return await call("apply", input, read: { Self.applied($0) })
    }

    public func end(restore: Bool) async -> Result<PageEnded, PageCallFailure> {
        await call("end", ["restore": restore], read: { Self.ended($0) })
    }

    // MARK: - The call

    /// One call: the answer read by `read`, or the deadline, whichever
    /// comes first.
    private func call<T: Sendable>(_ command: String, _ input: [String: Any], read: @escaping @Sendable (Any) -> T?) async -> Result<T, PageCallFailure> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, PageCallFailure>, Never>) in
            let once = OneShot(continuation)
            let deadline = deadline
            once.timer = Task { @MainActor in
                try? await Task.sleep(for: deadline)
                once.resume(.failure(.timedOut))
            }
            let finish: Finish = { result in
                switch result {
                case .success(let value):
                    once.resume(read(value).map { .success($0) } ?? .failure(.malformed))
                case .failure:
                    once.resume(.failure(.failed))
                }
            }
            if let stand {
                stand(command, input, finish)
            } else {
                perform(command, input, finish: finish)
            }
        }
    }

    /// The one call into a page. `BrowserScanTests` allows this line, in
    /// this file, once.
    private func perform(_ command: String, _ input: [String: Any], finish: @escaping Finish) {
        guard let webView else {
            finish(.failure(PageCallFailure.failed))
            return
        }
        webView.callAsyncJavaScript(PageTranslationScript.source, arguments: ["command": command, "input": input], in: nil, in: .world(name: PageScriptBridge.worldName)) { result in finish(result) }
    }

    // MARK: - Reading the answers

    private nonisolated static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private nonisolated static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, double >= 0, double <= 1e9 else { return nil }
        return Int(double)
    }

    private nonisolated static func integers(_ value: Any?) -> [Int]? {
        guard let array = value as? [Any] else { return nil }
        let numbers = array.compactMap(integer)
        return numbers.count == array.count ? numbers : nil
    }

    /// A `collect` answer: unchanged, held, or the runs within their
    /// bounds; anything else is `nil`.
    nonisolated static func collection(_ value: Any) -> PageCollection? {
        guard let object = value as? [String: Any], let loaded = bool(object["loaded"]),
              let state = object["state"] as? String, !state.isEmpty, state.count <= 64
        else { return nil }
        let written = bool(object["written"]) ?? false
        if bool(object["held"]) == true {
            return .held(loaded: loaded, written: written, state: state)
        }
        if bool(object["unchanged"]) == true {
            return .unchanged(loaded: loaded, written: written, state: state)
        }
        guard let list = object["runs"] as? [Any], list.count <= maximumRuns else { return nil }
        var runs: [PageRun] = []
        var units = 0
        for item in list {
            guard let run = item as? [String: Any], let id = integer(run["id"]), id > 0, let block = integer(run["block"]), block > 0,
                  let text = run["text"] as? String, !text.isEmpty, text.utf16.count <= PageBatcher.maximumRunUnits,
                  let whole = bool(run["whole"]), let inView = bool(run["inView"])
            else { return nil }
            units += text.utf16.count
            guard units <= maximumUnits else { return nil }
            runs.append(PageRun(id: id, block: block, text: text, whole: whole, inView: inView))
        }
        return .runs(runs, loaded: loaded, written: written, state: state)
    }

    nonisolated static func applied(_ value: Any) -> PageApplied? {
        guard let object = value as? [String: Any], let written = integers(object["written"]), let holding = integers(object["holding"]),
              let skipped = object["skipped"] as? [Any]
        else { return nil }
        // A skipped entry the script could not read is reported as it was.
        return PageApplied(written: written, skipped: skipped.compactMap(integer), holding: holding, foreign: bool(object["foreign"]) ?? false)
    }

    nonisolated static func ended(_ value: Any) -> PageEnded? {
        guard let object = value as? [String: Any], let had = bool(object["had"]), let restored = integer(object["restored"]) else { return nil }
        return PageEnded(had: had, restored: restored)
    }
}

/// Resumes its continuation once: with the answer or with the deadline,
/// whichever comes first.
@MainActor
private final class OneShot<T: Sendable> {
    private var continuation: CheckedContinuation<Result<T, PageCallFailure>, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Result<T, PageCallFailure>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, PageCallFailure>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        continuation.resume(returning: result)
    }
}
