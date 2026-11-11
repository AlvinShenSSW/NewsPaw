import NewsPawKit
import SwiftUI
import UIKit

extension Color {
    /// A colour that takes the token's light or dark value with the
    /// interface style. The token in `Palette` is the only definition.
    init(_ token: PaletteToken) {
        self.init(uiColor: UIColor { traits in
            let color = traits.userInterfaceStyle == .dark ? token.dark : token.light
            return UIColor(
                red: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: 1
            )
        })
    }
}

/// The app's visual tokens (ux section 5), defined once.
enum Theme {
    static let background = Color(Palette.background)
    static let groupedBackground = Color(Palette.groupedBackground)
    static let surface = Color(Palette.surface)
    static let hairline = Color(Palette.hairline)
    static let text = Color(Palette.text)
    static let secondaryText = Color(Palette.secondaryText)
    static let accent = Color(Palette.accent)
    static let onAccent = Color(Palette.onAccent)
    /// The layer the slide-over sidebar dims the content with.
    static let scrim = Color.black.opacity(0.35)

    /// Spacing on a 4 pt grid.
    enum Spacing {
        static let tight = 4.0
        static let small = 8.0
        static let medium = 12.0
        /// Side margins on iPhone.
        static let standard = 16.0
        static let large = 24.0
    }

    enum Radius {
        static let card = 12.0
        static let thumbnail = 8.0
    }

    /// Type sizes at the default Dynamic Type size; each scales with it.
    enum TypeSize {
        /// Reading text: `.body`, 17 pt at the default size.
        static let reading = Font.TextStyle.body
    }

    /// The smallest tap target (ux section 6).
    static let minimumTapTarget = 44.0
}

extension View {
    /// Paints the enclosing navigation stack's own background with a palette
    /// colour, so the colour reaches every edge of the stack. A view's own
    /// background is not enough: after the software keyboard has been shown,
    /// a stack created after a rotation ends its content 20 pt above the
    /// bottom and its default background shows there (RD03 F1).
    func stackBackground(_ color: Color) -> some View {
        containerBackground(color, for: .navigation)
    }
}
