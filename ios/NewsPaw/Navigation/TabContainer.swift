import SwiftUI

/// iPhone, and iPad below 700 pt: Today, Library, Starred and Settings,
/// each a navigation stack, with the bottom tab bar. An article opened from
/// a list is pushed on it.
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
                            if let list = route.list {
                                ArticleListView(kind: list)
                            } else if case .article(let id) = route {
                                ReadingView(articleID: id, list: navigation.libraryList ?? .allUnread, isPushed: true)
                            }
                        }
                }
            }
            Tab("Starred", systemImage: "star", value: AppTab.starred) {
                NavigationStack(path: $navigation.starredPath) {
                    ArticleListView(kind: .starred)
                        .navigationDestination(for: LibraryRoute.self) { route in
                            if case .article(let id) = route {
                                ReadingView(articleID: id, list: .starred, isPushed: true)
                            }
                        }
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack(path: $navigation.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: SettingsRoute.self) { route in
                            SettingsDestination(route: route)
                        }
                }
            }
        }
        // A compact size class keeps the bottom tab bar on iPad below
        // 700 pt, where the system would otherwise show a top bar.
        .environment(\.horizontalSizeClass, .compact)
    }
}
