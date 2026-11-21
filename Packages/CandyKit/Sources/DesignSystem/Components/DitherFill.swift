import CoreGraphics

/// Ordered-dither shapes on a fixed cell grid, for Redesign surfaces drawn as cells rather than vectors. A `Grid` holds
/// one byte per cell: 0 is empty, `k` paints the cell in the `k`th color. Rows run top first. A shape is a column
/// profile quantised to whole cells, so its edge is a staircase on the grid, outlined by solid edge cells, with a
/// texture inside. `image` turns the grid into a bitmap with one pixel per cell, which a layer scales up with nearest
/// filtering, so a cell is a crisp square at any scale.
public enum DitherFill {
    /// The chart cell in points, dither-kit's 2pt.
    public nonisolated static let chartCell: CGFloat = 2

    /// The texture inside a shape, in the order a chart hands them to its series.
    public enum Texture: Equatable, Sendable, CaseIterable {
        /// Solid at the foot, breaking up into the ordered dither toward the edge.
        case gradient
        /// Diagonal stripes two cells wide, rising to the right.
        case hatch
        /// The same stripes rising to the left.
        case counterHatch
        /// Every other cell of every other row.
        case dots

        /// The texture for the `i`th series, cycling.
        public nonisolated static func forSeries(_ i: Int) -> Texture { allCases[i % allCases.count] }

        /// Whether the cell at `x, y`, `t` of the way from the edge (0) to the foot (1), is on.
        public nonisolated func admits(_ x: Int, _ y: Int, depth t: Double) -> Bool {
            switch self {
            case .gradient: DitherFill.density(depth: t) > DitherFill.threshold(x, y)
            case .hatch: (x + y) & 3 < 2
            case .counterHatch: (x - y + 4096) & 3 < 2
            case .dots: x & 1 == 0 && y & 1 == 0
            }
        }
    }

