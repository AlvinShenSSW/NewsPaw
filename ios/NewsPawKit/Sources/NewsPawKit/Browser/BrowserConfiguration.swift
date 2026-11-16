import WebKit

/// The configuration of every embedded-browser session (RD10; spec N12):
/// the website data store it is handed, and nothing a page could use to
/// reach the app — no user script, no message handler, no scheme of the
/// app's. The only scheme handlers are the ones passed in, which the app
/// does only for the UI tests' fixture pages in a debug build.
public enum BrowserConfiguration {
    /// - Parameter allowsPictureInPicture: false for the adult library's
    ///   sessions (RD18 decision 13), whose video must not go on playing in
    ///   a window of its own after the app is left. Picture in Picture
    ///   exists on iOS only.
    @MainActor
    public static func make(
        dataStore: WKWebsiteDataStore, schemeHandlers: [String: any WKURLSchemeHandler] = [:],
        allowsPictureInPicture: Bool = true
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // A fresh controller: no user script and no message handler.
        configuration.userContentController = WKUserContentController()
        // Scripts run, as in any browser; a page may not open a window by
        // itself.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        configuration.allowsPictureInPictureMediaPlayback = allowsPictureInPicture
        #endif
        for (scheme, handler) in schemeHandlers {
            configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
        return configuration
    }
}
