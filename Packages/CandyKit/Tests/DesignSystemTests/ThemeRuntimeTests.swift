import AppKit
import XCTest
@testable import DesignSystem

/// ThemeRuntime against Chromium: the generated expressions, evaluated natively, must give the colors Chromium
/// resolved for the same inputs (fixtures/theme/theme-runtime-chromium.json, written by scripts/extract-tokens).
@MainActor
final class ThemeRuntimeTests: XCTestCase {
    struct Fixture: Decodable {
        struct Case: Decodable {
            struct Color: Decodable { let srgb: [Double]; let p3: [Double] }
            let roles: [String: String]
            let contrast: Int
            let colors: [String: [Color?]]
        }
        let names: [String]
        let cases: [String: Case]
    }

    static let fixture: Fixture = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/theme/theme-runtime-chromium.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    /// Canvas readback rounds to 4 decimals; color math in a different order adds a little more.
    let tolerance = 0.003

    func assertPalettes(_ palettes: ThemePalettes, match expected: (Int, Int) -> TokenColor?, _ label: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        let ordered = [palettes.light, palettes.dark, palettes.sidebarLight, palettes.sidebarDark]
        var worst = (0.0, "")
        for (ctx, palette) in ordered.enumerated() {
            for (i, got) in palette.members.enumerated() {
                guard let want = expected(i, ctx) else { continue }
                // Fully transparent colors have no meaningful channels.
                if want.srgb.w < 0.001 && got.srgb.w < 0.001 { continue }
                let d = (0..<4).map { max(abs(got.srgb[$0] - want.srgb[$0]), abs(got.displayP3[$0] - want.displayP3[$0])) }.max()!
                if d > worst.0 { worst = (d, "\(Palette.memberNames[i]) context \(ctx): got \(got.srgb) want \(want.srgb)") }
            }
        }
        XCTAssertLessThan(worst.0, tolerance, "\(label): \(worst.1)", file: file, line: line)
    }

    func testStandardExpressionsReproduceTheExtractedTokens() {
        let light = ThemeRuntime.evaluate(nil, contrast: 100, contexts: (0, 2))
        let dark = ThemeRuntime.evaluate(nil, contrast: 100, contexts: (1, 3))
        let evaluated = ThemePalettes(light: light.0, dark: dark.0, sidebarLight: light.1, sidebarDark: dark.1)
        let stock = [Tokens.light, Tokens.dark, Tokens.sidebarLight, Tokens.sidebarDark]
        assertPalettes(evaluated, match: { stock[$1].members[$0] }, "standard at 100%")
    }

    func testStockInputIsTheExtractedTokensExactly() {
        XCTAssertTrue(ThemeRuntime.resolve(ThemeRuntimeInput()).isSame(as: .standard))
    }

    func testBlueOrangeDiffLeavesOtherTokensUnchanged() {
        var input = ThemeRuntimeInput()
        input.blueOrangeDiff = true
        let output = ThemeRuntime.resolve(input)
        for (palette, stock) in [(output.light, Tokens.light), (output.dark, Tokens.dark)] {
            for (i, name) in Palette.memberNames.enumerated() where !name.hasPrefix("--diff-") {
                XCTAssertEqual(palette.members[i], stock.members[i], name)
            }
            XCTAssertNotEqual(palette.diffAddition, stock.diffAddition)
            XCTAssertEqual(palette.diffAddition, palette.diffAdditionForeground)
            XCTAssertEqual(palette.diffDeletion, palette.diffDeletionForeground)
        }
        for (dark, palette) in [(false, output.light), (true, output.dark)] {
            XCTAssertEqual(palette.diffAddedIcon.srgb.w, 0)
            XCTAssertEqual(palette.diffModifiedIcon.srgb.x, palette.mutedForeground.srgb.x)
            XCTAssertEqual(palette.diffModifiedIcon.srgb.w, palette.mutedForeground.srgb.w * (dark ? 0.65 : 1))
        }
        XCTAssertTrue(ThemeRuntime.resolve(.init()).isSame(as: .standard))
    }

