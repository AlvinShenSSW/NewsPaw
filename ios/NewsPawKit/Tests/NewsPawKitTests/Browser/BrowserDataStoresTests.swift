import Foundation
@testable import NewsPawKit
import Testing
import WebKit

/// RD19 decision 4, criterion 6 and assumption A1: each partition's browser
/// has its own website data store, and an identified store is a persistent
/// store of its own. The identified stores made here have test-only
/// identifiers and are removed at the end of each test (they are written
/// under the test runner's `~/Library/WebKit`).
@Suite("Browser data stores", .serialized)
@MainActor
struct BrowserDataStoresTests {
    @Test("criterion 6: the normal partition's store is the default one, the adult partition's its own identified store")
    func mapping() {
        let normal = BrowserDataStores.store(for: .normal)
        let adult = BrowserDataStores.store(for: .adult)
        #expect(normal === WKWebsiteDataStore.default())
        #expect(normal.identifier == nil)
        #expect(adult !== normal)
        #expect(adult.isPersistent)
        #expect(adult.identifier == BrowserDataStores.adultIdentifier)
    }

    @Test("under the UI tests: the normal store lasts the process, the adult one is the directory's own and never the real one")
    func uiTestMapping() async {
        let normal = BrowserDataStores.uiTestStore(for: .normal, directoryName: "UITest-A")
        #expect(!normal.isPersistent)
        let first = BrowserDataStores.uiTestAdultIdentifier(directoryName: "UITest-A")
        #expect(first == BrowserDataStores.uiTestAdultIdentifier(directoryName: "UITest-A"))
        #expect(first != BrowserDataStores.uiTestAdultIdentifier(directoryName: "UITest-B"))
        #expect(first != BrowserDataStores.adultIdentifier)
        let adult = BrowserDataStores.uiTestStore(for: .adult, directoryName: "UITest-A")
        #expect(adult.isPersistent)
        #expect(adult.identifier == first)
        #expect(await Self.removed([first]))
    }

    /// Removes the test's identified stores and waits for it, 60 s at most
    /// (a store is refused while a web view on it is still being
    /// released), so that none is left under the runner's `~/Library/WebKit`.
    /// A store is removed again for as long as WebKit lists it: on the iOS
    /// 26.5 simulator a removal that had returned without an error was
    /// still listed at once after it (#191).
    private static func removed(_ identifiers: [UUID]) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(60)
        var removing = identifiers
        while ContinuousClock.now < deadline {
            for identifier in removing {
                try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
            }
            let known = await WKWebsiteDataStore.allDataStoreIdentifiers
            removing = identifiers.filter { known.contains($0) }
            if removing.isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// The cookies of `store` named `name`.
    private static func cookies(named name: String, in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies().filter { $0.name == name }
    }

    /// Waits, with a bound a stalled runner does not reach, until `store`
    /// holds a cookie named `name`.
    private static func waitForCookie(_ name: String, in store: WKWebsiteDataStore) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if await !cookies(named: name, in: store).isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test("A1: two identified stores keep separate data; a second object for one identifier sees its data; Clear empties one only")
    func identifiedStoresAreSeparate() async throws {
        let first = UUID()
        let second = UUID()
        do {
            try await Self.separation(first, second)
        } catch {
            _ = await Self.removed([first, second])
            throw error
        }
        #expect(await Self.removed([first, second]))
    }

    /// A1's measurement on the stores of `first` and `second`; every web
    /// view it makes is gone when it returns.
    private static func separation(_ first: UUID, _ second: UUID) async throws {
        let server = try LoopbackServer { _, _ in
            LoopbackServer.Reply(
                headers: ["Content-Type: text/html", "Set-Cookie: rd19page=first; Max-Age=3600; Path=/"],
                body: Data("<p>A page that sets a cookie.</p>".utf8)
            )
        }
        let storeOne = WKWebsiteDataStore(forIdentifier: first)
        let storeTwo = WKWebsiteDataStore(forIdentifier: second)
        #expect(storeOne.isPersistent)
        #expect(storeTwo.isPersistent)

        // A page's Set-Cookie in the first store.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = storeOne
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        let loaded = LoadWaiter()
        view.navigationDelegate = loaded
        view.load(URLRequest(url: try #require(URL(string: server.base + "/set"))))
        try await loaded.wait()
        #expect(await Self.waitForCookie("rd19page", in: storeOne))

        // A cookie set through the second store's cookie store.
        let cookie = try #require(HTTPCookie(properties: [
            .name: "rd19store", .value: "second", .domain: "127.0.0.1", .path: "/", .expires: Date().addingTimeInterval(3600),
        ]))
        await storeTwo.httpCookieStore.setCookie(cookie)

        #expect(await !Self.cookies(named: "rd19page", in: storeOne).isEmpty)
        #expect(await Self.cookies(named: "rd19store", in: storeOne).isEmpty)
        #expect(await !Self.cookies(named: "rd19store", in: storeTwo).isEmpty)
        #expect(await Self.cookies(named: "rd19page", in: storeTwo).isEmpty)
        // The default store has neither.
        #expect(await Self.cookies(named: "rd19page", in: .default()).isEmpty)
        #expect(await Self.cookies(named: "rd19store", in: .default()).isEmpty)

        // Another object for the first identifier sees the same data.
        let again = WKWebsiteDataStore(forIdentifier: first)
        #expect(await !Self.cookies(named: "rd19page", in: again).isEmpty)

        // Clear (every type, since the distant past) empties the first and
        // leaves the second.
        await WebKitAdultBrowserData(identifier: first).clear()
        #expect(await Self.cookies(named: "rd19page", in: storeOne).isEmpty)
        #expect(await Self.cookies(named: "rd19page", in: again).isEmpty)
        #expect(await !Self.cookies(named: "rd19store", in: storeTwo).isEmpty)

        // The identifiers are known to WebKit while the stores exist.
        let known = await WKWebsiteDataStore.allDataStoreIdentifiers
        #expect(known.contains(first))
        #expect(known.contains(second))
        view.navigationDelegate = nil
    }

