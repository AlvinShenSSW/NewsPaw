import AppKit
import SwiftUI

/// Routes the selected sidebar page. Pages not yet redesigned host the settings views they
/// replace, so the app stays usable between the redesign's merges.
struct PageContent: View {
    let model: AppModel
    let page: Page

    var body: some View {
        if model.connection != .connected, page != .settings {
            BackendUnavailable(model: model)
        } else {
            switch page {
            case .overview: OverviewPage(model: model)
            case .digests: if let config = model.config { DigestsPage(model: model, config: config) }
            case .xAccounts: XAccountsPage(model: model)
            case .connect: ConnectPage(model: model)
            case .settings: SettingsPage(model: model)
            }
        }
    }
}

/// Shown on every page while the backend cannot be reached (interaction-spec §4.6).
struct BackendUnavailable: View {
    let model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.text(model.statusTitle)).font(.headline)
                Text(model.text(L10n.Shell.notRunningNote)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                BackendStartControls(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

struct CategorySymbol: View {
    let id: String

    var body: some View {
        if id == "av",
           let url = Bundle.module.url(forResource: "newspaw-female-head-preview", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 17, height: 17)
        } else {
            Image(systemName: [
                "world": "globe", "japan": "location", "australia": "map",
                "china": "building.columns", "electronics": "desktopcomputer",
                "ai": "brain.head.profile", "x": "at", "x_adult": "at",
            ][id] ?? "newspaper")
            .font(.system(size: 16))
        }
    }
}
