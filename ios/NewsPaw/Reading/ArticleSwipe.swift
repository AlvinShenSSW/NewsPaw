import SwiftUI
import UIKit

/// A swipe on the reading screen that opens the next or the previous
/// article (RD11 decision 11).
///
/// A UIKit swipe recogniser, not a SwiftUI drag gesture: measured with
/// animations on (assumption A4), a simultaneous `DragGesture` on the
/// reading screen's scroll view took the system's back swipe from the
/// middle of a pushed screen and the scrolling of a code block, while this
/// recogniser left vertical scrolling, the back swipe and the code block as
/// they are without it. It recognises together with every other recogniser,
/// and does not take a touch that starts in a box that scrolls sideways.
struct ArticleSwipe: UIGestureRecognizerRepresentable {
    let direction: UISwipeGestureRecognizer.Direction
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let recognizer = UISwipeGestureRecognizer()
        recognizer.direction = direction
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        recognizer.direction = direction
    }

    func handleUIGestureRecognizerAction(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        if recognizer.state == .ended {
            action()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// A touch inside a scroll view wider than its bounds scrolls that
        /// view: a code block.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view, current !== gestureRecognizer.view {
                if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
                    return false
                }
                view = current.superview
            }
            return true
        }
    }
}

extension View {
    /// The reading screen's swipes: towards the leading edge for the next
    /// article and, where the system has no back swipe (the reading pane),
    /// towards the trailing edge for the previous one.
    @ViewBuilder
    func articleSwipes(layoutDirection: LayoutDirection, next: @escaping () -> Void, previous: (() -> Void)?) -> some View {
        let towardsLeading: UISwipeGestureRecognizer.Direction = layoutDirection == .rightToLeft ? .right : .left
        let towardsTrailing: UISwipeGestureRecognizer.Direction = layoutDirection == .rightToLeft ? .left : .right
        if let previous {
            gesture(ArticleSwipe(direction: towardsLeading, action: next))
                .gesture(ArticleSwipe(direction: towardsTrailing, action: previous))
        } else {
            gesture(ArticleSwipe(direction: towardsLeading, action: next))
        }
    }
}
