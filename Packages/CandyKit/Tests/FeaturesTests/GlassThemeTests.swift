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
        #expect(ThemeDefinition.pickerBuiltIns.suffix(2) == [glass, ThemeDefinition.dither])
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

    /// Dither keeps the stock palette and solid surfaces, and names its picture (nil for the desktop picture).
    @Test func ditherFrostsAndNamesItsPicture() {
        let dither = ThemeDefinition.dither
        #expect(ThemePalette.reservedIds.contains(dither.id))
        #expect(ThemeCardDefinition(dither).previews == ThemeCardDefinition.standard.previews)
        let defaults = UserDefaults(suiteName: "cw.dither.tests.\(UUID().uuidString)")!
        defaults.set(dither.id, forKey: "theme.preference")
        let (input, _) = ThemeLibrary(defaults: defaults).runtimeInput(client: .defaults)
        #expect(!input.glassLight && !input.glassDark && input.ditherLight && input.ditherDark)
        #expect(input.light == nil && input.dark == nil)
        #expect(input.ditherPicture == DitherPicture.path)
        defaults.set(ThemeDefinition.glass.id, forKey: "theme.preference")
        let (glass, _) = ThemeLibrary(defaults: defaults).runtimeInput(client: .defaults)
        #expect(glass.glassDark && !glass.ditherDark && glass.ditherPicture == nil)
    }

    /// Glass Native was removed on 2026-10-14 (docs/decisions.md): a stored choice of it, as the theme or one side of
    /// a light and dark mix, reads as Glass, and its id stays reserved.
    @Test func storedGlassNativeReadsAsGlass() {
        let native = "candywrapper-glass-native", glass = ThemeDefinition.glass.id
        #expect(ThemePalette.reservedIds.contains(native))
        #expect(!ThemeDefinition.pickerBuiltIns.contains { $0.id == native })
        #expect(ThemePalette.normalizedId(native) == glass)

        let defaults = UserDefaults(suiteName: "cw.glass.tests.\(UUID().uuidString)")!
        let library = ThemeLibrary(defaults: defaults, pinned: nil)
        defaults.set(native, forKey: "theme.preference")
        defaults.set("dark", forKey: ThemeLibrary.appearanceModeKey)
        #expect(library.preference == glass)
        #expect(library.definition(native)?.id == glass)
        let (input, _) = library.runtimeInput(client: .defaults)
        #expect(input.glassLight && input.glassDark)

        // One side of a mix: Ocean in light, Glass Native in dark.
        defaults.set(try! JSONSerialization.data(withJSONObject: ["light": "ocean", "dark": native]), forKey: "theme.halves.v1")
        #expect(library.halves.light == "ocean" && library.halves.dark == glass)
        let (mixed, _) = library.runtimeInput(client: .defaults)
        #expect(!mixed.glassLight && mixed.glassDark && mixed.light?.builtInId == "ocean")
        // The stored values stay as they were, so nothing else the user set is touched.
        #expect(defaults.string(forKey: "theme.preference") == native)
        #expect(defaults.string(forKey: ThemeLibrary.appearanceModeKey) == "dark")
    }
}
