import CoreGraphics
import Foundation
import os

/// Redesign's Background = Picture (the user, 2026-11-21: "i like b1", "i like 2 ink", "no motion its horrid"): the
/// whole picture as an ordered Bayer dither in two inks of one hue on the ground, on a cell lattice from the panel's top
/// left whose size is the "Dot size" setting (`DitherDotSize`), with
/// no photo showing through and no dim layer. The picture's tone (`Tone`) is computed once per picture and canvas size
/// and cached; the inks and the page's shape (the composer's fall-off on a new thread, the reading column in a thread)
/// only re-threshold it, a few milliseconds on a worker. Touches no AppKit view, so it runs on any thread.
public enum PictureInk {
    /// The most of a cell's level that ink may cover, so a bright sky keeps a visible pattern.
    nonisolated static let coverage = 0.85
    /// Dark pictures are lifted until the median tone reaches this, so they don't come out as an empty frame with
    /// scattered dots (the mockup's dark coastline and hills). A low-key picture (`lowKey`) is not lifted.
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

    /// The picture's tone on the canvas, one byte a cell, row 0 at the top: gamma-encoded luma, smoothed, auto levels,
    /// half an S-curve and a gamma of 1.15 that keeps the ground dark. `hue` is Auto's.
    public struct Tone: Sendable {
        public let width: Int, height: Int
        public let values: [UInt8]
        public let hue: Double
        /// The median of `values`, 0...1, for the shadow lift.
        let median: Double
        /// How low-key the picture is for dark (`lowKey` of its histogram) and how high-key for light (the same rule on
        /// the inverted histogram), 0...1. A low-key picture keeps its black: no shadow lift.
        var lowKey = 0.0, highKey = 0.0
        /// The cell, in points.
        var unit = 3.0
    }

    /// Below this tone (after levels, 0...1, from the ground's side) a cell draws no dot, so grain and faint haze
    /// can't speckle the ground; tones above it ease in from no dots at all, so there is no contour.
    nonisolated static let blackPoint = 0.06
    /// The smoothing's tonal reach: neighbours closer than about this in tone blend, an edge brighter than it stays.
    nonisolated static let smoothRange = 0.06
    /// From this share of the levels' range up, a cell takes its brightest point instead of its mean, so a highlight
    /// smaller than a cell (a lamp head) still lights it.
    nonisolated static let highlightStart = 0.75
    /// Samples per cell side: about 0.75pt each, so the cell's mean and peak see sub-cell detail.
    nonisolated static func subsamples(cell: Double) -> Int { max(2, Int((cell / 0.75).rounded())) }

    /// How low-key a picture is, from a 256-bin histogram of its gamma-encoded luma (any scale): 1 when most of the
    /// frame is near black (under 0.1) and little sits in the mid-shadows (0.1 to 0.35), like a night photo of a few
    /// lamps; 0 for a dark landscape whose shadows hold broad detail, which the lift should fill.
    nonisolated static func lowKey(_ histogram: [Double]) -> Double {
        let total = histogram.reduce(0, +)
        guard histogram.count == 256, total > 0 else { return 0 }
        let black = histogram[0..<26].reduce(0, +) / total, shadow = histogram[26..<90].reduce(0, +) / total
        return DitherArt.smoothstep(0.55, 0.75, black) * (1 - DitherArt.smoothstep(0.15, 0.3, shadow))
    }

    /// The long side Auto's hue is read from. The hue comes from its own decode of this size, never from the tone's
    /// picture, which is decoded larger for a bigger window or finer dots: on the Great Wave a decode under about
    /// 1930 pixels scored blue (245 degrees) and a larger one olive, turned green, so a window resize changed the inks.
    nonisolated static let hueSide = 600

