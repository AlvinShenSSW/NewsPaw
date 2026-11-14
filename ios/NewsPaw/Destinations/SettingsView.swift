import NewsPawKit
import SwiftUI

/// Settings (ux S8). Each later issue adds its own row, in the order of
/// the ux table: Models & Translation, Refresh, Data, then About.
struct SettingsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: SettingsRoute.models) {
                    Label("Models & Translation", systemImage: "translate")
                }
                .accessibilityIdentifier(AccessibilityID.modelsRow)
                NavigationLink(value: SettingsRoute.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(AccessibilityID.refreshRow)
                NavigationLink(value: SettingsRoute.data) {
                    Label("Data", systemImage: "externaldrive")
                }
                .accessibilityIdentifier(AccessibilityID.dataRow)
            }
            .listRowBackground(Theme.surface)
            Section {
                NavigationLink(value: SettingsRoute.about) {
                    Label("About", systemImage: "info.circle")
                }
                .accessibilityIdentifier(AccessibilityID.aboutRow)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Settings")
    }
}

/// What a Settings route shows.
struct SettingsDestination: View {
    let route: SettingsRoute

    var body: some View {
        switch route {
        case .models: ModelsView()
        case .modelSlot(let role): ModelSlotForm(role: role)
        case .refresh: RefreshSettingsView()
        case .data: DataSettingsView()
        case .about: AboutView()
        }
    }
}

/// Settings → Refresh (ux S8; RD06): the interval and how long articles are
/// kept, each an inline picker whose options are rows, so that at the
/// largest text size every option wraps instead of being cut (a menu
/// picker's value is truncated there, measured). Background refresh arrives
/// with RD24.
struct RefreshSettingsView: View {
    @Environment(RefreshModel.self) private var refresh

    var body: some View {
        @Bindable var refresh = refresh
        List {
            Section {
                Picker("Refresh Interval", selection: $refresh.interval) {
                    Text("Every 15 Minutes").tag(RefreshInterval.fifteenMinutes)
                    Text("Every 30 Minutes").tag(RefreshInterval.thirtyMinutes)
                    Text("Every Hour").tag(RefreshInterval.sixtyMinutes)
                    Text("Manual Only").tag(RefreshInterval.manualOnly)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Refresh Interval")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("When you open the app and this long has passed since the last refresh, the library is refreshed. Pull down on Today to refresh at any time.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
            Section {
                Picker("Keep Articles", selection: $refresh.retention) {
                    Text("7 Days").tag(Retention.sevenDays)
                    Text("30 Days").tag(Retention.thirtyDays)
                    Text("90 Days").tag(Retention.ninetyDays)
                    Text("Forever").tag(Retention.forever)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Keep Articles")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("Counted from when an article was first seen. Starred articles are always kept. A change takes effect the next time you open the app.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Refresh")
    }
}

/// Settings → Data (ux S8; RD09 decision 14): the size of the current
/// library's image cache, read each time the screen is shown, and Clear for
/// that cache only. Export and import arrive with RD20.
struct DataSettingsView: View {
    @Environment(ReadingModel.self) private var reading
    @State private var size: Int?
    @State private var isClearing = false

    var body: some View {
        List {
            Section {
                LabeledContent {
                    Group {
                        if let size {
                            Text(Int64(size), format: .byteCount(style: .file))
                        } else {
                            Text(verbatim: "–")
                        }
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.cacheSize)
                } label: {
                    Text("Image Cache")
                }
                Button {
                    clear()
                } label: {
                    Text("Clear Image Cache")
                        .frame(minHeight: Theme.minimumTapTarget)
                }
                .disabled(size == nil || size == 0 || isClearing)
                .accessibilityIdentifier(AccessibilityID.clearCacheButton)
            } header: {
                Text("Images")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("Thumbnails of the images in article lists. Cleared images are fetched again when they are next shown.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Data")
        .onAppear {
            Task { size = await reading.library.imageCache.size() }
        }
    }

    private func clear() {
        isClearing = true
        Task {
            let cache = reading.library.imageCache
            await cache.clear()
            size = await cache.size()
            isClearing = false
        }
    }
}

/// About: the app's version.
struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent {
                    Text(verbatim: Self.version)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.versionValue)
                } label: {
                    Text("Version")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("About")
    }

    /// The marketing version and the build number, for example "0.1.0 (1)".
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