    func testChromiumFixtures() {
        for (key, c) in Self.fixture.cases {
            var roles: [ThemeColorRole: String] = [:]
            for role in ThemeColorRole.allCases { if let v = c.roles[role.cssVariable] { roles[role] = v } }
            let half = roles.isEmpty ? nil : ThemeRuntimeHalf(colors: roles)
            let palettes = ThemeRuntime.resolve(ThemeRuntimeInput(light: half, dark: half, contrast: c.contrast))
            assertPalettes(palettes, match: { i, ctx in
                c.colors[Palette.memberNames[i]]?[ctx].map {
                    TokenColor(srgb: SIMD4($0.srgb[0], $0.srgb[1], $0.srgb[2], $0.srgb[3]), displayP3: SIMD4($0.p3[0], $0.p3[1], $0.p3[2], $0.p3[3]))
                }
            }, key)
        }
    }

    func testThemedColorsFollowTheRuntimeAndCacheBetweenChanges() {
        let color = Themed.color(\.background)
        let appearance = NSAppearance(named: .aqua)!
        func srgb() -> NSColor {
            var c = NSColor.clear
            appearance.performAsCurrentDrawingAppearance { c = color.usingColorSpace(.sRGB)! }
            return c
        }
        let before = srgb()
        let red = ThemeRuntimeHalf(colors: Dictionary(uniqueKeysWithValues: ThemeColorRole.allCases.map { ($0, "#ff0000") }))
        ThemeRuntime.apply(ThemeRuntimeInput(light: red))
        defer { ThemeRuntime.apply(ThemeRuntimeInput()) }
        let themed = srgb()
        XCTAssertEqual(themed.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(themed.greenComponent, 0, accuracy: 0.01)
        ThemeRuntime.apply(ThemeRuntimeInput())
        XCTAssertEqual(srgb(), before)
    }

    /// Settings > Appearance > Light from Dark left every unchanged card painted in the old scheme's colors.
    func testAppearanceChangeRepaintsBoxDecorations() {
        let view = DSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let box = BoxDecorationLayer()
        box.host = view
        view.layer?.addSublayer(box)
        box.layout(boxSize: view.bounds.size)
        box.boxStyle.fill = Themed.color(\.card, 0.6)
        box.displayIfNeeded()
        XCTAssertFalse(box.needsDisplay())
        view.viewDidChangeEffectiveAppearance()
        XCTAssertTrue(box.needsDisplay())
    }

    /// 3814's shared editor defaults still use the older canvas/text colors. A theme must use its supplied
    /// role values even when T3's unthemed CSS has moved on (themePalettes.ts:111-236; index.css:1113-1228).
    func testStandardColorsAsAThemeUseTheSharedRoleValues() {
        let roles: [(KeyPath<Palette, TokenColor>, ThemeColorRole)] = [
            (\.sidebar, .sidebar), (\.sidebarForeground, .sidebarForeground),
            (\.background, .canvas), (\.card, .surface), (\.foreground, .text), (\.primary, .messageAction),
        ]
        for appearance in ThemeAppearance.allCases {
            let colors = ThemePalette.standardColors(appearance)
            let half = ThemeRuntimeHalf(colors: colors)
            let palettes = ThemeRuntime.resolve(ThemeRuntimeInput(light: half, dark: half))
            for sidebar in [false, true] {
                let palette = palettes.palette(dark: appearance == .dark, sidebar: sidebar)
                for (key, role) in roles {
                    let expected = ThemeCSSColor.parse(colors[role]!)!.token
                    XCTAssertEqual(palette[keyPath: key], expected, "\(appearance) sidebar=\(sidebar) \(role)")
                }
            }
        }
    }

    func testExpressionParser() {
        let e = ThemeCSSExpression.parse("color-mix(in oklab, color-mix(in oklab, var(--a) var(--p), #000), white 0%)")!
        let c = e.evaluate(colors: ["--a": ThemeCSSColor(srgb: 1, 1, 1)], percents: ["--p": 50])
        // Half white, half black in OKLab: L 0.5.
        XCTAssertEqual(c.lab.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(ThemeCSSColor.parse("#ffffff14")!.alpha, 0x14 / 255, accuracy: 1e-9)
        XCTAssertEqual(ThemeCSSColor.parse("oklch(99.2% 0 0)")!.lab.x, 0.992, accuracy: 1e-9)
        XCTAssertNil(ThemeCSSColor.parse("bogus"))
    }
}
