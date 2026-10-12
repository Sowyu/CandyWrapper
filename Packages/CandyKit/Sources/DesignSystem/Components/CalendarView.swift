import AppKit

/// T3's `Calendar` (`components/ui/calendar.tsx`, react-day-picker, mode single, outside days shown),
/// desktop values: 36px cells, 14px day text, 10px radius. Spec: docs/research/recovered/ui-components-a.md 21.
/// One month, Sunday first, en-US captions ("October 2026") and two-letter weekdays, as DayPicker's defaults.
public final class CalendarView: DSView {
    public var month: DateComponents { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    public var selected: DateComponents? { didSet { needsDisplay = true } }
    public var today: DateComponents { didSet { needsDisplay = true } }
    public var isDisabled: (@MainActor (DateComponents) -> Bool)? { didSet { needsDisplay = true } }
    public final var onSelect: (@MainActor (DateComponents) -> Void)?
    /// Keyboard focus on a day (`focus-visible:ring-[3px] ring-ring/50`).
    public var focusedDay: DateComponents? { didSet { needsDisplay = true } }

    public static let cell: CGFloat = 36
    private var calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.firstWeekday = 1; c.locale = Locale(identifier: "en_US"); return c }()
    private var hovered: (row: Int, col: Int)? { didSet { if hovered?.row != oldValue?.row || hovered?.col != oldValue?.col { needsDisplay = true } } }
    private var hoveredNav: Int? { didSet { if hoveredNav != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    public init(month: DateComponents, selected: DateComponents? = nil, today: DateComponents? = nil) {
        self.month = DateComponents(year: month.year, month: month.month, day: 1)
        self.selected = selected
        self.today = today ?? Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Calendar")
    }

    public override var wantsUpdateLayer: Bool { false }

    /// The days shown, six-day-wide weeks of (components, outside-the-month).
    var weeks: [[(DateComponents, Bool)]] {
        let first = calendar.date(from: month)!
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: first)!.count
        let count = Int(((Double(lead + days)) / 7).rounded(.up)) * 7
        return (0..<(count / 7)).map { w in
            (0..<7).map { d in
                let date = calendar.date(byAdding: .day, value: w * 7 + d - lead, to: first)!
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                return (c, c.month != month.month)
            }
        }
    }

    // Caption 36 + `mb-1`, weekday row 36, weeks: 36px cells with `py-px` (38px rows).
    private var gridTop: CGFloat { Self.cell + 4 + Self.cell }
    public override var intrinsicContentSize: NSSize { NSSize(width: 7 * Self.cell, height: gridTop + CGFloat(weeks.count) * 38) }

    private func dayRect(row: Int, col: Int) -> CGRect {
        CGRect(x: CGFloat(col) * Self.cell, y: gridTop + CGFloat(row) * 38 + 1, width: Self.cell, height: Self.cell)
    }

    private func navRect(_ i: Int) -> CGRect {
        CGRect(x: i == 0 ? 0 : bounds.width - Self.cell, y: 0, width: Self.cell, height: Self.cell)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldSmoothFonts(FontRuntime.smoothing)
        let muted72 = Themed.color(\.contrastMutedForeground, 0.72)
        // Caption `text-sm font-medium`, centred between the nav buttons.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "LLLL y"
        drawText(formatter.string(from: calendar.date(from: month)!), font: DSFont.ui(14, weight: .medium),
                 color: Themed.color(\.contrastForeground), in: CGRect(x: 0, y: 0, width: bounds.width, height: Self.cell), lineHeight: 20, ctx: ctx)
        // Nav buttons: chevrons 16px at 80% opacity, hover accent.
        for i in 0..<2 {
            let r = navRect(i)
            if hoveredNav == i {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
                ctx.setFillColor(Themed.color(\.accent).cgColor(in: self)); ctx.fillPath()
            }
            drawChevron(left: i == 0, in: r, color: Themed.color(\.contrastForeground, 0.8).cgColor(in: self), ctx: ctx)
        }
        // Weekdays: `text-xs font-medium text-muted-foreground/72`.
        let names = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        for (i, n) in names.enumerated() {
            drawText(n, font: DSFont.ui(12, weight: .medium), color: muted72,
                     in: CGRect(x: CGFloat(i) * Self.cell, y: Self.cell + 4, width: Self.cell, height: Self.cell), lineHeight: 16, ctx: ctx)
        }
        for (row, week) in weeks.enumerated() {
            for (col, (day, outside)) in week.enumerated() {
                let r = dayRect(row: row, col: col)
                let isSelected = selected.map { $0.year == day.year && $0.month == day.month && $0.day == day.day } ?? false
                let disabled = isDisabled?(day) ?? false
                let isToday = today.year == day.year && today.month == day.month && today.day == day.day
                let path = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
                var text = Themed.color(\.contrastForeground)
                if isSelected {
                    ctx.addPath(path); ctx.setFillColor(Themed.color(\.primary).cgColor(in: self)); ctx.fillPath()
                    text = Themed.color(\.primaryForeground)
                } else {
                    if hovered.map({ $0.row == row && $0.col == col }) ?? false, !disabled {
                        ctx.addPath(path); ctx.setFillColor(Themed.color(\.accent).cgColor(in: self)); ctx.fillPath()
                    }
                    if outside || disabled { text = muted72 }
                }
                if let f = focusedDay, f.year == day.year, f.month == day.month, f.day == day.day {
                    let ring = CGMutablePath()
                    ring.addPath(CGPath(roundedRect: r.insetBy(dx: -3, dy: -3), cornerWidth: 13, cornerHeight: 13, transform: nil))
                    ring.addPath(path)
                    ctx.addPath(ring); ctx.setFillColor(Themed.color(\.ring, 0.5).cgColor(in: self)); ctx.fillPath(using: .evenOdd)
                }
                let label = "\(day.day!)"
                let width = drawText(label, font: DSFont.ui(14), color: text, in: r, lineHeight: 20, ctx: ctx)
                if disabled {
                    // `line-through`
                    ctx.setFillColor(text.cgColor(in: self))
                    ctx.fill(CGRect(x: r.midX - width / 2, y: r.midY + 0.5, width: width, height: 1))
                }
                if isToday {
                    // 3px dot, `bottom-1`, primary; background on the selected day; foreground/30 when disabled.
                    let dot = disabled ? Themed.color(\.contrastForeground, 0.3) : isSelected ? Themed.color(\.background) : Themed.color(\.primary)
                    ctx.setFillColor(dot.cgColor(in: self))
                    ctx.fillEllipse(in: CGRect(x: r.midX - 1.5, y: r.maxY - 4 - 3, width: 3, height: 3))
                }
            }
        }
    }

    @discardableResult
    private func drawText(_ s: String, font: NSFont, color: NSColor, in r: CGRect, lineHeight: CGFloat, ctx: CGContext) -> CGFloat {
        let line = TextLine(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: r.midX - line.width / 2, y: line.baseline(top: r.minY + (r.height - lineHeight) / 2, lineHeight: lineHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line.line, ctx)
        ctx.restoreGState()
        return line.width
    }

    private func drawChevron(left: Bool, in r: CGRect, color: CGColor, ctx: CGContext) {
        // lucide chevron-left `m15 18-6-6 6-6`, chevron-right `m9 18 6-6-6-6`, 24 units at 16px.
        let s: CGFloat = 16 / 24, ox = r.midX - 8, oy = r.midY - 8
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        ctx.beginPath()
        if left { ctx.move(to: p(15, 18)); ctx.addLine(to: p(9, 12)); ctx.addLine(to: p(15, 6)) } else { ctx.move(to: p(9, 18)); ctx.addLine(to: p(15, 12)); ctx.addLine(to: p(9, 6)) }
        ctx.setStrokeColor(color); ctx.setLineWidth(2 * s); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // MARK: Input

    public func showMonth(offset: Int) {
        let d = calendar.date(byAdding: .month, value: offset, to: calendar.date(from: month)!)!
        month = calendar.dateComponents([.year, .month], from: d)
        month.day = 1
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func hit(_ event: NSEvent) -> (nav: Int?, day: (Int, Int)?) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0..<2 where navRect(i).contains(p) { return (i, nil) }
        for row in weeks.indices { for col in 0..<7 where dayRect(row: row, col: col).contains(p) { return (nil, (row, col)) } }
        return (nil, nil)
    }

    /// For tests and the gallery.
    public func previewHover(row: Int, col: Int) { hovered = (row, col) }

    public override func mouseMoved(with event: NSEvent) {
        let h = hit(event)
        hoveredNav = h.nav
        hovered = h.day.map { (row: $0.0, col: $0.1) }
    }

    public override func mouseExited(with event: NSEvent) { hovered = nil; hoveredNav = nil }

    public override func mouseUp(with event: NSEvent) {
        let h = hit(event)
        if let nav = h.nav { showMonth(offset: nav == 0 ? -1 : 1); return }
        guard let (row, col) = h.day else { return }
        let day = weeks[row][col].0
        if isDisabled?(day) ?? false { return }
        selected = day
        onSelect?(day)
    }
}
