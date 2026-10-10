import AppKit

/// One result row (CommandPaletteResults.tsx `CommandPaletteResultRow`).
public struct CommandPaletteItem: Sendable {
    public var title: String
    /// Bold text after the title (`New thread in <span class="font-semibold">demo-repo</span>`).
    public var titleEmphasis: String?
    public var icon: IconName?
    public var description: String?
    /// A thread search match line above the description (`ThreadSearchMatchExcerpt`).
    public var match: String?
    public var shortcut: String?
    public var timestamp: String?
    /// `titleTrailingContent` text such as "Current" (`text-xs text-muted-foreground/70`).
    public var note: String?
    public var isSubmenu = false
    public var isDisabled = false

    public init(_ title: String, icon: IconName? = nil, description: String? = nil, shortcut: String? = nil,
                timestamp: String? = nil, isSubmenu: Bool = false, isDisabled: Bool = false,
                titleEmphasis: String? = nil, match: String? = nil, note: String? = nil) {
        self.title = title; self.icon = icon; self.description = description; self.shortcut = shortcut
        self.timestamp = timestamp; self.isSubmenu = isSubmenu; self.isDisabled = isDisabled
        self.titleEmphasis = titleEmphasis; self.match = match; self.note = note
    }
}

public struct CommandPaletteGroup: Sendable {
    public var label: String?
    public var items: [CommandPaletteItem]
    public init(_ label: String?, _ items: [CommandPaletteItem]) { self.label = label; self.items = items }
}

/// T3's command palette surface: `CommandDialogPopup` > `CommandPaletteContent` (input, panel, footer).
/// Spec: docs/research/recovered/ui-components-a.md 12, copy from CommandPalette*.tsx.
public final class CommandPaletteView: DSView {
    public enum Content {
        case results([CommandPaletteGroup])
        /// `CommandPaletteEmptyState`. Nil message picks T3's default for the mode.
        case empty(message: String?, actionsOnly: Bool)
        /// The browse-mode status row, "Loading folders...".
        case loading(String)
    }

    /// `getCommandPaletteInputPlaceholder("root")`.
    public static let rootPlaceholder = "Search commands, projects, and threads..."

    public var content: Content { didSet { rebuild() } }
    /// Flat index over enabled and disabled rows. The app passes `active`, so the row gets `bg-accent`.
    public var highlightedIndex: Int? {
        didSet { rows.enumerated().forEach { $1.isHighlighted = $0 == highlightedIndex } }
    }
    public var footerActionLabel: String? { didSet { rebuildFooter() } }
    public var showsBackHint = false { didSet { rebuildFooter() } }
    public var escapeLabel = "Close" { didSet { rebuildFooter() } }
    /// A submenu's start addon: the back arrow in place of the search icon (CommandPalette.tsx:3488-3500).
    public var showsBackButton = false {
        didSet { searchIcon.isHidden = showsBackButton; backIcon.isHidden = !showsBackButton }
    }
    public final var onExecute: (@MainActor (Int) -> Void)?
    public final var onHighlight: (@MainActor (Int) -> Void)?
    public final var onBack: (@MainActor () -> Void)?

    public let input = InputView(placeholder: CommandPaletteView.rootPlaceholder, size: .lg)
    private let decoration = BoxDecorationLayer()
    private let footerLayer = BoxDecorationLayer()
    private let searchIcon = IconView(name: .search)
    private let backIcon = IconView(name: .arrowLeft)
    private let document = DSView()
    private lazy var scroll = ScrollAreaView(documentView: document, scrollFade: true)
    private var panelViews: [NSView] = []
    private var rows: [CommandRowView] = []
    private var footerGroups: [NSView] = []
    private var pendingHighlightScroll = false

    public static let width: CGFloat = 576
    public static let maxHeight: CGFloat = 420

