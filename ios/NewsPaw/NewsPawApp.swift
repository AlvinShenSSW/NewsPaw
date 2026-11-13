import SwiftUI

@main
struct NewsPawApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    init() {
        // Under the UI tests only: around context menus the harness waits up
        // to 60 s for an "animations complete" notification that never comes.
        if ProcessInfo.processInfo.environment[UITestLaunchKey.libraryDirectory] != nil {
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
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
    }
}
