import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Classic Glass's frost (docs/design.md "Glass"): only classic Glass frosts, its panes thin with the slider, and its
/// text keeps its ratio against the worst base the slider allows.
@MainActor
struct GlassFrostTests {
    @Test func onlyClassicGlassFrosts() {
        let defaults = UserDefaults(suiteName: "cw.glassfrost.tests.\(UUID().uuidString)")!
        let library = ThemeLibrary(defaults: defaults, pinned: nil)
        defaults.set(ThemeDefinition.glass.id, forKey: "theme.preference")
        var (input, _) = library.runtimeInput(client: .defaults)
        #expect(input.frostLight && input.frostDark)
        defaults.set(ThemeDefinition.glassNative.id, forKey: "theme.preference")
        (input, _) = library.runtimeInput(client: .defaults)
        #expect(input.glassLight && !input.frostLight && !input.frostDark)
        // Glass Native's palette is what it was before the frost.
        #expect(ThemeRuntime.resolve(input).isSame(as: {
            var plain = input; plain.frostLight = false; plain.frostDark = false; return ThemeRuntime.resolve(plain)
        }()))
    }

    @Test func textKeepsItsRatioAtEveryOpacity() {
        for dark in [false, true] {
            for opacity in stride(from: 0.1, through: 1.0, by: 0.1) {
                var input = ThemeRuntimeInput(glassOpacity: Int((opacity * 100).rounded()))
                input.glassLight = true; input.glassDark = true; input.frostLight = true; input.frostDark = true
                let palette = ThemeRuntime.resolve(input).palette(dark: dark, sidebar: false)
                let lb = WindowGlass.linear(WindowGlass.frostWorstBackground(palette.background, dark: dark, opacity: opacity))
                func ratio(_ c: TokenColor) -> Double {
                    let l = WindowGlass.luminance(c)
                    return (max(l, lb) + 0.05) / (min(l, lb) + 0.05)
                }
                #expect(ratio(palette.foreground) >= 4.5)
                #expect(ratio(palette.mutedForeground) >= 4.99)
                #expect(ratio(palette.iconMuted) >= 3.29)
                // Panes are see-through, denser as the slider rises, and never thinner than the floor.
                #expect(palette.card.srgb.w < 1 && palette.card.srgb.w >= 0.35)
                #expect(palette.codeBackground.srgb.w > palette.card.srgb.w)
            }
        }
        #expect(WindowGlass.frostBaseAlpha(opacity: 0.1) < WindowGlass.frostBaseAlpha(opacity: 0.8))
        #expect(WindowGlass.frostBaseAlpha(opacity: 1) > 0.96)
    }

    @Test func lightFillsBecomeOverlaysOfTheSameColor() {
        let stock = Tokens.light
        let overlay = WindowGlass.overlay(stock.accent, over: stock.background)
        // Black at alpha over the stock background paints the stock accent again.
        let b = (stock.background.srgb.x + stock.background.srgb.y + stock.background.srgb.z) / 3
        let a = (stock.accent.srgb.x + stock.accent.srgb.y + stock.accent.srgb.z) / 3
        #expect(overlay.srgb.x == 0 && abs(b * (1 - overlay.srgb.w) - a) < 1e-9)
    }
}
