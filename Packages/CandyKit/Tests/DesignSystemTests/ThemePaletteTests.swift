import Foundation
import Testing
@testable import DesignSystem

/// Ports of T3's themePalette.test.ts cases for the theme file format, canonical colors and the editor's
/// palette engines.
@Suite struct ThemePaletteTests {
    func asHex(_ v: String?) -> String { String(ThemePalette.hex(v!)!.prefix(7)) }

    func contrast(_ a: String?, _ b: String?) -> Double {
        func rgb(_ h: String) -> ThemePalette.RGB {
            let n = Int(h.dropFirst(), radix: 16)!
            return .init(Double(n >> 16 & 255), Double(n >> 8 & 255), Double(n & 255))
        }
        return ThemePalette.contrast(rgb(asHex(a)), rgb(asHex(b)))
    }

    /// Destructive buttons keep T3's white label on the stock reds and switch to dark text on a pale theme fill.
    @Test func textOnDestructiveFill() {
        #expect(Themed.readsWhite(on: Tokens.light.destructive))
        #expect(Themed.readsWhite(on: Tokens.dark.destructive))
        #expect(!Themed.readsWhite(on: TokenColor(srgb: SIMD4(0.97, 0.80, 0.82, 1), displayP3: SIMD4(0.97, 0.80, 0.82, 1))))
    }

