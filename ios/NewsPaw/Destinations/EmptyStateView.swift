import SwiftUI

/// A destination's truthful empty state: a symbol and a title, an optional
/// line under it, and an optional button below them.
struct EmptyStateView: View {
    let title: Text
    let systemImage: String
    let identifier: String
    var detail: Text?
    var action: Action?

    struct Action {
        let title: Text
        let identifier: String
        let perform: () -> Void
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            VStack(spacing: Theme.Spacing.medium) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                title
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                if let detail {
                    detail
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
            if let action {
                Button(action: action.perform) {
                    action.title
                        .frame(minWidth: Theme.minimumTapTarget, minHeight: Theme.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.tint)
                .accessibilityIdentifier(action.identifier)
            }
        }
        .padding(Theme.Spacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