    nonisolated static func tone(_ picture: CGImage, width w: Int, height h: Int, cell: Double = 3, hue: Double? = nil) -> Tone? {
        let s = subsamples(cell: cell), sw = w * s, sh = h * s
        guard w > 0, h > 0, let px = cover(picture, width: sw, height: sh) else { return nil }
        // Linear luma per sample; the cell's mean (the area's light) and its brightest sample.
        let linear = (0..<256).map { Float(lin(Double($0) / 255)) }
        var sum = [Float](repeating: 0, count: w * h), top = sum
        px.withUnsafeBufferPointer { p in
            linear.withUnsafeBufferPointer { l in
                sum.withUnsafeMutableBufferPointer { m in
                    top.withUnsafeMutableBufferPointer { t in
                        for y in 0..<sh {
                            let row = (y / s) * w, base = y * sw * 4
                            for x in 0..<sw {
                                let i = base + x * 4
                                let v = 0.2126 * l[Int(p[i])] + 0.7152 * l[Int(p[i + 1])] + 0.0722 * l[Int(p[i + 2])]
                                let c = row + x / s
                                m[c] += v
                                if v > t[c] { t[c] = v }
                            }
                        }
                    }
                }
            }
        }
        var mean = [Double](repeating: 0, count: w * h), peak = mean
        let n = Double(s * s)
        for c in 0..<(w * h) { mean[c] = enc(Double(sum[c]) / n); peak[c] = enc(Double(top[c])) }
        let smooth = smoothed(mean, width: w, height: h)
        var histogram = [Double](repeating: 0, count: 256)
        for v in smooth { histogram[min(Int(v * 255), 255)] += 1 }
        let lowKey = lowKey(histogram), highKey = Self.lowKey(histogram.reversed())
        let sorted = smooth.sorted()
        func q(_ f: Double) -> Double { sorted[min(Int(Double(sorted.count) * f), sorted.count - 1)] }
        // A low-key picture's 99th percentile is haze, not its lights: its range runs to the 99.9th instead, so the
        // haze stays dim. A high-key one keeps its darks the same way in light.
        var lo = q(0.01) + (q(0.001) - q(0.01)) * highKey, hi = q(0.99) + (q(0.999) - q(0.99)) * lowKey
        // A flat picture (a plain color desktop) has no range to stretch: its own lightness carries the tone.
        if hi - lo < 0.08 { lo = 0; hi = 1 }
        let start = lo + highlightStart * (hi - lo)
        let values = (0..<(w * h)).map { c -> UInt8 in
            let m = smooth[c], p = peak[c]
            let v = p > m ? m + (p - m) * DitherArt.smoothstep(start, hi, p) : m
            let x = min(max((v - lo) / (hi - lo), 0), 1)
            let t = pow(0.5 * x + 0.5 * DitherArt.smoothstep(0, 1, x), 1.15)
            return UInt8((t * 255).rounded())
        }
        let mid = values.sorted()[values.count / 2]
        return Tone(width: w, height: h, values: values, hue: hue ?? autoHue(picture), median: Double(mid) / 255,
                    lowKey: lowKey, highKey: highKey, unit: cell)
    }

    /// A 3 x 3 edge-keeping blur (a tent in space, weighted by tonal closeness): grain under `smoothRange` blends with
    /// its neighbours so it can't flip single cells, while the edge of a bright shape stays where it is.
    nonisolated static func smoothed(_ v: [Double], width w: Int, height h: Int) -> [Double] {
        let near = (0..<256).map { exp(-pow(Double($0) / 255 / smoothRange, 2) / 2) }
        var out = v
        v.withUnsafeBufferPointer { v in
            near.withUnsafeBufferPointer { near in
                out.withUnsafeMutableBufferPointer { out in
                    for y in 0..<h {
                        for x in 0..<w {
                            let c = v[y * w + x]
                            var sum = 0.0, weight = 0.0
                            for dy in -1...1 {
                                let yy = min(max(y + dy, 0), h - 1)
                                for dx in -1...1 {
                                    let xx = min(max(x + dx, 0), w - 1), n = v[yy * w + xx]
                                    let k = Double((2 - abs(dx)) * (2 - abs(dy))) * near[min(Int(abs(n - c) * 255), 255)]
                                    sum += n * k; weight += k
                                }
                            }
                            out[y * w + x] = sum / weight
                        }
                    }
                }
            }
        }
        return out
    }

    /// The gamma that lifts a median `m` to `medianFloor`, never darkening and never past 0.5.
    nonisolated static func lift(median m: Double) -> Double {
        guard m > 0.001, m < medianFloor else { return m <= 0.001 ? 0.5 : 1 }
        return max(log(medianFloor) / log(m), 0.5)
    }

