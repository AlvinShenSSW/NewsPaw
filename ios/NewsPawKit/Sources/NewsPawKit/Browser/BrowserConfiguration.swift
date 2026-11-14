import WebKit

/// The configuration of every embedded-browser session (RD10; spec N12):
/// the website data store it is handed, and nothing a page could use to
/// reach the app — no user script, no message handler, no scheme of the
/// app's. The only scheme handlers are the ones passed in, which the app
/// does only for the UI tests' fixture pages in a debug build.
public enum BrowserConfiguration {
    @MainActor
    public static func make(
        dataStore: WKWebsiteDataStore, schemeHandlers: [String: any WKURLSchemeHandler] = [:]
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // A fresh controller: no user script and no message handler.
        configuration.userContentController = WKUserContentController()
        // Scripts run, as in any browser; a page may not open a window by
        // itself.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        for (scheme, handler) in schemeHandlers {
            configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
        return configuration
    }
}
