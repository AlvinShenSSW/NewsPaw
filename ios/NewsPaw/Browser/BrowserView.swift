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
/// progress line while a page loads; Back, Forward, Reader Mode and More
/// below. The place of Translate stays empty until RD16. Reader mode's
/// temporary article (RD12) stands in place of the page, with its own bar.
struct BrowserView: View {
    @Environment(\.accent) private var accent
    let session: BrowserSession
    let close: (() -> Void)?
    @Environment(SourceModel.self) private var sources
    @Environment(ReadingSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var isShowingReadingSettings = false

    var body: some View {
        @Bindable var session = session
        WebViewHost(session: session)
            // Beneath a temporary article the page stays alive, with its
            // history (assumption A4), out of reach of VoiceOver.
            .accessibilityHidden(session.temporaryArticle != nil)
            // The page runs behind the bottom bar only; the web view keeps
            // its content clear of it, so the end of a page scrolls above
            // the bar. It stays out from under the top bar: the title and
            // the host follow the app's appearance and are drawn on the
            // app's own background, never on a page's, where a light page
            // in dark appearance (or a dark page in light) would hide them.
            //
            // Every region is ignored at the bottom, the keyboard's too: the
            // web view keeps its frame when a keyboard appears, and WebKit
            // itself keeps a page's focused field above the keyboard
            // (measured). With the container's region alone the web view is
            // resized by a keyboard, also by the keyboard of a sheet above
            // it, and then the Paste button of Add source did nothing on
            // iPad (measured; the same frame change under the page running
            // behind both bars did not have that effect).
            .ignoresSafeArea(.all, edges: .bottom)
            .overlay {
                if let failure = session.failure {
                    failureView(failure)
                }
            }
            .overlay {
                if let article = session.temporaryArticle {
                    TemporaryArticleView(article: article) { url in
                        session.openFromTemporaryArticle(url)
                    }
                }
            }
            .overlay(alignment: .top) {
                if session.isLoading {
                    ProgressView(value: session.progress)
                        .progressViewStyle(.linear)
                        .tint(accent)
                        .accessibilityLabel(Text("Loading"))
                        .accessibilityIdentifier(AccessibilityID.browserProgress)
                }
            }
            .stackBackground(Theme.background)
            .navigationTitle(Text(verbatim: session.displayTitle))
            .navigationSubtitle(Text(verbatim: session.host))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let article = session.temporaryArticle {
                    readerToolbar(article)
                } else {
                    toolbar
                }
            }
            // Pushed in the tab structure the tab bar would cover the bottom
            // bar.
            .toolbar(.hidden, for: .tabBar)
            .alert(Text("This page has no readable article"), isPresented: $session.isShowingNoReadableArticle) {
                Button("OK") {}
            }
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
        if let close, session.temporaryArticle == nil {
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
            readerButton
            moreMenu
        }
    }

    /// Reader Mode (RD12 decision 7): activity while the page is fetched
    /// again and extracted.
    private var readerButton: some View {
        Button {
            session.openReaderMode()
        } label: {
            if session.isExtractingArticle {
                ProgressView()
            } else {
                Label("Reader Mode", systemImage: "doc.plaintext")
            }
        }
        .disabled(!session.readerModeEnabled || session.isExtractingArticle)
        .accessibilityLabel(Text("Reader Mode"))
        .accessibilityValue(session.isExtractingArticle ? Text("Loading") : Text(verbatim: ""))
        .accessibilityIdentifier(AccessibilityID.browserReaderButton)
    }

    /// The temporary article's bar: Close, Share and "Aa"; no star and no
    /// previous or next.
    @ToolbarContentBuilder
    private func readerToolbar(_ article: TemporaryArticle) -> some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Close", systemImage: "xmark") {
                session.closeTemporaryArticle()
            }
            .accessibilityIdentifier(AccessibilityID.readerCloseButton)
            Spacer()
            ShareLink(item: article.address) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier(AccessibilityID.readerShareButton)
            Spacer()
            Button("Reading Settings", systemImage: "textformat.size") {
                isShowingReadingSettings = true
            }
            .accessibilityIdentifier(AccessibilityID.readerSettingsButton)
            .popover(isPresented: $isShowingReadingSettings) {
                ReadingSettingsPopover()
                    .environment(settings)
            }
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

/// A page as reader mode shows it (RD12 decision 7): the extraction's
/// title, the page's host and the blocks in RD11's `BlocksView`, in the
/// reading column, on the app's own background over the page. A link
/// tapped in it is loaded by the session.
private struct TemporaryArticleView: View {
    let article: TemporaryArticle
    let openLink: (URL) -> Void
    @Environment(ReadingSettings.self) private var settings
    @ScaledMetric(relativeTo: .title2) private var scaledTitleSize = 22.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
                Text(verbatim: article.title)
                    .font(.system(size: min(scaledTitleSize * settings.textSize.factor, ReadingMetrics.maximumSize), weight: .bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AccessibilityID.readerTitle)
                Text(verbatim: article.host)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.readerHost)
                BlocksView(blocks: article.content.blocks, settings: settings, images: article.content.images, openLink: openLink)
                if article.content.isCut {
                    Text("The rest of this article is on the original page.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(Theme.Spacing.standard)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.readerArticle)
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
