import AppKit
import DesignSystem
import T3Protocol

/// Redesign's Usage plot, drawn the way dither-kit draws its area chart: every series is a shape quantised to the 2pt
/// cell grid, so its top is a staircase of cells, outlined by solid edge cells in a lifted shade of the series color,
/// with a texture inside. The first series is solid at the foot and breaks up into ordered dither toward its edge; the
/// next ones hatch, counter-hatch and dot. Series overlay from the baseline as in T3 (UsageProviderChart.tsx:494-510),
/// heaviest behind, each one in front keeping a one-cell dark margin. No vector stroke and no blur: the whole plot is
/// one cached bitmap with a pixel per cell, rebuilt only when the size, figures, spotlight or appearance change. The
/// first time it shows, the columns build in left to right over 0.4 s; after that nothing moves.
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
        /// The series the legend spotlights; the others dim.
        var spotlight: String?
    }

    /// How the daily points become a column profile before it is quantised.
    enum Shape: Equatable, Sendable {
        /// Straight segments between the days.
        case linear
        /// Each day a flat run, half a period either side of it.
        case step
        /// T3's monotone curve.
        case smooth
    }

    static let shape = Shape.linear
    static let cell = DitherFill.chartCell
    /// Gridline dots: one cell in this many along each tick row; nil draws none.
    static let gridEvery: Int? = 3
    /// The edge's lift toward the text color, and the fill's fade toward the ground at the plot's top.
    static let edgeLift: CGFloat = 0.3
    static let topFade: Double = 0.35
    /// How far a series out of the spotlight keeps its color.
    static let spotlightDim: CGFloat = 0.28
    static let entranceDuration: CFTimeInterval = 0.4
    static let entranceFrames = 10

    var input = Input() { didSet { if input != oldValue { needsLayout = true } } }
    let fill = CALayer()
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

    /// The bitmap's colors: the gridline dots, then each series' fill and edge, then each series' holes.
    private func colors() -> [CGColor] {
        let ground = Themed.color(\.background), ink = Themed.color(\.foreground)
        var out = [Themed.color(\.border).cgColor(in: self)], holes: [CGColor] = []
        let dark = effectiveAppearance.isDark
        for (i, s) in input.series.enumerated() {
            // The edge lifts from the series color first, then both dim together toward the ground.
            var keep: CGFloat = s.dim
            if let spot = input.spotlight, spot != s.id { keep *= Self.spotlightDim }
            // A hatched series' lines step back toward the ground in light, where a dark provider color made the hatch
            // the heaviest mark on the page; its edge keeps full strength, so the silhouette still reads.
            let lines = i > 0 && !dark ? OKLab.mix(s.color, Self.lightHatch, ground) : s.color
            for c in [lines, OKLab.mix(s.color, 1 - Self.edgeLift, ink)] {
                out.append((keep < 1 ? OKLab.mix(c, keep, ground) : c).cgColor(in: self))
            }
            holes.append(OKLab.mix(s.color, Self.holeTint(i) * keep, ground).cgColor(in: self))
        }
        return out + holes
    }

    /// The grid's frame in the view: whole cells, its foot on the baseline.
    static func gridFrame(_ size: CGSize, cell c: CGFloat = cell) -> (rect: CGRect, columns: Int, rows: Int) {
        let cols = Int((size.width / c).rounded(.up)), rows = Int((size.height / c).rounded(.up))
        return (CGRect(x: 0, y: size.height - CGFloat(rows) * c, width: CGFloat(cols) * c, height: CGFloat(rows) * c), cols, rows)
    }

    /// A series' value at `u`, 0 to 1 across the plot, before quantising. `smooth` samples T3's curve in `tops`.
    static func value(_ values: [Double], at u: Double, shape: Shape) -> Double {
        guard let last = values.indices.last else { return 0 }
        guard last > 0 else { return values[0] }
        let f = min(Double(last), max(0, u * Double(last)))
        switch shape {
        case .step:
            return values[Int(UsageFormat.jsRound(f))]
        case .linear, .smooth:
            let i = min(last - 1, Int(f)), t = f - Double(i)
            return values[i] + (values[i + 1] - values[i]) * t
        }
    }

    /// Each series' top row per column, `rows` where it has nothing. A column with any usage shows at least its
    /// bottom cell, so a small series still draws a line along the baseline.
    static func tops(_ input: Input, size: CGSize, shape: Shape = shape, cell c: CGFloat = cell) -> [[Int]] {
        let frame = gridFrame(size, cell: c)
        guard size.width > 0, size.height > 0, input.scaleMax > 0 else { return input.series.map { _ in [] } }
        let sy = size.height / UsageChartLogic.viewHeight
        return input.series.map { s in
            let segs = shape == .smooth ? UsageChartLogic.curve(UsageChartLogic.points(s.values, max: input.scaleMax)) : []
            return (0..<frame.columns).map { x in
                let u = Double(min(size.width, (CGFloat(x) + 0.5) * c) / size.width)
                let y: CGFloat, positive: Bool
                if shape == .smooth {
                    y = UsageChartLogic.sample(segs, x: CGFloat(u) * UsageChartLogic.viewWidth)
                    positive = y < UsageChartLogic.viewHeight - 1e-9
                } else {
                    let v = value(s.values, at: u, shape: shape)
                    y = UsageChartLogic.y(v, max: input.scaleMax)
                    positive = v > 0
                }
                guard positive else { return frame.rows }
                let row = Int(((y * sy - frame.rect.minY) / c).rounded())
                return min(frame.rows - 1, max(0, row))
            }
        }
    }

    /// `tops` as the plot draws them: a series in front that is under one cell tall draws nothing where a series behind
    /// it stands, since its one-cell foot ran as a white strip along the rear series' base (Grok, G6, round 2).
    static func drawnTops(_ input: Input, size: CGSize, shape: Shape = shape, cell c: CGFloat = cell) -> [[Int]] {
        var tops = tops(input, size: size, shape: shape, cell: c)
        let rows = gridFrame(size, cell: c).rows
        for i in tops.indices.dropFirst() {
            for x in tops[i].indices where tops[i][x] == rows - 1 && tops[..<i].contains(where: { x < $0.count && $0[x] < rows - 1 }) {
                tops[i][x] = rows
            }
        }
        return tops
    }

    /// The whole plot as cells: gridline dots as layer 1, series `i`'s fill as `2 + 2i` and its edge as `3 + 2i`.
    /// Pure, so the same size and figures give the same cells.
    static func grid(_ input: Input, size: CGSize, shape: Shape = shape, cell c: CGFloat = cell,
                     textures: (Int) -> DitherFill.Texture = DitherFill.Texture.forSeries) -> DitherFill.Grid {
        let frame = gridFrame(size, cell: c)
        var grid = DitherFill.Grid(width: frame.columns, height: frame.rows)
        guard size.width > 0, size.height > 0 else { return grid }
        if let every = gridEvery {
            let sy = size.height / UsageChartLogic.viewHeight
            for t in input.ticks where t > 0 {
                let y = UsageChartLogic.y(t, max: input.scaleMax) * sy
                grid.dots(row: Int(((y - frame.rect.minY) / c).rounded(.down)), every: every, layer: 1)
            }
        }
        let tops = drawnTops(input, size: size, shape: shape, cell: c)
        for (i, top) in tops.enumerated() where !top.isEmpty {
            grid.fill(tops: top, layer: UInt8(2 + 2 * i), texture: textures(i), gap: i > 0, holes: holeLayer(i, of: tops.count))
        }
        // Every outline after every fill. A series in front covers the outline of those behind it, with its one-cell
        // margin: the rear edge used to run through the front's hatch (the user, r5-chart-overlap-weird.png).
        for (i, top) in tops.enumerated() where !top.isEmpty {
            let front = tops[(i + 1)...].filter { !$0.isEmpty }
            grid.edge(tops: top, layer: UInt8(3 + 2 * i), hidden: front.isEmpty ? nil : { [grid] x, y in front.contains { grid.covers($0, x, y) } })
        }
        return grid
    }

    /// Series `i`'s holes, after every fill and edge layer: dither-kit draws a hole as a dark tint of the series
    /// color, not the ground.
    static func holeLayer(_ i: Int, of count: Int) -> UInt8 { UInt8(2 + 2 * count + i) }
    /// How much of the series color a hole keeps over the ground: the first series' dither holes keep dither-kit's
    /// tint; a hatched series' gaps stay near the ground, so the hatch reads as lines rather than a dark mass and the
    /// two series stay apart.
    static func holeTint(_ series: Int) -> CGFloat { series == 0 ? 0.4 : 0.12 }
    /// How much of its color a hatched series' lines keep in light.
    static let lightHatch: CGFloat = 0.6

    /// The bitmap for a grid: fills and their holes fade toward the ground at the top of the plot, so the solid foot
    /// reads brightest.
    static func image(_ grid: DitherFill.Grid, colors: [CGColor], ground: CGColor) -> CGImage? {
        let count = (colors.count - 1) / 3
        let fills = Set((0..<count).flatMap { [UInt8(2 + 2 * $0), holeLayer($0, of: count)] })
        return DitherFill.image(grid, colors: colors, ramp: (fills, ground, topFade))
    }

    private func render() {
        let colors = colors()
        let key = Key(input: input, size: bounds.size, dark: effectiveAppearance.isDark, colors: colors)
        guard key != rendered else { return }
        rendered = key
        let frame = Self.gridFrame(bounds.size)
        let grid = Self.grid(input, size: bounds.size)
        let ground = Themed.color(\.background).cgColor(in: self)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = frame.rect
        fill.contents = Self.image(grid, colors: colors, ground: ground)
        CATransaction.commit()
        playEntranceIfDue(grid, colors: colors, ground: ground)
    }

    /// The columns build in once, left to right, the first time the chart shows figures in a window: Core Animation
    /// flips the frames, which exist only while it plays, and the last one is the resting plot.
    private func playEntranceIfDue(_ grid: DitherFill.Grid, colors: [CGColor], ground: CGColor) {
        guard !entered, window != nil, bounds.width > 0, input.scaleMax > 0,
              input.series.contains(where: { $0.values.contains { $0 > 0 } }) else { return }
        entered = true
        guard !Motion.reduced, let final = fill.contents else { return }
        let n = Self.entranceFrames
        let frames = (1..<n).compactMap { i in
            Self.image(grid.revealed(columns: grid.width * i / n), colors: colors, ground: ground)
        }
        let build = CAKeyframeAnimation(keyPath: "contents")
        build.values = frames + [final]
        build.calculationMode = .discrete
        build.duration = Self.entranceDuration
        fill.add(build, forKey: "entrance")
    }
}

