import AppKit
import Testing
@testable import DesignSystem

/// Redesign's X8 floors (docs/research/redesign-contrast-2026-11-27.md): muted text, placeholders and icons 4.5:1, text
/// on the accent 4.5:1, a control's edge 3:1, in both appearances and with every accent.
@MainActor
struct RedesignContrastFloorTests {
    private func ratio(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        OKLCH.contrast(OKLCH.luminance(a), OKLCH.luminance(b))
    }
    private func rgb(_ t: TokenColor) -> SIMD3<Double> { SIMD3(t.srgb.x, t.srgb.y, t.srgb.z) }
    private func rgb(_ hex: String) -> SIMD3<Double> { let c = DitherAccent.rgb(hex); return SIMD3(c.0, c.1, c.2) }

    private func redesign(accent: String = DitherAccent.teal.id) -> ThemeRuntimeInput {
        var input = ThemeRuntimeInput(light: ThemeDefinition.dither.colors(for: .light).map { ThemeRuntimeHalf(colors: $0) },
                                      dark: ThemeDefinition.dither.colors(for: .dark).map { ThemeRuntimeHalf(colors: $0) })
        input.ditherLight = true; input.ditherDark = true; input.ditherAccent = accent
        return input
    }

    @Test func mutedRolesKeepTheirFloorsOnEverySurface() {
        let palettes = ThemeRuntime.resolve(redesign())
        for dark in [true, false] {
            let p = dark ? palettes.dark : palettes.light, s = dark ? palettes.sidebarDark : palettes.sidebarLight
            // The composer, cards, menus, the ground and the sidebar.
            let grounds = [p.background, p.card, p.popover, s.sidebar].map(rgb)
            for ground in grounds {
                for role in [p.placeholder, p.mutedForeground, p.iconMuted] {
                    #expect(ratio(rgb(role), ground) >= 4.5, "\(dark ? "dark" : "light") \(role) on \(ground)")
                }
            }
            #expect(ratio(rgb(s.sidebarIconColor), rgb(s.sidebar)) >= 4.5, "\(dark ? "dark" : "light") sidebar icons")
            if !dark {
                // The diff counts in the header pill, on a white pill.
                #expect(ratio(rgb(p.diffAddition), SIMD3(1, 1, 1)) >= 4.5)
                #expect(ratio(rgb(p.diffDeletion), SIMD3(1, 1, 1)) >= 4.5)
            }
        }
    }

    /// The new-thread page's context row draws the text color at `Text.faint` on the ground (its feathered patch).
    @Test func faintRowTextKeepsMutedFloor() {
        let palettes = ThemeRuntime.resolve(redesign())
        for dark in [true, false] {
            let p = dark ? palettes.dark : palettes.light
            let a = Double(RedesignTokens.Text.faint(dark: dark)), ground = rgb(p.background)
            let text = rgb(p.foreground) * a + ground * (1 - a)
            #expect(ratio(text, ground) >= 4.5, "\(dark ? "dark" : "light")")
        }
    }

    @Test func textOnEveryAccentReads() {
        for accent in DitherAccent.all {
            for dark in [true, false] {
                let fill = rgb(accent.accent(dark: dark)), label = rgb(accent.foreground(dark: dark))
                #expect(ratio(fill, label) >= 4.5, "\(accent.id) \(dark ? "dark" : "light")")
            }
        }
    }

