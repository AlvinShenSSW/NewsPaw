import NewsPawKit
import Testing

@Suite("Window layout")
struct WindowLayoutTests {
    @Test("an iPad window chooses its structure by width", arguments: [
        (699.0, WindowLayout.Structure.tabs, false, 0.0),
        (700.0, .panes, false, 300.0),
        (744.0, .panes, false, 300.0),
        (799.0, .panes, false, 300.0),
        (800.0, .panes, false, 340.0),
        (834.0, .panes, false, 340.0),
        (1099.0, .panes, false, 340.0),
        (1100.0, .panes, true, 340.0),
        (1133.0, .panes, true, 340.0),
        (1210.0, .panes, true, 340.0),
    ])
    func pad(width: Double, structure: WindowLayout.Structure, sidebarIsPane: Bool, listPaneWidth: Double) {
        let layout = WindowLayout(idiom: .pad, width: width)
        #expect(layout.structure == structure)
        #expect(layout.sidebarIsPane == sidebarIsPane)
        #expect(layout.listPaneWidth == listPaneWidth)
    }

    @Test("an iPhone uses the tab structure at any width", arguments: [320.0, 440.0, 699.0, 700.0, 956.0, 1100.0, 1400.0])
    func phone(width: Double) {
        let layout = WindowLayout(idiom: .phone, width: width)
        #expect(layout.structure == .tabs)
        #expect(layout.sidebarIsPane == false)
    }
}
