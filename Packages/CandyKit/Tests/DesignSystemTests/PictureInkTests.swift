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

    /// Auto's inks come from the picture alone: the same file gives the same hue at a small window with Coarse dots
    /// and a large one with Fine dots, though the tone decodes it four times larger.
    @Test func autoInkIgnoresTheWindowAndDotSize() throws {
        let url = URL(filePath: "/System/Library/CoreServices/DefaultDesktop.heic")
        try #require(FileManager.default.fileExists(atPath: url.path))
        PictureInk.dropCache()
        let small = try #require(PictureInk.tone([url], width: 280, height: 260, cell: 3))
        PictureInk.dropCache()
        let large = try #require(PictureInk.tone([url], width: 1146, height: 824, cell: 1.5))
        PictureInk.dropCache()
        let picture = try #require(DitherArt.picture(url, maxPixels: PictureInk.hueSide))
        #expect(small.hue == large.hue && small.hue == PictureInk.autoHue(picture))
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
                // Dark also darkens toward the middle (`readingCalm`): at 0.7 the photos measured body 14.1:1 and muted
                // 6.6:1 at the worst cell, so its floor sits above the 7:1 and 4.5:1 the cap alone guarantees.
                let floors = dark ? (body: 12.0, muted: 6.0) : (body: 7.0, muted: 4.5)
                #expect(PictureInk.contrast(PictureInk.luminance(text[0]), worst) >= floors.body)
                #expect(PictureInk.contrast(PictureInk.luminance(text[1]), worst) >= floors.muted)
            }
        }
    }

    /// The darkening toward the middle of a thread has no edge: from the column's centre out to the panel's edge it
    /// never rises, it moves by under 1% a point, it is full behind the text and gone by the window's edge.
    @Test(arguments: [1100.0, 1440, 2200])
    func theDarkeningFallsOffWithNoStep(panel: Double) {
        let columns: [Double: [Double]] = [1100: [180, 0, 740, 800], 1440: [360, 0, 720, 900], 2200: [500, 0, 1200, 900]]
        let column = columns[panel]!
        let centre = column[0] + column[2] / 2
        var last = PictureInk.columnCalm(centre, column: column, panelWidth: panel)
        #expect(last == 1)
        for side in [1.0, -1.0] {
            last = 1
            var x = centre
            while x >= 0, x <= panel {
                let v = PictureInk.columnCalm(x, column: column, panelWidth: panel)
                #expect(v <= last + 1e-12 && last - v < 0.01, "x \(x): \(last) to \(v)")
                last = v
                x += side * 0.5
            }
        }
        // Behind the text, edge to edge, it holds in full.
        #expect(PictureInk.columnCalm(column[0], column: column, panelWidth: panel) == 1)
        #expect(PictureInk.columnCalm(column[0] + column[2], column: column, panelWidth: panel) == 1)
        // Gone by the panel's edge, the whole margin out.
        #expect(PictureInk.columnCalm(panel, column: column, panelWidth: panel) == 0)
        #expect(PictureInk.columnCalm(column[0] + column[2] + 120, column: column, panelWidth: panel) > 0)
    }

    /// The fall-off curve: full at the column's edge, none at the panel's, never rising, and flat at both ends so the
    /// fade has no visible start or end.
    @Test func theFalloffCurveIsFlatAtBothEnds() {
        #expect(PictureInk.calmFalloff(0) == 1 && PictureInk.calmFalloff(1) == 0)
        #expect(PictureInk.calmFalloff(-0.5) == 1 && PictureInk.calmFalloff(1.5) == 0)
        var last = 1.0
        for i in 1...1000 {
            let v = PictureInk.calmFalloff(Double(i) / 1000)
            #expect(v <= last, "t \(Double(i) / 1000)")
            last = v
        }
        let h = 1e-3
        #expect(abs(PictureInk.calmFalloff(h) - 1) / h < 0.01)
        #expect(abs(PictureInk.calmFalloff(1 - h)) / h < 0.02)
        // Its steepest point stays gentle: no step for the one-bit dots to show as a contour.
        let slopes = (0..<1000).map { abs(PictureInk.calmFalloff(Double($0 + 1) / 1000) - PictureInk.calmFalloff(Double($0) / 1000)) * 1000 }
        #expect(slopes.max()! < 2)
    }

    /// Rendered over an even picture, the dots get fewer toward the column's centre band by band, and in light the
    /// column stays clean as before.
    @Test func theDotsThinTowardTheMiddle() throws {
        let w = 480, h = 64, ground = SIMD3<Double>(repeating: 8.0 / 255)
        let column: [Double] = [360, 0, 720, 192]
        let tone = PictureInk.Tone(width: w, height: h, values: [UInt8](repeating: 150, count: w * h), hue: 0, median: 0.5)
        let art = try #require(PictureInk.render(tone, inks: PictureInk.inks(hue: 200), ground: ground, dark: true,
                                                 shape: .thread(column: column), text: []))
        let b = [UInt8](art.dataProvider!.data! as Data), row = art.bytesPerRow
        // Eight-cell bands, one Bayer tile wide, from the centre out to the right edge.
        var density: [Double] = []
        for band in stride(from: 240, to: w - 7, by: 8) {
            var on = 0
            for y in 0..<h { for x in band..<(band + 8) where b[y * row + x * 4 + 2] != 8 { on += 1 } }
            density.append(Double(on) / Double(8 * h))
        }
        #expect(zip(density, density.dropFirst()).allSatisfy { $0.1 >= $0.0 - 1e-9 }, "\(density)")
        #expect(density.first! < density.last! * (1 - PictureInk.readingCalm) + 0.05, "\(density)")
        #expect(density.last! > 0.5, "\(density)")
    }

    /// The same tone, inks and shape give the same cells, byte for byte, and the cells sit on the Bayer lattice:
    /// a mid tone with no fall-off lights the same cells in every 8 x 8 tile.
    @Test(arguments: [1.5, 2.0, 3.0])
    func theMaskIsDeterministic(cell: Double) throws {
        let w = 64, h = 48
        let values = (0..<(w * h)).map { UInt8(($0 * 37) % 256) }
        let tone = PictureInk.Tone(width: w, height: h, values: values, hue: 0, median: 0.5, unit: cell)
        let inks = PictureInk.inks(hue: 40), ground = SIMD3<Double>(repeating: 8.0 / 255)
        for shape in [PictureInk.Shape.plain, .hero(composer: [40, 40, 100, 30]), .thread(column: [30, 0, 90, 144])] {
            let a = try #require(PictureInk.render(tone, inks: inks, ground: ground, dark: true, shape: shape, text: []))
            let b = try #require(PictureInk.render(tone, inks: inks, ground: ground, dark: true, shape: shape, text: []))
            #expect(a.dataProvider!.data! as Data == b.dataProvider!.data! as Data)
        }
        // The same picture toned twice at this cell gives the same mask.
        let picture = try #require(DitherArt.picture(URL(filePath: "/System/Library/Desktop Pictures/Radial Sky Blue.heic"), maxPixels: 1600))
        let t1 = try #require(PictureInk.tone(picture, width: 200, height: 120, cell: cell))
        let t2 = try #require(PictureInk.tone(picture, width: 200, height: 120, cell: cell))
        #expect(t1.values == t2.values && t1.unit == cell)
        let mid = PictureInk.Tone(width: 16, height: 16, values: [UInt8](repeating: 128, count: 256), hue: 0, median: 0.5)
        let art = try #require(PictureInk.render(mid, inks: inks, ground: ground, dark: true, shape: .plain, text: []))
        let px = [UInt8](art.dataProvider!.data! as Data), row = art.bytesPerRow
        for y in 0..<8 { for x in 0..<8 { #expect(px[y * row + x * 4] == px[(y + 8) * row + (x + 8) * 4]) } }
    }

    /// A dark picture is lifted until its median tone reaches the floor; a bright one is left as it is, and so is a
    /// low-key one.
    @Test func darkPicturesAreLifted() {
        #expect(PictureInk.lift(median: 0.6) == 1)
        let g = PictureInk.lift(median: 0.1)
        #expect(g < 1 && g >= 0.5)
        #expect(abs(pow(0.1, g) - PictureInk.medianFloor) < 0.01 || g == 0.5)
        #expect(PictureInk.lift(median: 0.1, lowKey: 0) == g)
        #expect(PictureInk.lift(median: 0.1, lowKey: 1) == 1)
    }

    /// A 256-bin histogram with `share` of its pixels in each listed bin.
    func histogram(_ bins: [(Int, Double)]) -> [Double] {
        var h = [Double](repeating: 0, count: 256)
        for (b, share) in bins { h[b] += share * 1000 }
        return h
    }

    /// The low-key rule on synthetic histograms: a night photo of a few lamps (most of it near black, a small bright
    /// tail) is low-key; a dark landscape with broad shadow detail, a mid-grey picture and a bright one are not.
    @Test func lowKeyTellsANightPhotoFromADarkLandscape() {
        // The user's street lamps measured 97% under 0.1, 1% from 0.1 to 0.35, the lamps above 0.5.
        #expect(PictureInk.lowKey(histogram([(2, 0.6), (12, 0.37), (40, 0.02), (240, 0.01)])) > 0.99)
        // Saturn backlit: 75% near black, 15% shadow, a bright rim.
        #expect(PictureInk.lowKey(histogram([(5, 0.75), (40, 0.15), (200, 0.1)])) > 0.9)
        // Big Sur Dark: 43% under 0.1 and broad shadows from 0.1 to 0.35.
        #expect(PictureInk.lowKey(histogram([(15, 0.43), (40, 0.25), (70, 0.2), (110, 0.12)])) == 0)
        // A dark painting whose shadows hold detail: 61% near black but a third in the shadows.
        #expect(PictureInk.lowKey(histogram([(20, 0.61), (40, 0.34), (140, 0.05)])) < 0.05)
        // Mid grey and a bright picture.
        #expect(PictureInk.lowKey(histogram([(128, 1)])) == 0)
        #expect(PictureInk.lowKey(histogram((0..<256).map { ($0, 1.0 / 256) })) == 0)
        // Empty or malformed.
        #expect(PictureInk.lowKey([]) == 0)
    }

    /// macOS's dark mockup pictures keep their shadow lift (the mockup's Big Sur Dark coastline and Sonoma's hills),
    /// and none of the five is read as low-key.
    @Test(arguments: [
        "/System/Library/CoreServices/DefaultDesktop.heic",
        "/System/Library/Desktop Pictures/Radial Sky Blue.heic",
        "/System/Library/Desktop Pictures/.wallpapers/Sonoma Horizon/Sonoma Horizon.heic",
        "/System/Library/Desktop Pictures/.thumbnails/Tree Light.heic",
        "/System/Library/Desktop Pictures/.thumbnails/Big Sur Dark.heic",
    ])
    func mockupPicturesAreNotLowKey(_ path: String) throws {
        try #require(FileManager.default.fileExists(atPath: path), "macOS picture missing: \(path)")
        let picture = try #require(DitherArt.picture(URL(filePath: path), maxPixels: 1600))
        let tone = try #require(PictureInk.tone(picture, width: 480, height: 300, cell: 3))
        #expect(tone.lowKey < 0.05, "\(path): \(tone.lowKey)")
        #expect(tone.highKey < 0.05, "\(path): \(tone.highKey)")
        if path.contains("Big Sur Dark") || path.contains("Sonoma") {
            #expect(PictureInk.lift(median: tone.median, lowKey: tone.lowKey) < 1)
        }
    }

    /// Tones under the black point draw no dot at all; just above it they ease in.
    @Test func theBlackPointDrawsNothing() throws {
        let w = 64, h = 64, ground = SIMD3<Double>(repeating: 8.0 / 255)
        let below = UInt8((PictureInk.blackPoint * 255).rounded(.down))
        let dark = PictureInk.Tone(width: w, height: h, values: (0..<(w * h)).map { UInt8($0 % Int(below + 1)) }, hue: 0, median: 0.5)
        let art = try #require(PictureInk.render(dark, inks: PictureInk.inks(hue: 250), ground: ground, dark: true, shape: .plain, text: []))
        let b = [UInt8](art.dataProvider!.data! as Data), row = art.bytesPerRow
        for y in 0..<h { for x in 0..<w { #expect(b[y * row + x * 4] == 8 && b[y * row + x * 4 + 2] == 8, "\(x), \(y)") } }
        let above = PictureInk.Tone(width: w, height: h, values: [UInt8](repeating: below + 20, count: w * h), hue: 0, median: 0.5)
        let some = try #require(PictureInk.render(above, inks: PictureInk.inks(hue: 250), ground: ground, dark: true, shape: .plain, text: []))
        let c = [UInt8](some.dataProvider!.data! as Data)
        #expect((0..<(w * h)).contains { c[($0 / w) * row + ($0 % w) * 4 + 2] != 8 })
    }

    /// A night picture at the cell's sample grid: black with sensor grain, one lamp a single sample wide and a soft
    /// glow. The lamp lights its cell, the grain draws nothing, and the glow's dots thin outward.
    @Test(arguments: [1.5, 2.0, 3.0])
    func aSmallHighlightLightsItsCellAndGrainDrawsNothing(cell: Double) throws {
        let w = 80, h = 60, s = PictureInk.subsamples(cell: cell), pw = w * s, ph = h * s
        var px = [UInt8](repeating: 0, count: pw * ph * 4)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func noise() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8((seed >> 33) % 14) }
        // The glow is centred on cell (60, 15); the lamp is one sample in cell (20, 40).
        let glow = (x: Double(60 * s + s / 2), y: Double(15 * s + s / 2)), reach = Double(12 * s)
        for y in 0..<ph {
            for x in 0..<pw {
                let d = ((Double(x) - glow.x) * (Double(x) - glow.x) + (Double(y) - glow.y) * (Double(y) - glow.y)).squareRoot()
                let v = Double(noise()) + 200 * max(0, 1 - d / reach) * max(0, 1 - d / reach)
                for c in 0..<3 { px[(y * pw + x) * 4 + c] = UInt8(min(v, 255)) }
                px[(y * pw + x) * 4 + 3] = 255
            }
        }
        for c in 0..<3 { px[((40 * s + 1) * pw + 20 * s + 1) * 4 + c] = 255 }
        let picture = try #require(px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        })
        let tone = try #require(PictureInk.tone(picture, width: w, height: h, cell: cell))
        #expect(tone.lowKey > 0.9, "\(tone.lowKey)")
        #expect(tone.values[40 * w + 20] > 230, "lamp \(tone.values[40 * w + 20])")
        let inks = PictureInk.inks(hue: 250), ground = SIMD3<Double>(repeating: 8.0 / 255)
        let art = try #require(PictureInk.render(tone, inks: inks, ground: ground, dark: true, shape: .plain, text: []))
        let b = [UInt8](art.dataProvider!.data! as Data), row = art.bytesPerRow
        func lit(_ x: Int, _ y: Int) -> Bool { b[y * row + x * 4 + 2] != 8 }
        // Ink covers at most 85% of a level, so the brightest cell takes the light ink or, on some lattice spots, the deep.
        #expect([inks.light.bytes, inks.deep.bytes].contains(Array(b[(40 * row + 20 * 4)..<(40 * row + 20 * 4 + 3)])))
        // The grain: everything left of the glow and away from the lamp.
        for y in 0..<h { for x in 0..<40 where abs(x - 20) > 1 || abs(y - 40) > 1 { #expect(!lit(x, y), "grain at \(x), \(y)") } }
        // The glow thins outward: rings of cells around its centre, each no denser than the one inside it.
        var density: [Double] = []
        for r in stride(from: 0, through: 12, by: 3) {
            var on = 0, all = 0
            for y in 0..<h { for x in 40..<w {
                let d = (Double((x - 60) * (x - 60) + (y - 15) * (y - 15))).squareRoot()
                if d >= Double(r), d < Double(r + 3) { all += 1; if lit(x, y) { on += 1 } }
            } }
            density.append(Double(on) / Double(max(all, 1)))
        }
        #expect(zip(density, density.dropFirst()).allSatisfy { $0.0 >= $0.1 - 0.02 }, "\(density)")
        #expect(density.first! > 0.5 && density.last! < 0.05, "\(density)")
    }

    /// Every dot size lands on whole device pixels at 1x and 2x: Fine is 1.5pt (3 pixels) at 2x and 2pt at 1x.
    @Test func dotSizesLandOnWholePixels() {
        #expect(DitherDotSize.fine.points(scale: 2) == 1.5 && DitherDotSize.fine.points(scale: 1) == 2)
        #expect(DitherDotSize.medium.points(scale: 2) == 2 && DitherDotSize.coarse.points(scale: 2) == 3)
        for size in DitherDotSize.allCases {
            for scale: CGFloat in [1, 2] {
                let px = size.points(scale: scale) * scale
                #expect(px == px.rounded() && px >= 2, "\(size) at \(scale)x is \(px) px")
            }
        }
        #expect(DitherDotSize(rawValue: "medium") == .medium && DitherDotSize(rawValue: "huge") == nil)
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
        // Dot size applies live: Coarse renders 3pt cells, and back to Medium's 2pt, with no other change.
        let scale = window.backingScaleFactor
        #expect(hero.dot == DitherDotSize.medium.points(scale: scale))
        input.ditherDotSize = .coarse
        ThemeRuntime.apply(input)
        #expect(art.requestForTesting?.dot == 3)
        #expect(art.requestForTesting?.width == Int((art.bounds.width / 3).rounded(.up)))
        #expect(animations().isEmpty)
        input.ditherDotSize = .medium
        ThemeRuntime.apply(input)
        #expect(art.requestForTesting?.dot == DitherDotSize.medium.points(scale: scale))
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
        #expect(art.requestForTesting?.width == Int((art.bounds.width / art.requestForTesting!.dot).rounded(.up)))
        art.rendersInlineForTesting = true
        art.viewDidEndLiveResize()
        #expect(art.rendersForTesting == before + 1, "\(art.rendersForTesting - before) renders")
        #expect(art.requestForTesting?.width == Int((art.bounds.width / art.requestForTesting!.dot).rounded(.up)))
    }
}
