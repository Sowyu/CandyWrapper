import AppKit
import DesignSystem
import T3Protocol

/// Colors and marks the usage views share (usageProviders.ts:16-45, usageBreakdown.ts:46-55).
@MainActor
public enum UsageStyle {
    /// `PROVIDER_PRESENTATION[provider].color`.
    public static func color(_ p: UsageProviderKind) -> NSColor {
        switch p {
        case .codex: Themed.color(\.contrastForeground)
        case .claude: NSColor(srgbRed: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        case .grok: OKLab.mix(Themed.color(\.contrastForeground), 0.72, Themed.color(\.background))
        case .cursor: NSColor(srgbRed: 0x8b / 255, green: 0x8b / 255, blue: 0x8b / 255, alpha: 1)
        case .opencode: NSColor(srgbRed: 0x5b / 255, green: 0x9b / 255, blue: 0xbd / 255, alpha: 1)
        case .antigravity: NSColor(srgbRed: 0x8c / 255, green: 0x7b / 255, blue: 0xd1 / 255, alpha: 1)
        }
    }

    /// `barColor`: the limits bars take the cost chart's series color for Codex and Claude.
    public static func barColor(driver: String) -> NSColor {
        driver == "codex" ? color(.codex) : driver == "claudeAgent" ? color(.claude) : Themed.color(\.foreground)
    }

    /// `ink(percent)`: a neutral step between background and foreground.
    public static func ink(_ percent: CGFloat) -> NSColor { OKLab.mix(Themed.color(\.foreground), percent / 100, Themed.color(\.background)) }

    /// `ProviderMark` / `ProviderInstanceIcon` for a usage provider.
    public static func mark(_ p: UsageProviderKind, size: CGFloat, color: NSColor = Themed.color(\.mutedForeground)) -> NSView {
        let v = ProviderIcon.make(driver: p.driverKind, displayName: p.label, size: size, color: color)
        v.frame.size = NSSize(width: size, height: size)
        return v
    }

    static func tabular(_ px: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { SB.tabular(px, weight) }

    static func label(_ text: String, _ px: CGFloat, _ weight: NSFont.Weight = .regular, color: NSColor = Themed.color(\.foreground),
                      tabular: Bool = false, lineHeight: CGFloat? = nil) -> LabelView {
        let l = LabelView(text, font: tabular ? Self.tabular(px, weight) : DSFont.ui(px, weight: weight), color: color)
        l.lineHeight = lineHeight ?? (px <= 10 ? 14 : px <= 11 ? 16 : px <= 12 ? 16 : px <= 14 ? 20 : px <= 16 ? 24 : px <= 24 ? 32 : px <= 30 ? 36 : 40)
        return l
    }
}

/// The chart's maths (UsageProviderChart.tsx:15-220): columns per period, a 1/2/5 scale, and
/// monotone cubic curves that never overshoot spiky usage.
public enum UsageChartLogic {
    public static let viewWidth: CGFloat = 960
    public static let viewHeight: CGFloat = 260
    public static let tickCount = 4
    public static let plotTop: CGFloat = 8

    public struct Column: Equatable, Sendable {
        public var bands: [(provider: UsageProviderKind, value: Double)]
        public var total: Double
        public static func == (l: Self, r: Self) -> Bool { l.total == r.total && l.bands.map(\.value) == r.bands.map(\.value) }
        public func value(_ p: UsageProviderKind) -> Double { bands.first { $0.provider == p }?.value ?? 0 }
    }

    /// `buildPeriodColumns`.
    public static func columns(_ periods: [String], _ byPeriod: [String: UsagePeriodTotals], tokens: Bool) -> [Column] {
        periods.map { period in
            let entry = byPeriod[period]
            let bands = UsageProviderKind.allCases.map { p -> (provider: UsageProviderKind, value: Double) in
                let e = entry?.byProvider[p]
                return (p, e.map { tokens ? $0.totalTokens : $0.costUsd } ?? 0)
            }
            return Column(bands: bands, total: bands.reduce(0) { $0 + $1.value })
        }
    }

    /// `niceScale`: the max is a readable 1/2/5 x 10^n step at or above the peak.
    public static func niceScale(_ peak: Double, count: Int = tickCount) -> (max: Double, ticks: [Double]) {
        guard peak > 0 else { return (0, [0]) }
        let raw = peak / Double(count)
        let magnitude = pow(10, floor(log10(raw)))
        let n = raw / magnitude
        let step = (n > 5 ? 10 : n > 2 ? 5 : n > 1 ? 2 : 1) * magnitude
        let max = ceil(peak / step) * step
        var ticks: [Double] = []
        var v = 0.0
        while v <= max + step * 1e-6 { ticks.append(v); v += step }
        return (max, ticks)
    }

    /// `chartScale`: the largest single provider-period; unlabeled placeholder lines while loading.
    public static func scale(_ columns: [Column], loading: Bool) -> (max: Double, ticks: [Double], labeled: Bool) {
        let peak = columns.reduce(0) { m, c in c.bands.reduce(m) { Swift.max($0, $1.value) } }
        if peak == 0 && loading { return (Double(tickCount), (0...tickCount).map(Double.init), false) }
        let s = niceScale(peak)
        return (s.max, s.ticks, true)
    }

    /// `valueToY` in view units (260 high).
    public static func y(_ value: Double, max: Double) -> CGFloat {
        max == 0 ? viewHeight : viewHeight - CGFloat(value / max) * (viewHeight - plotTop)
    }

    /// `monotoneTangents`.
    static func tangents(_ pts: [CGPoint]) -> [CGFloat] {
        let n = pts.count
        guard n >= 2 else { return [0] }
        var slopes: [CGFloat] = []
        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y
            slopes.append(dx == 0 ? 0 : dy / dx)
        }
        var t = [CGFloat](repeating: 0, count: n)
        t[0] = slopes[0]
        t[n - 1] = slopes[n - 2]
        if n > 2 { for i in 1..<(n - 1) { let p = slopes[i - 1], q = slopes[i]; t[i] = p * q <= 0 ? 0 : (p + q) / 2 } }
        for i in 0..<(n - 1) {
            let s = slopes[i]
            if s == 0 { t[i] = 0; t[i + 1] = 0; continue }
            let a = t[i] / s, b = t[i + 1] / s, m = a * a + b * b
            if m > 9 { let k = 3 / sqrt(m); t[i] = k * a * s; t[i + 1] = k * b * s }
        }
        return t
    }

    /// `smoothCurve`: cubic segments (from, c1, c2, to) in view units.
    public static func curve(_ pts: [CGPoint]) -> [(CGPoint, CGPoint, CGPoint, CGPoint)] {
        guard pts.count >= 2 else { return [] }
        let t = tangents(pts)
        return (0..<(pts.count - 1)).map { i in
            let a = pts[i], b = pts[i + 1], dx = b.x - a.x
            return (a, CGPoint(x: a.x + dx / 3, y: a.y + t[i] * dx / 3), CGPoint(x: b.x - dx / 3, y: b.y - t[i + 1] * dx / 3), b)
        }
    }
}

/// `UsageProviderChart`: the y labels in a 56pt column, the 224pt plot with layered area series per
/// provider (fills, then strokes, heaviest first), the hover line and readout, and three x labels.
/// Drawn with Core Graphics; the 960x260 view box stretches to the plot like `preserveAspectRatio="none"`.
public final class UsageChartView: DSView {
    public struct Model: Equatable {
        public var providers: [UsageProviderKind] = []
        public var loading: Set<UsageProviderKind> = []
        public var periods: [String] = []
        public var byPeriod: [String: UsagePeriodTotals] = [:]
        public var tokens = false
        public var hourly = false
        public var timeZone: String?
        public var referenceTime: String?
        public init() {}
    }

