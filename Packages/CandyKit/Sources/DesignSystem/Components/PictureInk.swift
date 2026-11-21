import CoreGraphics
import Foundation
import os

/// Redesign's Background = Picture (the user, 2026-11-21: "i like b1", "i like 2 ink", "no motion its horrid"): the
/// whole picture as an ordered Bayer dither in two inks of one hue on the ground, on Gradient's 3pt cell lattice, with
/// no photo showing through and no dim layer. The picture's tone (`Tone`) is computed once per picture and canvas size
/// and cached; the inks and the page's shape (the composer's fall-off on a new thread, the reading column in a thread)
/// only re-threshold it, a few milliseconds on a worker. Touches no AppKit view, so it runs on any thread.
public enum PictureInk {
    /// The cell, in points: Gradient's (`DitherArt.gradientUnit`), so both modes sit on one lattice.
    public nonisolated static let cell: CGFloat = 3
    /// The most of a cell's level that ink may cover, so a bright sky keeps a visible pattern.
    nonisolated static let coverage = 0.85
    /// Dark pictures are lifted until the median tone reaches this, so they don't come out as an empty frame with
    /// scattered dots (the mockup's dark coastline and hills).
    nonisolated static let medianFloor = 0.34
    /// The deep and light inks' OKLCH lightness and chroma, and the light ink's hue turn (the approved mockup,
    /// dither-options-2026-11-21/ink/sheet-best-auto2.png).
    nonisolated static let deep = (l: 0.52, c: 0.10), light = (l: 0.82, c: 0.11), lightTurn = 12.0
    /// Capy's navy (#26314b), whose hue a near-grey picture takes.
    nonisolated static let navyHue: Double = oklch(srgb: SIMD3(0x26, 0x31, 0x4b) / 255).h

    /// Where the inks come from: the picture (Auto), or one color that becomes the light ink (Accent and Custom).
    public enum Choice: Hashable, Sendable {
        case auto
        case color(SIMD3<Double>)
    }

    /// Two inks of one hue, gamma-encoded sRGB 0...1.
    public struct Inks: Hashable, Sendable {
        public var deep: SIMD3<Double>, light: SIMD3<Double>
    }

    /// What the page shows over the art, in points from the canvas's top left.
    public enum Shape: Hashable, Sendable {
        /// Every page other than a new thread or a thread: the art as it is, under that page's scrim.
        case plain
        /// The new-thread page: the dots thin around the composer and toward the panel's edges.
        case hero(composer: [Double]?)
        /// A thread: behind the reading column the dots thin and dim until text keeps its floors.
        case thread(column: [Double]?)
    }

    // MARK: Inks

