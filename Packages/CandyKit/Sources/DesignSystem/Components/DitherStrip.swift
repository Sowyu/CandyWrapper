import CoreGraphics
import Foundation
import QuartzCore

/// Redesign's section rule (the sidebar's Working, Snoozed and Settled headers): a short strip of dots on a fixed
/// lattice in the row's own color, dense after the label and thinning out to nothing well before the chevron, as in
/// the user's pick (redesign-user-notes r5-snoozed-pick-dither-line.png). The lattice is the header's own cell grid, so
/// strips in stacked headers share columns, and a cell's Bayer threshold comes from its column, not from where the
/// strip starts.
public enum DitherStrip {
    /// Cell size in points. Dots sit on every other cell, so they are 2pt squares 4pt apart, the mock's 4px dot pitch.
    public static let cell: CGFloat = 2
    /// Cell rows: dots on the first and last, so the strip is 6pt tall with two dot rows.
    public static let rows = 3
    /// The gap between the label and the strip.
    public static let gap: CGFloat = 8
    /// The share of the free span where the strip ends; past it no cell is on.
    public static let reach: Double = 0.7
    /// The share of the free span that keeps every dot before the thinning starts.
    public static let solid: Double = 0.3

    public struct Span: Equatable, Sendable {
        /// The strip's first lattice column, at `first * cell` points in the header.
        public var first: Int
        /// Columns from `first`; zero draws nothing.
        public var count: Int
        public var minX: CGFloat { CGFloat(first) * DitherStrip.cell }
        public var maxX: CGFloat { CGFloat(first + count) * DitherStrip.cell }
    }

    /// The columns between `labelEnd + gap` and `limit` (where the chevron or accessory's own gap starts), snapped
    /// inward to the lattice so no cell reaches either side.
    public static func span(labelEnd: CGFloat, limit: CGFloat) -> Span {
        let first = Int((max(0, labelEnd + gap) / cell).rounded(.up))
        let last = Int((limit / cell).rounded(.down))
        return Span(first: first, count: max(0, last - first))
    }

    /// The strip's cells: layer 1 on, 0 off. A dot is on where its density beats its Bayer threshold, read on the dot
    /// lattice (half the cell lattice) so neighbouring dots take neighbouring levels.
    public static func grid(_ span: Span) -> DitherFill.Grid { grid(span, stretch: 1) }

    /// The cells with the thinning end stretched out (`stretch` above 1) or gathered in (below 1); 1 is the strip at
    /// rest. Dots stay on the lattice: a stretch moves where each density level falls, not the dots between cells.
    public static func grid(_ span: Span, stretch: Double) -> DitherFill.Grid {
        var g = DitherFill.Grid(width: span.count, height: rows)
        let n = Double(span.count)
        let reach = min(1, Self.reach * stretch), solid = Self.solid * min(1, stretch)
        guard n * reach >= 1 else { return g }
        for i in 0..<span.count {
            let column = span.first + i
            guard column & 1 == 0 else { continue }
            let density = min(1, 1 - (Double(i) / n - solid) / (reach - solid))
            guard density > 0 else { break }
            for y in stride(from: 0, to: rows, by: 2) where density > DitherFill.threshold(column / 2, y / 2) {
                g[i, y] = 1
            }
        }
        return g
    }

    // MARK: Motion (the user, 2026-11-21: "animate this thing in the line")

    /// The wave's half width in points: a dot brightens over this distance either side of the front.
    public static let waveRadius: Double = 10
    /// One wave along the whole line.
    public static let waveDuration: Double = 0.5
    /// The opacity a dot has at rest under the full-strength fill an animation uses: the rest fill's 0.7.
    public static let restAlpha: Double = 0.7
    /// How far the strip gathers in when a section opens (it then stretches out to rest) and how far it reaches when
    /// one closes (it then gathers back to rest).
    public static let openFrom: Double = 0.55, closeFrom: Double = 1.35

    /// One animation frame as alpha values, one pixel per point, `rows * cell + 1` pixels tall with the extra pixel of
    /// headroom on top for the wave's 1pt lift. `wave` is the wave's progress (0 to 1) or nil; `stretch` as in
    /// `grid(_:stretch:)`. Each dot is a `cell` square on its lattice cell, or 1pt higher while the wave crest is on it.
    public static func frame(_ span: Span, stretch: Double, wave: Double?) -> (width: Int, height: Int, alpha: [UInt8]) {
        let c = Int(cell), w = span.count * c, h = rows * c + 1
        var alpha = [UInt8](repeating: 0, count: max(0, w * h))
        let g = grid(span, stretch: stretch)
        let length = Double(w)
        for i in 0..<span.count {
            for y in 0..<rows where g[i, y] != 0 {
                var lift = 0, a = restAlpha
                if let wave {
                    let front = -waveRadius + (length + 2 * waveRadius) * wave
                    let centre = Double(i * c) + Double(c) / 2
                    let k = max(0, 1 - abs(centre - front) / waveRadius)
                    a = restAlpha + (1 - restAlpha) * k
                    lift = k > 0.5 ? 1 : 0
                }
                let value = UInt8((a * 255).rounded())
                for dy in 0..<c { for dx in 0..<c {
                    let px = i * c + dx, py = 1 + y * c + dy - lift
                    alpha[py * w + px] = value
                } }
            }
        }
        return (w, h, alpha)
    }

    /// What a header's strip is doing: a wave and a stretch, each from its start time, either or both.
    public struct Motion: Equatable, Sendable {
        public var waveStart: Double?
        public var stretchStart: (time: Double, from: Double)?
        public init() {}
        public static func == (a: Self, b: Self) -> Bool {
            a.waveStart == b.waveStart && a.stretchStart?.time == b.stretchStart?.time && a.stretchStart?.from == b.stretchStart?.from
        }
        @MainActor public static var now: () -> Double = { CACurrentMediaTime() }

        /// The frame's stretch and wave at `now`, or nil once both are done and the strip is back at rest.
        public mutating func frame(now: Double, stretchDuration: Double) -> (stretch: Double, wave: Double?)? {
            var wave: Double?
            if let start = waveStart {
                let p = (now - start) / DitherStrip.waveDuration
                if p >= 1 { waveStart = nil } else { wave = max(0, p) }
            }
            var stretch = 1.0
            if let s = stretchStart {
                let p = (now - s.time) / stretchDuration
                if p >= 1 { stretchStart = nil } else {
                    let eased = 1 - pow(1 - max(0, p), 3) // ease out, as Motion.curve
                    stretch = s.from + (1 - s.from) * eased
                }
            }
            return waveStart == nil && stretchStart == nil && wave == nil ? nil : (stretch, wave)
        }
    }

    /// `frame` as an alpha mask image.
    public static func frameMask(_ span: Span, stretch: Double, wave: Double?) -> CGImage? {
        let f = frame(span, stretch: stretch, wave: wave)
        guard f.width > 0, f.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: f.width, height: f.height, bitsPerComponent: 8, bytesPerRow: f.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: f.width * f.height * 4) else { return nil }
        for (i, a) in f.alpha.enumerated() { for k in 0..<4 { data[i * 4 + k] = a } } // white, premultiplied
        return ctx.makeImage()
    }

    /// The strip as an alpha mask, one pixel per cell, for a layer that fills it with the row's color.
    public static func mask(_ span: Span) -> CGImage? {
        guard span.count > 0 else { return nil }
        return DitherFill.image(grid(span), colors: [CGColor(gray: 1, alpha: 1)])
    }
}
