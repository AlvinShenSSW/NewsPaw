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
/// before the old one is taken down, and a host leaving the screen can
/// still be updated with a newer session; the web view therefore moves to
/// whichever host is in a window and laid out last, keeping its page and
/// history (measured: SwiftUI's `WebView` traps when a second view is made
/// for a page still bound to the first).
private struct WebViewHost: UIViewRepresentable {
    let session: BrowserSession

    func makeUIView(context: Context) -> WebViewContainer {
        WebViewContainer()
    }

    func updateUIView(_ container: WebViewContainer, context: Context) {
        container.webView = session.webView
    }
}

/// The view a web view is hosted in; it takes its web view back whenever
/// it is in a window and lays out, and hands it to another host of it when
/// it leaves the window.
final class WebViewContainer: UIView {
    /// Every container made, so that one leaving the window can hand its
    /// web view over.
    private static let all = NSHashTable<WebViewContainer>.weakObjects()

    var webView: WKWebView? {
        didSet { attach() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        Self.all.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, let webView, webView.superview === self {
            Self.all.allObjects.first { $0 !== self && $0.window != nil && $0.webView === webView }?.attach()
        } else {
            attach()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attach()
    }

    private func attach() {
        // The web view of a session that has ended.
        for view in subviews where view !== webView {
            view.removeFromSuperview()
        }
        guard window != nil, let webView, webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
    }
}
