import AppKit
import CoreText
import DesignSystem
import T3Protocol
import T3Store

/// `SidebarDraftRow` (Sidebar.tsx:833-950): `li py-0.5` around a 78pt `rounded-md` surface, content
/// `px-2.5 py-2`. Line 1 (h-5, gap-1.5): the warning pen, the project favicon, the project name in
/// `text-xs font-medium text-secondary-label`, the hover-only discard button. Line 2 (`mt-0.5`): the
/// prompt's first line in `text-sm font-medium text-foreground/90`. Unsent work is tinted
/// `bg-warning/4 hover:bg-warning/8`; the open draft is `bg-sidebar-row-active`.
final class SidebarDraftRowView: SidebarRowBase {
    private let surface = CALayer()
    private let pen = IconView(name: .squarePen, size: 12)
    private let monogram = ProjectMonogramView()
    private let project = LabelView()
    private let preview = LabelView()
    let discardButton = RowActionButton(icon: .x, size: 12, accessibility: "Discard draft")
    var onDiscard: (@MainActor (String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "borderColor": NSNull()]
        surface.cornerRadius = 8
        layer?.addSublayer(surface)
        for v in [pen, monogram, project, preview, discardButton] as [NSView] { addSubview(v) }
        project.font = SB.font(12, .medium); project.lineHeight = 16
        preview.font = SB.font(14, .medium); preview.lineHeight = 20
        discardButton.padding = 4
        discardButton.action = { [weak self] in if let d = self?.draft { self?.onDiscard?(d.id) } }
    }

    var draft: SidebarDraftRowModel? { if case .draft(let d)? = item { d } else { nil } }

    override func refresh() {
        guard let d = draft else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.backgroundColor = (d.isActive ? SB.c(\.sidebarRowActive) : SB.c(\.warning, state.hovered ? 0.08 : 0.04)).cgColor(in: self)
        surface.borderWidth = isKeyboardFocused ? 2 : 0
        surface.borderColor = SB.c(\.ring).cgColor(in: self)
        CATransaction.commit()
        pen.strokeColor = SB.c(\.warningForeground)
        monogram.projectTitle = d.projectTitle ?? d.projectLabel ?? ""
        monogram.source = d.projectIcon
        monogram.isHidden = d.projectTitle == nil
        project.text = d.projectLabel ?? ""
        project.color = SB.c(\.secondaryLabel)
        preview.text = d.preview
        preview.color = SB.c(\.foreground, 0.9)
        // `opacity-0 group-hover/sidebar-row:opacity-100`, and shown while it has keyboard focus.
        discardButton.isHidden = !(state.hovered || isKeyboardFocused)
        setAccessibilityLabel("\(d.preview), Unsent draft" + (d.projectLabel.map { ", \($0)" } ?? ""))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = CGRect(x: 0, y: 2, width: w, height: 78)
        CATransaction.commit()
        let left: CGFloat = 10, right = w - 10, top: CGFloat = 10
        var x = left
        pen.frame = NSRect(x: x, y: top + 4, width: 12, height: 12); x += 12 + 6
        if !monogram.isHidden { monogram.frame = NSRect(x: x, y: top + 2, width: 16, height: 16); x += 16 + 6 }
        // `ml-auto h-5 min-w-5`: the slot keeps 20pt even while the button is hidden.
        let bw = discardButton.preferredWidth
        discardButton.frame = NSRect(x: right - bw, y: top + 4, width: bw, height: 12)
        project.frame = NSRect(x: x, y: top + 2, width: max(0, right - max(20, bw) - 6 - x), height: 16)
        preview.frame = NSRect(x: left, y: top + 22, width: right - left, height: 20)
    }
}

