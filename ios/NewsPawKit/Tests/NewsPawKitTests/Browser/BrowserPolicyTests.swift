import Foundation
import Testing
@testable import NewsPawKit

/// RD10 decisions 5 and 10; criteria 4–6 as decisions: the embedded
/// browser's policy over its whole table, and the address it shows.
@Suite("Browser policy")
struct BrowserPolicyTests {
    typealias Action = BrowserPolicy.Action

    /// Every combination of the action's inputs.
    static let allActions: [Action] = {
        var actions: [Action] = []
        for scheme in BrowserPolicy.SchemeClass.allCases {
            for kind in BrowserPolicy.NavigationKind.allCases {
                for target in BrowserPolicy.TargetFrame.allCases {
                    for sameHost in [false, true] {
                        for download in [false, true] {
                            actions.append(Action(scheme: scheme, kind: kind, target: target, sameHost: sameHost, download: download))
                        }
                    }
                }
            }
        }
        return actions
    }()

    /// The table as decision 5 states it, row by row, written apart from the
    /// function.
    static func expected(_ action: Action) -> BrowserPolicy.ActionDecision {
        switch (action.scheme, action.target) {
        // Another scheme: the main frame and a new-window request ask; a
        // subframe is cancelled silently. A download flag changes nothing.
        case (.other, .main), (.other, .none): return .ask
        case (.other, .sub): return .cancelSilently
        // WebKit's own addresses: a download is a file; otherwise allowed in
        // a frame that exists and cancelled silently for a new window.
        case (.webKitInternal, _) where action.download: return .refuseAsFile
        case (.webKitInternal, .main), (.webKitInternal, .sub): return .allowSilently
        case (.webKitInternal, .none): return .cancelSilently
        // Web pages: a download is a file; a new window loads in place; a
        // tapped link to another host loads in place; the rest is followed.
        case (.web, _) where action.download: return .refuseAsFile
        case (.web, .none): return .loadInPlace
        case (.web, .main) where action.kind == .linkActivated && !action.sameHost: return .loadInPlace
        case (.web, .main), (.web, .sub): return .follow
        }
    }

    @Test("the whole action table")
    func wholeTable() {
        #expect(Self.allActions.count == 72)
        for action in Self.allActions {
            #expect(BrowserPolicy.decide(action) == Self.expected(action), "\(action)")
        }
    }

    @Test("no decision lets a download or an attachment through")
    func noDownload() {
        for action in Self.allActions where action.download {
            #expect(!BrowserPolicy.decide(action).allows, "\(action)")
        }
        for canShow in [false, true] {
            #expect(BrowserPolicy.decide(canShowType: canShow, contentDisposition: "attachment; filename=a.zip") == .refuseAsFile)
            #expect(BrowserPolicy.decide(canShowType: canShow, contentDisposition: "ATTACHMENT") == .refuseAsFile)
            #expect(BrowserPolicy.decide(canShowType: canShow, contentDisposition: " attachment ;filename=\"a\"") == .refuseAsFile)
        }
    }

    @Test("only follow and allow-silently let WebKit go ahead")
    func allows() {
        #expect(BrowserPolicy.ActionDecision.follow.allows)
        #expect(BrowserPolicy.ActionDecision.allowSilently.allows)
        for decision in [BrowserPolicy.ActionDecision.loadInPlace, .cancelSilently, .ask, .refuseAsFile] {
            #expect(!decision.allows)
        }
    }

    @Test("criterion 4: a new window or tab is shown in the same view")
    func newWindow() {
        // `target="_blank"` (a tapped link) and `window.open` (a script).
        for kind in BrowserPolicy.NavigationKind.allCases {
            for sameHost in [false, true] {
                let action = Action(scheme: .web, kind: kind, target: .none, sameHost: sameHost, download: false)
                #expect(BrowserPolicy.decide(action) == .loadInPlace)
            }
        }
        // `about:blank` asking for a new window is WebKit's own and is
        // dropped without a question.
        #expect(BrowserPolicy.decide(Action(scheme: .webKitInternal, kind: .other, target: .none, sameHost: false, download: false)) == .cancelSilently)
    }

