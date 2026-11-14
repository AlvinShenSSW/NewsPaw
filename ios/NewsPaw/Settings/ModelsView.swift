import NewsPawKit
import SwiftUI

/// Settings → Models & Translation (ux S8; RD13 decision 14): the primary
/// and backup model, each with its name and state. The reading-language and
/// translation switches of this screen arrive with RD14.
struct ModelsView: View {
    @Environment(ModelSettingsModel.self) private var models

    var body: some View {
        List {
            Section {
                row(.primary)
                    .accessibilityIdentifier(AccessibilityID.primaryModelRow)
                row(.backup)
                    .disabled(!models.hasPrimary)
                    .accessibilityIdentifier(AccessibilityID.backupModelRow)
            } header: {
                Text("Models")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                if !models.hasPrimary {
                    Text("Set up the primary model first")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.backupNeedsPrimary)
                }
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Models & Translation")
        .task { await models.reload() }
    }

    private func row(_ role: ModelRole) -> some View {
        NavigationLink(value: SettingsRoute.modelSlot(role)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                ModelWording.role(role)
                    .foregroundStyle(Theme.text)
                if let status = models.statuses[role] {
                    Text(verbatim: status.slot.model)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    ModelWording.state(status)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("Not set up")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(minHeight: Theme.minimumTapTarget, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
