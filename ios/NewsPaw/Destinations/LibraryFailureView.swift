import SwiftUI

/// Shown when the library cannot be opened, with the reason why (RD02).
struct LibraryFailureView: View {
    let failure: LibraryFailure

    var body: some View {
        VStack(spacing: 16) {
            Image(decorative: "Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
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
        .padding()
    }

    private func reason(_ text: Text) -> some View {
        text
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

#Preview("Newer library") {
    LibraryFailureView(failure: .newerSchema)
}

#Preview("Damaged library") {
    LibraryFailureView(failure: .damaged)
}

#Preview("Other failure") {
    LibraryFailureView(failure: .other(detail: "SQLite error 13: database or disk is full"))
}