/// `sidebar-draft-divider` (Sidebar.tsx:1059-1063): `mx-2.5 my-1.5 h-px bg-sidebar-border/60`.
final class SidebarDividerRowView: SidebarRowBase {
    private let line = CALayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(line)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func refresh() { line.backgroundColor = SB.c(\.sidebarBorder, 0.6).cgColor(in: self) }
    override func layout() {
        super.layout()
        line.frame = CGRect(x: 2, y: 6, width: max(0, bounds.width - 4), height: 1)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
}

/// The centered status text. Search: `px-2 py-6 text-center text-xs text-sidebar-muted-foreground`
/// (Sidebar.tsx:5202-5209). Empty list: `px-2 py-6 text-center text-xs text-muted-foreground/60`
/// (Sidebar.tsx:5556).
final class SidebarEmptyTextRowView: SidebarRowBase {
    private let label = LabelView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = SB.font(12); label.lineHeight = 16
        label.alignment = .center
        addSubview(label)
        setAccessibilityRole(.staticText)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func refresh() {
        guard case .emptyText(let text, let search)? = item else { return }
        label.text = text
        label.color = search ? SB.c(\.sidebarMutedForeground) : SB.c(\.mutedForeground, 0.6)
        setAccessibilityLabel(text)
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: 24, width: max(0, bounds.width - 16), height: 16)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
}

/// `SidebarSearchResultRow` (Sidebar.tsx:2229-2380): `min-h-9 gap-2.5 rounded-md px-2.5 py-1 text-sm`,
/// the favicon, then a column with the title and its time (`text-xs text-muted-foreground/55
/// tabular-nums`) and, for message matches, the excerpt. Highlighted or open: `bg-sidebar-row-active
/// text-sidebar-foreground`; otherwise `text-sidebar-muted-foreground/75` and the row hover.
final class SidebarSearchResultRowView: SidebarRowBase {
    private let surface = CALayer()
    private let monogram = ProjectMonogramView()
    private let title = LabelView()
    private let time = LabelView()
    private let excerpt = SearchExcerptView()
    private var moveTracking: NSTrackingArea?
    var onHover: (@MainActor (Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        surface.cornerRadius = 8
        layer?.addSublayer(surface)
        for v in [monogram, title, time, excerpt] as [NSView] { addSubview(v) }
        title.font = SB.font(14); title.lineHeight = 20
        time.font = SB.tabular(12); time.lineHeight = 16
        setAccessibilityRole(.button)
    }

    var result: SidebarSearchResultModel? { if case .searchResult(let r)? = item { r } else { nil } }

    override func refresh() {
        guard let r = result else { return }
        let lit = r.isHighlighted || r.isActive
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.backgroundColor = lit ? SB.c(\.sidebarRowActive).cgColor(in: self)
            : state.hovered ? SB.c(\.sidebarRowHover).cgColor(in: self) : nil
        CATransaction.commit()
        monogram.projectTitle = r.projectTitle ?? ""
        monogram.source = r.projectIcon
        monogram.isHidden = r.projectTitle == nil
        title.text = r.title
        title.color = lit || state.hovered ? SB.c(\.sidebarForeground) : SB.c(\.sidebarMutedForeground, 0.75)
        time.text = r.timeLabel
        time.color = SB.c(\.mutedForeground, 0.55)
        excerpt.isHidden = r.match == nil
        if let m = r.match { excerpt.set(isUser: m.isUser, snippet: m.snippet, query: r.query) }
        setAccessibilityLabel(r.title)
        setAccessibilitySelected(r.isHighlighted)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        CATransaction.commit()
        var x: CGFloat = 10
        if !monogram.isHidden { monogram.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16); x += 16 + 10 }
        let right = w - 10
        let column: CGFloat = excerpt.isHidden ? 20 : 36
        let top = (h - column) / 2
        let tw = ceil(time.textWidth)
        time.frame = NSRect(x: right - tw, y: top + 2, width: tw + 1, height: 16)
        title.frame = NSRect(x: x, y: top, width: max(0, right - tw - 10 - x), height: 20)
        excerpt.frame = NSRect(x: x, y: top + 20, width: max(0, right - x), height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveTracking { removeTrackingArea(moveTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        moveTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if let r = result, !r.isHighlighted { onHover?(r.index) }
    }
}

/// `ThreadSearchMatchExcerpt` (ThreadSearchMatch.tsx:51-66): `truncate text-xs text-muted-foreground/85`,
/// "You:" in `text-info-foreground` or "Agent:" in `text-success-foreground`, then the snippet with every
/// ASCII-case-insensitive hit of the query in `font-semibold text-foreground`.
final class SearchExcerptView: DSView {
    private var isUser = true, snippet = "", query = ""
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(isUser: Bool, snippet: String, query: String) {
        guard isUser != self.isUser || snippet != self.snippet || query != self.query else { return }
        self.isUser = isUser; self.snippet = snippet; self.query = query
        needsDisplay = true
    }

    /// `HighlightedSearchText`: ranges of the trimmed query, folding only A to Z.
    static func highlights(in text: String, query: String) -> [Range<String.Index>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        func fold(_ s: String) -> String { String(s.map { $0.isASCII && $0.isUppercase ? Character($0.lowercased()) : $0 }) }
        let folded = fold(text), fq = fold(q)
        var out: [Range<String.Index>] = []
        var from = folded.startIndex
        while let r = folded.range(of: fq, options: .literal, range: from..<folded.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    func attributed() -> NSAttributedString {
        let font = SB.font(12), bold = SB.font(12, .semibold)
        let base = NSColor(cgColor: SB.c(\.mutedForeground, 0.85).cgColor(in: self)) ?? .gray
        let fg = NSColor(cgColor: SB.c(\.foreground).cgColor(in: self)) ?? .black
        let tag = NSColor(cgColor: (isUser ? SB.c(\.infoForeground) : SB.c(\.successForeground)).cgColor(in: self)) ?? .gray
        let s = NSMutableAttributedString(string: isUser ? "You:" : "Agent:", attributes: [.font: font, .foregroundColor: tag])
        s.append(NSAttributedString(string: " ", attributes: [.font: font, .foregroundColor: base]))
        let body = NSMutableAttributedString(string: snippet, attributes: [.font: font, .foregroundColor: base])
        for r in Self.highlights(in: snippet, query: query) {
            body.addAttributes([.font: bold, .foregroundColor: fg], range: NSRange(r, in: snippet))
        }
        s.append(body)
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let text = attributed()
        let full = TextLine(text)
        var line = full.line
        if full.width > bounds.width, bounds.width > 0 {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: text.attributes(at: max(0, text.length - 1), effectiveRange: nil)))
            if let t = CTLineCreateTruncatedLine(full.line, Double(bounds.width), .end, ellipsis) { line = t }
        }
        let baseline = full.baseline(top: 0, lineHeight: 16)
        ctx.saveGState()
        ctx.setShouldSmoothFonts(true)
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