    @Test("criterion 5: another scheme asks from the main frame, never from a subframe")
    func otherSchemes() {
        let mailto = Action(scheme: BrowserPolicy.SchemeClass(URL(string: "mailto:someone@example.invalid")), kind: .linkActivated,
                            target: .main, sameHost: false, download: false)
        #expect(BrowserPolicy.decide(mailto) == .ask)
        let unknown = Action(scheme: BrowserPolicy.SchemeClass(URL(string: "newspaw-unknown://thing")), kind: .linkActivated,
                             target: .main, sameHost: false, download: false)
        #expect(BrowserPolicy.decide(unknown) == .ask)
        let framed = Action(scheme: .other, kind: .other, target: .sub, sameHost: false, download: false)
        #expect(BrowserPolicy.decide(framed) == .cancelSilently)
        let blankFrame = Action(scheme: BrowserPolicy.SchemeClass(URL(string: "about:blank")), kind: .other,
                                target: .sub, sameHost: false, download: false)
        #expect(BrowserPolicy.decide(blankFrame) == .allowSilently)
    }

    @Test("criterion 6: a download link, an attachment and an unshowable type are files")
    func files() {
        let link = Action(scheme: .web, kind: .linkActivated, target: .main, sameHost: true, download: true)
        #expect(BrowserPolicy.decide(link) == .refuseAsFile)
        #expect(BrowserPolicy.decide(canShowType: true, contentDisposition: "attachment; filename=report.pdf") == .refuseAsFile)
        #expect(BrowserPolicy.decide(canShowType: false, contentDisposition: nil) == .refuseAsFile)
        #expect(BrowserPolicy.decide(canShowType: true, contentDisposition: nil) == .allow)
        #expect(BrowserPolicy.decide(canShowType: true, contentDisposition: "inline") == .allow)
        #expect(BrowserPolicy.decide(canShowType: true, contentDisposition: "inline; filename=attachment.txt") == .allow)
    }

    @Test("a tapped link to the same host and a subframe are followed; another host is loaded in place")
    func hosts() {
        #expect(BrowserPolicy.decide(Action(scheme: .web, kind: .linkActivated, target: .main, sameHost: true, download: false)) == .follow)
        #expect(BrowserPolicy.decide(Action(scheme: .web, kind: .linkActivated, target: .main, sameHost: false, download: false)) == .loadInPlace)
        #expect(BrowserPolicy.decide(Action(scheme: .web, kind: .other, target: .main, sameHost: false, download: false)) == .follow)
        #expect(BrowserPolicy.decide(Action(scheme: .web, kind: .linkActivated, target: .sub, sameHost: false, download: false)) == .follow)
    }

    @Test("scheme classes")
    func schemeClasses() {
        #expect(BrowserPolicy.SchemeClass(URL(string: "https://example.invalid/")) == .web)
        #expect(BrowserPolicy.SchemeClass(URL(string: "HTTP://example.invalid/")) == .web)
        #expect(BrowserPolicy.SchemeClass(URL(string: "about:blank")) == .webKitInternal)
        #expect(BrowserPolicy.SchemeClass(URL(string: "blob:https://example.invalid/1")) == .webKitInternal)
        #expect(BrowserPolicy.SchemeClass(URL(string: "data:text/plain,x")) == .webKitInternal)
        #expect(BrowserPolicy.SchemeClass(URL(string: "tel:123")) == .other)
        #expect(BrowserPolicy.SchemeClass(URL(string: "file:///etc/hosts")) == .other)
        #expect(BrowserPolicy.SchemeClass(nil) == .other)
    }

    @Test("same host ignores case and needs a host on both sides")
    func sameHost() {
        #expect(BrowserPolicy.sameHost(URL(string: "https://Example.invalid/a"), URL(string: "http://example.invalid/b")))
        #expect(!BrowserPolicy.sameHost(URL(string: "https://www.example.invalid/"), URL(string: "https://example.invalid/")))
        #expect(!BrowserPolicy.sameHost(URL(string: "https://example.invalid/"), nil))
        #expect(!BrowserPolicy.sameHost(URL(string: "about:blank"), URL(string: "about:blank")))
    }

    @Test("decision 10: the shown address")
    func shownAddress() {
        let failed = URL(string: "https://failed.example.invalid/")
        let loading = URL(string: "https://loading.example.invalid/")
        let committed = URL(string: "https://committed.example.invalid/")
        #expect(BrowserAddress.shown(failed: failed, loading: loading, committed: committed) == failed)
        #expect(BrowserAddress.shown(failed: nil, loading: loading, committed: committed) == loading)
        #expect(BrowserAddress.shown(failed: nil, loading: nil, committed: committed) == committed)
        #expect(BrowserAddress.shown(failed: nil, loading: nil, committed: nil) == nil)
        #expect(BrowserAddress.host(of: committed) == "committed.example.invalid")
        #expect(BrowserAddress.host(of: URL(string: "about:blank")) == "about:blank")
        #expect(BrowserAddress.host(of: nil) == "")
    }
}