    /// Auto: the picture's most saturated prominent hue (OKLCH, chroma squared times area, near-greys ignored), with
    /// two corrections: olive (75 to 115 degrees) turns mustard at these lightnesses, so it rotates to leaf green 130;
    /// a near-grey picture (under 20% chromatic pixels) takes Capy's navy hue instead of a hue it barely has.
    public nonisolated static func autoHue(_ picture: CGImage) -> Double {
        let w = 120, h = 80
        guard let px = cover(picture, width: w, height: h) else { return navyHue }
        var score = [Double](repeating: 0, count: 24), sx = score, sy = score
        var chromatic = 0
        for i in 0..<(w * h) {
            let o = oklch(srgb: SIMD3(Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2])) / 255)
            guard o.c > 0.035, o.l > 0.12, o.l < 0.96 else { continue }
            chromatic += 1
            let k = Int(o.h / 15) % 24, weight = o.c * o.c
            score[k] += weight; sx[k] += cos(o.h * .pi / 180) * weight; sy[k] += sin(o.h * .pi / 180) * weight
        }
        if Double(chromatic) / Double(w * h) < 0.2 { return navyHue }
        var best = 0, bestScore = -1.0
        for k in 0..<24 {
            let s = 0.5 * score[(k + 23) % 24] + score[k] + 0.5 * score[(k + 1) % 24]
            if s > bestScore { bestScore = s; best = k }
        }
        var x = 0.0, y = 0.0
        for k in [(best + 23) % 24, best, (best + 1) % 24] { x += sx[k]; y += sy[k] }
        var hue = atan2(y, x) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (75...115).contains(hue) ? 130 : hue
    }

    /// Auto's inks for `hue`.
    public nonisolated static func inks(hue: Double) -> Inks {
        Inks(deep: srgb(oklch: deep.l, deep.c, hue), light: srgb(oklch: light.l, light.c, hue + lightTurn))
    }

    /// Accent and Custom: `color` is the light ink as it is, and the deep ink is its hue at the deep lightness.
    public nonisolated static func inks(light color: SIMD3<Double>) -> Inks {
        let o = oklch(srgb: color)
        return Inks(deep: srgb(oklch: deep.l, min(o.c, deep.c), o.h), light: color)
    }

    // MARK: Tone

    /// The picture's tone on the canvas, one byte a cell, row 0 at the top: gamma-encoded luma, auto levels from the
    /// 1st to the 99th percentile, half an S-curve and a gamma of 1.15 that keeps the ground dark. `hue` is Auto's.
    public struct Tone: Sendable {
        public let width: Int, height: Int
        public let values: [UInt8]
        public let hue: Double
        /// The median of `values` and of their inverse (light appearance), 0...1, for the shadow lift.
        let median: Double
    }

    nonisolated static func tone(_ picture: CGImage, width w: Int, height h: Int) -> Tone? {
        guard w > 0, h > 0, let px = cover(picture, width: w, height: h) else { return nil }
        var l = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let y = 0.2126 * lin(Double(px[i * 4]) / 255) + 0.7152 * lin(Double(px[i * 4 + 1]) / 255) + 0.0722 * lin(Double(px[i * 4 + 2]) / 255)
            l[i] = enc(y)
        }
        let sorted = l.sorted()
        var lo = sorted[sorted.count / 100], hi = sorted[min(sorted.count * 99 / 100, sorted.count - 1)]
        // A flat picture (a plain color desktop) has no range to stretch: its own lightness carries the tone.
        if hi - lo < 0.08 { lo = 0; hi = 1 }
        let values = l.map { v -> UInt8 in
            let x = min(max((v - lo) / (hi - lo), 0), 1)
            let t = pow(0.5 * x + 0.5 * DitherArt.smoothstep(0, 1, x), 1.15)
            return UInt8((t * 255).rounded())
        }
        let mid = values.sorted()[values.count / 2]
        return Tone(width: w, height: h, values: values, hue: autoHue(picture), median: Double(mid) / 255)
    }

    /// The gamma that lifts a median `m` to `medianFloor`, never darkening and never past 0.5.
    nonisolated static func lift(median m: Double) -> Double {
        guard m > 0.001, m < medianFloor else { return m <= 0.001 ? 0.5 : 1 }
        return max(log(medianFloor) / log(m), 0.5)
    }

    // MARK: Fall-off

    /// The new-thread page: how much of the art survives at `p` (points, top-left origin): it thins toward the
    /// composer and toward the panel's sides and foot, so the UI reads without a dim layer (the mockup's fall-off).
    nonisolated static func heroDensity(_ x: Double, _ y: Double, panel: CGSize, composer: [Double]?) -> Double {
        var around = 1.0
        if let c = composer, c.count == 4 {
            let dx = (x - (c[0] + c[2] / 2)) / 760, dy = (y - (c[1] + c[3] / 2 - 10)) / 230
            around = 0.3 + 0.7 * DitherArt.smoothstep(0.3, 1.5, (dx * dx + dy * dy).squareRoot())
        }
        let edge = DitherArt.smoothstep(0, 140, x) * DitherArt.smoothstep(0, 120, panel.width - x) * DitherArt.smoothstep(0, 200, panel.height - y)
        return around * (0.25 + 0.75 * edge)
    }

    /// How far beside the reading column the art comes back to full, in points.
    nonisolated static let columnFeather: Double = 120
    /// The share of the dots left right behind the column.
    nonisolated static let columnDensity = 0.4
    /// Text floors behind the column, measured against the worst cell: body 7:1, muted 4.5:1.
    nonisolated static let bodyFloor = 7.0, mutedFloor = 4.5

    /// 0 behind the column, easing to 1 `columnFeather` beside it.
    nonisolated static func columnOpen(_ x: Double, column c: [Double]) -> Double {
        let d = x < c[0] ? c[0] - x : x > c[0] + c[2] ? x - c[0] - c[2] : 0
        return DitherArt.smoothstep(0, 1, d / columnFeather)
    }

    // MARK: Threshold

    /// The art: `tone` thresholded in `inks` over `ground` for `shape`. In dark the light parts of the picture take
    /// ink (ground, deep, light); in light the dark parts do (ground, light, deep). Dither runs only between
    /// neighbouring levels. `text` is the body and muted text colors (sRGB 0...1), whose floors hold behind a column.
    nonisolated static func render(_ tone: Tone, inks: Inks, ground: SIMD3<Double>, dark: Bool, shape: Shape,
                                   text: [SIMD3<Double>]) -> CGImage? {
        let w = tone.width, h = tone.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        let unit = Double(cell)
        let panel = CGSize(width: Double(w) * unit, height: Double(h) * unit)
        // Level 1 sits next to the ground, level 2 beyond it.
        let levels = dark ? [inks.deep, inks.light] : [inks.light, inks.deep]
        let g = lift(median: dark ? tone.median : 1 - tone.median)
        let lut = (0..<256).map { i -> Double in
            let t = Double(i) / 255
            return pow(dark ? t : 1 - t, g)
        }
        let groundBytes = ground.byteTriple
        let levelBytes = levels.map(\.byteTriple)
        // Behind a column, the luminance each level may reach so the text keeps its floors.
        let groundY = luminance(ground)
        let bound = textBound(text, dark: dark)
        let capped = levels.map { capToward(ground: ground, ink: $0, groundY: groundY, bound: bound, dark: dark) }
        var row = [Double](repeating: 1, count: w)
        var open = [Double](repeating: 1, count: w)
        if case let .thread(column?) = shape, column.count == 4 {
            for x in 0..<w { open[x] = columnOpen((Double(x) + 0.5) * unit, column: column) }
        }
        for y in 0..<h {
            let py = (Double(y) + 0.5) * unit
            for x in 0..<w {
                let px = (Double(x) + 0.5) * unit
                var density = 1.0, top = 2.0
                switch shape {
                case .plain: break
                case let .hero(composer): density = heroDensity(px, py, panel: panel, composer: composer)
                case .thread:
                    // Behind the column the dots thin and stay on the near level, then come back over the feather.
                    let z = open[x]
                    density = columnDensity + (1 - columnDensity) * z
                    top = coverage + (2 - coverage) * z
                }
                row[x] = min(lut[Int(tone.values[y * w + x])] * coverage * 2 * density, top)
            }
            let b = (y & 7) * 8
            for x in 0..<w {
                let v = row[x]
                let lo = Int(v), threshold = (Double(DitherArt.bayer[b + (x & 7)]) + 0.5) / 64
                let level = lo < 2 && v - Double(lo) > threshold ? lo + 1 : lo
                let i = (y * w + x) * 4
                guard level > 0 else { data[i] = groundBytes.0; data[i + 1] = groundBytes.1; data[i + 2] = groundBytes.2; continue }
                var c = levelBytes[level - 1]
                if open[x] < 1 {
                    // Over the feather the cap eases from the text's floor to the ink itself.
                    let mixed = capped[level - 1] + (levels[level - 1] - capped[level - 1]) * open[x]
                    c = mixed.byteTriple
                }
                data[i] = c.0; data[i + 1] = c.1; data[i + 2] = c.2
            }
        }
        return ctx.makeImage()
    }

    /// The brightest (dark) or darkest (light) luminance behind text that keeps body at `bodyFloor` and muted at
    /// `mutedFloor`; nil when no text is given.
    nonisolated static func textBound(_ text: [SIMD3<Double>], dark: Bool) -> Double? {
        guard text.count == 2 else { return nil }
        let body = luminance(text[0]), muted = luminance(text[1])
        if dark { return min((body + 0.05) / bodyFloor - 0.05, (muted + 0.05) / mutedFloor - 0.05) }
        return max(bodyFloor * (body + 0.05) - 0.05, mutedFloor * (muted + 0.05) - 0.05)
    }

    /// `ink` moved toward `ground` in linear light until its luminance is within `bound`. The two stay one hue.
    nonisolated static func capToward(ground: SIMD3<Double>, ink: SIMD3<Double>, groundY: Double, bound: Double?, dark: Bool) -> SIMD3<Double> {
        let y = luminance(ink)
        guard let bound, dark ? y > bound : y < bound else { return ink }
        let share = abs(y - groundY) < 1e-6 ? 0 : min(max((bound - groundY) / (y - groundY), 0), 1)
        let gl = SIMD3(lin(ground.x), lin(ground.y), lin(ground.z)), il = SIMD3(lin(ink.x), lin(ink.y), lin(ink.z))
        // A little short of the exact share, so rounding to bytes never crosses the floor.
        let m: SIMD3<Double> = gl + (il - gl) * max(share - 0.03, 0)
        return SIMD3(enc(m.x), enc(m.y), enc(m.z))
    }

    // MARK: Cache

    /// One picture's tone at one canvas size, the last asked for. The art re-thresholds it for each page and ink.
    private struct CacheKey: Hashable { var url: URL, width: Int, height: Int }
    private nonisolated static let cache = OSAllocatedUnfairLock<(key: CacheKey, tone: Tone)?>(initialState: nil)

    /// The tone of the first of `urls` that decodes, at `width` x `height` cells, from the cache or decoded once.
    nonisolated static func tone(_ urls: [URL], width: Int, height: Int) -> Tone? {
        for url in urls {
            let key = CacheKey(url: url, width: width, height: height)
            if let hit = cache.withLock({ $0?.key == key ? $0?.tone : nil }) { return hit }
            guard let picture = DitherArt.picture(url, maxPixels: max(width, height) * 2),
                  let tone = tone(picture, width: width, height: height) else { continue }
            cache.withLock { $0 = (key, tone) }
            return tone
        }
        return DitherArt.builtInPicture().flatMap { tone($0, width: width, height: height) }
    }

    /// Drops the cached tone, for a hidden window.
    nonisolated static func dropCache() { cache.withLock { $0 = nil } }

    // MARK: Color

    /// The picture covering `width` x `height`, centered, as RGBA bytes with row 0 at the top.
    nonisolated static func cover(_ picture: CGImage, width w: Int, height h: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            let scale = max(Double(w) / Double(picture.width), Double(h) / Double(picture.height))
            let pw = Double(picture.width) * scale, ph = Double(picture.height) * scale
            ctx.interpolationQuality = .high
            ctx.draw(picture, in: CGRect(x: (Double(w) - pw) / 2, y: (Double(h) - ph) / 2, width: pw, height: ph))
            return true
        }
        return ok ? px : nil
    }

    nonisolated static func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    nonisolated static func enc(_ v: Double) -> Double { let v = min(max(v, 0), 1); return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    nonisolated static func luminance(_ c: SIMD3<Double>) -> Double { 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z) }
    nonisolated static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// OKLCH (Ottosson 2020) of a gamma-encoded sRGB color.
    nonisolated static func oklch(srgb c: SIMD3<Double>) -> (l: Double, c: Double, h: Double) {
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(B, A) * 180 / .pi
        if h < 0 { h += 360 }
        return (L, (A * A + B * B).squareRoot(), h)
    }

    /// Gamma-encoded sRGB at OKLCH, the chroma reduced until it fits sRGB.
    nonisolated static func srgb(oklch l: Double, _ c: Double, _ h: Double) -> SIMD3<Double> {
        func linear(_ c: Double) -> SIMD3<Double> {
            let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
            let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            return SIMD3(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
                         -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
                         -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)
        }
        var chroma = c
        while chroma > 0 {
            let v = linear(chroma)
            if v.min() >= -0.0005, v.max() <= 1.0005 { return SIMD3(enc(v.x), enc(v.y), enc(v.z)) }
            chroma -= 0.002
        }
        let v = linear(0)
        return SIMD3(enc(v.x), enc(v.y), enc(v.z))
    }
}

extension SIMD3 where Scalar == Double {
    /// Gamma-encoded 0...1 as three bytes.
    nonisolated var byteTriple: (UInt8, UInt8, UInt8) {
        func b(_ v: Double) -> UInt8 { UInt8(min(max(v * 255, 0), 255).rounded()) }
        return (b(x), b(y), b(z))
    }
}
