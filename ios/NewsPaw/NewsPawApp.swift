import SwiftUI

@main
struct NewsPawApp: App {
    @State private var model = AppModel()

    #if DEBUG
    init() {
        // Under the UI tests only: around context menus the harness waits up
        // to 60 s for an "animations complete" notification that never comes.
        let environment = ProcessInfo.processInfo.environment
        if environment[UITestLaunchKey.libraryDirectory] != nil, environment[UITestLaunchKey.keepAnimations] != "1" {
            UIView.setAnimationsEnabled(false)
        }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
    }
}