    /// The lift for a picture `key` low-key (0...1): the full lift for an underexposed picture, none for a low-key one.
    nonisolated static func lift(median m: Double, lowKey key: Double) -> Double {
        1 + (lift(median: m) - 1) * (1 - min(max(key, 0), 1))
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

    /// The text floors behind a thread's reading column, against the worst cell. Dark holds body at 15:1 and muted at
    /// 7.5:1: 14 and 6.8, what the Great Wave in a 1975pt window needed (picture-fix-2026-11-21/5 and 7), still left
    /// muted text and inline code on busy dots for the round-0 reviewers (W3). Light's minimum is 7:1 and 4.5:1;
    /// its column holds the calmer `lightColumnFloors` (`columnBound`).
    nonisolated static func floors(dark: Bool) -> (body: Double, muted: Double) { dark ? (15, 7.5) : (7, 4.5) }
    /// How the cap lets go beside the column (`calmFalloff`): the power on the distance before its smoothstep.
    nonisolated static let calmSpread = 1.3
    /// How fast the cap relaxes toward the window's edge: `cellCap` takes the fall-off to this power, so above 1 the
    /// cap lets go sooner beside the column and a picture in the margin keeps more of its light. Compared at 1, 2 and 3
    /// on the Great Wave, the street lamps and the full moon in a 1975pt window: 3 brought back a bright strip beside
    /// the column on the Great Wave, 2 keeps its fade smooth and gives the lamps and the moon's rim a little more light.
    nonisolated static let capRelax = 2.0
    /// The threshold jitter along the fade, in levels: a hash, strongest mid-fade and none at either end, so the line
    /// where a fade crosses from the deep ink to the light one breaks into dots instead of a solid strip. It never
    /// touches a cell with no tone, so black stays black.
    nonisolated static let calmJitter = 0.16

    /// The shortest distance, in points, the cap gets to let go over. A margin narrower than this ends with the cap
    /// still partly on, so a small window's margin stays dark-ish to the edge. Squeezing the whole fade into a 35pt
    /// margin at 1100pt brought the picture back at full strength in a bright strip along both edges.
    nonisolated static let calmReach = 160.0

    /// The cap's weight at `x` for a thread's reading column: 1 across the column, then `calmFalloff` of the way out
    /// over the margin on that side or `calmReach`, whichever is longer. A margin at least `calmReach` wide gets the
    /// whole curve and ends at 0; a narrower one is cut off partway, so its edge keeps some of the cap.
    nonisolated static func columnCalm(_ x: Double, column c: [Double], panelWidth: Double, hold: Double = calmHold) -> Double {
        let left = c[0], right = c[0] + c[2]
        if x >= left, x <= right { return 1 }
        let (d, margin) = x < left ? (left - x, left) : (x - right, panelWidth - right)
        return calmFalloff(max(d - hold, 0) / max(margin - hold, calmReach))
    }

    /// How far beside the column dark's cap holds fully before it starts to let go, in points. The inset card with the
    /// right panel open leaves margins of about 48pt; without the hold the cap let go across them and left a bright
    /// strip of picture at each of the card's edges (round-0 review, 03-thread-right-panel.dark.png). Light holds
    /// none: a narrow light card keeps most of the cap to its edges anyway (`calmReach`), and a hold left it no
    /// picture at all while the column was plain ground.
    nonisolated static let calmHold = 64.0

    /// The cap's weight at `t` of the way from the column's edge (0) to the panel's edge (1): 1 to 0 on a smoothstep of
    /// `t` to the `calmSpread`, so it has no slope at either end and no visible start or end.
    nonisolated static func calmFalloff(_ t: Double) -> Double {
        1 - DitherArt.smoothstep(0, 1, pow(min(max(t, 0), 1), calmSpread))
    }

    /// The brightest (dark) or darkest (light) a cell may be at fall-off `f`: the column's cap at 1, relaxing in
    /// luminance on a log scale to no cap at 0, the content area's edge. The cap only bites where the picture is brighter
    /// than it (darker in light), so a dark photo behind a thread is left as it is.
    nonisolated static func cellCap(column cap: Double, falloff f: Double, dark: Bool) -> Double {
        let k = pow(min(max(f, 0), 1), capRelax)
        return dark ? pow(max(cap, 1e-6), k) : 1 - pow(max(1 - cap, 1e-6), k)
    }

    /// A cell's luminance `y` held to `cap`: unchanged when it is within it, the cap when it is past it.
    nonisolated static func capped(_ y: Double, cap: Double, dark: Bool) -> Double { dark ? min(y, cap) : max(y, cap) }

    // MARK: Threshold

    /// The art: `tone` thresholded in `inks` over `ground` for `shape`. In dark the light parts of the picture take
    /// ink (ground, deep, light); in light the dark parts do (ground, light, deep). Dither runs only between
    /// neighbouring levels. `text` is the body and muted text colors (sRGB 0...1), whose floors hold behind a column:
    /// there each ink is held to the cell cap (`cellCap`), which relaxes across the margin, and nothing else changes.
    /// `dim` is "Dim behind text" (`TextDim`), which moves the floors' bound and leaves the falloff's shape alone.
    nonisolated static func render(_ tone: Tone, inks: Inks, ground: SIMD3<Double>, dark: Bool, shape: Shape,
                                   text: [SIMD3<Double>], dim: Int = TextDim.standard) -> CGImage? {
        let w = tone.width, h = tone.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        let unit = tone.unit
        let panel = CGSize(width: Double(w) * unit, height: Double(h) * unit)
        // Level 1 sits next to the ground, level 2 beyond it.
        let levels = dark ? [inks.deep, inks.light] : [inks.light, inks.deep]
        let g = lift(median: dark ? tone.median : 1 - tone.median, lowKey: dark ? tone.lowKey : tone.highKey)
        let lut = (0..<256).map { i -> Double in
            let t = Double(i) / 255
            return pow(max((dark ? t : 1 - t) - blackPoint, 0) / (1 - blackPoint), g)
        }
        let groundBytes = ground.byteTriple
        let levelBytes = levels.map(\.byteTriple)
        // Behind a column each level's ink is held to the cell cap, which relaxes toward the panel's edges.
        let groundY = luminance(ground)
        var row = [Double](repeating: 1, count: w), fade = [Double](repeating: 0, count: w)
        var columnInks: [(UInt8, UInt8, UInt8)]?
        // Light: both inks move toward the ground together by one share per cell (`quiet`), so the picture keeps its
        // two tones and its shapes at a lower contrast instead of collapsing to one pale ink at a floor.
        let table = dark ? [] : quietInks(levels, ground: ground)
        var quietX: [UInt8]?, quietCell: [UInt8]?, smoothAt: [Double]?
        let deepest = levels.map(luminance).min() ?? groundY
        if !dark, case let .thread(column?) = shape, column.count == 4,
           let bound = TextDim.pictureBound(columnBound(text, groundY: groundY, dark: false), groundY: groundY, dark: false, at: dim) {
            var q = [UInt8](repeating: UInt8(quietSteps), count: w), sm = [Double](repeating: 0, count: w)
            for x in 0..<w {
                let f = columnCalm((Double(x) + 0.5) * unit, column: column, panelWidth: panel.width, hold: 0)
                fade[x] = calmJitter * 4 * f * (1 - f)
                sm[x] = f
                let cap = cellCap(column: bound, falloff: f, dark: false)
                q[x] = quietStep(share: groundY - deepest > 1e-6 ? (groundY - cap) / (groundY - deepest) : 1)
            }
            quietX = q
            smoothAt = sm
        } else if !dark, case let .hero(composer?) = shape, composer.count == 4 {
            let bound = columnBound(text, groundY: groundY, dark: false)
            var q = [UInt8](repeating: UInt8(quietSteps), count: w * h)
            if let bound, groundY - deepest > 1e-6 {
                let near = (groundY - bound) / (groundY - deepest)
                for y in 0..<h {
                    for x in 0..<w {
                        let c = heroCalm((Double(x) + 0.5) * unit, (Double(y) + 0.5) * unit, composer: composer)
                        q[y * w + x] = quietStep(share: 1 - (1 - min(near, 1)) * c)
                    }
                }
            }
            quietCell = q
        }
        if dark, case let .thread(column?) = shape, column.count == 4,
           let bound = TextDim.pictureBound(columnBound(text, groundY: groundY, dark: dark), groundY: groundY, dark: dark, at: dim) {
            var inksAt = [(UInt8, UInt8, UInt8)](repeating: (0, 0, 0), count: w * 2)
            for x in 0..<w {
                let f = columnCalm((Double(x) + 0.5) * unit, column: column, panelWidth: panel.width, hold: dark ? calmHold : 0)
                let cap = cellCap(column: bound, falloff: f, dark: dark)
                fade[x] = calmJitter * 4 * f * (1 - f)
                for k in 0..<2 { inksAt[x * 2 + k] = capToward(ground: ground, ink: levels[k], groundY: groundY, bound: cap, dark: dark).byteTriple }
            }
            columnInks = inksAt
        }
        // Light behind a column: the tone over a few cells, so the dots form the picture's broad shapes in an even
        // screen instead of single dots beside the glyphs.
        let soft = smoothAt.map { _ in softTone(tone.values, width: w, height: h, radius: lightSoften) }
        let ledge = feather(tone.values, lut: lut, width: w, height: h)
        for y in 0..<h {
            let py = (Double(y) + 0.5) * unit
            for x in 0..<w {
                let px = (Double(x) + 0.5) * unit
                var density = 1.0
                if case let .hero(composer) = shape { density = heroDensity(px, py, panel: panel, composer: composer) }
                var t = Double(tone.values[y * w + x])
                if let soft, let s = smoothAt?[x], s > 0 { t += (Double(soft[y * w + x]) - t) * s }
                var v = lut[Int(t.rounded())] * coverage * 2 * density
                if v == 0 { v = Double(ledge[y * w + x]) * coverage * 2 * density }
                row[x] = v
                if fade[x] > 0, v > 0 {
                    var hash = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
                    hash = (hash ^ (hash >> 13)) &* 1_274_126_177
                    let reach = fade[x] * DitherArt.smoothstep(0, 0.25, v)
                    row[x] = min(max(v + reach * (Double(hash >> 24) / 255 - 0.5), 0), 2)
                }
            }
            let b = (y & 7) * 8
            for x in 0..<w {
                let v = row[x]
                let lo = Int(v), threshold = (Double(DitherArt.bayer[b + (x & 7)]) + 0.5) / 64
                let level = lo < 2 && v - Double(lo) > threshold ? lo + 1 : lo
                let i = (y * w + x) * 4
                guard level > 0 else { data[i] = groundBytes.0; data[i + 1] = groundBytes.1; data[i + 2] = groundBytes.2; continue }
                let c: (UInt8, UInt8, UInt8)
                if let q = quietX?[x] ?? quietCell?[y * w + x] { c = table[Int(q) * 2 + level - 1] } else { c = columnInks?[x * 2 + level - 1] ?? levelBytes[level - 1] }
                data[i] = c.0; data[i + 1] = c.1; data[i + 2] = c.2
            }
        }
        return ctx.makeImage()
    }

    /// The brightest (dark) or darkest (light) luminance behind text that keeps body and muted at their `floors`; nil
    /// when no text is given.
    nonisolated static func textBound(_ text: [SIMD3<Double>], dark: Bool) -> Double? {
        guard text.count == 2 else { return nil }
        let body = luminance(text[0]), muted = luminance(text[1]), f = floors(dark: dark)
        if dark { return min((body + 0.05) / f.body - 0.05, (muted + 0.05) / f.muted - 0.05) }
        return max(f.body * (body + 0.05) - 0.05, f.muted * (muted + 0.05) - 0.05)
    }

    /// The bound behind a thread's column at the standard "Dim behind text": the text floors' bound in dark; in light
    /// the calmer `lightColumnFloors`. Light's own 7:1 and 4.5:1 floors put pale ink right behind the words and all
    /// four round-0 reviewers found it hard to read (W3, W7, T2); plain ground (2026-11-26) lost the picture at
    /// ordinary widths (round 1). Nil when no text is given.
    nonisolated static func columnBound(_ text: [SIMD3<Double>], groundY: Double, dark: Bool) -> Double? {
        guard let bound = textBound(text, dark: dark) else { return nil }
        if dark { return bound }
        let muted = luminance(text[1]), body = luminance(text[0]), f = lightColumnFloors
        return max(bound, f.muted * (muted + 0.05) - 0.05, f.body * (body + 0.05) - 0.05)
    }

    /// Light's floors behind the column and around the composer, against the deepest ink: muted 5:1 where light's
    /// muted (#5c5c5a) has 6.3:1 on the plain ground, which puts the deep ink at about a third of its strength and
    /// leaves body text over 13:1. Compared on 2026-11-26 with 4.6 (the most picture, but right at the floor) and
    /// 5.4 (calmest, the picture faint), light-picture/sheet-thread-*.png.
    nonisolated static let lightColumnFloors = (body: 12.0, muted: 5.0)
    /// Light behind the column: the tone's box blur radius, in cells. Single dots beside glyphs read as noise; a
    /// softened tone draws an even screen in the picture's broad shapes. It eases in on the column's fall-off.
    nonisolated static let lightSoften = 2

    /// How many shares `quietInks` holds between the ground (0) and the inks as they are (`quietSteps`).
    nonisolated static let quietSteps = 64
    /// Rounds down, so a quantized share never takes an ink past its bound.
    nonisolated static func quietStep(share: Double) -> UInt8 { UInt8((min(max(share, 0), 1) * Double(quietSteps)).rounded(.down)) }

    /// Light's inks at each share from the ground to themselves, in linear light, as byte triples: entry `2 * q + k`
    /// is level `k + 1` at share `q / quietSteps`. Both inks scale by the same share, so they keep their ratio.
    nonisolated static func quietInks(_ levels: [SIMD3<Double>], ground: SIMD3<Double>) -> [(UInt8, UInt8, UInt8)] {
        let g = SIMD3(lin(ground.x), lin(ground.y), lin(ground.z))
        return (0...quietSteps).flatMap { q -> [(UInt8, UInt8, UInt8)] in
            let s = Double(q) / Double(quietSteps)
            return levels.map { ink in
                let m = g + (SIMD3(lin(ink.x), lin(ink.y), lin(ink.z)) - g) * s
                return SIMD3(enc(m.x), enc(m.y), enc(m.z)).byteTriple
            }
        }
    }

    /// The new-thread page in light: 1 at the composer, easing to 0 away from it, on `heroDensity`'s ellipse.
    nonisolated static func heroCalm(_ x: Double, _ y: Double, composer c: [Double]) -> Double {
        let dx = (x - (c[0] + c[2] / 2)) / 760, dy = (y - (c[1] + c[3] / 2 - 10)) / 230
        return 1 - DitherArt.smoothstep(0.3, 1.5, (dx * dx + dy * dy).squareRoot())
    }

    /// How many cells a long horizontal edge feathers into the empty ground beside it, the share of the tone it starts
    /// at, and how wide a run (cells each way) counts as long.
    nonisolated static let featherReach = 10, featherShare = 0.9, featherRun = 8

    /// Tone (0...1 after the black point) for the empty cells above and below a long horizontal edge, thinning over
    /// `featherReach` cells. A horizon of a dark photo (Big Sur Night Grasses: a lifted sky over a sea under the black
    /// point) drew a dot field that stopped on one ruler-straight row, which read as a seam (round-1 review, W3). Only
    /// a run of tone `featherRun` cells each way counts, so a lamp head keeps no halo and grain stays clean.
    nonisolated static func feather(_ values: [UInt8], lut: [Double], width w: Int, height h: Int) -> [Float] {
        var run = [Float](repeating: 0, count: w * h), out = run
        let span = Float(2 * featherRun + 1)
        for y in 0..<h {
            var s: Float = 0
            for x in -featherRun...featherRun { s += Float(lut[Int(values[y * w + min(max(x, 0), w - 1)])]) }
            for x in 0..<w {
                run[y * w + x] = s / span
                s += Float(lut[Int(values[y * w + min(x + featherRun + 1, w - 1)])]) - Float(lut[Int(values[y * w + max(x - featherRun, 0)])])
            }
        }
        for c in run.indices { run[c] *= Float(DitherArt.smoothstep(0.1, 0.3, Double(run[c]))) }
        for y in 0..<h {
            for x in 0..<w {
                var best: Float = 0
                for d in 1...featherReach {
                    let k = Float(featherShare) * (1 - Float(d) / Float(featherReach + 1))
                    if y >= d { best = max(best, run[(y - d) * w + x] * k) }
                    if y + d < h { best = max(best, run[(y + d) * w + x] * k) }
                }
                out[y * w + x] = best
            }
        }
        return out
    }

    /// The tone box-blurred over `radius` cells each way.
    nonisolated static func softTone(_ v: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        guard r > 0 else { return v }
        var a = [Double](repeating: 0, count: w * h), out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            var s = 0.0
            for x in -r...r { s += Double(v[y * w + min(max(x, 0), w - 1)]) }
            for x in 0..<w {
                a[y * w + x] = s / Double(2 * r + 1)
                s += Double(v[y * w + min(x + r + 1, w - 1)]) - Double(v[y * w + max(x - r, 0)])
            }
        }
        for x in 0..<w {
            var s = 0.0
            for y in -r...r { s += a[min(max(y, 0), h - 1) * w + x] }
            for y in 0..<h {
                out[y * w + x] = UInt8(min(max(s / Double(2 * r + 1), 0), 255).rounded())
                s += a[min(y + r + 1, h - 1) * w + x] - a[max(y - r, 0) * w + x]
            }
        }
        return out
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
    private struct CacheKey: Hashable { var url: URL, width: Int, height: Int, cell: Double }
    private nonisolated static let cache = OSAllocatedUnfairLock<(key: CacheKey, tone: Tone)?>(initialState: nil)

    /// The tone of the first of `urls` that decodes, at `width` x `height` cells of `cell` points, from the cache or
    /// decoded once.
    nonisolated static func tone(_ urls: [URL], width: Int, height: Int, cell: Double) -> Tone? {
        for url in urls {
            let key = CacheKey(url: url, width: width, height: height, cell: cell)
            if let hit = cache.withLock({ $0?.key == key ? $0?.tone : nil }) { return hit }
            guard let picture = DitherArt.picture(url, maxPixels: max(width, height) * subsamples(cell: cell)),
                  let tone = tone(picture, width: width, height: height, cell: cell,
                                  hue: DitherArt.picture(url, maxPixels: hueSide).map(autoHue)) else { continue }
            cache.withLock { $0 = (key, tone) }
            return tone
        }
        return DitherArt.builtInPicture().flatMap { tone($0, width: width, height: height, cell: cell) }
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

    /// Mid grey, the answer for a lightness or hue that is NaN or infinite.
    nonisolated static let nonFiniteFallback = SIMD3<Double>(repeating: 0.5)
    /// Above any sRGB color's OKLCH chroma (about 0.33), so the cap changes nothing a real color can reach and the
    /// fitting loop below runs at most `maxChroma / 0.002` steps.
    nonisolated static let maxChroma = 0.5

    /// Gamma-encoded sRGB at OKLCH, the chroma reduced until it fits sRGB. A NaN chroma counts as grey, an infinite
    /// or huge one as `maxChroma`, a lightness outside -1...2 as the nearer end, and a non-finite lightness or hue gives
    /// `nonFiniteFallback`.
    nonisolated static func srgb(oklch l: Double, _ c: Double, _ h: Double) -> SIMD3<Double> {
        guard l.isFinite, h.isFinite else { return nonFiniteFallback }
        // OKLCH lightness is 0...1. The wider clamp leaves every real color alone and keeps the cubes below finite.
        let l = min(max(l, -1), 2)
        func linear(_ c: Double) -> SIMD3<Double> {
            let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
            let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            return SIMD3(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
                         -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
                         -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)
        }
        var chroma = c.isNaN ? 0 : min(c, maxChroma)
        // Counted, so no input can spin it: 0.5 / 0.002 is 250 steps, the bound leaves room for rounding.
        for _ in 0..<Int(maxChroma / 0.002) + 2 where chroma > 0 {
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
