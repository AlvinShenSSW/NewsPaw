import SwiftUI

/// iPhone, and iPad below 700 pt: Today, Library, Starred and Settings,
/// each a navigation stack, with the bottom tab bar. An article opened from
/// a list is pushed on it, and the browser on the article or on the Library
/// root for a web-page source (RD10).
struct TabContainer: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab("Today", systemImage: "sun.max", value: AppTab.today) {
                NavigationStack {
                    TodayView()
                        .toolbar { partitionSwitch }
                }
            }
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                NavigationStack(path: $navigation.libraryPath) {
                    LibraryRootView()
                        .toolbar { partitionSwitch }
                        .navigationDestination(for: LibraryRoute.self) { route in
                            if let list = navigation.list(of: route) {
                                ArticleListView(kind: list)
                            } else if case .article(let id) = route {
                                ReadingView(articleID: id, list: navigation.libraryList ?? .allUnread, isPushed: true)
                            } else {
                                // An article's page, or a web-page source.
                                BrowserPane(stack: .library)
                            }
                        }
                }
            }
            Tab("Starred", systemImage: "star", value: AppTab.starred) {
                NavigationStack(path: $navigation.starredPath) {
                    ArticleListView(kind: .starred)
                        .toolbar { partitionSwitch }
                        .navigationDestination(for: LibraryRoute.self) { route in
                            if case .article(let id) = route {
                                ReadingView(articleID: id, list: .starred, isPushed: true)
                            } else if case .page = route {
                                BrowserPane(stack: .starred)
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

    /// The partition switch at the leading edge of the bar on the root
    /// screens of Today, Library and Starred (ux section 2), only while the
    /// adult partition is turned on: the capsule, and in the adult
    /// partition the lock button as an item of its own. A pushed screen
    /// has its back button there instead.
    @ToolbarContentBuilder
    private var partitionSwitch: some ToolbarContent {
        if model.showsPartitionSwitch {
            ToolbarItem(placement: .topBarLeading) {
                PartitionMenu()
            }
            // The capsule draws its own shape.
            .sharedBackgroundVisibility(.hidden)
            if model.shown?.partition == .adult {
                ToolbarItem(placement: .topBarLeading) {
                    PartitionLockButton()
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }
}
