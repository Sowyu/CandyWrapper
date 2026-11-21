import CoreGraphics

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
    public static func grid(_ span: Span) -> DitherFill.Grid {
        var g = DitherFill.Grid(width: span.count, height: rows)
        let n = Double(span.count)
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

    /// The strip as an alpha mask, one pixel per cell, for a layer that fills it with the row's color.
    public static func mask(_ span: Span) -> CGImage? {
        guard span.count > 0 else { return nil }
        return DitherFill.image(grid(span), colors: [CGColor(gray: 1, alpha: 1)])
    }
}
