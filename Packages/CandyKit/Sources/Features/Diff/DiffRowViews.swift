import AppKit
import CoreText
import DesignSystem

/// What a row view needs to configure itself; owned by `DiffListView`.
@MainActor
struct DiffRowContext {
    let diff: UnifiedDiff
    let layout: DiffLayout
    let highlighter: DiffHighlighter
    /// Horizontal scroll of code text when lines do not wrap.
    let scrollX: CGFloat
}

/// How file headers show their line counts. pierre's own `-D +A` (T3's turn diffs), or T3's
/// right-aligned `DiffStatLabel` columns (`+A -D`, compact counts), which T3 uses for the
/// git-backed lazy source shown in reference captures 09 and 10.
public enum DiffStatStyle: Sendable { case pierre, aligned }

class DiffRowView: DSView {
    var rowIndex = -1
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = DiffStyle.surface.cgColor(in: self) }
}

// MARK: - File header

/// pierre's `[data-diffs-header]` with T3's overrides and header slots (DiffPanel.tsx:123-195):
/// collapse chevron, change icon, start-truncated path, copy button, counts.
final class DiffFileHeaderView: DiffRowView {
    let chevron = ButtonView(nil, icon: .chevronRight, variant: .ghost, size: .iconMicro)
    let icon = DiffChangeIconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    let title = DiffTitleView()
    let copy = ButtonView(nil, icon: .copy, variant: .ghostMuted, size: .iconMicro)
    let stat = DiffStatView()
    private let hoverBar = CALayer()
    private var tracking: NSTrackingArea?
    private(set) var file = -1
    var onToggle: (@MainActor (Int) -> Void)?
    var onOpenFile: (@MainActor (String) -> Void)?
    private var path = ""
    /// The pull request Code tab's "Viewed" tick (PullRequestCodeTab.tsx:849-880): a checkbox and
    /// its word, "Changed" when the file moved since it was ticked. Hidden outside that tab.
    let viewedBox = CheckboxView()
    let viewedLabel = LabelView("Viewed", font: DSFont.ui(12))
    var onViewed: (@MainActor (String, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        copy.iconSize = 12
        hoverBar.isHidden = true
        hoverBar.actions = ["hidden": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(hoverBar)
        [chevron, icon, title, copy, stat, viewedBox, viewedLabel].forEach(addSubview)
        viewedLabel.lineHeight = 16
        viewedBox.isHidden = true
        viewedLabel.isHidden = true
        viewedBox.onChange = { [weak self] value in if let self { self.onViewed?(self.path, value == .on) } }
        chevron.action = { [weak self] in if let self { self.onToggle?(self.file) } }
        copy.action = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            let copied = NSPasteboard.general.setString(path, forType: .string)
            AnchoredCopyToast.show(from: copy, success: copied)
        }
        setAccessibilityRole(.button)
    }

    func configure(viewed: (viewed: Bool, stale: Bool)?) {
        viewedBox.isHidden = viewed == nil
        viewedLabel.isHidden = viewed == nil
        viewedBox.value = viewed?.viewed == true ? .on : .off
        viewedLabel.text = viewed?.stale == true ? "Changed" : "Viewed"
        viewedLabel.color = viewed?.stale == true ? Themed.color(\.warningForeground) : Themed.color(\.mutedForeground)
        needsLayout = true
    }

    func configure(file index: Int, _ file: UnifiedDiff.File, collapsed: Bool, statStyle: DiffStatStyle) {
        self.file = index
        path = file.path
        chevron.icon = collapsed ? .chevronRight : .chevronDown
        chevron.iconColor = DiffStyle.iconColor(file.change)
        icon.change = file.change
        title.text = file.path
        stat.set(additions: file.additions, deletions: file.deletions, style: statStyle)
        setAccessibilityLabel(file.path)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // `padding-inline: 8px 12px`, `gap: 8px`; the chevron has `-ms-0.5`.
        chevron.frame = NSRect(x: 6, y: 6, width: 20, height: 20)
        icon.frame = NSRect(x: 34, y: 8, width: 16, height: 16)
        let statWidth = stat.preferredWidth
        var statRight = bounds.width - 12
        if !viewedBox.isHidden {
            let lw = ceil(viewedLabel.textWidth)
            viewedLabel.frame = NSRect(x: statRight - lw, y: 8, width: lw + 1, height: 16)
            viewedBox.frame = NSRect(x: statRight - lw - 6 - 16, y: 8, width: 16, height: 16)
            statRight = viewedBox.frame.minX - 12
        }
        stat.frame = NSRect(x: statRight - statWidth, y: 0, width: statWidth, height: DiffStyle.headerHeight)
        let titleMax = max(0, stat.frame.minX - (statWidth > 0 ? 8 : 0) - 8 - 20 - 58)
        let titleWidth = min(title.naturalWidth, titleMax)
        title.frame = NSRect(x: 58, y: 8, width: titleWidth, height: 16)
        copy.frame = NSRect(x: 58 + titleWidth + 8, y: 6, width: 20, height: 20)
        hoverBar.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
    }

    override func updateLayer() {
        super.updateLayer()
        hoverBar.backgroundColor = DiffStyle.headerHoverBar.cgColor(in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { hoverBar.isHidden = false }
    override func mouseExited(with event: NSEvent) { hoverBar.isHidden = true; title.hovered = false }
    override func mouseMoved(with event: NSEvent) {
        title.hovered = title.frame.contains(convert(event.locationInWindow, from: nil))
    }

    /// The name opens the file; anywhere else toggles the file (DiffPanel.tsx:1107-1160).
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !viewedBox.isHidden, viewedBox.frame.union(viewedLabel.frame).contains(point) { return }
        if title.frame.contains(point), let onOpenFile { onOpenFile(path) } else { onToggle?(file) }
    }
    override func mouseDown(with event: NSEvent) {}
}

/// File name in the header: 12px sans on a 16px line, truncated at the start like pierre's
/// `direction: rtl; text-overflow: ellipsis`. Hover tints it toward `--primary` (120ms in T3).
final class DiffTitleView: DSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private static let font = DSFont.ui(12)
    private static let hoverColor = DiffStyle.mix(DiffStyle.codeForeground, 0.84, Themed.color(\.primary))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
    }

