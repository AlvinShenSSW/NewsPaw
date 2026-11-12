import SwiftUI

/// Settings. Each later issue adds its own row; About is the first.
struct SettingsView: View {
    var body: some View {
        List {
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