/// The legend over Redesign's chart: a square swatch and the name per series. Hovering an entry spotlights its series;
/// clicking locks the spotlight until it is clicked again.
final class UsageChartLegendView: DSView {
    var onSpotlight: ((String?) -> Void)?
    private var items: [UsageChartLegendItem] = []
    private(set) var hovered: String?
    private(set) var locked: String?
    var spotlight: String? { locked ?? hovered }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Legend")
    }

    func set(_ entries: [(id: String, label: String, color: NSColor)]) {
        if entries.map(\.id) != items.map(\.id) {
            items.forEach { $0.removeFromSuperview() }
            items = entries.map { e in
                let item = UsageChartLegendItem(id: e.id, label: e.label, color: e.color)
                item.onHover = { [weak self] id, inside in self?.hover(id, inside) }
                item.onPress = { [weak self] id in self?.toggle(id) }
                addSubview(item)
                return item
            }
            if let locked, !entries.contains(where: { $0.id == locked }) { self.locked = nil }
            hovered = nil
            needsLayout = true
        }
        sync()
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
        sync(); onSpotlight?(spotlight)
    }

    func toggle(_ id: String) {
        locked = locked == id ? nil : id
        sync(); onSpotlight?(spotlight)
    }

    private func sync() {
        for item in items { item.state = (spotlight == nil || spotlight == item.id, locked == item.id) }
    }

    override var fittingSize: NSSize {
        let w = items.reduce(0) { $0 + $1.fittingSize.width } + RedesignTokens.Space.m * CGFloat(max(0, items.count - 1))
        return NSSize(width: ceil(w), height: 20)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for item in items {
            let w = item.fittingSize.width
            item.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w + RedesignTokens.Space.m
        }
    }
}