    var naturalWidth: CGFloat { ceil(line(color: .black).width) }

    private func line(color: NSColor) -> TextLine {
        TextLine(NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: color]))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldSmoothFonts(true)
        let color = hovered ? Self.hoverColor : DiffStyle.codeForeground
        let line = line(color: color)
        var ctLine = line.line
        if line.width > bounds.width + 0.5 {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: [.font: Self.font, .foregroundColor: color]))
            if let cut = CTLineCreateTruncatedLine(ctLine, Double(bounds.width), .start, ellipsis) { ctLine = cut }
        }
        let baseline = line.baseline(top: 0, lineHeight: 16)
        // `direction: rtl` aligns a truncated name to the right edge of its box.
        let x = ctLine === line.line ? 0 : bounds.width - CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
    }
}

/// Header counts. pierre: `-D` then `+A` (zero counts hidden), mono 11px, `gap: 1ch`.
/// Aligned (T3 `DiffStatLabel`): `+A` and `-D` right-aligned in two 4ch columns 8px apart.
final class DiffStatView: DSView {
    /// `right` edge of each part; text wider than its column starts at `left` instead, as an
    /// overflowing `text-align: right` box does in CSS.
    private var parts: [(text: String, color: NSColor, right: CGFloat, left: CGFloat)] = []
    private(set) var preferredWidth: CGFloat = 0
    private var font = DSFont.mono(11)
    /// DiffStatLabel sits 1px lower than pierre's centered `line-height: 1` counts (measured in 10).
    private var baselineShift: CGFloat = 0
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
    }

    func set(additions: Int, deletions: Int, style: DiffStatStyle) {
        let add = Themed.color(\.diffAddition), del = Themed.color(\.diffDeletion)
        switch style {
        case .pierre:
            font = DSFont.mono(11)
            baselineShift = 0
            let gap = DSFont.ui(12).advancement(forGlyph: DSFont.ui(12).glyph(withName: "zero")).width // 1ch of the header font
            var items: [(String, NSColor)] = []
            if deletions > 0 { items.append(("-\(deletions)", DiffStyle.deletionBase)) }
            if additions > 0 { items.append(("+\(additions)", DiffStyle.additionBase)) }
            var x: CGFloat = 0
            var placed: [(String, NSColor, CGFloat)] = []
            for (i, item) in items.enumerated() {
                if i > 0 { x += gap }
                x += width(item.0)
                placed.append((item.0, item.1, x))
            }
            parts = placed.map { ($0.0, $0.1, $0.2, -.greatestFiniteMagnitude) }
            preferredWidth = x
        case .aligned:
            // Measured in reference 10: 11px mono text in columns of 4ch of the 12px sans header
            // font (the grid container is not `font-mono`).
            font = DSFont.mono(11)
            baselineShift = 1
            let sans = DSFont.ui(12)
            let ch = sans.advancement(forGlyph: sans.glyph(withName: "zero")).width
            parts = [("+\(DiffStatView.compact(additions))", add, 4 * ch, 0), ("-\(DiffStatView.compact(deletions))", del, 8 * ch + 8, 4 * ch + 8)]
            preferredWidth = 8 * ch + 8
        }
        needsDisplay = true
    }

    /// The panel header's totals (`DiffStatLabel layout="inline"`, `text-2xs`): `+A -D`, compact,
    /// mono 11px, `gap-1`.
    func setInline(additions: Int, deletions: Int) {
        font = DSFont.mono(11)
        baselineShift = 0
        let plus = "+\(Self.compact(additions))", minus = "-\(Self.compact(deletions))"
        let a = width(plus)
        parts = [(plus, Themed.color(\.diffAddition), a, 0), (minus, Themed.color(\.diffDeletion), a + 4 + width(minus), 0)]
        preferredWidth = a + 4 + width(minus)
        needsDisplay = true
    }

    /// The changed files card's per-row counts (`font-mono text-3xs` around an aligned
    /// `DiffStatLabel`): two right-aligned 4ch columns of the mono font, 8px apart.
    func setAligned(additions: Int, deletions: Int, size: CGFloat) {
        font = DSFont.mono(size)
        // The grid sits `align-middle` on the row's 16px text line, 1px under the box's center (47).
        baselineShift = 1
        let ch = width("0")
        parts = [("+\(Self.compact(additions))", Themed.color(\.diffAddition), 4 * ch, 0),
                 ("-\(Self.compact(deletions))", Themed.color(\.diffDeletion), 8 * ch + 8, 4 * ch + 8)]
        preferredWidth = 8 * ch + 8
        needsDisplay = true
    }

    /// `+A -D` at an explicit size and gap (the card header's `text-xs` inline label).
    func setInline(additions: Int, deletions: Int, size: CGFloat) {
        setInline(additions: additions, deletions: deletions)
        guard size != font.pointSize else { return }
        font = DSFont.mono(size)
        let plus = "+\(Self.compact(additions))", minus = "-\(Self.compact(deletions))"
        let a = width(plus)
        parts = [(plus, Themed.color(\.diffAddition), a, 0), (minus, Themed.color(\.diffDeletion), a + 4 + width(minus), 0)]
        preferredWidth = a + 4 + width(minus)
    }

    private func width(_ s: String) -> CGFloat { TextLine(NSAttributedString(string: s, attributes: [.font: font])).width }

    /// `formatCompactDiffCount` (DiffStatLabel.tsx): 999, 1.2k, 21k, 1.5m.
    static func compact(_ value: Int) -> String {
        func unit(_ v: Double, _ suffix: String) -> String {
            v < 10 ? String(format: "%.1f", v).replacingOccurrences(of: ".0", with: "") + suffix : "\(Int(v.rounded()))\(suffix)"
        }
        if value < 1000 { return "\(value)" }
        if value < 1_000_000 { return unit(Double(value) / 1000, "k") }
        if value < 1_000_000_000 { return unit(Double(value) / 1_000_000, "m") }
        return unit(Double(value) / 1_000_000_000, "b")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldSmoothFonts(true)
        for part in parts {
            let line = TextLine(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: part.color]))
            // pierre's counts are a `line-height: 1` box centered in the header; DiffStatLabel's sit
            // on the header's 12px text line.
            let lineHeight = font.pointSize
            let baseline = line.baseline(top: (bounds.height - lineHeight) / 2 + baselineShift, lineHeight: lineHeight)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: max(part.left, part.right - line.width), y: baseline)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line.line, ctx)
            ctx.restoreGState()
        }
    }
}

