import SwiftUI

/// A destination's truthful empty state: text only, no control.
struct EmptyStateView: View {
    let title: Text
    let systemImage: String
    let identifier: String

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            title
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
