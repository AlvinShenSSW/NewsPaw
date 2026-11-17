import SwiftUI

@main
struct NewsPawApp: App {
    @State private var model = AppModel()

    #if DEBUG
    init() {
        // Under the UI tests only: around context menus the harness waits up
        // to 60 s for an "animations complete" notification that never comes.
        // A check made by hand on a transition asks to keep them.
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
        // Background refresh (RD24): SwiftUI registers the identifier at
        // launch and runs the action for a delivered task; a cancelled
        // action is the system's time running out, and its return
        // completes the task.
        .backgroundTask(.appRefresh(BackgroundRefreshTask.identifier)) { [model] in
            await model.backgroundRefresh()
        }
    }
}
