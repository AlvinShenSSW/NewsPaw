import NewsPawKit
import SwiftUI

/// Why the library could not be opened, as the placeholder screen tells it.
enum LibraryFailure: Equatable {
    case newerSchema
    case damaged
    /// Anything else, with the underlying description shown as technical
    /// detail (SQLite's own English wording, not translated).
    case other(detail: String)

    init(_ error: any Error) {
        switch error {
        case LibraryError.newerSchema: self = .newerSchema
        case LibraryError.damaged: self = .damaged
        case LibraryError.storage(let description): self = .other(detail: description)
        default: self = .other(detail: String(describing: error))
        }
    }
}

/// Shown until the reader's first screens exist, or, when the library cannot
/// be opened, the reason why.
struct PlaceholderView: View {
    var failure: LibraryFailure?

    var body: some View {
        VStack(spacing: 16) {
            Image(decorative: "Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            if let failure {
                failureMessage(failure)
            } else {
                Text("NewsPaw")
                    .font(.largeTitle.bold())
                Text("The reader is being built.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func failureMessage(_ failure: LibraryFailure) -> some View {
        Text("NewsPaw could not open its library.")
            .font(.title2.bold())
            .multilineTextAlignment(.center)
        switch failure {
        case .newerSchema:
            reason(Text("It was created by a newer version of the app. Update NewsPaw to open it."))
        case .damaged:
            reason(Text("The library file is damaged or is not a NewsPaw library."))
        case .other(let detail):
            reason(Text("Something went wrong while opening it."))
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
    }

    private func reason(_ text: Text) -> some View {
        text
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

#Preview("Placeholder") {
    PlaceholderView()
}

#Preview("Newer library") {
    PlaceholderView(failure: .newerSchema)
}

#Preview("Damaged library") {
    PlaceholderView(failure: .damaged)
}

#Preview("Other failure") {
    PlaceholderView(failure: .other(detail: "SQLite error 13: database or disk is full"))
}
