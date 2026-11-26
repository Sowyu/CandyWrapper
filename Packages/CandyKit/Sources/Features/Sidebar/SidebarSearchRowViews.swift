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
        surface.cornerRadius = DesignGeometry.radius(8, in: self)
        layer?.addSublayer(surface)
        for v in [pen, monogram, project, preview, discardButton] as [NSView] { addSubview(v) }
        project.font = SB.font(12, .medium); project.lineHeight = 16
        preview.font = SB.font(14, .medium); preview.lineHeight = 20
        discardButton.padding = 4
        HoverReveal.snap([discardButton], visible: false, hides: true)
        discardButton.action = { [weak self] in if let d = self?.draft { self?.onDiscard?(d.id) } }
    }

    var draft: SidebarDraftRowModel? { if case .draft(let d)? = item { d } else { nil } }

    override func refresh() {
        guard let d = draft else { return }
        surface.cornerRadius = DesignGeometry.radius(8, in: self)
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
        // `opacity-0 transition-opacity group-hover/sidebar-row:opacity-100` (Sidebar.tsx:933), and shown
        // while the row has keyboard focus.
        HoverReveal.fade([discardButton], visible: state.hovered || isKeyboardFocused, hides: true)
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
///
/// Under Redesign the row is the inline state view instead: an icon for what the text says, then the text.
final class SidebarEmptyTextRowView: SidebarRowBase {
    private let label = LabelView()
    let emptyState = EmptyView(title: "", size: .inline)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = SB.font(12); label.lineHeight = 16
        label.alignment = .center
        addSubview(label)
        addSubview(emptyState)
        emptyState.isHidden = true
        setAccessibilityRole(.staticText)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func refresh() {
        guard case .emptyText(let text, let search)? = item else { return }
        label.text = text
        label.color = search ? SB.c(\.sidebarMutedForeground) : SB.c(\.mutedForeground, 0.6)
        setAccessibilityLabel(text)
        let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        label.isHidden = redesign
        emptyState.isHidden = !redesign
        if redesign { emptyState.redesign = Self.copy(text, search: search) }
    }

    /// Redesign's copy for the sidebar's status text (Sidebar.tsx:5202-5209, 5556).
    static func copy(_ text: String, search: Bool) -> StateCopy {
        switch text {
        case "Couldn't search thread messages":
            return StateCopy(title: "Could not search messages", detail: "Edit the search to try again.", icon: .circleAlert)
        case "No threads found": return StateCopy(title: "No threads found", detail: "Try other words.", icon: .search)
        case _ where text.hasPrefix("Searching"): return StateCopy(title: text, icon: .search)
        default: return StateCopy(title: text, icon: search ? .search : .messageSquare)
        }
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: 24, width: max(0, bounds.width - 16), height: 16)
        let h = emptyState.height(forWidth: bounds.width)
        emptyState.frame = NSRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
}

/// "No projects yet" and the Add project button under it (Sidebar.tsx:5554-5569): `text-xs
/// text-muted-foreground/60`, then `rounded-md border border-sidebar-border px-2.5 py-1 text-2xs font-medium
/// text-sidebar-muted-foreground`, hover `bg-sidebar-row-hover text-sidebar-foreground`, a `size-3` plus.
final class SidebarNoProjectsRowView: SidebarRowBase {
    private let label = LabelView("No projects yet")
    let button = SidebarNoProjectsButton()
    var onAddProject: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = SB.font(12); label.lineHeight = 16
        label.alignment = .center
        addSubview(label)
        addSubview(button)
        button.action = { [weak self] in self?.performAction() }
    }

    /// The filter's Show all projects, for a `.scopeEmpty` item.
    var onShowAllProjects: (@MainActor () -> Void)?

    override func refresh() {
        let scoped: String? = if case .scopeEmpty(let text)? = item { text } else { nil }
        label.text = scoped ?? "No projects yet"
        setAccessibilityLabel(label.text)
        button.showsAddProject = scoped == nil
        label.color = SB.c(\.mutedForeground, 0.6)
        button.isKeyboardFocused = isKeyboardFocused
        needsLayout = true
    }

    override func performAction() {
        if case .scopeEmpty? = item { onShowAllProjects?() } else { onAddProject?() }
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: 24, width: max(0, bounds.width - 16), height: 16)
        let w = button.preferredWidth
        button.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: 48, width: w, height: 26)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
}

final class SidebarNoProjectsButton: ControlView {
    private let icon = IconView(name: .plus, size: 12)
    private let title = LabelView("Add project")
    var isKeyboardFocused = false { didSet { needsDisplay = true } }
    /// "Add project" with its plus, or the filter's "Show all projects" without an icon.
    var showsAddProject = true {
        didSet {
            guard showsAddProject != oldValue else { return }
            title.text = showsAddProject ? "Add project" : "Show all projects"
            icon.isHidden = !showsAddProject
            setAccessibilityLabel(title.text)
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        transitions = .colors // transition-colors (Sidebar.tsx:5563)
        title.font = SB.font(11, .medium); title.lineHeight = 16
        addSubview(icon)
        addSubview(title)
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        setAccessibilityLabel("Add project")
    }

    /// `px-2.5`, the icon (`-mx-0.5`), `gap-1.5`, the label.
    var preferredWidth: CGFloat { 2 * (10 + 1) + (showsAddProject ? 12 - 4 + 6 : 0) + ceil(title.textWidth) }

    override var acceptsFirstResponder: Bool { false }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 11 - 2, y: (bounds.height - 12) / 2, width: 12, height: 12)
        title.frame = NSRect(x: showsAddProject ? 11 + 12 - 4 + 6 : 11, y: (bounds.height - 16) / 2, width: ceil(title.textWidth) + 1, height: 16)
    }

    override func updateLayer() {
        let hot = state.hovered || isKeyboardFocused
        Motion.setBackground(layer, hot ? SB.c(\.sidebarRowHover).cgColor(in: self) : nil)
        layer?.borderColor = SB.c(\.sidebarBorder).cgColor(in: self)
        let color = hot ? SB.c(\.sidebarForeground) : SB.c(\.sidebarMutedForeground)
        title.color = color
        icon.strokeColor = color
    }
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
    var onMenu: (@MainActor (ThreadId, NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        surface.cornerRadius = DesignGeometry.radius(8, in: self)
        layer?.addSublayer(surface)
        for v in [monogram, title, time, excerpt] as [NSView] { addSubview(v) }
        title.font = SB.font(14); title.lineHeight = 20
        time.font = SB.tabular(12); time.lineHeight = 16; time.alignment = .right
        setAccessibilityRole(.button)
    }

    var result: SidebarSearchResultModel? { if case .searchResult(let r)? = item { r } else { nil } }

    override func refresh() {
        guard let r = result else { return }
        surface.cornerRadius = DesignGeometry.radius(8, in: self)
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
        // `min-w-8 text-right` (SidebarThreadRow.tsx at 5258, #42011): at least 32 pt, wider for a longer translated time.
        let tw = max(32, ceil(time.textWidth))
        time.frame = NSRect(x: right - tw - 1, y: top + 2, width: tw + 1, height: 16)
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

    /// SidebarThreadRow.tsx:1889-1896 at 5258 (#31545): a right click opens the result's thread actions.
    override func rightMouseDown(with event: NSEvent) {
        guard let r = result, let onMenu else { return super.rightMouseDown(with: event) }
        onMenu(r.id, event)
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
        ctx.setShouldSmoothFonts(FontRuntime.smoothing)
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
