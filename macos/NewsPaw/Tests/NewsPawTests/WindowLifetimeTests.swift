import AppKit
import Testing

@testable import NewsPaw

@Test @MainActor func reopeningClosedSettingsUsesItsRegisteredWindowAction() {
    let lifetime = WindowLifetime()
    let app = NSApplication.shared
    var opens = 0
    #expect(lifetime.applicationShouldHandleReopen(app, hasVisibleWindows: false))
    lifetime.revealSettings = { opens += 1 }
    #expect(lifetime.applicationShouldHandleReopen(app, hasVisibleWindows: true))
    #expect(opens == 0)
    #expect(!lifetime.applicationShouldHandleReopen(app, hasVisibleWindows: false))
    #expect(opens == 1)
    #expect(!lifetime.applicationShouldTerminateAfterLastWindowClosed(app))
}
