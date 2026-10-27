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
    /// The match's author: true for "You:", false for "Agent:"; nil draws the line plain.
    public var matchIsUser: Bool?
    /// UTF-16 offsets in `match` of the query's hits, drawn semibold in the foreground.
    public var matchHighlights: [Int]?
    /// A match hint's "Label:" length (`SearchMatchHintLine`): the line at muted/85 with the label at muted/70.
    public var matchHintLabelLength: Int?
    public var shortcut: String?
    public var timestamp: String?
    /// `titleTrailingContent` text such as "Current" (`text-xs text-muted-foreground/70`).
    public var note: String?
    public var isSubmenu = false
    public var isDisabled = false
    /// A colored glyph in place of `icon` (a file type icon in the file picker).
    public var glyph: (IconDefinition, NSColor)?
    /// A 16px view in place of `icon`, made when the row is built (a project's favicon, `ProjectFavicon size-4`).
    public var makeIcon: (@MainActor @Sendable () -> NSView)?
    /// Fuzzy match positions (UTF-16): set, the text is muted with these characters semibold.
    public var titleHighlights: [Int]?
    public var descriptionHighlights: [Int]?
    /// A context row (`flex min-h-8 items-center gap-2 rounded-sm px-2 py-1.5`): no hover, no click, full opacity.
    public var isStatic = false
    /// `titleTrailingContent`: a muted 16px glyph at the end (`CheckIcon ms-auto size-4 text-muted-foreground/70`).
    public var trailingIcon: IconName?
    /// `titleTrailingContent`: a checkbox at the end (`<Checkbox checked>`).
    public var trailingCheckbox: Bool?
    /// The note drawn as the warning-outline micro button ("Setup Required").
    public var noteIsWarning = false
    /// `titleTrailingContent` as a view, sized by its `intrinsicContentSize` (a thread's pull request badge).
    public var makeTrailing: (@MainActor @Sendable () -> NSView)?

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
        /// A mode that lays out its own body (`panelSize="fill"`): the dialog is 420 tall (`h-105`).
        case custom(NSView)
    }

    /// Controls inside the input's end (`inputAccessory`, `absolute inset-e-2.5 top-1/2`); the
    /// input keeps `pe-30` clear for them.
    public var inputAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            inputAccessory.map(addSubview)
            input.paddingOverride = (32, inputAccessory == nil ? 11 : 120)
            needsLayout = true
        }
    }

    /// `getCommandPaletteInputPlaceholder("root")`.
    public static let rootPlaceholder = "Search commands, projects, and threads..."

    public var content: Content { didSet { rebuild() } }
    /// Flat index over enabled and disabled rows. The app passes `active`, so the row gets `bg-accent`.
    public var highlightedIndex: Int? {
        didSet { rows.forEach { $1.isHighlighted = $0 == highlightedIndex } }
    }
    public var footerActionLabel: String? { didSet { if footerActionLabel != oldValue { rebuildFooter() } } }
    /// `footerTrailing`: a footer action at the end ("Open in Finder", `CommandFooterAction`).
    public var footerTrailing: NSView? {
        didSet { oldValue?.removeFromSuperview(); footerTrailing.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true }
    }
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
    private var searchIcon = IconView(name: .search)
    /// The input's start addon at the root: the search glass, or Add project's folder while a path is typed
    /// (`isBrowsing ? { startAddon: <FolderPlusIcon /> }`, CommandPalette.tsx:3494-3500).
    public var startIcon: IconName = .search {
        didSet {
            guard startIcon != oldValue else { return }
            let next = IconView(name: startIcon)
            next.alphaValue = searchIcon.alphaValue
            next.isHidden = searchIcon.isHidden
            next.frame = searchIcon.frame
            next.strokeColor = Themed.color(\.contrastIconMuted)
            addSubview(next, positioned: .above, relativeTo: searchIcon)
            searchIcon.removeFromSuperview()
            searchIcon = next
        }
    }
    private let backIcon = IconView(name: .arrowLeft)
    private let document = DSView()
    // A virtualized list, so a plain overflow scroller (CommandPaletteResults.tsx:147-152).
    private lazy var scroll = ScrollAreaView(documentView: document, scrollFade: true, scrollbars: .native)
    private var panelViews: [NSView] = []
    /// Every result row, flat, with its top and height in the document (`x` and width come from layout).
    private var items: [CommandPaletteItem] = []
    private var rowSlots: [(y: CGFloat, height: CGFloat)] = []
    /// The group labels' tops in the document.
    private var labelTops: [CGFloat] = []
    private var resultsHeight: CGFloat = 0
    /// Row views exist only near the visible part of the list, as in T3's LegendList (CommandPaletteResults.tsx:121).
    /// A view per result cost 120 to 160 ms a keystroke with 1,500 threads (docs/research/m10-load-2026-10-12.md).
    private var rows: [Int: CommandRowView] = [:]
    private static let overscan: CGFloat = 240
    private var footerGroups: [NSView] = []
    private var pendingHighlightScroll = false
    private var customView: NSView?

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
        (scroll.scrollView.verticalScroller as? ScrollAreaScroller)?.trackInset = 8 // `[&::-webkit-scrollbar-track]:my-2`
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.scrollView.contentView)
        rebuild()
        rebuildFooter()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command palette")
    }

    // MARK: Building

    private func rebuild() {
        panelViews.forEach { $0.removeFromSuperview() }
        panelViews = []
        rows.values.forEach { $0.removeFromSuperview() }
        rows = [:]
        items = []
        rowSlots = []
        labelTops = []
        resultsHeight = 0
        switch content {
        case .results(let groups):
            // `py-2` around the groups; a `px-2 py-1.5` 12px label is 28 tall; a label after a group gets `pt-1.5`.
            var y: CGFloat = 8
            for (g, group) in groups.enumerated() {
                if g > 0 { y += 6 }
                if let label = group.label {
                    let l = LabelView(label, font: DSFont.ui(12, weight: .medium))
                    l.lineHeight = 16
                    panelViews.append(l)
                    labelTops.append(y + 6)
                    y += 28
                }
                for item in group.items {
                    let h = CommandRowView.height(for: item)
                    items.append(item)
                    rowSlots.append((y, h))
                    y += h
                }
            }
            resultsHeight = groups.isEmpty ? 100 : y + 8
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
        case .custom:
            break
        }
        panelViews.forEach(document.addSubview)
        if case .custom(let view) = content {
            if customView !== view { customView?.removeFromSuperview(); customView = view; addSubview(view) }
        } else {
            customView?.removeFromSuperview()
            customView = nil
        }
        scroll.isHidden = customView != nil
        restyle()
        highlightedIndex = highlightedIndex.flatMap { items.isEmpty ? nil : min($0, items.count - 1) }
        invalidateIntrinsicContentSize()
        needsLayout = true
        scroll.scroll(to: .zero)
    }

    private func rebuildFooter() {
        footerGroups.forEach { $0.removeFromSuperview() }
        invalidateIntrinsicContentSize()
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

    public var enabledIndices: [Int] { items.indices.filter { !items[$0].isDisabled && !items[$0].isStatic } }

    public func moveHighlight(by delta: Int) {
        let enabled = enabledIndices
        guard !enabled.isEmpty else { return }
        let current = highlightedIndex.flatMap { enabled.firstIndex(of: $0) } ?? (delta > 0 ? -1 : enabled.count)
        highlightedIndex = enabled[(current + delta + enabled.count) % enabled.count]
        scrollHighlightIntoView()
    }

    /// `scrollIntoView({ block: "nearest" })` with the list's `scroll-py-6`.
    public func scrollHighlightIntoView() {
        guard let i = highlightedIndex, i < items.count else { return }
        // Before the first layout there is no visible height to scroll against; layout comes back here.
        guard scroll.frame.height > 0 else { pendingHighlightScroll = true; return }
        layoutSubtreeIfNeeded()
        let frame = NSRect(x: 0, y: rowSlots[i].y, width: 1, height: rowSlots[i].height).insetBy(dx: 0, dy: -24)
        let visible = scroll.scrollView.contentView.bounds
        var y = visible.minY
        if frame.minY < visible.minY { y = frame.minY } else if frame.maxY > visible.maxY { y = frame.maxY - visible.height }
        y = max(0, min(y, document.frame.height - visible.height))
        if y != visible.minY { scroll.scroll(to: NSPoint(x: 0, y: y)) }
    }

    // MARK: Layout

    private static let inputRow: CGFloat = 6 + 36 + 6
    /// `py-2.5` around the hints (20) or a taller footer action (`Open in Finder` keeps the xs button's 24).
    private var footerHeight: CGFloat { 20 + max(20, footerTrailing?.intrinsicContentSize.height ?? 0) }

    private var panelContentHeight: CGFloat {
        switch content {
        case .results: return resultsHeight
        case .empty: return 100   // `py-10` around a 20px line
        case .loading: return 44  // `py-3`
        case .custom: return Self.maxHeight
        }
    }

    /// `max-h-105` on the popup and `max-h-[min(28rem,70vh)]` on the panel; the panel scrolls past it.
    public override var intrinsicContentSize: NSSize {
        if case .custom = content { return NSSize(width: Self.width, height: Self.maxHeight) }
        return NSSize(width: Self.width, height: min(Self.maxHeight, 2 + Self.inputRow + min(448, panelContentHeight) + footerHeight))
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
        let footerTop = inner.maxY - footerHeight
        scroll.frame = NSRect(x: inner.minX, y: panelTop, width: inner.width, height: max(0, footerTop - panelTop))
        let width = scroll.frame.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.frame.height, panelContentHeight))
        switch content {
        case .results:
            for (label, top) in zip(panelViews, labelTops) { label.frame = NSRect(x: 16, y: top, width: width - 32, height: 16) }
            realizeRows()
        case .empty:
            panelViews.first?.frame = NSRect(x: 0, y: 40, width: width, height: 20)
        case .loading:
            panelViews.first?.frame = NSRect(x: 16, y: 12, width: width - 32, height: 20)
        case .custom(let view):
            view.frame = scroll.frame
        }
        if let inputAccessory {
            let s = inputAccessory.intrinsicContentSize
            inputAccessory.frame = NSRect(x: inner.maxX - 10 - s.width, y: inner.minY + (Self.inputRow - s.height) / 2,
                                          width: s.width, height: s.height)
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
            group.frame = NSRect(x: x, y: footerTop + (footerHeight - 20) / 2, width: w, height: 20)
            x += w + 12
        }
        if let footerTrailing {
            // `ms-auto` at the footer's end.
            let s = footerTrailing.intrinsicContentSize
            footerTrailing.frame = NSRect(x: inner.maxX - 16 - s.width, y: footerTop + (footerHeight - s.height) / 2, width: s.width, height: s.height)
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


    /// Classic Glass's blur under the frosted pane (`WindowGlass.syncPaneBlur`).
    private var paneBlur: BackdropBlurView?
    private func syncPaneBlur() { paneBlur = WindowGlass.syncPaneBlur(paneBlur, in: self, radius: 18) }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncPaneBlur()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncPaneBlur()
        restyle()
    }

    private func restyle() {
        // `dialog-glass`, radius 18px (same box as DialogView).
        // ponytail: solid --background instead of 80% plus backdrop blur; identical over T3's dialog backdrop tint
        var box = BoxStyle()
        box.radius = 18
        box.fill = WindowGlass.floating(stock: Themed.color(\.background))
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
        for view in panelViews { (view as? LabelView)?.color = Themed.color(\.contrastMutedForeground) }
        needsLayout = true
    }

    public override func updateLayer() {
        // The footer layer covers only the footer strip.
        let inner = bounds.insetBy(dx: 1, dy: 1)
        footerLayer.layout(boxSize: CGSize(width: inner.width, height: footerHeight))
        footerLayer.frame.origin = CGPoint(x: inner.minX - footerLayer.outset, y: inner.maxY - footerHeight - footerLayer.outset)
    }

    /// Creates the row views near the visible part of the list and drops the rest.
    private func realizeRows() {
        guard case .results = content else { return }
        let width = document.frame.width
        // The clip view takes its new size only when the scroll view lays out, after this layout pass, so the
        // height comes from the list frame set here: a stale clip height left the last visible rows blank.
        let clip = scroll.scrollView.contentView.bounds
        let visible = NSRect(x: 0, y: clip.minY, width: width, height: max(clip.height, scroll.frame.height))
            .insetBy(dx: 0, dy: -Self.overscan)
        // ponytail: linear scan of the slots, microseconds per 1,000 results; binary search if lists reach 100,000
        var keep = Set<Int>()
        for (i, slot) in rowSlots.enumerated() where slot.y < visible.maxY && slot.y + slot.height > visible.minY {
            keep.insert(i)
            let frame = NSRect(x: 8, y: slot.y, width: width - 16, height: slot.height)
            if let row = rows[i] { if row.frame != frame { row.frame = frame }; continue }
            let item = items[i]
            let row = CommandRowView(item)
            row.onHover = { [weak self] in
                guard !item.isDisabled, !item.isStatic, let self, self.highlightedIndex != i else { return }
                self.highlightedIndex = i
                self.onHighlight?(i)
            }
            row.onClick = { [weak self] in if !item.isDisabled, !item.isStatic { self?.onExecute?(i) } }
            row.isHighlighted = i == highlightedIndex
            row.frame = frame
            document.addSubview(row)
            rows[i] = row
        }
        for (i, row) in rows where !keep.contains(i) {
            row.removeFromSuperview()
            rows[i] = nil
        }
    }

    @objc private func listScrolled() { realizeRows() }

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
    private var customIcon: NSView?
    private var trailingView: NSView?
    private var chevron: IconView?
    private var trailingGlyph: IconView?
    private var checkbox: CheckboxView?
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
            matchLine.highlightedIndices = item.matchHighlights
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
        if let make = item.makeTrailing {
            trailingView = make()
            addSubview(trailingView!)
        }
        if let make = item.makeIcon {
            customIcon = make()
            addSubview(customIcon!)
        } else if let (definition, color) = item.glyph {
            iconView = IconView(definition: definition, size: 16, color: color)
            addSubview(iconView!)
        } else if let icon = item.icon { iconView = IconView(name: icon); addSubview(iconView!) }
        title.highlightedIndices = item.titleHighlights
        detail.highlightedIndices = item.descriptionHighlights
        if item.isSubmenu { chevron = IconView(name: .chevronRight); addSubview(chevron!) }
        if let name = item.trailingIcon { trailingGlyph = IconView(name: name); addSubview(trailingGlyph!) }
        if let checked = item.trailingCheckbox {
            let box = CheckboxView(value: checked ? .on : .off)
            box.isHidden = false
            checkbox = box
            addSubview(box)
        }
        if item.noteIsWarning {
            noteLabel.wantsLayer = true
            noteLabel.layer?.cornerRadius = 6
            noteLabel.layer?.borderWidth = 1
            noteLabel.alignment = .center
            noteLabel.font = DSFont.ui(11, weight: .medium)
        }
        alphaValue = item.isDisabled && !item.isStatic ? 0.64 : 1
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title + (item.titleEmphasis ?? ""))
        restyle()
    }

    /// One line: 6 + 20 + 6. Each description or match line adds 16.
    var height: CGFloat { Self.height(for: item) }
    static func height(for item: CommandPaletteItem) -> CGFloat { 32 + (item.description == nil ? 0 : 16) + (item.match == nil ? 0 : 16) }

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        if let icon = customIcon ?? iconView {
            // `CommandPaletteTitleIcon` (CommandPaletteResults.tsx:153-155): `h-5 self-start pt-0.5`, so the
            // icon sits with the title line, 3pt into it, however many lines follow.
            icon.frame = NSRect(x: x, y: 6 + 3, width: 16, height: 16)
            x += 16 + 8
        }
        var right = bounds.width - 8
        if let chevron {
            chevron.frame = NSRect(x: right - 16 + 2, y: (bounds.height - 16) / 2, width: 16, height: 16) // `-me-0.5`
            right -= 14 + 8
        }
        if let trailingGlyph {
            trailingGlyph.frame = NSRect(x: right - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
            right -= 16 + 8
        }
        if let checkbox {
            checkbox.frame = NSRect(x: right - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
            right -= 16 + 8
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
            // The warning button is `size="micro"`: 20px tall, `px-1.5`, with its border.
            let w = ceil(noteLabel.textWidth) + (item.noteIsWarning ? 14 : 0)
            let h: CGFloat = item.noteIsWarning ? 20 : 16
            noteLabel.frame = NSRect(x: right - w, y: (bounds.height - h) / 2, width: w, height: h)
            right -= w + 8
        }
        if let trailingView {
            let size = trailingView.intrinsicContentSize
            trailingView.frame = NSRect(x: right - size.width, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            right -= size.width + 8
        }
        title.frame = NSRect(x: x, y: 6, width: max(0, right - x), height: 20)
        var y: CGFloat = 26
        if item.match != nil { matchLine.frame = NSRect(x: x, y: y, width: max(0, right - x), height: 16); y += 16 }
        detail.frame = NSRect(x: x, y: y, width: max(0, right - x), height: 16)
    }

    private func restyle() {
        let fg = isHighlighted ? Themed.color(\.contrastAccentForeground) : Themed.color(\.contrastForeground)
        title.color = item.titleHighlights == nil ? fg : Themed.color(\.contrastMutedForeground)
        title.highlightColor = Themed.color(\.contrastForeground)
        // `text-xs text-muted-foreground/85`, the tag in info or success, hits `font-semibold text-foreground`.
        matchLine.color = Themed.color(\.contrastMutedForeground, item.matchIsUser == nil && item.matchHintLabelLength == nil ? 1 : 0.85)
        matchLine.highlightColor = Themed.color(\.contrastForeground)
        matchLine.prefixColor = item.matchIsUser.map { ($0 ? 4 : 6, Themed.color($0 ? \.infoForeground : \.successForeground)) }
            ?? item.matchHintLabelLength.map { ($0, Themed.color(\.contrastMutedForeground, 0.7)) }
        detail.color = item.descriptionHighlights == nil ? Themed.color(\.contrastMutedForeground, 0.7) : Themed.color(\.contrastMutedForeground)
        detail.highlightColor = Themed.color(\.contrastForeground)
        shortcut.color = Themed.color(\.contrastSecondaryLabel)
        trailing.color = Themed.color(\.contrastMutedForeground, 0.7)
        noteLabel.color = item.noteIsWarning ? Themed.color(\.warningForeground) : Themed.color(\.contrastMutedForeground, 0.7)
        noteLabel.layer?.borderColor = item.noteIsWarning ? Themed.color(\.warning, 0.32).cgColor(in: self) : nil
        trailingGlyph?.strokeColor = Themed.color(\.contrastMutedForeground, 0.7)
        if item.glyph == nil { iconView?.strokeColor = Themed.color(\.contrastIconMuted) } // ITEM_ICON_CLASS `size-4 text-icon-muted`
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
    // The row takes every click, the trailing checkbox's too (it only mirrors the row's state).
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
