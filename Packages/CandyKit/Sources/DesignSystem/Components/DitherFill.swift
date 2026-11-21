import CoreGraphics

/// Ordered-dither fills on a fixed cell grid, for Redesign surfaces that fill a shape with binary cells in one color, the
/// way the Gradient background does (`DitherArt.gradientFrames`). A `Grid` holds one byte per cell: 0 is empty, `k` paints
/// the cell in the `k`th color. Rows run top first. `image` turns it into a bitmap with one pixel per cell, which a layer
/// scales up with nearest filtering, so a cell is a crisp square at any scale and the whole fill costs a few kilobytes.
public enum DitherFill {
    /// The cell pitch in points, the Gradient background's 3pt grid.
    public nonisolated static let cell: CGFloat = 3

    /// Which cells a layer may use. `checker` keeps every other cell, so two layers on opposite phases share an area
    /// without covering each other. `hatched` keeps diagonal stripes two cells wide, for a secondary series.
    public enum Pattern: Equatable, Sendable {
        case full
        case checker(phase: Int)
        case hatched

        public nonisolated func admits(_ x: Int, _ y: Int) -> Bool {
            switch self {
            case .full: true
            case .checker(let phase): (x + y + phase) & 1 == 0
            case .hatched: (x + y) & 3 < 2
            }
        }
    }

    /// The cell's ordered threshold in 0..<1, from the Gradient background's 8 x 8 Bayer matrix.
    public nonisolated static func threshold(_ x: Int, _ y: Int) -> Double {
        (Double(DitherArt.bayer[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
    }

    /// How full the fill is at `depth`, 0 at the series line to 1 at the baseline: dense under the line, thinning to
    /// nothing at the baseline. It stays under 1, so even the first row under the line keeps a pattern.
    public nonisolated static func density(depth t: Double) -> Double {
        let u = 1 - min(1, max(0, t))
        return peak * u * u
    }

    /// The density right under the line.
    public nonisolated static let peak: Double = 0.85

    public struct Grid: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public var cells: [UInt8]
        /// Each painted cell's depth below its line, 0 to 255, so an entrance can switch cells on from the line down
        /// without rebuilding the fill. Dotted rules sit at 0 and show from the start.
        public var depths: [UInt8]

        public init(width: Int, height: Int) {
            self.width = max(0, width)
            self.height = max(0, height)
            cells = [UInt8](repeating: 0, count: self.width * self.height)
            depths = cells
        }

        /// The fill with only the cells within `reveal` (0...1) of the depth below their line.
        public func revealed(_ reveal: Double) -> Grid {
            var g = self
            let cut = UInt8(max(0, min(255, (reveal * 255).rounded(.down))))
            for i in g.cells.indices where g.depths[i] > cut { g.cells[i] = 0 }
            return g
        }

        public subscript(x: Int, y: Int) -> UInt8 {
            get { cells[y * width + x] }
            set { cells[y * width + x] = newValue }
        }

        /// A dotted rule along row `y`: every other cell, in `layer`, only where the cell is empty.
        public mutating func dots(row y: Int, layer: UInt8) {
            guard y >= 0, y < height else { return }
            for x in stride(from: 0, to: width, by: 2) where self[x, y] == 0 { self[x, y] = layer }
        }

        /// The area under a series. `tops[x]` is the line's height in column `x`, in rows from the grid's top
        /// (fractional), and the baseline is the grid's foot. A cell is on where the fill's density at its depth beats
        /// its threshold and `pattern` admits it. `reveal` (0...1) keeps only the cells within that share of the depth
        /// below the line, for the entrance; 1 is the resting fill.
        public mutating func area(tops: [Double], layer: UInt8, pattern: Pattern = .full, reveal: Double = 1) {
            let base = Double(height)
            for x in 0..<min(width, tops.count) {
                let top = min(base, max(0, tops[x]))
                let depth = base - top
                guard depth > 0 else { continue }
                for y in max(0, Int(top.rounded(.down)))..<height {
                    let centre = Double(y) + 0.5
                    guard centre >= top, pattern.admits(x, y) else { continue }
                    let t = (centre - top) / depth
                    if t <= reveal, DitherFill.density(depth: t) > DitherFill.threshold(x, y) {
                        self[x, y] = layer
                        depths[y * width + x] = UInt8(max(1, min(255, (t * 255).rounded(.up))))
                    }
                }
            }
        }
    }

    /// The grid as a bitmap, one pixel per cell, `colors[k - 1]` for layer `k` and clear for 0.
    public nonisolated static func image(_ grid: Grid, colors: [CGColor]) -> CGImage? {
        let w = grid.width, h = grid.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        let rgba: [[UInt8]] = colors.map { c in
            let s = c.converted(to: space, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
            let a = s.count > 3 ? s[3] : 1
            func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * a * 255).rounded()))) }
            return [byte(s[0]), byte(s.count > 2 ? s[1] : s[0]), byte(s.count > 2 ? s[2] : s[0]), UInt8(max(0, min(255, (a * 255).rounded())))]
        }
        // Row 0 of the buffer is the top of the image.
        for i in 0..<(w * h) {
            let k = Int(grid.cells[i])
            guard k > 0, k <= rgba.count else { continue }
            let c = rgba[k - 1]
            data[i * 4] = c[0]; data[i * 4 + 1] = c[1]; data[i * 4 + 2] = c[2]; data[i * 4 + 3] = c[3]
        }
        return ctx.makeImage()
    }
}
