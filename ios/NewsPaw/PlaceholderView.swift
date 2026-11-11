import SwiftUI

/// Shown until the reader's first screens exist.
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(decorative: "Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            Text("NewsPaw")
                .font(.largeTitle.bold())
            Text("The reader is being built.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    PlaceholderView()
}
