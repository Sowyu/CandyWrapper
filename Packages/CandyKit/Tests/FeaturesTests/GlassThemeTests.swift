import Foundation
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// CandyWrapper's Glass theme: a picker card that keeps T3's stock palette and only frosts the window.
@MainActor
struct GlassThemeTests {
    @Test func glassKeepsTheStockPaletteAndFrostsEachSideItOwns() {
        let glass = ThemeDefinition.glass
        #expect(ThemeDefinition.pickerBuiltIns.last { !$0.isGlassNative } == glass)
        #expect(ThemePalette.reservedIds.contains(glass.id))
        #expect(ThemeCardDefinition(glass).previews == ThemeCardDefinition.standard.previews)

        let defaults = UserDefaults(suiteName: "cw.glass.tests.\(UUID().uuidString)")!
        let library = ThemeLibrary(defaults: defaults)
        defaults.set(glass.id, forKey: "theme.preference")
        let (input, forced) = library.runtimeInput(client: .defaults)
        #expect(input.glassLight && input.glassDark)
        #expect(input.light == nil && input.dark == nil)
        #expect(forced == "system")
        // Glass only moves muted text to stay readable over the frost; the rest is the stock palette.
        let stock = ThemeRuntime.resolve(ThemeRuntimeInput()), glassy = ThemeRuntime.resolve(input)
        #expect(glassy.dark.mutedForeground.srgb.x > stock.dark.mutedForeground.srgb.x)
        #expect(glassy.light.mutedForeground.srgb.x < stock.light.mutedForeground.srgb.x)
        #expect(glassy.dark.foreground == stock.dark.foreground && glassy.light.background == stock.light.background)

        // A mix: Ocean in light, Glass in dark frosts only the dark side.
        defaults.set(try! JSONSerialization.data(withJSONObject: ["light": "ocean"]), forKey: "theme.halves.v1")
        let (mixed, _) = library.runtimeInput(client: .defaults)
        #expect(!mixed.glassLight && mixed.glassDark)
        #expect(mixed.light?.builtInId == "ocean")
    }
}
