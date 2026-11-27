import Foundation
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign light keeps WCAG AA on its plain ground and sidebar.
@MainActor
struct RedesignLightContrastTests {
    private func ratio(_ a: TokenColor, _ b: TokenColor) -> Double {
        let la = WindowGlass.luminance(a), lb = WindowGlass.luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    private func gray(_ v: Double) -> TokenColor { TokenColor(srgb: SIMD4(v, v, v, 1), displayP3: SIMD4(v, v, v, 1)) }

    @Test func mutedTextIconsAndEdgesReadOnTheGround() {
        var input = ThemeRuntimeInput()
        input.ditherLight = true
        input.light = ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!)
        let palettes = ThemeRuntime.resolve(input)
        let ground = palettes.light.background
        for p in [palettes.light, palettes.sidebarLight] {
            for c in [p.foreground, p.mutedForeground, p.secondaryLabel, p.placeholder, p.sidebarMutedForeground, p.infoForeground,
                      p.warningForeground, p.destructiveForeground] {
                #expect(ratio(c, ground) >= 4.5)
                #expect(ratio(c, palettes.sidebarLight.sidebar) >= 4.5)
            }
            for c in [p.iconMuted, p.sidebarIconColor, p.ring] { #expect(ratio(c, ground) >= 3) }
            #expect(ratio(.white, p.primary) >= 4.5)
        }
        #expect(ratio(gray(0x85 / 255), palettes.sidebarLight.sidebar) >= 3)
        for accent in DitherAccent.all {
            let a = ThemeCSSColor.parse(accent.accent(dark: false))!.token
            #expect(ratio(a, ground) >= 3)
            #expect(ratio(.white, a) >= 4.5)
        }
    }

    /// The light palette's own steps (docs/research/redesign-light-audit-2026-11-21.md): body 7:1 and muted 4.5:1 on
    /// every surface text sits on, status 4.5:1, and the ground, sidebar and cards
    /// three distinct steps.
    @Test func lightPaletteKeepsItsSteps() {
        var input = ThemeRuntimeInput()
        input.ditherLight = true
        input.light = ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!)
        let palettes = ThemeRuntime.resolve(input)
        let p = palettes.light, s = palettes.sidebarLight
        let opaque = [p.background, p.card, p.popover, s.sidebar]
        for bg in opaque { #expect(bg.srgb.w >= 1) }
        // The user bubble may be an overlay on the art; check it composited over the ground.
        let bubble = p.messageSurface.srgb, a = bubble.w, g = p.background.srgb
        let over = TokenColor(srgb: SIMD4(bubble.x * a + g.x * (1 - a), bubble.y * a + g.y * (1 - a), bubble.z * a + g.z * (1 - a), 1),
                              displayP3: SIMD4(0, 0, 0, 1))
        for bg in opaque + [over] {
            #expect(ratio(p.foreground, bg) >= 7)
            #expect(ratio(p.mutedForeground, bg) >= 4.5)
            #expect(ratio(p.successForeground, bg) >= 4.5)
            #expect(ratio(p.warningForeground, bg) >= 4.5)
            #expect(ratio(p.destructiveForeground, bg) >= 4.5)
        }
        #expect(ratio(s.successForeground, s.sidebar) >= 4.5)
        #expect(ratio(p.iconMuted, p.card) >= 4.5)
        // Three visible steps: sidebar darker than the ground, cards white above it.
        let l = { (c: TokenColor) in WindowGlass.luminance(c) }
        #expect(l(s.sidebar) < l(p.background) && l(p.background) < l(p.card))
        #expect(ratio(p.background, p.card) >= 1.04)
        #expect(ratio(s.sidebar, p.background) >= 1.05)
        // Not pure white everywhere: the ground is off-white.
        #expect(p.background.srgb.x < 0.99)
    }

    @Test func syntaxReadsOnACodeBlockOverTheArt() {
        let block = gray(0xf1 / 255)
        for kind in CodeTokenKind.allCases {
            let v = kind.redesignLight
            let c = TokenColor(srgb: SIMD4(Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255, 1),
                               displayP3: SIMD4(0, 0, 0, 1))
            #expect(ratio(c, block) >= 4.5, "\(kind)")
        }
    }
}

private extension TokenColor {
    static let white = TokenColor(srgb: SIMD4(1, 1, 1, 1), displayP3: SIMD4(1, 1, 1, 1))
}