// MARK: - Hunk separator

/// `[data-separator="line-info"]` with T3's overrides: a 24px band, "N unmodified lines" in 11px
/// sans at 52% foreground between two 1px rules (unified); split shows the label alone at the left.
final class DiffSeparatorView: DiffRowView {
    let label = LabelView("", font: DSFont.ui(11), color: DiffStyle.separatorText)
    private let leftRule = CALayer(), rightRule = CALayer()
    var split = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 20
        for rule in [leftRule, rightRule] {
            rule.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(rule)
        }
        addSubview(label)
    }

    func configure(hidden: Int, split: Bool) {
        self.split = split
        label.text = hidden == 1 ? "1 unmodified line" : "\(hidden) unmodified lines"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // `padding-inline: 8px 12px`; in unified the rules share the rest equally around the label.
        let inner = CGRect(x: 8, y: 2, width: max(0, bounds.width - 20), height: 20)
        // Split: the rules have no room but their flex gaps stay, so the label starts 8px in.
        let x = split ? inner.minX + 8 : inner.minX + (inner.width - label.textWidth) / 2
        label.frame = NSRect(x: x, y: inner.minY, width: ceil(label.textWidth), height: 20)
        let ruleY = inner.minY + 9.5
        leftRule.isHidden = split
        rightRule.isHidden = split
        leftRule.frame = CGRect(x: inner.minX, y: ruleY, width: max(0, label.frame.minX - 8 - inner.minX), height: 1)
        rightRule.frame = CGRect(x: label.frame.minX + label.textWidth + 8, y: ruleY,
                                 width: max(0, inner.maxX - (label.frame.minX + label.textWidth + 8)), height: 1)
    }

    override func updateLayer() {
        super.updateLayer()
        let rule = DiffStyle.separatorRule.cgColor(in: self)
        leftRule.backgroundColor = rule
        rightRule.backgroundColor = rule
    }
}

