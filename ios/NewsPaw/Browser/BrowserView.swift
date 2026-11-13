import NewsPawKit
import SwiftUI
import UIKit
import WebKit

/// The browser of a stack (ux S5; RD10): its session's page with the bars,
/// or nothing while the session is being made or has just ended.
struct BrowserPane: View {
    let stack: BrowserStack
    /// In the reading pane: Close returns to the article.
    var close: (() -> Void)?
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        if let session = browser.session(stack) {
            BrowserView(session: session, close: close)
        } else {
            Theme.background
                .ignoresSafeArea()
                .toolbar(.hidden, for: .tabBar)
        }
    }
}

/// The page, the failure state in its place, and the bars: the title in
/// one line (the host while there is none) with the host under it and a
/// progress line while a page loads; Back, Forward and More below. The
/// places of Translate and reader mode stay empty until RD16 and RD12.
struct BrowserView: View {
    let session: BrowserSession
    let close: (() -> Void)?
    @Environment(SourceModel.self) private var sources
    @Environment(\.openURL) private var openURL

    var body: some View {
        WebViewHost(session: session)
            // The page runs behind the bars; the web view keeps its content
            // clear of them, so the end of a page scrolls above the bottom
            // bar.
            .ignoresSafeArea(.container, edges: .vertical)
            .overlay {
                if let failure = session.failure {
                    failureView(failure)
                }
            }
            .overlay(alignment: .top) {
                if session.isLoading {
                    ProgressView(value: session.progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .accessibilityLabel(Text("Loading"))
                        .accessibilityIdentifier(AccessibilityID.browserProgress)
                }
            }
            .stackBackground(Theme.background)
            .navigationTitle(Text(verbatim: session.displayTitle))
            .navigationSubtitle(Text(verbatim: session.host))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            // Pushed in the tab structure the tab bar would cover the bottom
            // bar.
            .toolbar(.hidden, for: .tabBar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.browser)
    }

    // MARK: - Failure (decision 7)

    private func failureView(_ failure: BrowserFailure) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            Text("Could not open this page")
                .font(.headline)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text(verbatim: failure.reason)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(AccessibilityID.browserFailureReason)
            Button("Try Again") {
                session.tryAgain()
            }
            .buttonStyle(.bordered)
            .frame(minHeight: Theme.minimumTapTarget)
            .accessibilityIdentifier(AccessibilityID.browserTryAgainButton)
            if let url = failure.url {
                Button("Open in Safari") {
                    openURL(url)
                }
                .frame(minHeight: Theme.minimumTapTarget)
                .accessibilityIdentifier(AccessibilityID.browserFailureSafariButton)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.browserFailure)
    }

    // MARK: - Bars

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let close {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", systemImage: "xmark", action: close)
                    .accessibilityIdentifier(AccessibilityID.browserCloseButton)
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Back", systemImage: "chevron.backward") {
                session.goBack()
            }
            .disabled(!session.backEnabled)
            .accessibilityIdentifier(AccessibilityID.browserBackButton)
            Button("Forward", systemImage: "chevron.forward") {
                session.goForward()
            }
            .disabled(!session.forwardEnabled)
            .accessibilityIdentifier(AccessibilityID.browserForwardButton)
            Spacer()
            moreMenu
        }
    }

    /// Reload, Share, Open in Safari, Save This Page as a Source, Copy Link,
    /// and Source Settings when the browser shows a web-page source.
    private var moreMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            Button("Reload", systemImage: "arrow.clockwise") {
                session.reload()
            }
            if let url = session.shownURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button("Open in Safari", systemImage: "safari") {
                    openURL(url)
                }
                Button("Save This Page as a Source", systemImage: "plus.circle") {
                    sources.beginAddSource(address: url.absoluteString)
                }
                Button("Copy Link", systemImage: "link") {
                    UIPasteboard.general.string = url.absoluteString
                }
            }
            if let id = session.sourceID {
                Button("Source Settings", systemImage: "gearshape") {
                    sources.beginSettings(id)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.browserMoreMenu)
    }
}

/// Hosts the session's one web view. A container switch makes a new host
/// before the old one is taken down; the web view moves to the newest host,
/// keeping its page and history (measured: SwiftUI's `WebView` traps when a
/// second view is made for a page still bound to the first).
private struct WebViewHost: UIViewRepresentable {
    let session: BrowserSession

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let webView = session.webView
        // The web view of a session that has ended.
        for view in container.subviews where view !== webView {
            view.removeFromSuperview()
        }
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