    @Test("review round 1: a leftover adult store is removed at launch, and none is made when there is none")
    func leftoverStoreRemoved() async throws {
        let left = UUID()
        // A store that was used: it holds a cookie, and WebKit lists it.
        let cookie = try #require(HTTPCookie(properties: [
            .name: "rd19left", .value: "1", .domain: "127.0.0.1", .path: "/", .expires: Date().addingTimeInterval(3600),
        ]))
        await WKWebsiteDataStore(forIdentifier: left).httpCookieStore.setCookie(cookie)
        let deadline = ContinuousClock.now + .seconds(60)
        while await !WKWebsiteDataStore.allDataStoreIdentifiers.contains(left), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(left))
        // At launch nothing holds the store; here the store object made
        // above may live a moment longer, and WebKit refuses a store in
        // use: asked again until it is gone, 60 s at most.
        let removal = ContinuousClock.now + .seconds(60)
        repeat {
            await WebKitAdultBrowserData(identifier: left).removeLeftoverStore()
        } while await WKWebsiteDataStore.allDataStoreIdentifiers.contains(left) && ContinuousClock.now < removal
        #expect(await !WKWebsiteDataStore.allDataStoreIdentifiers.contains(left))

        let never = UUID()
        await WebKitAdultBrowserData(identifier: never).removeLeftoverStore()
        #expect(await !WKWebsiteDataStore.allDataStoreIdentifiers.contains(never))
    }

    @Test("A2: removing the store while a web view on it is alive, and after it is released")
    func removeStoreInUseAndReleased() async throws {
        let identifier = UUID()
        var webView: WKWebView? = {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
            return WKWebView(frame: .zero, configuration: configuration)
        }()
        let loaded = LoadWaiter()
        webView?.navigationDelegate = loaded
        webView?.loadHTMLString("<p>in use</p>", baseURL: URL(string: "https://example.invalid/"))
        try await loaded.wait()
        // While the web view is alive: removal fails as "in use", which the
        // adult browser data count as removed.
        var inUse: (any Error)?
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: identifier)
        } catch {
            inUse = error
        }
        Self.record("A2 removal while a web view is alive: \(inUse.map { "\(($0 as NSError).domain) \(($0 as NSError).code) \(($0 as NSError).localizedDescription)" } ?? "no error")")
        if let inUse {
            #expect(WebKitAdultBrowserData.isInUse(inUse))
        }
        try await WebKitAdultBrowserData(identifier: identifier).removeStore()
        webView = nil
        // Released: the removal succeeds and the identifier is gone.
        let deadline = ContinuousClock.now + .seconds(60)
        var removed = false
        while ContinuousClock.now < deadline {
            if (try? await WKWebsiteDataStore.remove(forIdentifier: identifier)) != nil {
                removed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(removed)
        #expect(await !WKWebsiteDataStore.allDataStoreIdentifiers.contains(identifier))
    }

    /// Writes a measurement to the test's output: the evidence of A2.
    private static func record(_ line: String) {
        print("RD19 measurement: \(line)")
    }
}
