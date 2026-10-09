import AppKit

/// T3's `Table` (`apps/web/src/components/ui/table.tsx`): 12px text, 40px header cells, 8px cell padding,
/// 1px row borders (none under the last row), muted/50 hover and muted selected rows.
/// Columns size like Chromium's auto table layout: max-content widths, extra space shared in proportion.
/// Spec: docs/research/recovered/ui-components-b.md section 15.
public final class DataTableView: DSView {
    public var headers: [String] { didSet { rebuild() } }
    public var rows: [[String]] { didSet { rebuild() } }
    /// `data-state="selected"` rows.
    public var selectedRows: Set<Int> = [] { didSet { needsDisplay = true } }
    /// The hovered body row (`hover:bg-muted/50`); tracked from the pointer, settable for previews.
    public var hoveredRow: Int? { didSet { if hoveredRow != oldValue { needsDisplay = true } } }

    private var headLabels: [LabelView] = []
    private var cellLabels: [[LabelView]] = []
    private var trackingArea: NSTrackingArea?

    static let headHeight: CGFloat = 40, rowHeight: CGFloat = 32

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
        super.init(frame: .zero)
        rebuild()
    }

    private func rebuild() {
        (headLabels + cellLabels.flatMap { $0 }).forEach { $0.removeFromSuperview() }
        func label(_ text: String, head: Bool) -> LabelView {
            let l = LabelView(text, font: DSFont.ui(12, weight: head ? .medium : .regular), color: Themed.color(\.contrastForeground))
            l.lineHeight = 16
            addSubview(l)
            return l
        }
        headLabels = headers.map { label($0, head: true) }
        cellLabels = rows.map { $0.map { label($0, head: false) } }
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    /// Collapsed borders: the header row is 40px with its border centered on its bottom edge,
    /// each body row 32px plus 1px of border shared with its neighbours.
    public override var intrinsicContentSize: NSSize {
        let body = rows.isEmpty ? 0 : CGFloat(rows.count) * (Self.rowHeight + 1) - 0.5
        return NSSize(width: NSView.noIntrinsicMetric, height: Self.headHeight + body)
    }

    private func columnWidths() -> [CGFloat] {
        var widths = headLabels.map { $0.textWidth + 16 }
        for row in cellLabels { for (i, l) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], l.textWidth + 16) } }
        let total = widths.reduce(0, +)
        guard total > 0, bounds.width > total else { return widths }
        return widths.map { $0 + (bounds.width - total) * $0 / total }
    }

    /// Top of body row `i`'s padding box.
    private func rowTop(_ i: Int) -> CGFloat { Self.headHeight + 0.5 + CGFloat(i) * (Self.rowHeight + 1) }

    public override func layout() {
        super.layout()
        let widths = columnWidths()
        var x: CGFloat = 0
        for (c, w) in widths.enumerated() {
            headLabels[c].frame = NSRect(x: x + 8, y: (Self.headHeight - 0.5 - 16) / 2, width: w - 16, height: 16)
            for (r, row) in cellLabels.enumerated() where c < row.count {
                row[c].frame = NSRect(x: x + 8, y: rowTop(r) + 8, width: w - 16, height: 16)
            }
            x += w
        }
    }

    public override var wantsUpdateLayer: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for i in rows.indices {
            let fill: NSColor? = selectedRows.contains(i) ? Themed.color(\.muted) : hoveredRow == i ? Themed.color(\.muted, 0.5) : nil
            if let fill {
                ctx.setFillColor(fill.cgColor(in: self))
                ctx.fill(CGRect(x: 0, y: rowTop(i), width: bounds.width, height: Self.rowHeight))
            }
        }
        ctx.setFillColor(Themed.color(\.contrastBorder).cgColor(in: self))
        ctx.fill(CGRect(x: 0, y: Self.headHeight - 0.5, width: bounds.width, height: 1))
        for i in rows.indices.dropLast() {
            ctx.fill(CGRect(x: 0, y: rowTop(i) + Self.rowHeight, width: bounds.width, height: 1))
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        hoveredRow = rows.indices.first { y >= rowTop($0) - 0.5 && y < rowTop($0) + Self.rowHeight + 0.5 }
    }

    public override func mouseExited(with event: NSEvent) { hoveredRow = nil }
}
