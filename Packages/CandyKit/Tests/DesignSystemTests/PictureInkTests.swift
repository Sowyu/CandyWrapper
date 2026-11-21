import AppKit
import Testing
@testable import DesignSystem

extension SIMD3 where Scalar == Double {
    var bytes: [UInt8] { let b = byteTriple; return [b.0, b.1, b.2] }
}

/// Redesign's Picture in two inks (the user, 2026-11-21: "i like 2 ink"): the Auto rule picks the approved mockup's
/// inks, text keeps its floors behind a thread's column, the mask is deterministic, and nothing moves or re-renders
/// per frame.
struct PictureInkTests {
    func hex(_ c: SIMD3<Double>) -> String { let b = c.byteTriple; return String(format: "#%02x%02x%02x", b.0, b.1, b.2) }

    func close(_ a: SIMD3<Double>, _ hex: Int) -> Bool {
        let b = SIMD3(Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)) / 255
        let d = a - b
        return max(abs(d.x), abs(d.y), abs(d.z)) <= 3.0 / 255
    }

    /// A flat picture of one sRGB color.
    func flat(_ r: Double, _ g: Double, _ b: Double) -> CGImage {
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return ctx.makeImage()!
    }

    /// The mockup's Auto results (dither-options-2026-11-21/ink/sheet-best-auto2.png) on macOS's own pictures.
    @Test(arguments: [
        ("/System/Library/CoreServices/DefaultDesktop.heic", 0x95572d, 0xf6b576),
        ("/System/Library/Desktop Pictures/Radial Sky Blue.heic", 0x077396, 0x86cdff),
        ("/System/Library/Desktop Pictures/.wallpapers/Sonoma Horizon/Sonoma Horizon.heic", 0x557432, 0x9bd694),
    ])
    func autoInkMatchesTheApprovedMockup(_ path: String, _ deep: Int, _ light: Int) throws {
        try #require(FileManager.default.fileExists(atPath: path), "macOS picture missing: \(path)")
        let picture = try #require(DitherArt.picture(URL(filePath: path), maxPixels: 1200))
        let inks = PictureInk.inks(hue: PictureInk.autoHue(picture))
        #expect(close(inks.deep, deep), "deep \(hex(inks.deep))")
        #expect(close(inks.light, light), "light \(hex(inks.light))")
    }

    /// A near-grey picture takes Capy's navy hue, and an olive one turns leaf green.
    @Test func greyTakesNavyAndOliveTurnsGreen() {
        #expect(PictureInk.autoHue(flat(0.6, 0.6, 0.62)) == PictureInk.navyHue)
        // #8a8a3a is an olive near 100 degrees in OKLCH.
        let olive = flat(0x8a / 255.0, 0x8a / 255.0, 0x3a / 255.0)
        #expect((75...115).contains(PictureInk.oklch(srgb: SIMD3(0x8a, 0x8a, 0x3a) / 255).h))
        #expect(PictureInk.autoHue(olive) == 130)
        // A saturated red keeps its own hue.
        #expect(abs(PictureInk.autoHue(flat(0.85, 0.15, 0.15)) - PictureInk.oklch(srgb: SIMD3(0.85, 0.15, 0.15)).h) < 8)
    }

    /// Accent and Custom: the color is the light ink as it is, and the deep ink is its hue at L 0.52.
    @Test func aColorBecomesTheLightInk() {
        let accent = SIMD3(0x8b, 0x7c, 0xf6) / 255.0
        let inks = PictureInk.inks(light: accent)
        #expect(inks.light == accent)
        let deep = PictureInk.oklch(srgb: inks.deep)
        #expect(abs(deep.l - 0.52) < 0.01)
        #expect(abs(deep.h - PictureInk.oklch(srgb: accent).h) < 2)
    }

    /// Behind a thread's column, body text keeps 7:1 and muted text 4.5:1 against the worst cell, for the brightest,
    /// the busiest and the most saturated pictures, in dark and in light.
    /// Light leaves no dot behind the column or in the 16pt gap beside it, and the ink is back past the edge.
    @Test func lightColumnIsClean() throws {
        let w = 400, h = 20, ground = SIMD3<Double>(repeating: 0xf8 / 255.0)
        let column: [Double] = [300, 0, 600, 60]
        let tone = PictureInk.Tone(width: w, height: h, values: [UInt8](repeating: 0, count: w * h), hue: 0, median: 0.5)
        let art = try #require(PictureInk.render(tone, inks: PictureInk.inks(hue: 250), ground: ground, dark: false,
                                                 shape: .thread(column: column), text: [SIMD3(repeating: 0x17 / 255.0), SIMD3(repeating: 0x5c / 255.0)]))
        let b = [UInt8](art.dataProvider!.data! as Data), row = art.bytesPerRow
        func inked(_ x: Int) -> Bool { (0..<h).contains { y in b[y * row + x * 4] != 0xf8 || b[y * row + x * 4 + 2] != 0xf8 } }
        for x in 0..<w {
            let px = Double(x) * 3 + 1.5
            if px >= column[0] - 16, px <= column[0] + column[2] + 16 { #expect(!inked(x), "x \(px)") }
            if px < column[0] - 48 || px > column[0] + column[2] + 48 { #expect(inked(x), "x \(px)") }
        }
    }

    @Test(arguments: [true, false])
    func textKeepsItsFloorsBehindTheColumn(dark: Bool) throws {
        let w = 400, h = 200
        let ground = dark ? SIMD3<Double>(repeating: 8.0 / 255) : SIMD3<Double>(repeating: 1)
        let text: [SIMD3<Double>] = dark ? [SIMD3(repeating: 0xf5 / 255.0), SIMD3(0xaa, 0xaa, 0xab) / 255.0]
            : [SIMD3(repeating: 0x0a / 255.0), SIMD3(repeating: 0x73 / 255.0)]
        let column: [Double] = [300, 0, 600, 600]
        // White, black, a checkerboard of both and a saturated yellow; tones from 0 to 255.
        let tones: [[UInt8]] = [
            [UInt8](repeating: 255, count: w * h), [UInt8](repeating: 0, count: w * h),
            (0..<(w * h)).map { (($0 % w) / 4 + ($0 / w) / 4) % 2 == 0 ? 255 : 0 },
            (0..<(w * h)).map { UInt8($0 % 256) },
        ]
        for values in tones {
            for inks in [PictureInk.inks(hue: 100), PictureInk.inks(hue: 250), PictureInk.inks(light: SIMD3(1, 1, 0.2))] {
                let tone = PictureInk.Tone(width: w, height: h, values: values, hue: 0, median: 0.5)
                let art = try #require(PictureInk.render(tone, inks: inks, ground: ground, dark: dark, shape: .thread(column: column), text: text))
                let b = [UInt8](art.dataProvider!.data! as Data), row = art.bytesPerRow
                var worst = dark ? 0.0 : 1.0
                for y in 0..<h {
                    for x in 0..<w where Double(x) * 3 + 1.5 >= column[0] && Double(x) * 3 + 1.5 <= column[0] + column[2] {
                        let i = y * row + x * 4
                        let l = PictureInk.luminance(SIMD3(Double(b[i]), Double(b[i + 1]), Double(b[i + 2])) / 255)
                        worst = dark ? max(worst, l) : min(worst, l)
                    }
                }
                #expect(PictureInk.contrast(PictureInk.luminance(text[0]), worst) >= 7)
                #expect(PictureInk.contrast(PictureInk.luminance(text[1]), worst) >= 4.5)
            }
        }
    }

    /// The same tone, inks and shape give the same cells, byte for byte, and the cells sit on the Bayer lattice:
    /// a mid tone with no fall-off lights the same cells in every 8 x 8 tile.
    @Test func theMaskIsDeterministic() throws {
        let w = 64, h = 48
        let values = (0..<(w * h)).map { UInt8(($0 * 37) % 256) }
        let tone = PictureInk.Tone(width: w, height: h, values: values, hue: 0, median: 0.5)
        let inks = PictureInk.inks(hue: 40), ground = SIMD3<Double>(repeating: 8.0 / 255)
        for shape in [PictureInk.Shape.plain, .hero(composer: [40, 40, 100, 30]), .thread(column: [30, 0, 90, 144])] {
            let a = try #require(PictureInk.render(tone, inks: inks, ground: ground, dark: true, shape: shape, text: []))
            let b = try #require(PictureInk.render(tone, inks: inks, ground: ground, dark: true, shape: shape, text: []))
            #expect(a.dataProvider!.data! as Data == b.dataProvider!.data! as Data)
        }
        let mid = PictureInk.Tone(width: 16, height: 16, values: [UInt8](repeating: 128, count: 256), hue: 0, median: 0.5)
        let art = try #require(PictureInk.render(mid, inks: inks, ground: ground, dark: true, shape: .plain, text: []))
        let px = [UInt8](art.dataProvider!.data! as Data), row = art.bytesPerRow
        for y in 0..<8 { for x in 0..<8 { #expect(px[y * row + x * 4] == px[(y + 8) * row + (x + 8) * 4]) } }
    }

    /// A dark picture is lifted until its median tone reaches the floor; a bright one is left as it is.
    @Test func darkPicturesAreLifted() {
        #expect(PictureInk.lift(median: 0.6) == 1)
        let g = PictureInk.lift(median: 0.1)
        #expect(g < 1 && g >= 0.5)
        #expect(abs(pow(0.1, g) - PictureInk.medianFloor) < 0.01 || g == 0.5)
    }

    /// Picture never moves: opening a new thread, a thread and back adds no animation to the art, no Gradient frames
    /// exist, and a live resize scales the cached image instead of rendering per frame, then renders once.
    @MainActor @Test func pictureHoldsStillAndResizesOnTheGPU() throws {
        _ = NSApplication.shared
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion }
        Motion.reducedOverride = false
        var input = ThemeRuntimeInput(light: ThemeDefinition.dither.colors(for: .light).map { ThemeRuntimeHalf(colors: $0) },
                                      dark: ThemeDefinition.dither.colors(for: .dark).map { ThemeRuntimeHalf(colors: $0) })
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let shell = SidebarLayoutView(defaults: UserDefaults(suiteName: "cw.picture-ink.\(UUID().uuidString)")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer { window.contentView = nil }
        shell.layoutSubtreeIfNeeded()
        let art = try #require(shell.main.subviews.first { $0 is DitherArtView } as? DitherArtView)
        art.windowIsActiveOverride = true
        art.rendersInlineForTesting = true
        let page = NSView(frame: shell.main.bounds)
        shell.main.addSubview(page)
        func animations() -> [String] { (art.layer?.sublayers ?? []).flatMap { [$0] + ($0.mask.map { [$0] } ?? []) }.flatMap { $0.animationKeys() ?? [] } }
        DitherArtView.setComposer(NSRect(x: 200, y: 300, width: 600, height: 90), from: page)
        DitherArtView.setEmphasis(.hero, from: page)
        defer { DitherArtView.setEmphasis(nil, from: page); DitherArtView.setComposer(nil, from: page) }
        let hero = try #require(art.requestForTesting)
        #expect(hero.tint == nil && !hero.blur)
        guard case .hero(composer: _?) = hero.shape else { Issue.record("no composer in \(hero.shape)"); return }
        #expect(art.contentsForTesting != nil)
        #expect(animations().isEmpty)
        #expect(art.scrimAlphaForTesting == 0)
        DitherArtView.setColumn(NSRect(x: 300, y: 0, width: 500, height: 700), from: page)
        DitherArtView.setEmphasis(.thread, from: page)
        defer { DitherArtView.setColumn(nil, from: page) }
        guard case .thread(column: _?) = art.requestForTesting?.shape else { Issue.record("no column"); return }
        #expect(animations().isEmpty)
        #expect(art.scrimAlphaForTesting == 0)
        DitherArtView.setEmphasis(.hero, from: page)
        #expect(animations().isEmpty)
        #expect(!art.gradientAnimatingForTesting)

        // A drag: twenty sizes, no render until the drag pauses, and the cached image always covers the panel.
        art.rendersInlineForTesting = false
        let before = art.rendersForTesting
        for i in 1...20 {
            art.frame = NSRect(x: 0, y: 0, width: 900 + CGFloat(i) * 7, height: 760)
            art.needsLayout = true
            art.layoutSubtreeIfNeeded()
            let layer = try #require(art.layer?.sublayers?.first)
            #expect(layer.frame.minX <= 0.5 && layer.frame.maxX >= art.bounds.maxX - 0.5, "\(layer.frame) in \(art.bounds), step \(i)")
            #expect(layer.frame.minY <= 0.5 && layer.frame.maxY >= art.bounds.maxY - 0.5, "\(layer.frame) in \(art.bounds), step \(i)")
        }
        #expect(art.rendersForTesting == before)
        // The last size waits, then the end of the live resize renders it once.
        #expect(art.requestForTesting?.width == Int((art.bounds.width / PictureInk.cell).rounded(.up)))
        art.rendersInlineForTesting = true
        art.viewDidEndLiveResize()
        #expect(art.rendersForTesting == before + 1, "\(art.rendersForTesting - before) renders")
        #expect(art.requestForTesting?.width == Int((art.bounds.width / PictureInk.cell).rounded(.up)))
    }
}