// MARK: - Code rows

/// One code row (or a "No newline at end of file" row), unified or split. Backgrounds and change
/// bars are layers; only the numbers and code are drawn, by `DiffCodeTextView`.
final class DiffLineRowView: DiffRowView {
    private struct Side {
        let gutter = CALayer(), code = CALayer(), bar = CALayer()
    }
    private var sides: [Side] = []
    let text = DiffCodeTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for _ in 0..<2 {
            let side = Side()
            for l in [side.gutter, side.code, side.bar] {
                l.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
                layer?.addSublayer(l)
            }
            sides.append(side)
        }
        addSubview(text)
        text.layer?.zPosition = 1
    }

    private var kinds: [(UnifiedDiff.Line.Kind?, Bool)] = [] // per side: kind (nil = missing), noNewline row

    func configure(row: DiffLayout.Row, _ context: DiffRowContext) {
        let layout = context.layout
        let columns = layout.columns[Int(row.file)]
        let isMarker = row.kind == .noNewline
        let indices: [Int32] = columns.isSplit ? [row.left, row.right] : [row.left]
        kinds = indices.map { $0 >= 0 ? (context.diff.lines[Int($0)].kind, isMarker) : (nil, isMarker) }
        text.configure(row: row, columns: columns, context, marker: isMarker)
        needsLayout = true
        needsDisplay = true
    }

    private var columns: DiffLayout.Columns? { text.columns }

    override func layout() {
        super.layout()
        text.frame = bounds
        guard let columns else { return }
        let h = bounds.height
        for (i, side) in sides.enumerated() {
            let present = i < kinds.count
            [side.gutter, side.code, side.bar].forEach { $0.isHidden = !present }
            guard present else { continue }
            let gutterX = i == 0 ? 0 : columns.codeX[0] + columns.codeWidth[0]
            // The new side's gutter starts after the 1px seam; both end with the 2px surface border.
            let lead: CGFloat = i == 0 ? 0 : 1
            side.gutter.frame = CGRect(x: gutterX + lead, y: 0, width: columns.gutter - DiffStyle.gutterBorder - lead, height: h)
            let seam: CGFloat = (i == 0 && kinds.count == 2) ? 1 : 0
            side.code.frame = CGRect(x: columns.codeX[i], y: 0, width: columns.codeWidth[i] - seam, height: h)
            side.bar.frame = CGRect(x: gutterX + lead, y: 0, width: DiffStyle.barWidth, height: h)
        }
    }

    override func updateLayer() {
        super.updateLayer()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for (i, side) in sides.enumerated() where i < kinds.count {
            let (kind, marker) = kinds[i]
            let gutter: NSColor, code: NSColor
            switch kind {
            case .addition?: gutter = marker ? DiffStyle.surface : DiffStyle.additionNumber; code = DiffStyle.additionLine
            case .deletion?: gutter = marker ? DiffStyle.surface : DiffStyle.deletionNumber; code = DiffStyle.deletionLine
            case .context?: gutter = DiffStyle.surface; code = DiffStyle.surface
            case nil: gutter = marker ? DiffStyle.surface : DiffStyle.gutterBuffer; code = DiffStyle.surface
            }
            side.gutter.backgroundColor = gutter.cgColor(in: self)
            side.code.backgroundColor = kind == nil && !marker ? DiffStyle.bufferPattern(dark: dark) : code.cgColor(in: self)
            let showBar = !marker && (kind == .addition || kind == .deletion)
            side.bar.isHidden = !showBar
            side.bar.backgroundColor = kind == .deletion ? DiffStyle.deletionBarPattern(dark: dark) : DiffStyle.additionBase.cgColor(in: self)
        }
    }
}

