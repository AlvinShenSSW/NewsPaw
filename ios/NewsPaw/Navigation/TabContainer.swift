import SwiftUI

/// iPhone, and iPad below 700 pt: Today, Library, Starred and Settings,
/// each a navigation stack, with the bottom tab bar.
struct TabContainer: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab("Today", systemImage: "sun.max", value: AppTab.today) {
                NavigationStack {
                    TodayView()
                }
            }
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                NavigationStack(path: $navigation.libraryPath) {
                    LibraryRootView()
                        .navigationDestination(for: LibraryRoute.self) { route in
                            switch route {
                            case .allUnread: ArticleListView(kind: .allUnread)
                            case .category(let id): ArticleListView(kind: .category(id))
                            }
                        }
                }
            }
            Tab("Starred", systemImage: "star", value: AppTab.starred) {
                NavigationStack {
                    ArticleListView(kind: .starred)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack(path: $navigation.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: SettingsRoute.self) { _ in AboutView() }
                }
            }
        }
        // A compact size class keeps the bottom tab bar on iPad below
        // 700 pt, where the system would otherwise show a top bar.
        .environment(\.horizontalSizeClass, .compact)
    }
}
