import XCTest
@testable import DesignSystem

/// Ports of T3's themePalette.test.ts cases for the theme file format, canonical colors and the editor's
/// palette engines.
final class ThemePaletteTests: XCTestCase {
    func asHex(_ v: String?) -> String { String(ThemePalette.hex(v!)!.prefix(7)) }

    func contrast(_ a: String?, _ b: String?) -> Double {
        func rgb(_ h: String) -> ThemePalette.RGB {
            let n = Int(h.dropFirst(), radix: 16)!
            return .init(Double(n >> 16 & 255), Double(n >> 8 & 255), Double(n & 255))
        }
        return ThemePalette.contrast(rgb(asHex(a)), rgb(asHex(b)))
    }

    /// Destructive buttons keep T3's white label on the stock reds and switch to dark text on a pale theme fill.
    func testTextOnDestructiveFill() {
        XCTAssertTrue(Themed.readsWhite(on: Tokens.light.destructive))
        XCTAssertTrue(Themed.readsWhite(on: Tokens.dark.destructive))
        XCTAssertFalse(Themed.readsWhite(on: TokenColor(srgb: SIMD4(0.97, 0.80, 0.82, 1), displayP3: SIMD4(0.97, 0.80, 0.82, 1))))
    }

    func testBuiltInsAreCanonical() {
        for theme in ThemeDefinition.builtIns {
            for colors in [theme.colors] + theme.variants.values {
                for value in colors.values { XCTAssertEqual(ThemePalette.canonical(value), value) }
            }
            XCTAssertEqual(theme.modes, [.light, .dark])
            XCTAssertTrue(theme.sidebarArtwork)
        }
        XCTAssertEqual(ThemeColorRole.allCases.count, 61)
        XCTAssertEqual(ThemeColorRole.terminalSelection.cssVariable, "--app-theme-terminal-selection-background")
        XCTAssertEqual(ThemeColorRole.sidebarRowHover.cssVariable, "--app-theme-sidebar-row-hover")
    }

    func testVividPalettesFromExactSeeds() {
        let seeds: [(ThemeAppearance, String, String)] = [(.light, "#f4f9f2", "#1d8a4e"), (.dark, "#101a2c", "#4f8fe8"), (.dark, "#211a23", "#df5398"),
                                                          (.light, "#fdf6ec", "#c2571b"), (.light, "#111827", "#8ab4f8"), (.dark, "#f5ecf5", "#a84370")]
        for (appearance, canvas, accent) in seeds {
            let c = ThemePalette.vividColors(appearance, background: canvas, accent: accent)
            XCTAssertTrue(c[.canvas]!.hasPrefix("oklch("))
            XCTAssertEqual(asHex(c[.canvas]), canvas)
            XCTAssertEqual(asHex(c[.accent]), accent)
            XCTAssertGreaterThanOrEqual(contrast(c[.text], c[.canvas]), 7)
            XCTAssertGreaterThanOrEqual(contrast(c[.textMuted], c[.canvas]), 4.5)
            XCTAssertLessThan(contrast(c[.textMuted], c[.canvas]), 5.5)
            XCTAssertGreaterThanOrEqual(contrast(c[.mutedForeground], c[.muted]), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(c[.placeholder], c[.surfaceRaised]), 4.5)
            XCTAssertEqual(c[.secondaryLabel], c[.textMuted])
            XCTAssertGreaterThanOrEqual(contrast(c[.accentForeground], c[.accent]), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(c[.messageActionForeground], c[.messageAction]), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(c[.messageForeground], c[.messageSurface]), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(c[.sidebarForeground], c[.sidebar]), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(c[.errorForeground], c[.errorSurface]), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(c[.warningForeground], c[.warningSurface]), 4.5)
            XCTAssertNotEqual(c[.messageAction], c[.accent])
            XCTAssertEqual(asHex(c[.update]), accent)
            XCTAssertEqual(c.count, ThemeColorRole.allCases.count)
        }
    }

    func testSmallFileMergesOntoTheBase() throws {
        let theme = try ThemePalette.parseFile(["version": 1, "name": "Ocean dusk", "appearance": "dark",
                                                "colors": ["canvas": "#07152f", "accent": "#67c2ff"]])
        XCTAssertEqual(theme.id, "ocean-dusk")
        XCTAssertEqual(theme.colors[.canvas], ThemePalette.canonical("#07152f"))
        XCTAssertEqual(theme.colors[.placeholder], ThemePalette.canonical("#968d9f"))
    }