/// Draws a code row's line numbers and highlighted text, wrapped at the layout's break points.
final class DiffCodeTextView: DSView {
    private struct Piece { var line: CTLine; var x: CGFloat; var y: CGFloat; var clip: CGRect }
    private var pieces: [Piece] = []
    private(set) var columns: DiffLayout.Columns?
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
        // Long unwrapped lines are clipped to the row, not drawn into a wider backing store.
        clipsToBounds = true
    }

    func configure(row: DiffLayout.Row, columns: DiffLayout.Columns, _ context: DiffRowContext, marker: Bool) {
        self.columns = columns
        pieces = []
        let font = DiffStyle.codeFont, ch = DiffStyle.ch
        let indices: [Int32] = columns.isSplit ? [row.left, row.right] : [row.left]
        for (side, index) in indices.enumerated() where index >= 0 {
            let line = context.diff.lines[Int(index)]
            let codeX = columns.codeX[side] + ch
            if marker {
                let attributed = NSAttributedString(string: "No newline at end of file", attributes: [.font: font, .foregroundColor: DiffStyle.noNewlineText])
                pieces.append(Piece(line: CTLineCreateWithAttributedString(attributed), x: codeX, y: 0, clip: .infinite))
                continue
            }
            // Number: right-aligned before the 1ch right padding and the 2px border.
            let number = line.kind == .deletion || (columns.isSplit && side == 0) ? line.oldNumber : line.newNumber
            let numberColor: NSColor = line.kind == .addition ? DiffStyle.additionBase : line.kind == .deletion ? DiffStyle.deletionBase : DiffStyle.number
            let numberLine = CTLineCreateWithAttributedString(NSAttributedString(string: String(number), attributes: [.font: font, .foregroundColor: numberColor]))
            let gutterRight = (side == 0 ? 0 : columns.codeX[0] + columns.codeWidth[0] + 1) + columns.gutter - DiffStyle.gutterBorder - ch
            pieces.append(Piece(line: numberLine, x: gutterRight - CGFloat(CTLineGetTypographicBounds(numberLine, nil, nil, nil)), y: 0, clip: .infinite))
            let clip = CGRect(x: columns.codeX[side], y: 0, width: columns.codeWidth[side], height: .greatestFiniteMagnitude)
            // Code, colored by token, cut at the wrap breaks.
            let text = context.diff.text(line)
            let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: DiffStyle.codeText])
            let length = attributed.length
            for span in context.highlighter.spans(file: Int(row.file), line: Int(index)) {
                let start = Int(span.start), end = min(length, start + Int(span.length))
                guard start < end else { continue }
                attributed.addAttribute(.foregroundColor, value: span.kind.color, range: NSRange(location: start, length: end - start))
                if span.kind == .emphasis {
                    attributed.addAttribute(.font, value: DiffStyle.codeItalicFont, range: NSRange(location: start, length: end - start))
                }
            }
            let breaks = columns.columns[side].map { DiffLayout.wrapBreaks(text, columns: $0) } ?? []
            var start = 0
            for (k, end) in (breaks + [length]).enumerated() {
                let piece = attributed.attributedSubstring(from: NSRange(location: start, length: max(0, end - start)))
                pieces.append(Piece(line: CTLineCreateWithAttributedString(Self.expandTabs(piece)), x: codeX - (columns.columns[side] == nil ? context.scrollX : 0),
                                    y: CGFloat(k) * DiffStyle.lineHeight, clip: clip))
                start = end
            }
        }
        needsDisplay = true
    }

    /// `tab-size: 2`: Core Text's default tab stops are wider, so tabs become spaces before drawing.
    // ponytail: replaces each tab with two spaces instead of advancing to the next stop; exact for
    // leading indentation, off by one column after odd-length text.
    static func expandTabs(_ s: NSAttributedString) -> NSAttributedString {
        guard s.string.contains("\t") else { return s }
        let m = NSMutableAttributedString(attributedString: s)
        var r = (m.string as NSString).range(of: "\t")
        while r.location != NSNotFound {
            m.replaceCharacters(in: r, with: "  ")
            r = (m.string as NSString).range(of: "\t", options: [], range: NSRange(location: r.location + 2, length: m.length - r.location - 2))
        }
        return m
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        let metrics = TextLine(NSAttributedString(string: "0", attributes: [.font: DiffStyle.codeFont]))
        let baselineOffset = metrics.baseline(top: 0, lineHeight: DiffStyle.lineHeight)
        ctx.textMatrix = .identity
        for piece in pieces {
            ctx.saveGState()
            // Bounded by the view: AppKit records this drawing and replays it at 2x, and the
            // piece's unbounded height overflowed to an empty clip there (code never showed on
            // screen while offscreen snapshots were fine).
            if !piece.clip.isInfinite { ctx.clip(to: piece.clip.intersection(bounds)) }
            ctx.translateBy(x: piece.x, y: piece.y + baselineOffset)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(piece.line, ctx)
            ctx.restoreGState()
        }
    }
}