    public init(content: Content = .results([])) {
        self.content = content
        super.init(frame: .zero)
        decoration.host = self
        decoration.outset = 80
        footerLayer.host = self
        layer?.addSublayer(decoration)
        layer?.addSublayer(footerLayer)
        layer?.masksToBounds = false
        input.unstyled = true
        input.paddingOverride = (32, 11) // `ps-[calc(var(--command-shell-inset)+1.5rem)]`, size lg `pe-[calc(--spacing(3)-1px)]`
        addSubview(input)
        searchIcon.alphaValue = 0.8 // addon `opacity-80`
        addSubview(searchIcon)
        backIcon.isHidden = true
        backIcon.alphaValue = 0.8 // the addon's `opacity-80`; the button's arrow takes the foreground color
        addSubview(backIcon)
        scroll.layer?.masksToBounds = true
        addSubview(scroll)
        rebuild()
        rebuildFooter()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command palette")
    }

    // MARK: Building

    private func rebuild() {
        panelViews.forEach { $0.removeFromSuperview() }
        panelViews = []
        rows = []
        switch content {
        case .results(let groups):
            var index = 0
            for group in groups {
                var views: [NSView] = []
                if let label = group.label {
                    let l = LabelView(label, font: DSFont.ui(12, weight: .medium))
                    l.lineHeight = 16
                    views.append(l)
                }
                for item in group.items {
                    let row = CommandRowView(item)
                    let i = index
                    row.onHover = { [weak self] in
                        guard !item.isDisabled, let self, self.highlightedIndex != i else { return }
                        self.highlightedIndex = i
                        self.onHighlight?(i)
                    }
                    row.onClick = { [weak self] in if !item.isDisabled { self?.onExecute?(i) } }
                    rows.append(row)
                    views.append(row)
                    index += 1
                }
                panelViews.append(GroupView(views))
            }
        case .empty(let message, let actionsOnly):
            let l = LabelView(message ?? (actionsOnly ? "No matching actions." : "No matching commands, projects, or threads."),
                              font: DSFont.ui(14))
            l.lineHeight = 20
            l.alignment = .center
            panelViews.append(l)
        case .loading(let message):
            let l = LabelView(message, font: DSFont.ui(14))
            l.lineHeight = 20
            panelViews.append(l)
        }
        panelViews.forEach(document.addSubview)
        restyle()
        highlightedIndex = highlightedIndex.flatMap { rows.isEmpty ? nil : min($0, rows.count - 1) }
        invalidateIntrinsicContentSize()
        needsLayout = true
        scroll.scroll(to: .zero)
    }

