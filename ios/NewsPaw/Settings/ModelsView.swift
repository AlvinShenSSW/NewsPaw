import NewsPawKit
import SwiftUI

/// Settings → Models & Translation (ux S8; RD13 decision 14): the primary
/// and backup model, each with its name and state. The reading-language and
/// translation switches of this screen arrive with RD14.
struct ModelsView: View {
    @Environment(ModelSettingsModel.self) private var models
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        // At the accessibility sizes the large title is cut on iPhone
        // ("Models & Tra…"); the inline title is not enlarged and fits.
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .automatic)
        .task { await models.reload() }
    }

    private func row(_ role: ModelRole) -> some View {
        NavigationLink(value: SettingsRoute.modelSlot(role)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                // An explicit colour is not dimmed by `disabled`: the
                // backup's title is secondary while it cannot be set up.
                ModelWording.role(role)
                    .foregroundStyle(role == .primary || models.hasPrimary ? Theme.text : Theme.secondaryText)
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
