import NewsPawKit
import SwiftUI
import UIKit

/// The cover (spec N09; ux S7; RD18 decision 12): a window of its own in
/// the scene, above the app's window and above its sheets, alerts and
/// menus, with the background colour and the NewsPaw logo and nothing
/// else. The app model shows it while the adult workspace is shown and the
/// scene is not active, so that the app switcher's picture holds nothing of
/// the adult partition.
///
/// Plain UIKit, so that it is drawn in the same step that shows it.
@MainActor
final class CoverWindow {
    private var window: UIWindow?

    var isShown: Bool {
        window?.isHidden == false
    }

    /// Makes the window, hidden, so that showing it later only unhides it.
    func prepare() {
        guard window == nil, let scene = Self.scene() else { return }
        let window = UIWindow(windowScene: scene)
        // Above alerts, which are above sheets and menus (measured, RD18
        // assumption A1).
        window.windowLevel = .alert + 1
        window.rootViewController = CoverViewController()
        window.isUserInteractionEnabled = true
        window.isHidden = true
        self.window = window
    }

    func show() {
        prepare()
        window?.isHidden = false
    }

    func hide() {
        window?.isHidden = true
    }

    /// The app has one window scene (ux section 2).
    private static func scene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

private final class CoverViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Theme.background)
        let logo = UIImageView(image: UIImage(named: "Logo"))
        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 32
        logo.layer.cornerCurve = .continuous
        logo.clipsToBounds = true
        logo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 160),
            logo.heightAnchor.constraint(equalToConstant: 160),
        ])
        // One element, and nothing under it, for assistive technologies.
        view.accessibilityViewIsModal = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "NewsPaw"
        view.accessibilityIdentifier = AccessibilityID.cover
    }
}
