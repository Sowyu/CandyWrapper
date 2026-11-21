import AppKit
import DesignSystem
import T3Protocol

/// Redesign's Usage plot: each series' area as an ordered-dither fill on the 3pt cell grid, dense under the line and
/// thinning to nothing at the baseline, the gridlines as dotted rows on the same grid, and each series line as a crisp
/// 1.5pt stroke on top. The fill is one cached bitmap with a pixel per cell, rebuilt only when the size, the figures or
/// the appearance change. The first time it shows, the cells switch on from each line downward over 0.4 s; after that
/// nothing moves. The hover readout and its hairline live in `UsageChartPlotView`, above this view.
final class UsageDitherPlotView: DSView {
    struct Series: Equatable {
        var id: String
        var color: NSColor
        var values: [Double]
        /// T3's 40% for a provider still loading.
        var dim: CGFloat = 1
        /// The color is a dynamic color made fresh each time; the render key holds its resolved value.
        static func == (l: Self, r: Self) -> Bool { l.id == r.id && l.values == r.values && l.dim == r.dim }
    }

    /// The series heaviest first, which is also the drawing order: lighter series sit in front.
    struct Input: Equatable {
        var series: [Series] = []
        var scaleMax: Double = 0
        var ticks: [Double] = []
    }

    /// How a series in front shares the cells where its area overlaps one behind it.
    enum Overlap: Equatable, Sendable {
        /// Every series on the full grid; the one in front takes the cell.
        case layered
        /// Inside an overlap the series take turns on a checkerboard; outside it each keeps the full grid.
        case checker
        /// The heaviest series on the full grid, every other series in diagonal stripes.
        case hatched
    }

    static let overlap = Overlap.checker
    static let entranceDuration: CFTimeInterval = 0.4
    static let entranceFrames = 10

    var input = Input() { didSet { if input != oldValue { needsLayout = true } } }
    let fill = CALayer()
    private var lines: [CAShapeLayer] = []
    private var rendered: Key?
    /// Whether the entrance has played; it plays once per chart.
    private(set) var entered = false

    private struct Key: Equatable {
        var input: Input
        var size: CGSize
        var dark: Bool
        var colors: [CGColor]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fill.magnificationFilter = .nearest
        fill.contentsGravity = .resize
        fill.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }

    /// The colors the bitmap paints: the gridline dots, then one per series.
    private func colors() -> [CGColor] {
        let ground = Themed.color(\.background)
        return [Themed.color(\.border).cgColor(in: self)] + input.series.map { s in
            (s.dim < 1 ? OKLab.mix(s.color, s.dim, ground) : s.color).cgColor(in: self)
        }
    }

    /// The grid's frame in the view: whole cells, its foot on the baseline.
    static func gridFrame(_ size: CGSize, cell c: CGFloat = DitherFill.cell) -> (rect: CGRect, columns: Int, rows: Int) {
        let cols = Int((size.width / c).rounded(.up)), rows = Int((size.height / c).rounded(.up))
        return (CGRect(x: 0, y: size.height - CGFloat(rows) * c, width: CGFloat(cols) * c, height: CGFloat(rows) * c), cols, rows)
    }

    /// The curve of each series in view units.
    static func curves(_ input: Input) -> [[(CGPoint, CGPoint, CGPoint, CGPoint)]] {
        input.series.map { UsageChartLogic.curve(UsageChartLogic.points($0.values, max: input.scaleMax)) }
    }