    func testLiteralFormatsKeepAlpha() throws {
        let theme = try ThemePalette.parseFile(["version": 1, "name": "Translucent", "appearance": "light", "colors": [
            "canvas": "oklch(62% 0.2 280deg / 50%)", "accent": "#abcd", "focus": "rgb(10 20 30 / 50%)", "error": "hsl(350 80% 50%)",
            "sidebar": "oklab(0.6 0.1 -0.1)", "terminalScrollbar": "transparent", "terminalScrollbarHover": "rgb(10 20 30 / none)"]])
        XCTAssertEqual(theme.colors[.canvas], "oklch(0.62 0.2 280 / 0.5)")
        XCTAssertEqual(ThemePalette.hex(theme.colors[.accent]!), "#aabbccdd")
        XCTAssertEqual(ThemePalette.hex(theme.colors[.focus]!), "#0a141e80")
        XCTAssertEqual(theme.colors[.terminalScrollbar], "oklch(0 0 0 / 0)")
        XCTAssertEqual(ThemePalette.hex(theme.colors[.terminalScrollbarHover]!), "#0a141e00")
    }

    func testExtremeChromaIsGamutMapped() throws {
        let theme = try ThemePalette.parseFile(["version": 1, "name": "Extreme chroma", "appearance": "light", "colors": ["accent": "oklch(0.5 1e303 0)"]])
        XCTAssertEqual(theme.colors[.accent], "oklch(0.5 1e+303 0)")
        XCTAssertEqual(ThemePalette.hex(theme.colors[.accent]!), "#b5005e")
    }

    func testRejectsBadFiles() {
        func message(_ v: [String: Any]) -> String? {
            do { _ = try ThemePalette.parseFile(v); return nil } catch { return (error as? ThemePalette.FileError)?.message }
        }
        XCTAssertEqual(message(["version": 1, "name": "X", "appearance": "light", "colors": ["nope": "#fff"]]), "\"nope\" is not a supported theme color role.")
        XCTAssertEqual(message(["version": 1, "name": "X", "appearance": "light", "colors": ["canvas": "var(--x)"]]),
                       "The color for \"canvas\" must be a literal CSS color such as oklch(0.62 0.2 280).")
        XCTAssertEqual(message(["version": 2, "name": "X", "appearance": "light", "colors": [:]]), "This theme file uses an unsupported version. Expected 1.")
        XCTAssertEqual(message(["version": 1, "id": "grove", "name": "X", "appearance": "light", "colors": ["canvas": "#fff"]]), "The theme id \"grove\" is reserved.")
        XCTAssertEqual(message(["version": 1, "name": "X", "appearance": "light", "colors": ["canvas": "#fff"], "variants": ["light": ["canvas": "#fff"]]]),
                       "Theme variants must not repeat the base appearance \"light\".")
    }

    func testExportRoundTrips() throws {
        var theme = try ThemePalette.parseFile(["version": 1, "id": "community-demo", "name": "Community Demo", "appearance": "dark",
                                                "colors": ["canvas": "#111111"], "variants": ["light": ["canvas": "#fafafa"]]])
        theme.collection = .init(id: "open-vsx:demo.theme", label: "Demo Theme")
        theme.managed = true
        let text = ThemePalette.serializeFile(theme)
        XCTAssertTrue(text.hasPrefix("{\n  \"version\": 1,\n  \"id\": \"community-demo\",\n  \"name\": \"Community Demo\",\n  \"appearance\": \"dark\",\n  \"colors\": {\n    \"canvas\": \"oklch("))
        let back = try ThemePalette.parseFile(JSONSerialization.jsonObject(with: Data(text.utf8)))
        XCTAssertEqual(back, theme)
    }

    func testAdvancedFamilyUpdateKeepsOtherRoles() {
        let base = ThemePalette.standardColors(.light)
        let updated = ThemePalette.updateFamily(.light, base, role: .accent, value: "#e11d48")
        XCTAssertEqual(asHex(updated[.accent]), "#e11d48")
        XCTAssertEqual(updated[.focus], updated[.accent])
        XCTAssertEqual(updated[.terminalCursor], updated[.accent])
        XCTAssertEqual(updated[.canvas], base[.canvas])
        XCTAssertGreaterThanOrEqual(contrast(updated[.accentForeground], updated[.accent]), 4.5)
        let canvas = ThemePalette.updateFamily(.light, base, role: .canvas, value: "#123456")
        XCTAssertEqual(canvas[.chrome], canvas[.canvas])
        XCTAssertEqual(canvas[.toolbar], canvas[.canvas])
    }

    func testIdsAndNumbers() {
        XCTAssertEqual(ThemePalette.themeId(fromName: "  My Theme!! 2 "), "my-theme-2")
        XCTAssertEqual(ThemePalette.themeId(fromName: "!!!"), "custom-theme")
        XCTAssertEqual(ThemePalette.format(1.0, 6), "1")
        XCTAssertEqual(ThemePalette.format(0.5, 6), "0.5")
        XCTAssertEqual(ThemePalette.format(-0.0000001, 6), "0")
    }
}
