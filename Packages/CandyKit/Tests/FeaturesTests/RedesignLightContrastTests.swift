import Foundation
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign light keeps WCAG AA over its art: the darkest dot the light scrim allows is about #d7d7d7.
@MainActor
struct RedesignLightContrastTests {
    private func ratio(_ a: TokenColor, _ b: TokenColor) -> Double {
        let la = WindowGlass.luminance(a), lb = WindowGlass.luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    private func gray(_ v: Double) -> TokenColor { TokenColor(srgb: SIMD4(v, v, v, 1), displayP3: SIMD4(v, v, v, 1)) }

    @Test func lightScrimHoldsTheArtNearTheBackground() {
        let standard = (reduceTransparency: false, increaseContrast: false)
        for page in [DitherArt.Page.hero, .thread, .settings, .page] {
            #expect(DitherArt.scrim(page, standard, light: true) >= 0.65)
            #expect(DitherArt.scrim(page, standard, light: true) >= DitherArt.scrim(page, standard))
        }
        #expect(DitherArt.scrim(.hero, standard) == 0)
    }

    @Test func mutedTextIconsAndEdgesReadOverTheArt() {
        var input = ThemeRuntimeInput()
        input.ditherLight = true
        input.light = ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!)
        let palettes = ThemeRuntime.resolve(input)
        let darkestDot = gray((249 - DitherArt.reach * (1 - DitherArt.lightScrim(.hero))) / 255)
        for p in [palettes.light, palettes.sidebarLight] {
            for c in [p.foreground, p.mutedForeground, p.secondaryLabel, p.placeholder, p.sidebarMutedForeground, p.infoForeground,
                      p.warningForeground, p.destructiveForeground] {
                #expect(ratio(c, darkestDot) >= 4.5)
                #expect(ratio(c, palettes.sidebarLight.sidebar) >= 4.5)
            }
            for c in [p.iconMuted, p.sidebarIconColor, p.ring] { #expect(ratio(c, darkestDot) >= 3) }
            #expect(ratio(.white, p.primary) >= 4.5)
        }
        #expect(ratio(gray(0x85 / 255), palettes.sidebarLight.sidebar) >= 3)
        for accent in DitherAccent.all {
            let a = ThemeCSSColor.parse(accent.accent(dark: false))!.token
            #expect(ratio(a, darkestDot) >= 3)
            #expect(ratio(.white, a) >= 4.5)
        }
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
