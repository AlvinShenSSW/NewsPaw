/// The kind of device the window is on, as far as the layout cares.
public enum DeviceIdiom: Sendable, Hashable {
    case phone
    case pad
}

/// The app's structure for a window (ux section 2): a function of the
/// device idiom and the window's width alone, so it is the same after a
/// rotation, a Split View or Stage Manager change, and with the keyboard up.
public struct WindowLayout: Sendable, Hashable {
    public enum Structure: Sendable, Hashable {
        /// The bottom tab bar: iPhone always, iPad below `paneMinimumWidth`.
        case tabs
        /// Panes side by side: iPad from `paneMinimumWidth`.
        case panes
    }

    /// From this width an iPad window shows panes instead of tabs.
    public static let paneMinimumWidth = 700.0
    /// From this width the sidebar is a pane that is always shown; below it,
    /// it slides over the content.
    public static let sidebarPaneMinimumWidth = 1100.0
    /// The sidebar's width as a pane.
    public static let sidebarPaneWidth = 280.0
    /// The sidebar's width when it slides over the content.
    public static let slideOverWidth = 320.0
    /// When the list and reading panes together have less than this width,
    /// the list pane uses `narrowListPaneWidth`, otherwise
    /// `wideListPaneWidth`.
    public static let wideListMinimumWidth = 800.0
    public static let narrowListPaneWidth = 300.0
    public static let wideListPaneWidth = 340.0

    public let structure: Structure
    /// Whether the sidebar is a pane (true) or slides over (false). Only
    /// meaningful for `.panes`.
    public let sidebarIsPane: Bool
    /// The list pane's width beside the reading pane. Only meaningful for
    /// `.panes`.
    public let listPaneWidth: Double

    public init(idiom: DeviceIdiom, width: Double) {
        guard idiom == .pad, width >= Self.paneMinimumWidth else {
            structure = .tabs
            sidebarIsPane = false
            listPaneWidth = 0
            return
        }
        structure = .panes
        sidebarIsPane = width >= Self.sidebarPaneMinimumWidth
        let listAndReading = width - (sidebarIsPane ? Self.sidebarPaneWidth : 0)
        listPaneWidth = listAndReading < Self.wideListMinimumWidth ? Self.narrowListPaneWidth : Self.wideListPaneWidth
    }
}
