import AppKit
import Testing
@testable import DesignSystem

/// Redesign's "Tint from picture": off is today's palette exactly, and on never costs text its contrast.
@MainActor
struct PictureTintTests {
    static func redesign(blur: Bool = false) -> ThemeRuntimeInput {
        var input = ThemeRuntimeInput()
        input.ditherLight = true; input.ditherDark = true
        input.light = ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light) ?? ThemeDefinition.dither.colors)
        input.dark = ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark) ?? ThemeDefinition.dither.colors)
        input.ditherBlur = blur
        return input
    }

    static func solid(_ r: Double, _ g: Double, _ b: Double) -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    /// Saturated primaries and secondaries, orange, white, black and a mid grey.
    static let extremes: [(String, CGImage)] = [
        ("red", solid(1, 0, 0)), ("green", solid(0, 1, 0)), ("blue", solid(0, 0, 1)), ("yellow", solid(1, 1, 0)),
        ("magenta", solid(1, 0, 1)), ("cyan", solid(0, 1, 1)), ("orange", solid(1, 0.5, 0)), ("white", solid(1, 1, 1)),
        ("black", solid(0, 0, 0)), ("grey", solid(0.5, 0.5, 0.5)),
    ]

    static func same(_ a: ThemePalettes, _ b: ThemePalettes) -> Bool {
        a.light.members == b.light.members && a.dark.members == b.dark.members
            && a.sidebarLight.members == b.sidebarLight.members && a.sidebarDark.members == b.sidebarDark.members
    }

    @Test(arguments: [false, true]) func offIsTodaysPalette(blur: Bool) {
        let today = ThemeRuntime.resolve(Self.redesign(blur: blur))
        var off = Self.redesign(blur: blur)
        off.pictureTint = PictureTint.tint(of: Self.solid(1, 0.5, 0))
        off.ditherTintFromPicture = false
        #expect(Self.same(ThemeRuntime.resolve(off), today))
        // Flower has no picture, so it takes no tint.
        var flower = off
        flower.ditherTintFromPicture = true
        flower.ditherFlower = true
        var flowerToday = Self.redesign(blur: blur)
        flowerToday.ditherFlower = true
        #expect(Self.same(ThemeRuntime.resolve(flower), ThemeRuntime.resolve(flowerToday)))
        // On, it changes the palette; the default themes never take it.
        var on = off
        on.ditherTintFromPicture = true
        #expect(!Self.same(ThemeRuntime.resolve(on), today))
        var stock = ThemeRuntimeInput()
        stock.pictureTint = on.pictureTint
        #expect(Self.same(ThemeRuntime.resolve(stock), ThemeRuntime.resolve(ThemeRuntimeInput())))
    }

    /// The surfaces text sits on, and the text drawn on them.
    static let textSurfaces = ["--background", "--app-chrome-background", "--card", "--popover", "--surface-raised", "--muted",
                               "--secondary", "--accent", "--message-surface", "--code-background", "--toolbar-background",
                               "--toolbar-control"]
    static let sidebarSurfaces = ["--sidebar", "--sidebar-control-surface"]

    static func contrast(_ a: TokenColor, _ b: TokenColor) -> Double {
        let la = WindowGlass.luminance(a), lb = WindowGlass.luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func member(_ palette: Palette, _ name: String) -> TokenColor {
        palette.members[Palette.memberNames.firstIndex(of: name)!]
    }

    @Test func extremePicturesKeepTheContrastFloors() {
        let today = ThemeRuntime.resolve(Self.redesign())
        for (name, picture) in Self.extremes {
            var input = Self.redesign()
            input.pictureTint = PictureTint.tint(of: picture)
            let chroma = (input.pictureTint! * input.pictureTint!).sum().squareRoot()
            #expect(chroma <= PictureTint.maxChroma + 1e-9, "\(name)")
            let tinted = ThemeRuntime.resolve(input)
            for dark in [true, false] {
                for sidebar in [false, true] {
                    let p = tinted.palette(dark: dark, sidebar: sidebar), old = today.palette(dark: dark, sidebar: sidebar)
                    let body = Self.member(p, sidebar ? "--sidebar-foreground" : "--foreground")
                    let muted = Self.member(p, sidebar ? "--sidebar-muted-foreground" : "--muted-foreground")
                    for surface in sidebar ? Self.sidebarSurfaces : Self.textSurfaces {
                        let s = Self.member(p, surface)
                        guard s.srgb.w >= 1 else { continue }
                        let label = "\(name) \(dark ? "dark" : "light") \(surface)"
                        #expect(Self.contrast(body, s) >= 7, "\(label) body \(Self.contrast(body, s))")
                        #expect(Self.contrast(muted, s) >= 4.5, "\(label) muted \(Self.contrast(muted, s))")
                        // The tint keeps each surface's lightness: contrast moves by under 2%.
                        let before = Self.contrast(muted, Self.member(old, surface))
                        #expect(abs(Self.contrast(muted, s) / before - 1) < 0.02, "\(label) moved from \(before)")
                    }
                }
            }
        }
    }

    @Test func greyPictureBarelyTints() {
        let tint = PictureTint.tint(of: Self.solid(0.5, 0.5, 0.5))
        #expect((tint * tint).sum().squareRoot() < 0.001)
    }
}
