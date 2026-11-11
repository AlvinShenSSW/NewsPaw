import NewsPawKit
import Testing

@Suite("Palette")
struct PaletteTests {
    @Test("the contrast ratio matches the WCAG reference values")
    func contrastReference() {
        let white = PaletteColor(hex: 0xFFFFFF)
        let black = PaletteColor(hex: 0x000000)
        #expect(abs(PaletteColor.contrastRatio(white, black) - 21) < 0.001)
        #expect(PaletteColor.contrastRatio(white, white) == 1)
        // #777777 on white is the textbook 4.48:1.
        #expect(abs(PaletteColor.contrastRatio(PaletteColor(hex: 0x777777), white) - 4.48) < 0.01)
        #expect(PaletteColor.contrastRatio(black, white) == PaletteColor.contrastRatio(white, black))
    }

    @Test("every text and accent token reaches 4.5:1 on each background it is used on, in light and dark")
    func textContrast() {
        #expect(Palette.textPairings.count == 4 * 3 + 2)
        for pairing in Palette.textPairings {
            let light = PaletteColor.contrastRatio(pairing.foreground.light, pairing.background.light)
            let dark = PaletteColor.contrastRatio(pairing.foreground.dark, pairing.background.dark)
            #expect(light >= Palette.minimumTextContrast, "\(pairing.foreground.name) on \(pairing.background.name), light: \(light)")
            #expect(dark >= Palette.minimumTextContrast, "\(pairing.foreground.name) on \(pairing.background.name), dark: \(dark)")
        }
    }

    @Test("the on-accent token is paired with the accent, and white on the dark accent would fail")
    func onAccent() {
        #expect(Palette.textPairings.contains { $0.foreground == Palette.onAccent && $0.background == Palette.accent })
        let whiteOnDarkAccent = PaletteColor.contrastRatio(PaletteColor(hex: 0xFFFFFF), Palette.accent.dark)
        #expect(whiteOnDarkAccent < Palette.minimumTextContrast)
    }

    @Test("the tokens hold the values of ux section 5")
    func values() {
        #expect(Palette.background == token(0xFFFFFF, 0x121211))
        #expect(Palette.groupedBackground == token(0xF5F4F1, 0x121211))
        #expect(Palette.surface == token(0xFFFFFF, 0x1D1D1B))
        #expect(Palette.hairline == token(0xE3E1DC, 0x32322F))
        #expect(Palette.text == token(0x1B1B19, 0xF1F0EC))
        #expect(Palette.secondaryText == token(0x5E5D58, 0xA6A59E))
        #expect(Palette.accent == token(0xB4401F, 0xF0875F))
        #expect(Palette.adultAccent == token(0x7A3E9D, 0xC99AE6))
    }

    private func token(_ light: UInt32, _ dark: UInt32) -> PaletteToken? {
        let candidates = [
            Palette.background, Palette.groupedBackground, Palette.surface, Palette.hairline,
            Palette.text, Palette.secondaryText, Palette.accent, Palette.adultAccent, Palette.onAccent,
        ]
        return candidates.first { $0.light == PaletteColor(hex: light) && $0.dark == PaletteColor(hex: dark) }
    }
}