    /// The palette as `ThemeLibrary` builds it, with the accent's roles merged in, so the resolved primary and send
    /// button labels follow `DitherAccent.foreground` for every accent, teal included (docs/decisions.md, 2026-11-27).
    @Test func accentLabelsReadInTheResolvedPalette() {
        for accent in DitherAccent.all {
            var input = redesign(accent: accent.id)
            input.light = ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!.merging(accent.colors(dark: false)) { $1 })
            input.dark = ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!.merging(accent.colors(dark: true)) { $1 })
            let palettes = ThemeRuntime.resolve(input)
            for dark in [true, false] {
                let p = dark ? palettes.dark : palettes.light, side = "\(accent.id) \(dark ? "dark" : "light")"
                #expect(ratio(rgb(p.primary), rgb(p.primaryForeground)) >= 4.5, "\(side) primary")
                #expect(ratio(rgb(p.messageAction), rgb(p.messageActionForeground)) >= 4.5, "\(side) send")
            }
        }
        // The base palette already carries teal's rule, so nothing depends on the merge for the default.
        for dark in [true, false] {
            let base = ThemeDefinition.dither.colors(for: dark ? .dark : .light)!
            #expect(base[.accentForeground] == DitherAccent.teal.foreground(dark: dark))
            #expect(base[.messageActionForeground] == DitherAccent.teal.foreground(dark: dark))
        }
    }

    /// A file link in the accent reads at 4.5:1 on the ground, a card and the chip's muted fill, for every accent.
    @Test func accentTextReadsOnItsChips() {
        let palettes = ThemeRuntime.resolve(redesign())
        for accent in DitherAccent.all {
            for dark in [true, false] {
                let p = dark ? palettes.dark : palettes.light
                for ground in [p.background, p.card, p.muted] {
                    #expect(ratio(rgb(accent.text(dark: dark)), rgb(ground)) >= 4.5, "\(accent.id) \(dark ? "dark" : "light") on \(ground)")
                }
            }
        }
    }

    @Test func destructiveFillKeepsWhiteAtFourAndAHalf() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(redesign())
        for dark in [true, false] {
            let fill = RedesignTokens.Destructive.fill(dark: dark).usingColorSpace(.sRGB)!
            let c = SIMD3(Double(fill.redComponent), Double(fill.greenComponent), Double(fill.blueComponent))
            #expect(ratio(c, SIMD3(1, 1, 1)) >= 4.5, "\(dark ? "dark" : "light") destructive \(c)")
        }
    }

    /// An empty radio's edge keeps 3:1 on the card it sits on (C6, round 2).
    @Test func emptyRadioEdgeReads() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(redesign())
        for dark in [true, false] {
            let radio = RadioView(checked: false)
            radio.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            radio.restyle()
            let border = try #require(radio.decoration.boxStyle.border)
            var c = SIMD3<Double>(0, 0, 0)
            radio.effectiveAppearance.performAsCurrentDrawingAppearance {
                let s = border.usingColorSpace(.sRGB)!
                c = SIMD3(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
            }
            let card = rgb(dark ? ThemeRuntime.palettes.dark.card : ThemeRuntime.palettes.light.card)
            #expect(ratio(c, card) >= 3, "\(dark ? "dark" : "light") radio edge \(c) on \(card)")
        }
    }

    /// The off switch drawn offscreen on a Settings card: the track's pixel against the card's keeps 3:1.
    @Test func offSwitchEdgeReadsOnTheCard() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(redesign())
        for dark in [true, false] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let card = dark ? ThemeRuntime.palettes.dark.card : ThemeRuntime.palettes.light.card
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 30))
            host.appearance = appearance
            host.wantsLayer = true
            host.layer?.backgroundColor = CGColor(srgbRed: card.srgb.x, green: card.srgb.y, blue: card.srgb.z, alpha: 1)
            let toggle = SwitchView(isOn: false)
            toggle.frame = NSRect(x: 10, y: 6, width: 32, height: 18)
            host.addSubview(toggle)
            // A borderless window lays the switch out and gives it its appearance, as the fidelity tests draw.
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.display()
            defer { window.contentView = nil }
            // Into an sRGB bitmap straight from the layers: `cacheDisplay` went through the window's color space and
            // read light's #8a8a87 track as #999998.
            let w = 60, h = 30
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            appearance.performAsCurrentDrawingAppearance { host.layer?.render(in: ctx) }
            func at(_ x: Int, _ y: Int) -> SIMD3<Double> {
                let i = (y * w + x) * 4
                return SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255
            }
            // The track's pixel farthest from the card along the switch's middle row, and the card beside the switch.
            let ground = at(3, 15)
            let track = (26...40).map { at($0, 15) }.max { ratio($0, ground) < ratio($1, ground) } ?? ground
            #expect(ratio(track, ground) >= 3, "\(dark ? "dark" : "light"): track \(track) on \(ground)")
        }
    }
}
