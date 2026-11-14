import Foundation

/// What the embedded browser does with a navigation or a response (RD10
/// decision 5; spec N12). A pure function of what the web view reports, so
/// that a unit test covers its whole table; the browser only applies it.
/// No decision allows a download or an attachment.
public enum BrowserPolicy {
    /// The class of an address's scheme.
    public enum SchemeClass: Hashable, Sendable, CaseIterable {
        /// `http` and `https`: a web page.
        case web
        /// `about:`, `blob:` and `data:`: WebKit's own.
        case webKitInternal
        /// Anything else: `mailto:`, `tel:`, an app's own scheme.
        case other

        public init(_ url: URL?) {
            switch url?.scheme?.lowercased() {
            case "http", "https": self = .web
            case "about", "blob", "data": self = .webKitInternal
            default: self = .other
            }
        }
    }

    /// How the navigation was started, as far as the policy cares: a link
    /// the owner tapped, or anything else (a load by the app, a form, a
    /// script, back and forward, reload).
    public enum NavigationKind: Hashable, Sendable, CaseIterable {
        case linkActivated
        case other
    }

    /// The frame a navigation is for.
    public enum TargetFrame: Hashable, Sendable, CaseIterable {
        case main
        case sub
        /// No frame: the page asked for a new window or tab.
        case none
    }

    /// A navigation the browser is asked about.
    public struct Action: Hashable, Sendable {
        public var scheme: SchemeClass
        public var kind: NavigationKind
        public var target: TargetFrame
        /// Whether the address's host is the shown page's.
        public var sameHost: Bool
        /// Whether WebKit would download it (a link with `download`).
        public var download: Bool

        public init(scheme: SchemeClass, kind: NavigationKind, target: TargetFrame, sameHost: Bool, download: Bool) {
            self.scheme = scheme
            self.kind = kind
            self.target = target
            self.sameHost = sameHost
            self.download = download
        }
    }

    public enum ActionDecision: Hashable, Sendable {
        /// Allowed: a web page in the frame that asked for it.
        case follow
        /// Cancelled, and the address loaded by the browser in the page: a
        /// new-window request, or a tapped link to another host, which the
        /// system must not hand to an installed app.
        case loadInPlace
        /// Allowed without anything shown: WebKit's own address in a frame
        /// that exists.
        case allowSilently
        /// Cancelled without anything shown.
        case cancelSilently
        /// Cancelled; the owner is asked whether another app opens it.
        case ask
        /// Cancelled; the owner is told that the link is a file.
        case refuseAsFile

        /// Whether WebKit is let go ahead with the navigation.
        public var allows: Bool {
            self == .follow || self == .allowSilently
        }
    }

    public enum ResponseDecision: Hashable, Sendable {
        case allow
        case refuseAsFile
    }

    /// The decision for a navigation.
    public static func decide(_ action: Action) -> ActionDecision {
        switch action.scheme {
        case .other:
            // Another app's link is never followed; only the main frame and
            // a new-window request may ask.
            return action.target == .sub ? .cancelSilently : .ask
        case .webKitInternal:
            if action.download {
                return .refuseAsFile
            }
            return action.target == .none ? .cancelSilently : .allowSilently
        case .web:
            if action.download {
                return .refuseAsFile
            }
            switch action.target {
            case .none:
                return .loadInPlace
            case .main:
                return action.kind == .linkActivated && !action.sameHost ? .loadInPlace : .follow
            case .sub:
                return .follow
            }
        }
    }

    /// The decision for a response: one the web view cannot show, or one
    /// marked as an attachment, is refused as a file.
    public static func decide(canShowType: Bool, contentDisposition: String?) -> ResponseDecision {
        guard canShowType else { return .refuseAsFile }
        return isAttachment(contentDisposition) ? .refuseAsFile : .allow
    }

    /// Whether a `Content-Disposition` value's type is `attachment`.
    static func isAttachment(_ disposition: String?) -> Bool {
        guard let disposition else { return false }
        let type = disposition.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
    }

    /// Whether two addresses have the same host, ignoring case; an address
    /// without a host matches nothing.
    public static func sameHost(_ url: URL?, _ other: URL?) -> Bool {
        guard let host = url?.host(percentEncoded: false)?.lowercased(),
              let otherHost = other?.host(percentEncoded: false)?.lowercased()
        else { return false }
        return host == otherHost
    }
}

/// The address the browser shows (RD10 decision 10): the failed address
/// while the failure state is shown; the address being loaded until a page
/// commits; otherwise the page's own address. The top bar's host, "Try
/// Again", "Open in Safari", Share, Copy Link and "Save This Page as a
/// Source" all use it.
public enum BrowserAddress {
    public static func shown(failed: URL?, loading: URL?, committed: URL?) -> URL? {
        failed ?? loading ?? committed
    }

    /// The host to show for an address: its host, or the whole address when
    /// it has none.
    public static func host(of url: URL?) -> String {
        guard let url else { return "" }
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            return host
        }
        return url.absoluteString
    }
}