final class UsageChartLegendItem: DSView {
    let id: String
    var onHover: ((String, Bool) -> Void)?
    var onPress: ((String) -> Void)?
    /// Lit when nothing is spotlit or this entry is; locked when a click holds it.
    var state = (lit: true, locked: false) {
        didSet {
            label.color = Themed.color(state.locked ? \.foreground : \.mutedForeground)
            swatch.alphaValue = state.lit ? 1 : UsageDitherPlotView.spotlightDim
            label.alphaValue = state.lit ? 1 : UsageDitherPlotView.spotlightDim
            setAccessibilityValue(state.locked ? "spotlit" : nil)
        }
    }
    private let swatch: UsageChartSwatchView
    private let label: LabelView
    private var tracking: NSTrackingArea?

    init(id: String, label text: String, color: NSColor) {
        self.id = id
        swatch = UsageChartSwatchView(color: color)
        label = LabelView(text, font: DSFont.mono(11), color: Themed.color(\.mutedForeground))
        label.lineHeight = 16
        super.init(frame: .zero)
        addSubview(swatch); addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
        setAccessibilityHelp("Spotlights \(text) in the chart")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: 8 + 6 + ceil(label.textWidth) + 1, height: 20) }

    override func layout() {
        super.layout()
        swatch.frame = NSRect(x: 0, y: ((bounds.height - 8) / 2).rounded(), width: 8, height: 8)
        label.frame = NSRect(x: 14, y: ((bounds.height - 16) / 2).rounded(), width: ceil(label.textWidth) + 1, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(id, true) }
    override func mouseExited(with event: NSEvent) { onHover?(id, false) }
    override func mouseDown(with event: NSEvent) { onPress?(id) }
    override func accessibilityPerformPress() -> Bool { onPress?(id); return true }
}
