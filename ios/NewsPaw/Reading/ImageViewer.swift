import SwiftUI
import UIKit

/// The full-screen viewer of a body image (ux S4; RD11 decision 9): the
/// image on black in a system scroll view for zoom and pan, with Close.
struct ImageViewer: View {
    let image: ViewedImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ZoomableImage(image: image.image, label: image.alternativeText ?? String(localized: "Image"))
                .ignoresSafeArea()
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(Theme.Spacing.standard)
            .accessibilityIdentifier(AccessibilityID.imageViewerCloseButton)
        }
        .accessibilityAction(.escape) { dismiss() }
        .statusBarHidden()
    }
}

/// The image in a `UIScrollView`: pinch to zoom, drag to pan, double tap
/// to zoom in and back.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let label: String

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView(image: image)
        view.imageView.accessibilityLabel = label
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.imageView.accessibilityLabel = label
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView: UIImageView

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityIdentifier = AccessibilityID.imageViewerImage
        addSubview(imageView)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // At rest the image fills the view; zoomed, the scroll view owns
        // its frame.
        if zoomScale == minimumZoomScale, imageView.frame.size != bounds.size {
            imageView.frame = bounds
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let side = bounds.width / 2.5
            zoom(to: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side * bounds.height / max(bounds.width, 1)), animated: true)
        }
    }
}