    /// The whole fill as cells: gridline dots as layer 1, series `i` as layer `i + 2`. Pure, so the same size and
    /// figures give the same cells.
    static func grid(_ input: Input, size: CGSize, overlap: Overlap = overlap, reveal: Double = 1, cell c: CGFloat = DitherFill.cell) -> DitherFill.Grid {
        let frame = gridFrame(size, cell: c)
        var grid = DitherFill.Grid(width: frame.columns, height: frame.rows)
        guard size.width > 0, size.height > 0 else { return grid }
        let sx = size.width / UsageChartLogic.viewWidth, sy = size.height / UsageChartLogic.viewHeight
        for t in input.ticks {
            let y = UsageChartLogic.y(t, max: input.scaleMax) * sy
            grid.dots(row: min(frame.rows - 1, max(0, Int(((y - frame.rect.minY) / c).rounded(.down)))), layer: 1)
        }
        // Each series' line in rows from the grid's top, per column.
        let tops: [[Double]] = curves(input).map { segs in
            guard !segs.isEmpty else { return [] }
            return (0..<frame.columns).map { x in
                let px = min(size.width, (CGFloat(x) + 0.5) * c)
                return Double((UsageChartLogic.sample(segs, x: px / sx) * sy - frame.rect.minY) / c)
            }
        }
        switch overlap {
        case .layered, .hatched:
            for (i, top) in tops.enumerated() where !top.isEmpty {
                grid.area(tops: top, layer: UInt8(i + 2), pattern: overlap == .hatched && i > 0 ? .hatched : .full, reveal: reveal)
            }
        case .checker:
            // Each series on its own grid first, then each cell goes to the series whose turn it is among those whose
            // area holds the cell, front first.
            let own = tops.map { top -> DitherFill.Grid in
                var g = DitherFill.Grid(width: frame.columns, height: frame.rows)
                if !top.isEmpty { g.area(tops: top, layer: 1, reveal: reveal) }
                return g
            }
            for y in 0..<frame.rows {
                let centre = Double(y) + 0.5
                for x in 0..<frame.columns {
                    func holds(_ i: Int) -> Bool { x < tops[i].count && centre >= tops[i][x] }
                    var count = 0
                    for i in tops.indices where holds(i) { count += 1 }
                    guard count > 0 else { continue }
                    // The turn-th holder, front (last drawn) first.
                    var turn = (x + y) % count, owner = -1
                    for i in tops.indices.reversed() where holds(i) {
                        if turn == 0 { owner = i; break }
                        turn -= 1
                    }
                    if own[owner][x, y] != 0 {
                        grid[x, y] = UInt8(owner + 2)
                        grid.depths[y * frame.columns + x] = own[owner].depths[y * frame.columns + x]
                    }
                }
            }
        }
        return grid
    }

    /// Each series line in the view's points, flipped like the view.
    static func linePaths(_ input: Input, size: CGSize) -> [CGPath?] {
        let sx = size.width / UsageChartLogic.viewWidth, sy = size.height / UsageChartLogic.viewHeight
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        return curves(input).map { segs in
            guard let first = segs.first else { return nil }
            let path = CGMutablePath()
            path.move(to: pt(first.0))
            for s in segs { path.addCurve(to: pt(s.3), control1: pt(s.1), control2: pt(s.2)) }
            return path
        }
    }

    private func render() {
        let colors = colors()
        let key = Key(input: input, size: bounds.size, dark: effectiveAppearance.isDark, colors: colors)
        guard key != rendered else { return }
        rendered = key
        let frame = Self.gridFrame(bounds.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = frame.rect
        let grid = Self.grid(input, size: bounds.size)
        fill.contents = DitherFill.image(grid, colors: colors)
        let paths = Self.linePaths(input, size: bounds.size)
        while lines.count < paths.count {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.lineWidth = 1.5
            l.lineJoin = .round
            l.lineCap = .round
            layer?.addSublayer(l)
            lines.append(l)
        }
        while lines.count > paths.count { lines.removeLast().removeFromSuperlayer() }
        for (i, l) in lines.enumerated() {
            l.frame = bounds
            l.path = paths[i]
            l.strokeColor = colors[i + 1]
        }
        CATransaction.commit()
        playEntranceIfDue(grid, colors: colors)
    }

    /// The fill builds in once, the first time the chart shows figures in a window: Core Animation flips the frames,
    /// which exist only while it plays, and the last one is the resting fill.
    private func playEntranceIfDue(_ grid: DitherFill.Grid, colors: [CGColor]) {
        guard !entered, window != nil, bounds.width > 0, input.scaleMax > 0,
              input.series.contains(where: { $0.values.contains { $0 > 0 } }) else { return }
        entered = true
        guard !Motion.reduced, let final = fill.contents else { return }
        let n = Self.entranceFrames
        let frames = (1..<n).compactMap { i in
            DitherFill.image(grid.revealed(Double(i) / Double(n)), colors: colors)
        }
        let build = CAKeyframeAnimation(keyPath: "contents")
        build.values = frames + [final]
        build.calculationMode = .discrete
        build.duration = Self.entranceDuration
        fill.add(build, forKey: "entrance")
    }
}