    public var model = Model() { didSet { if model != oldValue { rebuild() } } }
    static let plotHeight: CGFloat = 224
    public static let height: CGFloat = plotHeight + 4 + 14

    private let plot = UsageChartPlotView()
    private var yLabels: [LabelView] = []
    private let xLabels = (0..<3).map { _ in UsageStyle.label("", 10, color: Themed.color(\.mutedForeground), lineHeight: 14) }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(plot)
        xLabels.forEach(addSubview)
        xLabels[1].alignment = .center
        xLabels[2].alignment = .right
        plot.owner = self
    }

    private func format(_ v: Double) -> String { model.tokens ? UsageFormat.tokens(v) : UsageFormat.usd(v) }
    func formatPeriod(_ p: String) -> String { model.hourly ? UsageFormat.hourShort(p, timeZone: model.timeZone) : UsageFormat.dayShort(p) }
    func formatTooltipPeriod(_ p: String) -> String {
        if model.hourly, let ref = model.referenceTime { return UsageFormat.relativeHourShort(p, relativeTo: ref, timeZone: model.timeZone) }
        return formatPeriod(p)
    }

    private func rebuild() {
        let m = model
        let columns = UsageChartLogic.columns(m.periods, m.byPeriod, tokens: m.tokens)
        let scale = UsageChartLogic.scale(columns, loading: !m.loading.isEmpty)
        plot.columns = columns
        plot.scaleMax = scale.max
        plot.ticks = scale.ticks
        yLabels.forEach { $0.removeFromSuperview() }
        yLabels = scale.labeled ? scale.ticks.map { t in
            let l = UsageStyle.label(t == 0 ? "0" : format(t), 10, color: Themed.color(\.mutedForeground), tabular: true, lineHeight: 14)
            l.alignment = .right
            addSubview(l)
            return l
        } : []
        let ps = m.periods
        xLabels[0].text = ps.first.map(formatPeriod)?.uppercased() ?? ""
        xLabels[1].text = ps.isEmpty ? "" : formatPeriod(ps[ps.count / 2]).uppercased()
        xLabels[2].text = ps.last.map(formatPeriod)?.uppercased() ?? ""
        plot.dataChanged()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let h = Self.plotHeight
        plot.frame = NSRect(x: 56 + 8, y: 0, width: max(0, bounds.width - 64), height: h)
        for (i, l) in yLabels.enumerated() where i < plot.ticks.count {
            let y = UsageChartLogic.y(plot.ticks[i], max: plot.scaleMax) / UsageChartLogic.viewHeight * h
            l.frame = NSRect(x: 0, y: (y - 7).rounded(), width: 56, height: 14)
        }
        let xw = max(0, bounds.width - 64)
        for (i, l) in xLabels.enumerated() {
            let w = ceil(l.textWidth) + 1
            let x: CGFloat = i == 0 ? 64 : i == 1 ? 64 + (xw - w) / 2 : bounds.width - w
            l.frame = NSRect(x: x, y: h + 4, width: w, height: 14)
        }
        // `justify-between` centers the middle label between its neighbours' edges, not the plot.
        let a = xLabels[0].frame.maxX, c = xLabels[2].frame.minX, w1 = xLabels[1].frame.width
        xLabels[1].frame.origin.x = a + ((c - a) - w1) / 2
    }
}