    /// The cell's ordered threshold in 0..<1, from the Gradient background's 8 x 8 Bayer matrix.
    public nonisolated static func threshold(_ x: Int, _ y: Int) -> Double {
        (Double(DitherArt.bayer[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
    }

    /// How full a gradient is at `depth`, 0 at the edge to 1 at the foot of that column's own area: about half under
    /// the edge, breaking up gradually over the top `reach` of the area. The holes thin out slowly (a square root),
    /// so the last scattered rows reach about half way down, as dither-kit's area chart does.
    public nonisolated static func density(depth t: Double) -> Double {
        let open = max(0, 1 - max(0, t) / reach)
        return min(1, 1 - (1 - edgeDensity) * open.squareRoot())
    }

    /// The gradient's density right under the edge.
    public nonisolated static let edgeDensity: Double = 0.5
    /// How far down the area the break-up reaches, as a share of the area's height at that column.
    public nonisolated static let reach: Double = 0.55

    public struct Grid: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public var cells: [UInt8]

        public init(width: Int, height: Int) {
            self.width = max(0, width)
            self.height = max(0, height)
            cells = [UInt8](repeating: 0, count: self.width * self.height)
        }

        public subscript(x: Int, y: Int) -> UInt8 {
            get { cells[y * width + x] }
            set { cells[y * width + x] = newValue }
        }

        /// A dotted rule along row `y`, a cell every `every` cells, in `layer`, only where the cell is empty.
        public mutating func dots(row y: Int, every: Int, layer: UInt8) {
            guard y >= 0, y < height, every > 0 else { return }
            for x in stride(from: 0, to: width, by: every) where self[x, y] == 0 { self[x, y] = layer }
        }

        /// Whether the cell is inside the shape whose top row in each column is `tops[x]` (`height` for none).
        @inline(__always) func inside(_ tops: [Int], _ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < tops.count && y < height && y >= tops[x]
        }

        /// A shape's inside in its texture, in `layer`, over whatever is there. With `gap`, the cells around the
        /// shape are cleared first, so a shape in front keeps a one-cell dark margin from the one behind. A column
        /// only one cell tall clears no margin, so a series that barely registers draws a line, not a dark band.
        /// `holes` is the layer for the cells inside the shape that the texture leaves open; 0 leaves them clear.
        public mutating func fill(tops: [Int], layer: UInt8, texture: Texture, gap: Bool, holes: UInt8 = 0) {
            let n = min(width, tops.count)
            if gap {
                for x in 0..<n where tops[x] < height - 1 {
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        for y in max(0, tops[x] - 1)..<height where !inside(tops, nx, y) { self[nx, y] = 0 }
                    }
                }
            }
            for x in 0..<n where tops[x] < height {
                let top = tops[x], depth = Double(height - top)
                for y in top..<height {
                    self[x, y] = texture.admits(x, y, depth: Double(y - top) / depth) ? layer : holes
                }
            }
        }

        /// A shape's outline in `layer`: every inside cell with the cell above it, or beside it, outside the shape.
        /// It follows the staircase, risers included, and leaves the foot open.
        public mutating func edge(tops: [Int], layer: UInt8) {
            let n = min(width, tops.count)
            for x in 0..<n where tops[x] < height {
                for y in tops[x]..<height {
                    // The plot's own left and right borders draw no edge.
                    let left = x == 0 || inside(tops, x - 1, y), right = x == n - 1 || inside(tops, x + 1, y)
                    if inside(tops, x, y - 1) && left && right { break }
                    self[x, y] = layer
                }
            }
        }

        /// The grid with every column from `columns` on cleared, for an entrance that builds left to right.
        public func revealed(columns: Int) -> Grid {
            var g = self
            let cut = max(0, min(width, columns))
            guard cut < width else { return g }
            for y in 0..<height { for x in cut..<width { g[x, y] = 0 } }
            return g
        }
    }

    /// The grid as a bitmap, one pixel per cell, `colors[k - 1]` for layer `k` and clear for 0. Layers in `ramp`
    /// mix toward `ramp.toward` by up to `ramp.share` at the top row, falling to nothing at the bottom row, so a
    /// solid foot glows a little brighter than the dithered top without any blur.
    public nonisolated static func image(_ grid: Grid, colors: [CGColor],
                                         ramp: (layers: Set<UInt8>, toward: CGColor, share: Double)? = nil) -> CGImage? {
        let w = grid.width, h = grid.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        func comps(_ c: CGColor) -> [Double] {
            let s = c.converted(to: space, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
            return s.count >= 4 ? s.map(Double.init) : [Double(s[0]), Double(s[0]), Double(s[0]), Double(s.count > 1 ? s[1] : 1)]
        }
        func bytes(_ c: [Double]) -> (UInt8, UInt8, UInt8, UInt8) {
            func b(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            return (b(c[0] * c[3]), b(c[1] * c[3]), b(c[2] * c[3]), b(c[3]))
        }
        let base = colors.map(comps)
        let toward = ramp.map { comps($0.toward) }
        // One color per layer per row: only ramped layers change down the rows.
        var table = [(UInt8, UInt8, UInt8, UInt8)](repeating: (0, 0, 0, 0), count: (base.count + 1) * h)
        for (k, c) in base.enumerated() {
            let ramped = ramp.map { $0.layers.contains(UInt8(k + 1)) } ?? false
            for y in 0..<h {
                var v = c
                if ramped, let ramp, let toward {
                    let share = ramp.share * (1 - (Double(y) + 0.5) / Double(h))
                    for i in 0..<3 { v[i] = c[i] + (toward[i] - c[i]) * share }
                }
                table[(k + 1) * h + y] = bytes(v)
            }
        }
        // Row 0 of the buffer is the top of the image.
        for y in 0..<h {
            for x in 0..<w {
                let k = Int(grid.cells[y * w + x])
                guard k > 0, k <= base.count else { continue }
                let c = table[k * h + y], i = (y * w + x) * 4
                data[i] = c.0; data[i + 1] = c.1; data[i + 2] = c.2; data[i + 3] = c.3
            }
        }
        return ctx.makeImage()
    }
}