    private func rebuildFooter() {
        footerGroups.forEach { $0.removeFromSuperview() }
        func hint(_ keys: [KbdView], _ text: String) -> NSView {
            for k in keys {
                k.fillOverride = Themed.color(\.contrastForeground, 0.08)
                k.textOverride = Themed.color(\.contrastForeground)
            }
            let l = LabelView(text, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.contrastMutedForeground))
            l.lineHeight = 20
            return HintView(KbdGroupView(keys), l)
        }
        var groups = [hint([KbdView(icon: .arrowUp), KbdView(icon: .arrowDown)], "Navigate")]
        if let footerActionLabel { groups.append(hint([KbdView("Enter")], footerActionLabel)) }
        if showsBackHint { groups.append(hint([KbdView("Backspace")], "Back")) }
        groups.append(hint([KbdView("Esc")], escapeLabel))
        footerGroups = groups
        groups.forEach(addSubview)
        needsLayout = true
    }

    public var enabledIndices: [Int] { rows.indices.filter { !rows[$0].item.isDisabled } }

    public func moveHighlight(by delta: Int) {
        let enabled = enabledIndices
        guard !enabled.isEmpty else { return }
        let current = highlightedIndex.flatMap { enabled.firstIndex(of: $0) } ?? (delta > 0 ? -1 : enabled.count)
        highlightedIndex = enabled[(current + delta + enabled.count) % enabled.count]
        scrollHighlightIntoView()
    }

    /// `scrollIntoView({ block: "nearest" })` with the list's `scroll-py-6`.
    public func scrollHighlightIntoView() {
        guard let i = highlightedIndex, i < rows.count else { return }
        // Before the first layout there is no visible height to scroll against; layout comes back here.
        guard scroll.frame.height > 0 else { pendingHighlightScroll = true; return }
        layoutSubtreeIfNeeded()
        let row = rows[i]
        let frame = document.convert(row.bounds, from: row).insetBy(dx: 0, dy: -24)
        let visible = scroll.scrollView.contentView.bounds
        var y = visible.minY
        if frame.minY < visible.minY { y = frame.minY } else if frame.maxY > visible.maxY { y = frame.maxY - visible.height }
        y = max(0, min(y, document.frame.height - visible.height))
        if y != visible.minY { scroll.scroll(to: NSPoint(x: 0, y: y)) }
    }

    // MARK: Layout

    private static let inputRow: CGFloat = 6 + 36 + 6
    private static let footerHeight: CGFloat = 40

    private var panelContentHeight: CGFloat {
        switch content {
        case .results(let groups):
            if groups.isEmpty { return 100 }
            // `py-2` plus groups; a label after a group gets `pt-1.5`.
            return 16 + panelViews.map { ($0 as! GroupView).contentHeight }.reduce(0, +) + CGFloat(max(0, groups.count - 1)) * 6
        case .empty: return 100   // `py-10` around a 20px line
        case .loading: return 44  // `py-3`
        }
    }

    /// `max-h-105` on the popup and `max-h-[min(28rem,70vh)]` on the panel; the panel scrolls past it.
    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: min(Self.maxHeight, 2 + Self.inputRow + min(448, panelContentHeight) + Self.footerHeight))
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let inner = bounds.insetBy(dx: 1, dy: 1)
        // Input wrapper: 8px inline, 6px block; the input keeps its invisible 1px border.
        input.frame = NSRect(x: inner.minX + 8 + 1, y: inner.minY + 6 + 1, width: inner.width - 16 - 2, height: 34)
        searchIcon.frame = NSRect(x: inner.minX + 8 + 1 + 9, y: inner.minY + 6 + 10, width: 16, height: 16)
        backIcon.frame = searchIcon.frame
        let panelTop = inner.minY + Self.inputRow
        let footerTop = inner.maxY - Self.footerHeight
        scroll.frame = NSRect(x: inner.minX, y: panelTop, width: inner.width, height: max(0, footerTop - panelTop))
        let width = scroll.frame.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.frame.height, panelContentHeight))
        switch content {
        case .results:
            var y: CGFloat = 8
            for (i, view) in panelViews.enumerated() {
                let group = view as! GroupView
                if i > 0 { y += 6 }
                group.frame = NSRect(x: 8, y: y, width: width - 16, height: group.contentHeight)
                y += group.contentHeight
            }
        case .empty:
            panelViews.first?.frame = NSRect(x: 0, y: 40, width: width, height: 20)
        case .loading:
            panelViews.first?.frame = NSRect(x: 16, y: 12, width: width - 32, height: 20)
        }
        if pendingHighlightScroll, scroll.frame.height > 0 {
            pendingHighlightScroll = false
            DispatchQueue.main.async { [weak self] in self?.scrollHighlightIntoView() }
        }
        // Footer: `px-4 py-2.5`, groups `gap-3`, each a KbdGroup `gap-1` of keys and text.
        footerLayer.layout(boxSize: bounds.size)
        var x = inner.minX + 16
        for group in footerGroups {
            let w = group.intrinsicContentSize.width
            group.frame = NSRect(x: x, y: footerTop + 10, width: w, height: 20)
            x += w + 12
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if showsBackButton, searchIcon.frame.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) {
            onBack?()
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Style

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        // `dialog-glass`, radius 18px (same box as DialogView).
        // ponytail: solid --background instead of 80% plus backdrop blur; identical over T3's dialog backdrop tint
        var box = BoxStyle()
        box.radius = 18
        box.fill = Themed.color(\.background)
        box.border = Themed.pick(light: Themed.color(\.contrastForeground, 0.1), dark: Themed.white(0.08))
        box.shadows = [
            BoxShadow(y: 1, color: Themed.pick(light: .clear, dark: Themed.white(0.04)), inset: true),
            BoxShadow(y: 24, blur: 64, spread: -24, color: Themed.pick(light: Themed.black(0.65), dark: .clear)),
            BoxShadow(y: 24, blur: 72, spread: -20, color: Themed.pick(light: .clear, dark: Themed.black(0.9))),
        ]
        decoration.boxStyle = box
        // Footer fill `bg-foreground/[0.025]`, bottom corners 17px, inside the 1px border.
        var footer = BoxStyle()
        footer.fill = Themed.color(\.contrastForeground, 0.025)
        footer.radius = 17
        footer.corners = .bottom
        footerLayer.boxStyle = footer
        footerLayer.frame = .zero
        searchIcon.strokeColor = Themed.color(\.contrastIconMuted)
        backIcon.strokeColor = Themed.color(\.contrastForeground)
        for view in panelViews {
            (view as? LabelView)?.color = Themed.color(\.contrastMutedForeground)
            (view as? GroupView)?.restyle()
        }
        needsLayout = true
    }

    public override func updateLayer() {
        // The footer layer covers only the footer strip.
        let inner = bounds.insetBy(dx: 1, dy: 1)
        footerLayer.layout(boxSize: CGSize(width: inner.width, height: Self.footerHeight))
        footerLayer.frame.origin = CGPoint(x: inner.minX - footerLayer.outset, y: inner.maxY - Self.footerHeight - footerLayer.outset)
    }

    /// A group label (`px-2 py-1.5 text-xs font-medium text-muted-foreground`) and its rows.
    final class GroupView: DSView {
        let views: [NSView]
        init(_ views: [NSView]) {
            self.views = views
            super.init(frame: .zero)
            views.forEach(addSubview)
        }
        var contentHeight: CGFloat { views.reduce(0) { $0 + ($1 is LabelView ? 28 : ($1 as! CommandRowView).height) } }
        func restyle() { views.compactMap { $0 as? LabelView }.forEach { $0.color = Themed.color(\.contrastMutedForeground) } }
        override func layout() {
            super.layout()
            var y: CGFloat = 0
            for v in views {
                if v is LabelView {
                    v.frame = NSRect(x: 8, y: y + 6, width: bounds.width - 16, height: 16)
                    y += 28
                } else {
                    let h = (v as! CommandRowView).height
                    v.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
                    y += h
                }
            }
        }
    }

    /// KbdGroup with trailing text, `gap-1`.
    final class HintView: DSView {
        let keys: KbdGroupView, label: LabelView
        init(_ keys: KbdGroupView, _ label: LabelView) {
            self.keys = keys; self.label = label
            super.init(frame: .zero)
            addSubview(keys); addSubview(label)
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: keys.intrinsicContentSize.width + 4 + label.textWidth, height: 20)
        }
        override func layout() {
            super.layout()
            let kw = keys.intrinsicContentSize.width
            keys.frame = NSRect(x: 0, y: 0, width: kw, height: 20)
            label.frame = NSRect(x: kw + 4, y: 0, width: label.textWidth + 1, height: 20)
        }
    }
}