/// The plot itself, with hover. The hovered column follows the pointer the way `onMouseMove` does
/// (UsageProviderChart.tsx:299-315): AppKit stops sending `mouseMoved` to an area it rebuilt under a
/// still pointer (the page rebuilds its sections on every model change and moves the chart with
/// them), so HoverSync forwards the moves and the plot reads the pointer itself.
final class UsageChartPlotView: DSView, HoverSyncPointerClient {
    weak var owner: UsageChartView?
    var columns: [UsageChartLogic.Column] = []
    var scaleMax: Double = 0
    var ticks: [Double] = []
    var hoverIndex: Int? { didSet { if hoverIndex != oldValue { updateTooltip(); needsLayout = true } } }
    private var hoverPoint: CGPoint = .zero
    private var pointerInside = false
    /// The hover line (`stroke-muted-foreground`, 1px, from `PLOT_TOP` down) sits on its own layer, so
    /// moving it does not redraw the series.
    private let crosshair = DSView()
    private let tooltip = UsageChartTooltipView()
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        crosshair.isHidden = true
        addSubview(crosshair)
        tooltip.isHidden = true
        tooltip.layer?.zPosition = 10
        addSubview(tooltip)
    }

    override var wantsUpdateLayer: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; followPointer() }
    override func mouseMoved(with event: NSEvent) { if pointerInside { followPointer() } }
    func hoverPointerMoved() { if pointerInside { followPointer() } }
    override func mouseExited(with event: NSEvent) { pointerInside = false; hoverIndex = nil }

    /// `handleMove`: the nearest period to the pointer, the readout 12pt off it.
    private func followPointer() {
        guard let owner, let window, !owner.model.periods.isEmpty, bounds.width > 0 else { hoverIndex = nil; return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let x = min(bounds.width, max(0, p.x)), y = min(bounds.height, max(0, p.y))
        hoverPoint = CGPoint(x: x, y: y)
        let n = owner.model.periods.count
        hoverIndex = min(n - 1, max(0, Int(UsageFormat.jsRound(Double(x / bounds.width) * Double(n - 1)))))
        positionTooltip()
    }

    /// New figures under a still pointer: the readout stays and shows them (T3 keeps `hoverIndex`).
    func dataChanged() {
        if pointerInside { followPointer(); updateTooltip() } else { hoverIndex = nil }
        needsDisplay = true
        needsLayout = true
    }

    private func updateTooltip() {
        guard let owner, let i = hoverIndex, i < owner.model.periods.count, i < columns.count else { tooltip.isHidden = true; return }
        let m = owner.model
        let tokens = m.tokens
        let format: (Double) -> String = { tokens ? UsageFormat.tokens($0) : UsageFormat.usd($0) }
        let column = columns[i]
        let rows: [(UsageProviderKind, String, Bool)] = m.providers.map { p in (p, format(column.value(p)), m.loading.contains(p)) }
        tooltip.set(title: owner.formatTooltipPeriod(m.periods[i]), rows: rows,
                    total: format(columns[i].total), partial: m.providers.contains { m.loading.contains($0) })
        tooltip.isHidden = false
        positionTooltip()
    }

    private func positionTooltip() {
        let s = tooltip.fittingSize
        let gap: CGFloat = 12
        let left = hoverPoint.x + gap + s.width <= bounds.width ? hoverPoint.x + gap : hoverPoint.x - gap - s.width
        let top = hoverPoint.y + gap + s.height <= bounds.height ? hoverPoint.y + gap : hoverPoint.y - gap - s.height
        tooltip.frame = NSRect(x: min(max(0, left), max(0, bounds.width - s.width)), y: min(max(0, top), max(0, bounds.height - s.height)),
                               width: s.width, height: s.height)
    }

    override func layout() {
        super.layout()
        guard let i = hoverIndex, let n = owner?.model.periods.count else { crosshair.isHidden = true; return }
        let stepX = n < 2 ? 0 : bounds.width / CGFloat(n - 1)
        // The stroke centred on the column, on the half point the old drawn line used.
        let x = ((CGFloat(i) * stepX) * 2).rounded() / 2
        let top = UsageChartLogic.plotTop * bounds.height / UsageChartLogic.viewHeight
        crosshair.frame = NSRect(x: x - 0.5, y: top, width: 1, height: max(0, bounds.height - top))
        crosshair.layer?.backgroundColor = Themed.color(\.mutedForeground).cgColor(in: self)
        crosshair.isHidden = false
        if !tooltip.isHidden { positionTooltip() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let m = owner.model
        let sx = bounds.width / UsageChartLogic.viewWidth, sy = bounds.height / UsageChartLogic.viewHeight
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        // Gridlines, 1px `text-border`.
        ctx.setLineWidth(1)
        ctx.setStrokeColor(Themed.color(\.border).cgColor(in: self))
        for t in ticks {
            let y = UsageChartLogic.y(t, max: scaleMax) * sy
            let snapped = (y * 2).rounded() / 2
            ctx.move(to: CGPoint(x: 0, y: snapped))
            ctx.addLine(to: CGPoint(x: bounds.width, y: snapped))
        }
        ctx.strokePath()

        let n = m.periods.count
        let stepX = n < 2 ? 0 : UsageChartLogic.viewWidth / CGFloat(n - 1)
        let series = m.providers.map { p -> (p: UsageProviderKind, total: Double, path: CGPath?) in
            let pts = columns.enumerated().map { i, c in CGPoint(x: CGFloat(i) * stepX, y: UsageChartLogic.y(c.value(p), max: scaleMax)) }
            let segs = UsageChartLogic.curve(pts)
            guard let first = segs.first else { return (p, 0, nil) }
            let path = CGMutablePath()
            path.move(to: pt(first.0.x, first.0.y))
            for s in segs { path.addCurve(to: pt(s.3.x, s.3.y), control1: pt(s.1.x, s.1.y), control2: pt(s.2.x, s.2.y)) }
            return (p, columns.reduce(0) { $0 + $1.value(p) }, path)
        }.enumerated().sorted { ($1.element.total, $0.offset) < ($0.element.total, $1.offset) }.map(\.element)
        // Fills first, then every stroke, so no series covers another's line. Loading series at 40%.
        for s in series {
            guard let line = s.path else { continue }
            let area = line.mutableCopy()!
            area.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
            area.addLine(to: CGPoint(x: 0, y: bounds.height))
            area.closeSubpath()
            let dim: CGFloat = m.loading.contains(s.p) ? 0.4 : 1
            ctx.addPath(area)
            ctx.setFillColor(UsageStyle.color(s.p).withAlphaComponent(0.12 * dim).cgColor(in: self))
            ctx.fillPath()
        }
        ctx.setLineWidth(2)
        ctx.setLineJoin(.round)
        for s in series {
            guard let line = s.path else { continue }
            let dim: CGFloat = m.loading.contains(s.p) ? 0.4 : 1
            ctx.addPath(line)
            ctx.setStrokeColor(UsageStyle.color(s.p).withAlphaComponent(dim).cgColor(in: self))
            ctx.strokePath()
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true; needsLayout = true }
}

/// The hover readout: `surface-glass rounded-xl border-border/50 px-2.5 py-2 text-xs shadow-lg`, min 144pt.
final class UsageChartTooltipView: DSView {
    private let box = BoxView()
    private let title = UsageStyle.label("", 12, color: Themed.color(\.mutedForeground))
    private var rows: [(NSView, LabelView, LabelView)] = []
    private var providers: [UsageProviderKind] = []
    private let rule = DSView()
    private let totalLabel = UsageStyle.label("Total", 12, color: Themed.color(\.mutedForeground))
    private let totalValue = UsageStyle.label("", 12, tabular: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var s = BoxStyle()
        s.radius = 12
        s.fill = Themed.color(\.popover, 0.92)
        s.border = Themed.color(\.border, 0.5)
        s.shadows = [BoxShadow(y: 10, blur: 15, spread: -3, color: Themed.black(0.1)), BoxShadow(y: 4, blur: 6, spread: -4, color: Themed.black(0.1))]
        box.boxStyle = s
        addSubview(box)
        for v in [title, rule, totalLabel, totalValue] as [NSView] { addSubview(v) }
        rule.layer?.backgroundColor = Themed.color(\.border).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(title t: String, rows data: [(UsageProviderKind, String, Bool)], total: String, partial: Bool) {
        title.text = t
        // Moving across columns changes only the figures; the provider rows stay.
        if data.map(\.0) != providers {
            rows.forEach { $0.0.removeFromSuperview(); $0.1.removeFromSuperview(); $0.2.removeFromSuperview() }
            providers = data.map(\.0)
            rows = data.map { p, _, _ in
                let icon = UsageStyle.mark(p, size: 12)
                let name = UsageStyle.label(p.label, 12, color: Themed.color(\.mutedForeground))
                let v = UsageStyle.label("", 12, tabular: true)
                v.alignment = .right
                for x in [icon, name, v] as [NSView] { addSubview(x) }
                return (icon, name, v)
            }
        }
        for (row, (_, value, loading)) in zip(rows, data) {
            row.2.text = value
            row.2.color = Themed.color(loading ? \.mutedForeground : \.foreground)
        }
        totalValue.text = total
        totalValue.color = Themed.color(partial ? \.mutedForeground : \.foreground)
        totalValue.alignment = .right
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let labelW = rows.map { 12 + 6 + ceil($0.1.textWidth) }.max() ?? 0
        let valueW = (rows.map { ceil($0.2.textWidth) } + [ceil(totalValue.textWidth)]).max() ?? 0
        let w = max(144, max(ceil(title.textWidth), labelW + 12 + valueW, ceil(totalLabel.textWidth) + 12 + valueW) + 20 + 2)
        return NSSize(width: ceil(w), height: 8 + 16 + 4 + CGFloat(rows.count) * 16 + 4 + 1 + 16 + 8 + 2)
    }

    override func layout() {
        super.layout()
        box.frame = bounds
        let x: CGFloat = 11, w = bounds.width - 22
        var y: CGFloat = 9
        title.frame = NSRect(x: x, y: y, width: w, height: 16)
        y += 20
        for (icon, name, value) in rows {
            icon.frame = NSRect(x: x, y: y + 2, width: 12, height: 12)
            name.frame = NSRect(x: x + 18, y: y, width: ceil(name.textWidth) + 1, height: 16)
            value.frame = NSRect(x: x, y: y, width: w, height: 16)
            y += 16
        }
        y += 4
        rule.frame = NSRect(x: x, y: y, width: w, height: 1)
        y += 5
        totalLabel.frame = NSRect(x: x, y: y, width: 60, height: 16)
        totalValue.frame = NSRect(x: x, y: y, width: w, height: 16)
    }

    override func updateLayer() { rule.layer?.backgroundColor = Themed.color(\.border).cgColor(in: self) }
}

/// One part-to-whole bar with its legend (`UsageShareBar`): segments `h-2 gap-0.5`, `min-w-1`, the ends
/// rounded fully; a legend of swatches, labels and values. Empty segments drop out; nothing without a total.
public final class UsageShareBarView: DSView {
    public struct Segment: Equatable {
        public var label: String
        public var value: Double
        public var color: NSColor
        public init(label: String, value: Double, color: NSColor) { self.label = label; self.value = value; self.color = color }
    }

    private let title: LabelView
    public var aside: NSView? { didSet { oldValue?.removeFromSuperview(); aside.map(addSubview); needsLayout = true } }
    private let bar = UsageShareStripView()
    private var legend: [(NSView, LabelView, LabelView)] = []
    let segments: [Segment]
    private let format: (Double) -> String

    public init?(label: String, segments: [Segment], format: @escaping (Double) -> String) {
        let visible = segments.filter { $0.value > 0 }
        guard visible.reduce(0, { $0 + $1.value }) > 0 else { return nil }
        self.segments = visible
        self.format = format
        title = UsageStyle.label(label, 14, .medium)
        super.init(frame: .zero)
        addSubview(title)
        bar.segments = visible
        let total = visible.reduce(0) { $0 + $1.value }
        bar.tooltips = visible.map { "\($0.label) · \(format($0.value)) · \(UsageFormat.percent($0.value / total))" }
        addSubview(bar)
        bar.setAccessibilityLabel("\(label): " + visible.map { "\($0.label) \(format($0.value))" }.joined(separator: ", "))
        legend = visible.map { s in
            let swatch = DSView()
            swatch.layer?.cornerRadius = 2
            swatch.layer?.backgroundColor = s.color.cgColor
            let l = UsageStyle.label(s.label, 12, color: Themed.color(\.mutedForeground))
            let v = UsageStyle.label(format(s.value), 12, tabular: true)
            for x in [swatch, l, v] as [NSView] { addSubview(x) }
            return (swatch, l, v)
        }
    }

    private func legendRows(_ width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, item) in legend.enumerated() {
            let w = 8 + 6 + ceil(item.1.textWidth) + 6 + ceil(item.2.textWidth)
            if x > 0, x + w > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(i)
            x += w + 16
        }
        return rows
    }

    public func height(forWidth width: CGFloat) -> CGFloat { 20 + 10 + 8 + 10 + CGFloat(legendRows(width).count) * 16 + CGFloat(legendRows(width).count - 1) * 4 }

    public override func layout() {
        super.layout()
        title.frame = NSRect(x: 0, y: 0, width: ceil(title.textWidth) + 1, height: 20)
        if let aside {
            let s = aside.fittingSize
            aside.frame = NSRect(x: bounds.width - s.width, y: 20 - s.height - 1, width: s.width, height: s.height)
        }
        bar.frame = NSRect(x: 0, y: 30, width: bounds.width, height: 8)
        var y: CGFloat = 48
        for row in legendRows(bounds.width) {
            var x: CGFloat = 0
            for i in row {
                let (sw, l, v) = legend[i]
                sw.frame = NSRect(x: x, y: y + 4, width: 8, height: 8)
                x += 14
                l.frame = NSRect(x: x, y: y, width: ceil(l.textWidth) + 1, height: 16)
                x += ceil(l.textWidth) + 6
                v.frame = NSRect(x: x, y: y, width: ceil(v.textWidth) + 1, height: 16)
                x += ceil(v.textWidth) + 16
            }
            y += 20
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for (i, item) in legend.enumerated() { item.0.layer?.backgroundColor = segments[i].color.cgColor(in: self) }
    }
}

/// The bar's strip: flex items sized `value 1 0` with a 4pt floor, 2pt apart.
final class UsageShareStripView: DSView {
    var segments: [UsageShareBarView.Segment] = []
    var tooltips: [String] = []
    private var tips: [TooltipController] = []
    private var cells: [DSView] = []

    override var wantsUpdateLayer: Bool { false }

    /// CSS flex with `min-width: 4px`: segments below the floor freeze at it, the rest share what is left.
    static func widths(_ values: [Double], total width: CGFloat, gap: CGFloat = 2, minimum: CGFloat = 4) -> [CGFloat] {
        let free = max(0, width - gap * CGFloat(max(0, values.count - 1)))
        var frozen = Set<Int>()
        var out = [CGFloat](repeating: 0, count: values.count)
        while true {
            let remaining = free - CGFloat(frozen.count) * minimum
            let sum = values.enumerated().filter { !frozen.contains($0.offset) }.reduce(0) { $0 + $1.element }
            var changed = false
            for (i, v) in values.enumerated() where !frozen.contains(i) {
                out[i] = sum > 0 ? remaining * CGFloat(v / sum) : 0
                if out[i] < minimum { frozen.insert(i); changed = true }
            }
            for i in frozen { out[i] = minimum }
            if !changed { return out }
        }
    }

    override func layout() {
        super.layout()
        if cells.count != segments.count {
            cells.forEach { $0.removeFromSuperview() }
            tips = []
            cells = segments.enumerated().map { i, _ in
                let c = DSView()
                addSubview(c)
                if i < tooltips.count { tips.append(TooltipController.attach(to: c, text: tooltips[i])) }
                return c
            }
        }
        let ws = Self.widths(segments.map(\.value), total: bounds.width)
        var x: CGFloat = 0
        for (i, c) in cells.enumerated() {
            c.frame = NSRect(x: x, y: 0, width: ws[i], height: bounds.height)
            x += ws[i] + 2
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (i, c) in cells.enumerated() {
            let r = c.frame
            let path = CGMutablePath()
            let first = i == 0, last = i == cells.count - 1
            let full = r.height / 2, small: CGFloat = 2
            let tl = first ? full : small, bl = tl, tr = last ? full : small, br = tr
            path.move(to: CGPoint(x: r.minX + tl, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
            path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: min(tr, r.width / 2))
            path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: min(br, r.width / 2))
            path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: min(bl, r.width / 2))
            path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: min(tl, r.width / 2))
            ctx.addPath(path)
            ctx.setFillColor(segments[i].color.cgColor(in: self))
            ctx.fillPath()
        }
    }
}

/// `usageBreakdown.ts`: model ordering, shares, cache hit rate and the type and speed segments.
@MainActor
public enum UsageBreakdown {
    public static func sortByTokens(_ models: [UsageModelTotals]) -> [UsageModelTotals] {
        models.enumerated().sorted { l, r in
            if l.element.totalTokens != r.element.totalTokens { return l.element.totalTokens > r.element.totalTokens }
            if l.element.costUsd != r.element.costUsd { return l.element.costUsd > r.element.costUsd }
            return l.offset < r.offset
        }.map(\.element)
    }

    /// `modelShare`: nil for the cost share of an unknown cost.
    public static func share(_ m: UsageModelTotals, tokens: Bool) -> Double? { tokens ? m.tokenShare : m.isCostUnknown ? nil : m.costShare }

    /// `cacheHitRate`: cache writes count as misses.
    public static func cacheHitRate(_ m: UsageModelTotals) -> Double? {
        let input = m.tokens.uncachedInputTokens + m.tokens.cachedInputTokens + m.tokens.cacheCreationTokens
        return input == 0 ? nil : m.tokens.cachedInputTokens / input
    }

    /// `costPerMillionTokens`.
    public static func costPerMillion(_ m: UsageModelTotals) -> Double? {
        let priced = m.totalTokens - m.unpricedTokens
        return priced <= 0 || m.isCostUnknown ? nil : m.costUsd / priced * 1_000_000
    }

    public static func costSegments(_ c: UsageCategorySplit) -> [UsageShareBarView.Segment] {
        [.init(label: "Input", value: c.input, color: UsageStyle.ink(60)),
         .init(label: "Cache read", value: c.cacheRead, color: UsageStyle.ink(30)),
         .init(label: "Cache write", value: c.cacheWrite, color: UsageStyle.ink(72)),
         .init(label: "Output", value: c.output, color: UsageStyle.ink(100)),
         .init(label: "Other", value: c.unsplit >= 0.005 ? c.unsplit : 0, color: UsageStyle.ink(44))]
    }

    public static func tokenSegments(_ t: UsageTokenTotals) -> [UsageShareBarView.Segment] {
        [.init(label: "Input", value: t.uncachedInputTokens, color: UsageStyle.ink(60)),
         .init(label: "Cache read", value: t.cachedInputTokens, color: UsageStyle.ink(30)),
         .init(label: "Cache write", value: t.cacheCreationTokens, color: UsageStyle.ink(72)),
         .init(label: "Output", value: t.outputTokens, color: UsageStyle.ink(100))]
    }

    public static func speedSegments(_ s: UsageSpeedCost) -> [UsageShareBarView.Segment] {
        [.init(label: "Standard", value: s.standard, color: UsageStyle.ink(34)),
         .init(label: "Fast", value: s.fast, color: UsageStyle.ink(66)),
         .init(label: "Ultrafast", value: s.ultrafast, color: UsageStyle.ink(100))]
    }

    /// `SpeedPremium`: "Premium $1.23" beside the speed bar.
    public static func premiumLabel(_ usd: Double) -> NSView {
        let l = UsageStyle.label("Premium ", 12, color: Themed.color(\.mutedForeground))
        l.emphasizedSuffix = UsageFormat.usd(usd)
        l.text = "Premium " + UsageFormat.usd(usd)
        l.frame.size = NSSize(width: ceil(l.textWidth) + 1, height: 16)
        return l
    }
}