    @Test func builtInsAreCanonical() {
        for theme in ThemeDefinition.builtIns {
            for colors in [theme.colors] + theme.variants.values {
                for value in colors.values { #expect(ThemePalette.canonical(value) == value) }
            }
            #expect(theme.modes == [.light, .dark])
            #expect(theme.sidebarArtwork)
        }
        #expect(ThemeColorRole.allCases.count == 61)
        #expect(ThemeColorRole.terminalSelection.cssVariable == "--app-theme-terminal-selection-background")
        #expect(ThemeColorRole.sidebarRowHover.cssVariable == "--app-theme-sidebar-row-hover")
    }

    @Test func vividPalettesFromExactSeeds() {
        let seeds: [(ThemeAppearance, String, String)] = [(.light, "#f4f9f2", "#1d8a4e"), (.dark, "#101a2c", "#4f8fe8"), (.dark, "#211a23", "#df5398"),
                                                          (.light, "#fdf6ec", "#c2571b"), (.light, "#111827", "#8ab4f8"), (.dark, "#f5ecf5", "#a84370")]
        for (appearance, canvas, accent) in seeds {
            let c = ThemePalette.vividColors(appearance, background: canvas, accent: accent)
            #expect(c[.canvas]!.hasPrefix("oklch("))
            #expect(asHex(c[.canvas]) == canvas)
            #expect(asHex(c[.accent]) == accent)
            #expect(contrast(c[.text], c[.canvas]) >= 7)
            #expect(contrast(c[.textMuted], c[.canvas]) >= 4.5)
            #expect(contrast(c[.textMuted], c[.canvas]) < 5.5)
            #expect(contrast(c[.mutedForeground], c[.muted]) >= 4.5)
            #expect(contrast(c[.placeholder], c[.surfaceRaised]) >= 4.5)
            #expect(c[.secondaryLabel] == c[.textMuted])
            #expect(contrast(c[.accentForeground], c[.accent]) >= 4.5)
            #expect(contrast(c[.messageActionForeground], c[.messageAction]) >= 4.5)
            #expect(contrast(c[.messageForeground], c[.messageSurface]) >= 4.5)
            #expect(contrast(c[.sidebarForeground], c[.sidebar]) >= 4.5)
            #expect(contrast(c[.errorForeground], c[.errorSurface]) >= 4.5)
            #expect(contrast(c[.warningForeground], c[.warningSurface]) >= 4.5)
            #expect(c[.messageAction] != c[.accent])
            #expect(asHex(c[.update]) == accent)
            #expect(c.count == ThemeColorRole.allCases.count)
        }
    }

    @Test func smallFileMergesOntoTheBase() throws {
        let theme = try ThemePalette.parseFile(["version": 1, "name": "Ocean dusk", "appearance": "dark",
                                                "colors": ["canvas": "#07152f", "accent": "#67c2ff"]])
        #expect(theme.id == "ocean-dusk")
        #expect(theme.colors[.canvas] == ThemePalette.canonical("#07152f"))
        #expect(theme.colors[.placeholder] == ThemePalette.canonical("#968d9f"))
    }

    @Test func literalFormatsKeepAlpha() throws {
        let theme = try ThemePalette.parseFile(["version": 1, "name": "Translucent", "appearance": "light", "colors": [
            "canvas": "oklch(62% 0.2 280deg / 50%)", "accent": "#abcd", "focus": "rgb(10 20 30 / 50%)", "error": "hsl(350 80% 50%)",
            "sidebar": "oklab(0.6 0.1 -0.1)", "terminalScrollbar": "transparent", "terminalScrollbarHover": "rgb(10 20 30 / none)"]])
        #expect(theme.colors[.canvas] == "oklch(0.62 0.2 280 / 0.5)")
        #expect(ThemePalette.hex(theme.colors[.accent]!) == "#aabbccdd")
        #expect(ThemePalette.hex(theme.colors[.focus]!) == "#0a141e80")
        #expect(theme.colors[.terminalScrollbar] == "oklch(0 0 0 / 0)")
        #expect(ThemePalette.hex(theme.colors[.terminalScrollbarHover]!) == "#0a141e00")
    }

    @Test func extremeChromaIsGamutMapped() throws {
        let theme = try ThemePalette.parseFile(["version": 1, "name": "Extreme chroma", "appearance": "light", "colors": ["accent": "oklch(0.5 1e303 0)"]])
        #expect(theme.colors[.accent] == "oklch(0.5 1e+303 0)")
        #expect(ThemePalette.hex(theme.colors[.accent]!) == "#b5005e")
    }

    @Test func rejectsBadFiles() {
        func message(_ v: [String: Any]) -> String? {
            do { _ = try ThemePalette.parseFile(v); return nil } catch { return (error as? ThemePalette.FileError)?.message }
        }
        #expect(message(["version": 1, "name": "X", "appearance": "light", "colors": ["nope": "#fff"]]) == "\"nope\" is not a supported theme color role.")
        #expect(message(["version": 1, "name": "X", "appearance": "light", "colors": ["canvas": "var(--x)"]]) == "The color for \"canvas\" must be a literal CSS color such as oklch(0.62 0.2 280).")
        #expect(message(["version": 2, "name": "X", "appearance": "light", "colors": [:]]) == "This theme file uses an unsupported version. Expected 1.")
        #expect(message(["version": 1, "id": "grove", "name": "X", "appearance": "light", "colors": ["canvas": "#fff"]]) == "The theme id \"grove\" is reserved.")
        #expect(message(["version": 1, "name": "X", "appearance": "light", "colors": ["canvas": "#fff"], "variants": ["light": ["canvas": "#fff"]]]) == "Theme variants must not repeat the base appearance \"light\".")
    }

    @Test func exportRoundTrips() throws {
        var theme = try ThemePalette.parseFile(["version": 1, "id": "community-demo", "name": "Community Demo", "appearance": "dark",
                                                "colors": ["canvas": "#111111"], "variants": ["light": ["canvas": "#fafafa"]]])
        theme.collection = .init(id: "open-vsx:demo.theme", label: "Demo Theme")
        theme.managed = true
        let text = ThemePalette.serializeFile(theme)
        #expect(text.hasPrefix("{\n  \"version\": 1,\n  \"id\": \"community-demo\",\n  \"name\": \"Community Demo\",\n  \"appearance\": \"dark\",\n  \"colors\": {\n    \"canvas\": \"oklch("))
        let back = try ThemePalette.parseFile(JSONSerialization.jsonObject(with: Data(text.utf8)))
        #expect(back == theme)
    }

    @Test func advancedFamilyUpdateKeepsOtherRoles() {
        let base = ThemePalette.standardColors(.light)
        let updated = ThemePalette.updateFamily(.light, base, role: .accent, value: "#e11d48")
        #expect(asHex(updated[.accent]) == "#e11d48")
        #expect(updated[.focus] == updated[.accent])
        #expect(updated[.terminalCursor] == updated[.accent])
        #expect(updated[.canvas] == base[.canvas])
        #expect(contrast(updated[.accentForeground], updated[.accent]) >= 4.5)
        let canvas = ThemePalette.updateFamily(.light, base, role: .canvas, value: "#123456")
        #expect(canvas[.chrome] == canvas[.canvas])
        #expect(canvas[.toolbar] == canvas[.canvas])
    }

    @Test func idsAndNumbers() {
        #expect(ThemePalette.themeId(fromName: "  My Theme!! 2 ") == "my-theme-2")
        #expect(ThemePalette.themeId(fromName: "!!!") == "custom-theme")
        #expect(ThemePalette.format(1.0, 6) == "1")
        #expect(ThemePalette.format(0.5, 6) == "0.5")
        #expect(ThemePalette.format(-0.0000001, 6) == "0")
    }
}