/// `CommandItem` with `active`: `rounded-sm px-2 py-1.5 gap-2`, 14px foreground title, 16px muted icon,
/// `bg-accent text-accent-foreground` while active. Disabled rows are `opacity-64`.
final class CommandRowView: DSView {
    let item: CommandPaletteItem
    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true; restyle() } } }
    final var onHover: (@MainActor () -> Void)?
    final var onClick: (@MainActor () -> Void)?
    private let title = LabelView()
    private let matchLine = LabelView()
    private let detail = LabelView()
    private let trailing = LabelView()
    private let noteLabel = LabelView()
    private let shortcut = TrackedLabelView("", font: DSFont.ui(12, weight: .medium), tracking: 1.2, color: .clear, lineHeight: 16)
    private var iconView: IconView?
    private var chevron: IconView?
    private var trackingArea: NSTrackingArea?

    init(_ item: CommandPaletteItem) {
        self.item = item
        super.init(frame: .zero)
        title.text = item.title
        title.emphasizedSuffix = item.titleEmphasis
        title.font = DSFont.ui(14); title.lineHeight = 20
        addSubview(title)
        if let m = item.match {
            matchLine.text = m; matchLine.font = DSFont.ui(12); matchLine.lineHeight = 16
            addSubview(matchLine)
        }
        if let d = item.description {
            detail.text = d; detail.font = DSFont.ui(12); detail.lineHeight = 16
            addSubview(detail)
        }
        if let s = item.shortcut {
            shortcut.text = s
            addSubview(shortcut)
        }
        if let t = item.timestamp {
            trailing.text = t
            trailing.font = DSFont.ui(12) // `tabular-nums`
            trailing.lineHeight = 16
            trailing.truncates = false
            trailing.alignment = .right
            addSubview(trailing)
        }
        if let n = item.note {
            noteLabel.text = n; noteLabel.font = DSFont.ui(12); noteLabel.lineHeight = 16; noteLabel.truncates = false
            addSubview(noteLabel)
        }
        if let icon = item.icon { iconView = IconView(name: icon); addSubview(iconView!) }
        if item.isSubmenu { chevron = IconView(name: .chevronRight); addSubview(chevron!) }
        alphaValue = item.isDisabled ? 0.64 : 1
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title + (item.titleEmphasis ?? ""))
        restyle()
    }

    /// One line: 6 + 20 + 6. Each description or match line adds 16.
    var height: CGFloat { 32 + (item.description == nil ? 0 : 16) + (item.match == nil ? 0 : 16) }

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        if let iconView {
            iconView.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
            x += 16 + 8
        }
        var right = bounds.width - 8
        if let chevron {
            chevron.frame = NSRect(x: right - 16 + 2, y: (bounds.height - 16) / 2, width: 16, height: 16) // `-me-0.5`
            right -= 14 + 8
        }
        if item.shortcut != nil {
            // `ms-auto`; `tracking-widest` (.1em) follows every glyph, the last one included.
            let w = shortcut.intrinsicContentSize.width
            shortcut.frame = NSRect(x: right - w, y: (bounds.height - 16) / 2, width: w, height: 16)
            right -= w + 8
        }
        if item.timestamp != nil {
            let w = max(48, ceil(trailing.textWidth)) // `min-w-12 text-right`
            trailing.frame = NSRect(x: right - w, y: (bounds.height - 16) / 2, width: w, height: 16)
            right -= w + 8
        }
        if item.note != nil {
            let w = ceil(noteLabel.textWidth)
            noteLabel.frame = NSRect(x: right - w, y: (bounds.height - 16) / 2, width: w, height: 16)
            right -= w + 8
        }
        title.frame = NSRect(x: x, y: 6, width: max(0, right - x), height: 20)
        var y: CGFloat = 26
        if item.match != nil { matchLine.frame = NSRect(x: x, y: y, width: max(0, right - x), height: 16); y += 16 }
        detail.frame = NSRect(x: x, y: y, width: max(0, right - x), height: 16)
    }

    private func restyle() {
        let fg = isHighlighted ? Themed.color(\.contrastAccentForeground) : Themed.color(\.contrastForeground)
        title.color = fg
        matchLine.color = Themed.color(\.contrastMutedForeground)
        detail.color = Themed.color(\.contrastMutedForeground, 0.7)
        shortcut.color = Themed.color(\.contrastSecondaryLabel)
        trailing.color = Themed.color(\.contrastMutedForeground, 0.7)
        noteLabel.color = Themed.color(\.contrastMutedForeground, 0.7)
        iconView?.strokeColor = Themed.color(\.contrastIconMuted) // ITEM_ICON_CLASS `size-4 text-icon-muted`
        chevron?.strokeColor = Themed.color(\.contrastMutedForeground, 0.7)
    }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = isHighlighted ? Themed.color(\.accent).cgColor(in: self) : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {} // `onMouseDown preventDefault`: focus stays in the input
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
