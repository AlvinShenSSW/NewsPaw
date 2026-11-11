import Foundation

/// An opaque sRGB colour of the palette.
public struct PaletteColor: Sendable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    /// A colour from its `0xRRGGBB` value.
    public init(hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    /// The relative luminance defined by WCAG 2.
    public var relativeLuminance: Double {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG 2 contrast ratio of two colours, from 1 to 21; the order of
    /// the arguments does not matter.
    public static func contrastRatio(_ first: PaletteColor, _ second: PaletteColor) -> Double {
        let lighter = max(first.relativeLuminance, second.relativeLuminance)
        let darker = min(first.relativeLuminance, second.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// One token of the palette: its value in light and in dark appearance.
public struct PaletteToken: Sendable, Hashable {
    /// The token's name, for test messages.
    public let name: String
    public let light: PaletteColor
    public let dark: PaletteColor

    init(_ name: String, light: UInt32, dark: UInt32) {
        self.name = name
        self.light = PaletteColor(hex: light)
        self.dark = PaletteColor(hex: dark)
    }
}

/// The colour tokens of ux section 5: the only definition of the app's
/// colours. The app builds its dynamic colours from these values, so the
/// values tested here are the values shown.
public enum Palette {
    /// Lists and the reading screen.
    public static let background = PaletteToken("background", light: 0xFFFFFF, dark: 0x121211)
    /// Today and Settings.
    public static let groupedBackground = PaletteToken("groupedBackground", light: 0xF5F4F1, dark: 0x121211)
    /// Cards and grouped rows.
    public static let surface = PaletteToken("surface", light: 0xFFFFFF, dark: 0x1D1D1B)
    /// Separators and card borders.
    public static let hairline = PaletteToken("hairline", light: 0xE3E1DC, dark: 0x32322F)
    /// Titles and body text.
    public static let text = PaletteToken("text", light: 0x1B1B19, dark: 0xF1F0EC)
    /// Original titles and metadata.
    public static let secondaryText = PaletteToken("secondaryText", light: 0x5E5D58, dark: 0xA6A59E)
    /// The accent of the normal partition: unread dot, links, selected
    /// controls.
    public static let accent = PaletteToken("accent", light: 0xB4401F, dark: 0xF0875F)
    /// The accent of the adult partition, in the same roles. Not used by the
    /// interface until the partition switch exists.
    public static let adultAccent = PaletteToken("adultAccent", light: 0x7A3E9D, dark: 0xC99AE6)
    /// A label on a control filled with an accent. White on the dark accent
    /// would be 2.5:1, so dark appearance uses the dark ink.
    public static let onAccent = PaletteToken("onAccent", light: 0xFFFFFF, dark: 0x121211)

    /// The backgrounds that text and accents are drawn on.
    public static let backgrounds = [background, groupedBackground, surface]

    /// Every pairing of a text or accent token with a background it is used
    /// on, and of the on-accent token with each accent. Each must reach
    /// `minimumTextContrast` in light and in dark appearance.
    public static let textPairings: [(foreground: PaletteToken, background: PaletteToken)] =
        [text, secondaryText, accent, adultAccent].flatMap { foreground in
            backgrounds.map { (foreground: foreground, background: $0) }
        }
        + [accent, adultAccent].map { (foreground: onAccent, background: $0) }

    /// The contrast ux section 5 requires of text and accent colours.
    public static let minimumTextContrast = 4.5
}
