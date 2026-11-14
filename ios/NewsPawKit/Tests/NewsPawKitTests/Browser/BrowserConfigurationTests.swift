import Foundation
import Testing
import WebKit
@testable import NewsPawKit

/// RD10 criterion 7: a browser session's configuration gives a page no
/// interface to the app — what the WebKit API exposes of it is asserted.
@Suite("Browser configuration")
@MainActor
struct BrowserConfigurationTests {
    /// Schemes a handler of the app's could have been registered for.
    static let schemes = ["newspaw", "newspaw-app", "newspaw-fixture", "app", "bridge", "x-newspaw"]

    @Test("no user script, no message handler, no scheme handler outside UI-test mode")
    func plain() {
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = BrowserConfiguration.make(dataStore: store)
        #expect(configuration.userContentController.userScripts.isEmpty)
        for scheme in Self.schemes {
            #expect(configuration.urlSchemeHandler(forURLScheme: scheme) == nil, "\(scheme)")
        }
        #expect(configuration.websiteDataStore === store, "the store handed in is the one used")
        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    }

    @Test("a scheme handler is registered only when passed")
    func handlerOnlyWhenPassed() {
        final class Handler: NSObject, WKURLSchemeHandler {
            func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {}
            func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
        }
        let handler = Handler()
        let configuration = BrowserConfiguration.make(dataStore: .nonPersistent(), schemeHandlers: ["newspaw-fixture": handler])
        #expect(configuration.urlSchemeHandler(forURLScheme: "newspaw-fixture") === handler)
        #expect(configuration.urlSchemeHandler(forURLScheme: "newspaw") == nil)
        #expect(configuration.userContentController.userScripts.isEmpty)
    }
}
