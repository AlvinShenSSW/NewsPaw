import NewsPawKit
import SwiftUI
import UIKit

/// An image opened in the viewer.
struct ViewedImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let alternativeText: String?
}

/// An image of an article's body (RD11 decision 9).
///
/// At the column's width and never larger than its own size (a pixel of the
/// stored image is a point at most), and not at all when it is under 8
/// pixels on a side. Until it arrives its place is reserved on the surface
/// colour: at the size its tag declared, else 3:2. An image that fails, or
/// that the system cannot decode, shows its alternative text in that place,
/// or a symbol when it has none. It is decoded to the width it is shown at,
/// off the main actor, and let go when it leaves the screen. A tap on a
/// loaded image opens the viewer.
struct BodyImageView: View {
    let image: ArticleImage
    let index: Int
    let session: BodyImageSession
    let view: (ViewedImage) -> Void
    /// Called when the image turns out to be under 8 pixels on a side: its
    /// row then takes no room.
    let undrawn: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var phase = Phase.waiting
    /// The width the image has on screen, in points.
    @State private var shownWidth = 0.0

    private enum Phase {
        case waiting
        case loaded(UIImage)
        case failed
    }

    var body: some View {
        Group {
            switch phase {
            case .loaded(let decoded):
                Button {
                    open()
                } label: {
                    Image(uiImage: decoded)
                        .resizable()
                        .aspectRatio(aspectRatio, contentMode: .fit)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: maximumWidth, alignment: .leading)
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier(AccessibilityID.readingImage(index))
            case .waiting:
                place
                    .accessibilityElement()
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier(AccessibilityID.readingImagePlaceholder(index))
            case .failed:
                place
                    .overlay {
                        failure
                    }
                    .accessibilityElement()
                    .accessibilityLabel(image.alternativeText.map { Text(verbatim: $0) } ?? Text("Image not available"))
                    .accessibilityIdentifier(AccessibilityID.readingImageFailed(index))
            }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { shownWidth = $0 }
        .task(id: shownWidth) {
            await load()
        }
        .onDisappear {
            // Off screen the decoded image is let go; its place stays.
            if case .loaded = phase {
                phase = .waiting
            }
        }
    }

    private var label: Text {
        image.alternativeText.map { Text(verbatim: $0) } ?? Text("Image")
    }

    /// The image's place: the surface colour at the image's shape, with a
    /// hairline around it (in light appearance the surface is the page's
    /// colour).
    private var place: some View {
        Theme.surface
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: maximumWidth, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.thumbnail).strokeBorder(Theme.hairline, lineWidth: 1)
            }
    }

    /// The alternative text, or a symbol when there is none.
    @ViewBuilder
    private var failure: some View {
        if let text = image.alternativeText {
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(Theme.Spacing.small)
        } else {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// The size the layout goes by, in pixels: the stored image's once it
    /// has arrived, else what the tag declared.
    private var knownSize: CGSize? {
        if let size = session.sizes[image.url] {
            return size
        }
        return image.declaredSize.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Width over height: the image's, else 3:2.
    private var aspectRatio: Double {
        guard let size = knownSize, size.width > 0, size.height > 0 else { return 1.5 }
        return size.width / size.height
    }

    /// An image is never drawn wider than its pixels.
    private var maximumWidth: Double {
        knownSize.map { Double($0.width) } ?? .infinity
    }

    private func load() async {
        let url = image.url
        if session.undrawn.contains(url) {
            undrawn()
            return
        }
        if session.failed.contains(url) {
            phase = .failed
            return
        }
        guard shownWidth > 0 else { return }
        if case .loaded(let decoded) = phase, abs(decoded.size.width - min(shownWidth, maximumWidth)) < 1 {
            return
        }
        guard let data = await session.loader.image(for: url) else {
            fail(url)
            return
        }
        guard let size = BodyImageLoader.pixelSize(of: data) else {
            fail(url)
            return
        }
        if min(size.width, size.height) < BodyImageLoader.minimumDrawnSide {
            session.markUndrawn(url)
            undrawn()
            return
        }
        let pixelSize = CGSize(width: size.width, height: size.height)
        session.setSize(pixelSize, of: url)
        // The longer side at the width it is shown at.
        let width = min(shownWidth, pixelSize.width)
        let longerSide = width * max(1, pixelSize.height / pixelSize.width) * displayScale
        guard let decoded = await Self.decode(data, maximumPixelSize: Int(longerSide.rounded(.up))), !Task.isCancelled else {
            if !Task.isCancelled {
                fail(url)
            }
            return
        }
        phase = .loaded(UIImage(cgImage: decoded, scale: CGFloat(decoded.width) / width, orientation: .up))
    }

    /// A failure of this opening; a cancelled request is not one.
    private func fail(_ url: URL) {
        guard !Task.isCancelled else { return }
        session.markFailed(url)
        phase = .failed
    }

    @concurrent
    private static func decode(_ data: Data, maximumPixelSize: Int) async -> CGImage? {
        BodyImageLoader.decoded(data, maximumPixelSize: maximumPixelSize)
    }

    /// Opens the viewer on the stored image, decoded at its own size.
    private func open() {
        let url = image.url
        let alternativeText = image.alternativeText
        let loader = session.loader
        Task {
            guard let data = await loader.image(for: url),
                  let decoded = await Self.decode(data, maximumPixelSize: BodyImageLoader.maximumPixelSize)
            else { return }
            view(ViewedImage(image: UIImage(cgImage: decoded), alternativeText: alternativeText))
        }
    }
}
