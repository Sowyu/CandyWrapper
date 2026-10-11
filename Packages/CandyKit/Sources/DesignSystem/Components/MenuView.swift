import AppKit

/// One entry of a Menu, Select, Combobox or Autocomplete list (T3's `menu.tsx`, `select.tsx`,
/// `combobox.tsx`, `autocomplete.tsx`). Spec: docs/research/recovered/ui-components-a.md 9-11, 13.
public struct MenuItem {
    public enum Kind {
        case item
        case checkbox(Bool)
        /// Radio items in one run (between separators or labels) form a group.
        case radio(Bool)
        case label
        case separator
        case submenu([MenuItem])
        /// A wrapping 12pt paragraph (`px-2 py-1.5 text-xs`): warning, or destructive with `isDestructive`.
        case note
    }

    public var kind: Kind
    public var title: String
    public var icon: IconName?
    /// macOS glyph form, for example `⇧⌘K` (keybindings.ts:191-224).
    public var shortcut: String?
    public var isDestructive = false
    public var isDisabled = false
    /// `data-inset`: room for an icon column.
    public var inset = false
    /// Called on activation. Checkbox and radio items get their new state through `onToggle`.
    public var action: (@MainActor () -> Void)?
    public var onToggle: (@MainActor (Bool) -> Void)?
    /// base-ui `closeOnClick` on checkbox and radio items: picking one runs `action` and closes
    /// the menu. Off by default, as in base-ui.
    public var closesOnClick = false
    /// A 12px leading glyph with a 6px gap, in `muted-foreground` (`size-3` plus `gap-1.5` in the
    /// composer's select items, BranchToolbarEnvironmentSelector.tsx:117-124).
    public var glyph: IconDefinition?
    /// A 14px trailing glyph pushed to the end (`ml-auto`, ProjectEnvironmentBadge.tsx:36-50), with its tooltip.
    public var badge: IconDefinition?
    public var badgeTooltip: String?
    /// Extra height under the content: an `inline-flex` span in a 20px line box sits on the baseline and
    /// grows the row by the 1px below it (BranchToolbarEnvironmentSelector.tsx:126-131 in a SelectItem).
    public var extraBottom: CGFloat = 0
    /// A second, muted 12pt line under the title (`PreviousWorktreeItemContent`); the glyph aligns to the title.
    public var subtitle: String?
    /// A tooltip on the row, shown even while it is disabled (disabled reasons, side left).
    public var tooltip: String?
    /// Controls at the row's end (the browser menu's zoom cluster), made when the row is built.
    public var accessory: (@MainActor () -> NSView)?
    public var accessoryWidth: CGFloat = 0
    /// base-ui `closeOnClick={false}` on a plain item: a click on the row does nothing.
    public var keepsOpen = false
    /// The leading icon in its own color at full opacity (a pull request state glyph), not the muted one.
    public var iconColor: NSColor?

    public init(_ title: String, icon: IconName? = nil, shortcut: String? = nil, kind: Kind = .item, destructive: Bool = false,
                disabled: Bool = false, inset: Bool = false, action: (@MainActor () -> Void)? = nil) {
        self.kind = kind; self.title = title; self.icon = icon; self.shortcut = shortcut
        self.isDestructive = destructive; self.isDisabled = disabled; self.inset = inset; self.action = action
    }

    public static var separator: MenuItem { MenuItem("", kind: .separator) }
    public static func note(_ text: String, destructive: Bool = false) -> MenuItem { MenuItem(text, kind: .note, destructive: destructive) }
    public static func label(_ title: String, inset: Bool = false) -> MenuItem { MenuItem(title, kind: .label, inset: inset) }
    public static func checkbox(_ title: String, checked: Bool, onToggle: (@MainActor (Bool) -> Void)? = nil) -> MenuItem {
        var item = MenuItem(title, kind: .checkbox(checked))
        item.onToggle = onToggle
        return item
    }
    public static func radio(_ title: String, checked: Bool, onToggle: (@MainActor (Bool) -> Void)? = nil) -> MenuItem {
        var item = MenuItem(title, kind: .radio(checked))
        item.onToggle = onToggle
        return item
    }
    public static func submenu(_ title: String, icon: IconName? = nil, _ items: [MenuItem]) -> MenuItem {
        MenuItem(title, icon: icon, kind: .submenu(items))
    }

    var isSelectable: Bool {
        switch kind { case .label, .separator, .note: false; default: !isDisabled }
    }
    var isChecked: Bool {
        switch kind { case .checkbox(let on), .radio(let on): on; default: false }
    }
}

/// The popup list behind Menu, Select, Combobox and Autocomplete. The styles differ only in the
/// surface and the fills for highlighted and selected rows.
public final class MenuPopupView: DSView, PopupContent, PressDragMenu {
    public enum Style: Sendable {
        case menu, select, combobox, autocomplete
    }

    public let style: Style
    public private(set) var items: [MenuItem]
    /// `data-highlighted`, from the pointer or the keyboard.
    public var highlightedIndex: Int? {
        didSet { if highlightedIndex != oldValue { rowsDidChange(); scrollToHighlight() } }
    }
    /// Minimum width, for example the trigger width (`min-w-(--anchor-width)`).
    public var minimumWidth: CGFloat = 0 {
        didSet {
            rows.forEach { $0.wrapWidth = minimumWidth > 0 ? minimumWidth - 2 * Self.inset : 256 }
            invalidateIntrinsicContentSize()
        }
    }
    /// Combobox and Autocomplete cap the list at 23rem.
    var maximumHeight: CGFloat = .greatestFiniteMagnitude
    /// Text shown when there are no items (ComboboxEmpty).
    public var emptyText: String? { didSet { rebuild() } }
    /// Called after an item is chosen; Select and Combobox use it.
    public final var onChoose: (@MainActor (Int) -> Void)?
    /// Letter keys handled before typeahead (the right panel's + menu picks a surface by letter).
    public final var characterOverride: (@MainActor (String) -> Bool)?

    private let decoration = BoxDecorationLayer()
    private let dropShadow = PopupShadowLayer()
    private let clip = DSView()
    private var rows: [MenuRowView] = []
    private var emptyLabel: LabelView?
    private var scrollOffset: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var typeahead = ""
    private var typeaheadTime: TimeInterval = 0
    private var submenuWork: DispatchWorkItem?
    private var lastPointer: CGPoint?
    private var openSubmenu: (popup: OpenPopup, index: Int)?
    public weak var hostPopup: OpenPopup?

    public init(items: [MenuItem], style: Style = .menu) {
        self.style = style
        self.items = items
        super.init(frame: .zero)
        decoration.host = self
        dropShadow.host = self
        layer?.addSublayer(dropShadow)
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        clip.layer?.masksToBounds = true
        addSubview(clip)
        let look = surface.split()
        decoration.boxStyle = look.box
        dropShadow.radius = 10
        dropShadow.shadows = look.shadows
        rebuild()
    }

    var surface: PopupSurface { style == .autocomplete ? .opaque : .glass }

    public func setItems(_ items: [MenuItem]) {
        self.items = items
        highlightedIndex = nil
        rebuild()
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.map { MenuRowView(item: $0, style: style) }
        // Notes wrap at the anchor width, or `max-w-64` without one.
        rows.forEach { $0.wrapWidth = minimumWidth > 0 ? minimumWidth - 2 * Self.inset : 256 }
        rows.forEach(clip.addSubview)
        emptyLabel?.removeFromSuperview()
        emptyLabel = nil
        if items.isEmpty, let emptyText {
            let label = LabelView(emptyText, font: DSFont.ui(14), color: Themed.color(\.contrastMutedForeground))
            label.lineHeight = 20
            label.alignment = .center
            clip.addSubview(label)
            emptyLabel = label
        }
        scrollOffset = 0
        rowsDidChange()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func rowsDidChange() {
        for (i, row) in rows.enumerated() {
            row.highlighted = i == highlightedIndex || (openSubmenu?.index == i)
        }
    }

    // MARK: Size and layout

    /// List padding 4 plus the 1px border.
    static let inset: CGFloat = 5

    var contentHeight: CGFloat {
        if let emptyLabel { return emptyLabel.intrinsicContentSize.height + 16 }
        return rows.reduce(0) { $0 + $1.height }
    }

    public override var intrinsicContentSize: NSSize {
        var width = rows.map(\.naturalWidth).max() ?? 0
        if let emptyLabel { width = max(width, emptyLabel.intrinsicContentSize.width + 16) }
        // `min-w-[min(10rem,...)]` for menus; the anchor width for the others.
        let floor = style == .menu ? max(160, minimumWidth) : minimumWidth
        let w = max(floor, width + 2 * Self.inset)
        let h = min(contentHeight + 2 * Self.inset, maximumHeight)
        return NSSize(width: (w * 2).rounded(.up) / 2, height: h)
    }

    public var popupSize: CGSize { intrinsicContentSize }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        dropShadow.update(boxSize: bounds.size)
        clip.frame = bounds.insetBy(dx: 1, dy: 1)
        var y = Self.inset - 1 - scrollOffset
        for row in rows {
            row.frame = NSRect(x: Self.inset - 1, y: y, width: clip.bounds.width - 2 * (Self.inset - 1), height: row.height)
            y += row.height
        }
        if let emptyLabel {
            emptyLabel.frame = NSRect(x: Self.inset + 7, y: Self.inset + 7, width: clip.bounds.width - 2 * (Self.inset + 7), height: 20)
        }
    }

    private var maxScroll: CGFloat { max(0, contentHeight + 2 * Self.inset - bounds.height) }

    private func scrollToHighlight() {
        guard let i = highlightedIndex, i < rows.count, bounds.height > 0 else { return }
        let top = rows[..<i].reduce(0) { $0 + $1.height }
        let visible = bounds.height - 2 * Self.inset
        if top < scrollOffset { scrollOffset = top } else if top + rows[i].height > scrollOffset + visible { scrollOffset = top + rows[i].height - visible }
        needsLayout = true
    }

    public override func scrollWheel(with event: NSEvent) {
        scrollOffset = min(max(0, scrollOffset - event.scrollingDeltaY), maxScroll)
        needsLayout = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        dropShadow.update(boxSize: bounds.size)
    }

    // MARK: Keyboard (base-ui menu navigation: loop, skip disabled, typeahead)

    public func popupHandleKey(_ key: PopupKey) -> Bool {
        switch key {
        case .down: move(1); return true
        case .up: move(-1); return true
        case .home: highlightedIndex = selectable.first; return true
        case .end: highlightedIndex = selectable.last; return true
        case .enter:
            if let i = highlightedIndex { activate(i, byKeyboard: true) }
            return true
        case .space:
            if !typeahead.isEmpty, Date().timeIntervalSinceReferenceDate - typeaheadTime < Self.typeaheadReset {
                return typeAhead(" ")
            }
            guard style == .menu || style == .select else { return false } // comboboxes type the space
            if let i = highlightedIndex { activate(i, byKeyboard: true) }
            return true
        case .right:
            guard style == .menu, let i = highlightedIndex, case .submenu = items[i].kind else { return style == .menu }
            openSubmenu(at: i, highlightFirst: true)
            return true
        case .left:
            // In a submenu, Left closes it and highlights its trigger again.
            guard style == .menu, let popup = hostPopup, popup.parent != nil, let host = popup.container.superview as? PopupHost else { return style == .menu }
            host.close(popup, returnFocus: false)
            return true
        case .escape:
            // Escape closes the whole menu tree and returns focus to the root trigger.
            guard let popup = hostPopup, let host = popup.container.superview as? PopupHost else { return false }
            var root = popup
            while let parent = root.parent { root = parent }
            host.close(root)
            return true
        case .tab:
            return false
        case .character(let c):
            if let characterOverride, characterOverride(c) { return true }
            // Comboboxes filter as the user types; only menus and selects use typeahead.
            guard style == .menu || style == .select else { return false }
            return typeAhead(c)
        }
    }

    /// base-ui's typeahead buffer resets after 500ms without a key (a timestamp, not a timer).
    static let typeaheadReset: TimeInterval = 0.5

    private func typeAhead(_ c: String) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if now - typeaheadTime > Self.typeaheadReset { typeahead = "" }
        typeaheadTime = now
        typeahead += c.lowercased()
        let start = (highlightedIndex ?? -1)
        // A repeated single letter cycles through matches; a longer prefix stays on the current match.
        let order = selectable.sorted { a, b in
            let ra = (a - start - (typeahead.count > 1 ? 0 : 1) + items.count) % items.count
            let rb = (b - start - (typeahead.count > 1 ? 0 : 1) + items.count) % items.count
            return ra < rb
        }
        let needle = typeahead.allSatisfy({ $0 == typeahead.first }) && typeahead.count > 1 ? String(typeahead.first!) : typeahead
        if let match = order.first(where: { items[$0].title.lowercased().hasPrefix(needle) }) { highlightedIndex = match }
        return true
    }

    var selectable: [Int] { items.indices.filter { items[$0].isSelectable } }

    private func move(_ delta: Int) {
        let s = selectable
        guard !s.isEmpty else { return }
        guard let current = highlightedIndex, let pos = s.firstIndex(of: current) else {
            highlightedIndex = delta > 0 ? s.first : s.last
            return
        }
        highlightedIndex = s[(pos + delta + s.count) % s.count] // base-ui menus loop focus
    }

    /// Closes the whole menu tree, then runs row `i`'s action. Closing first keeps the menu from
    /// staying drawn under a modal the action opens (an alert's run loop blocks until it ends).
    private func choose(_ i: Int) {
        let action = items[i].action
        onChoose?(i)
        closeTree()
        action?()
    }

    /// Chooses row `i`: toggles checkbox and radio rows in place, opens submenus, otherwise runs the
    /// action and closes the whole menu tree.
    public func activate(_ i: Int, byKeyboard: Bool = false) {
        guard i < items.count, items[i].isSelectable else { return }
        switch items[i].kind {
        case .checkbox(let on):
            items[i].kind = .checkbox(!on)
            rows[i].item = items[i]
            items[i].onToggle?(!on)
        case .radio(let on):
            if style == .menu {
                if !on {
                    for j in radioGroup(of: i) { items[j].kind = .radio(j == i); rows[j].item = items[j] }
                    items[i].onToggle?(true)
                }
                if items[i].closesOnClick { choose(i) }
            } else {
                choose(i)
            }
        case .submenu:
            openSubmenu(at: i, highlightFirst: byKeyboard)
        case .item:
            if !items[i].keepsOpen { choose(i) }
        case .label, .separator, .note:
            break
        }
    }

    private func radioGroup(of i: Int) -> [Int] {
        func isRadio(_ j: Int) -> Bool { if case .radio = items[j].kind { true } else { false } }
        var lo = i, hi = i
        while lo > 0, isRadio(lo - 1) { lo -= 1 }
        while hi < items.count - 1, isRadio(hi + 1) { hi += 1 }
        return Array(lo...hi)
    }

    public func closeTree() {
        guard let popup = hostPopup, let host = popup.container.superview as? PopupHost else { return }
        var root = popup
        while let parent = root.parent { root = parent }
        host.close(root)
    }

    // MARK: Submenus

    func openSubmenu(at i: Int, highlightFirst: Bool) {
        guard case .submenu(let children) = items[i].kind, let popup = hostPopup,
              let host = popup.container.superview as? PopupHost else { return }
        if openSubmenu?.index == i { return }
        let sub = MenuPopupView(items: children, style: .menu)
        // Submenu triggers get `data-popup-open` only, not `data-pressed`.
        let child = host.open(sub, trigger: rows[i], placement: .submenu, pressesTrigger: false, returnsFocus: false, parent: popup)
        sub.hostPopup = child
        if highlightFirst { sub.highlightedIndex = sub.selectable.first }
        openSubmenu = (child, i)
        highlightedIndex = i
        child.onClose = { [weak self] in
            guard let self else { return }
            self.openSubmenu = nil
            self.rowsDidChange()
        }
        rowsDidChange()
    }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    func rowIndex(at point: CGPoint) -> Int? {
        rows.firstIndex { $0.frame.contains(clip.convert(point, from: self)) }
    }

    public func pressDragRow(at windowPoint: NSPoint) -> Int? {
        rowIndex(at: convert(windowPoint, from: nil)).flatMap { items[$0].isSelectable ? $0 : nil }
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { lastPointer = p }
        // Safe triangle: while the pointer heads for an open submenu, keep the submenu trigger highlighted.
        if let open = openSubmenu, let last = lastPointer, let host = superview?.superview,
           Self.inSafeTriangle(p, from: last, toward: convert(open.popup.container.frame, from: host)) { return }
        guard let i = rowIndex(at: p), items[i].isSelectable else { return }
        highlightedIndex = i
        submenuWork?.cancel()
        if case .submenu = items[i].kind {
            // base-ui submenu triggers open on hover after 100ms.
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.openSubmenu(at: i, highlightFirst: false) } }
            submenuWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        } else if let open = openSubmenu, let host = open.popup.container.superview as? PopupHost {
            host.close(open.popup, returnFocus: false)
        }
    }

    /// True when `p` lies in the triangle between the last pointer position and the submenu's near edge.
    static func inSafeTriangle(_ p: CGPoint, from a: CGPoint, toward rect: CGRect) -> Bool {
        let edgeX = rect.minX >= a.x ? rect.minX : rect.maxX
        let b = CGPoint(x: edgeX, y: rect.minY), c = CGPoint(x: edgeX, y: rect.maxY)
        func sign(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat { (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y) }
        let d1 = sign(p, a, b), d2 = sign(p, b, c), d3 = sign(p, c, a)
        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
        return !(neg && pos)
    }

    public override func mouseExited(with event: NSEvent) {
        submenuWork?.cancel()
        if openSubmenu == nil { highlightedIndex = nil }
    }

    public override func mouseDown(with event: NSEvent) {}

    public override func mouseUp(with event: NSEvent) {
        if let i = rowIndex(at: convert(event.locationInWindow, from: nil)) { activate(i) }
    }

    public override func resetCursorRects() {
        for row in rows where row.item.isSelectable && style != .autocomplete { addCursorRect(convert(row.frame, from: clip), cursor: .pointingHand) }
    }
}

public extension MenuPopupView {
    /// Opens a dropdown menu under `trigger` (MenuTrigger + MenuPopup). Opened from the keyboard,
    /// the first item is highlighted, as in base-ui. Returns nil when the trigger has no window.
    @discardableResult
    static func show(_ items: [MenuItem], from trigger: NSView, placement: PopupPlacement = .menu,
                     minimumWidth: CGFloat = 0, anchorRect: CGRect? = nil) -> MenuPopupView? {
        guard let host = trigger.popupHost else { return nil }
        let menu = MenuPopupView(items: items)
        menu.minimumWidth = minimumWidth
        menu.hostPopup = host.open(menu, trigger: trigger, anchorRect: anchorRect, placement: placement, swallowsOutsideClick: true)
        if NSApp.currentEvent?.type == .keyDown { menu.highlightedIndex = menu.selectable.first }
        return menu
    }

    /// Opens a context menu at `point` in `view`'s coordinates.
    @discardableResult
    static func showContextMenu(_ items: [MenuItem], in view: NSView, at point: CGPoint) -> MenuPopupView? {
        guard let host = view.popupHost else { return nil }
        let menu = MenuPopupView(items: items)
        let anchor = CGRect(origin: host.convert(point, from: view), size: .zero)
        menu.hostPopup = host.open(menu, trigger: nil, anchorRect: anchor, placement: .contextMenu,
                                   swallowsOutsideClick: true, pressesTrigger: false, returnsFocus: false)
        return menu
    }
}

/// One row. Geometry is the desktop one: min-height 28, padding 4px 8px, radius 6, 14px text.
final class MenuRowView: DSView {
    var item: MenuItem { didSet { configure() } }
    let style: MenuPopupView.Style
    var highlighted = false { didSet { if highlighted != oldValue { restyle() } } }

    private let fill = BoxDecorationLayer()
    private let label = LabelView()
    private var iconView: IconView?
    private var trailing: IconView?
    private var glyphView: IconView?
    private var badgeView: IconView?
    private var check: CAShapeLayer?
    private var shortcut: TrackedLabelView?
    private var accessoryView: NSView?

    init(item: MenuItem, style: MenuPopupView.Style) {
        self.item = item
        self.style = style
        super.init(frame: .zero)
        fill.host = self
        layer?.addSublayer(fill)
        addSubview(label)
        configure()
    }

    var isLabel: Bool { if case .label = item.kind { true } else { false } }
    var isSeparator: Bool { if case .separator = item.kind { true } else { false } }
    var isCheckbox: Bool { if case .checkbox = item.kind { true } else { false } }
    var isNote: Bool { if case .note = item.kind { true } else { false } }
    /// The width a note wraps at.
    var wrapWidth: CGFloat = 256
    private var note: TextBlockView?
    private var subtitleLabel: LabelView?
    private var tooltipController: TooltipController?

    /// Row height: 28 for items and labels, 9 for separators (1px + 4px margins), 44 with a subtitle, and a note's
    /// wrapped lines plus 12.
    var height: CGFloat {
        if isSeparator { return 9 }
        if isNote, let note { return note.height(forWidth: wrapWidth - 16) + 12 }
        return (item.subtitle != nil ? 44 : 28) + item.extraBottom
    }

    var paddingLeading: CGFloat {
        if isLabel { return item.inset ? 32 : 8 }
        return item.inset ? 32 : 8
    }
    var paddingTrailing: CGFloat { isCheckbox ? 16 : 8 }

    /// max-content width of the row.
    var naturalWidth: CGFloat {
        if isSeparator || isNote { return 16 }
        var w = paddingLeading + paddingTrailing + label.textWidth
        if isCheckbox { w += 16 + 8 }
        if iconView != nil { w += 12 + 8 }
        if glyphView != nil { w += 12 + 6 }
        if badgeView != nil { w += 8 + 14 }
        if let shortcut { w += 8 + shortcut.intrinsicContentSize.width }
        if trailing != nil { w += 8 + 14 }
        if accessoryView != nil { w += 8 + item.accessoryWidth }
        return w
    }

    private func configure() {
        iconView?.removeFromSuperview(); iconView = nil
        trailing?.removeFromSuperview(); trailing = nil
        glyphView?.removeFromSuperview(); glyphView = nil
        badgeView?.removeFromSuperview(); badgeView = nil
        shortcut?.removeFromSuperview(); shortcut = nil
        accessoryView?.removeFromSuperview(); accessoryView = item.accessory?()
        accessoryView.map(addSubview)
        check?.removeFromSuperlayer(); check = nil
        note?.removeFromSuperview(); note = nil
        subtitleLabel?.removeFromSuperview(); subtitleLabel = nil
        label.isHidden = isNote
        if isNote {
            let t = TextBlockView()
            t.text = item.title
            t.font = DSFont.ui(12)
            t.lineHeight = 16
            addSubview(t)
            note = t
        }
        if let subtitle = item.subtitle {
            let l = LabelView(subtitle, font: DSFont.ui(12))
            l.lineHeight = 16
            addSubview(l)
            subtitleLabel = l
        }
        if let tip = item.tooltip {
            if tooltipController == nil {
                tooltipController = TooltipController.attach(to: self, text: tip, placement: PopupPlacement(side: .left, align: .center, sideOffset: 4))
            }
            tooltipController?.text = tip
        }
        label.text = item.title
        if isLabel {
            label.font = DSFont.ui(12, weight: .medium)
            label.lineHeight = 16
        } else {
            label.font = DSFont.ui(14)
            label.lineHeight = 20
        }
        if let icon = item.icon, !isLabel, !isSeparator {
            let v = IconView(name: icon)
            addSubview(v)
            iconView = v
        }
        if let glyph = item.glyph, !isLabel, !isSeparator {
            let v = IconView(definition: glyph, size: 12)
            addSubview(v)
            glyphView = v
        }
        if let badge = item.badge, !isLabel, !isSeparator {
            let v = IconView(definition: badge, size: 14)
            if let tip = item.badgeTooltip {
                TooltipController.attach(to: v, text: tip)
                v.setAccessibilityElement(true)
                v.setAccessibilityRole(.image)
                v.setAccessibilityLabel(tip)
            }
            addSubview(v)
            badgeView = v
        }
        if case .submenu = item.kind {
            let v = IconView(name: .chevronRight)
            addSubview(v)
            trailing = v
        }
        if let s = item.shortcut {
            let v = TrackedLabelView(s, font: DSFont.ui(12, weight: .medium), tracking: 1.2,
                                     color: Themed.color(\.contrastSecondaryLabel), lineHeight: 16)
            addSubview(v)
            shortcut = v
        }
        if case .checkbox(let on) = item.kind, on {
            // menu.tsx:156-170: a custom check path, stroke 2 in a 24 box, drawn at 16px.
            let shape = CAShapeLayer()
            var t = CGAffineTransform(scaleX: 16.0 / 24, y: 16.0 / 24)
            shape.path = (try? SVGPath.parse("M5.252 12.7 10.2 18.63 18.748 5.37"))?.copy(using: &t)
            shape.lineWidth = 2 * 16.0 / 24
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.fillColor = nil
            shape.actions = ["position": NSNull(), "bounds": NSNull(), "strokeColor": NSNull()]
            layer?.addSublayer(shape)
            check = shape
        }
        alphaValue = item.isDisabled && !isNote ? 0.64 : 1
        restyle()
        needsLayout = true
    }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 6
        let accent = Themed.color(\.accent)
        let selectedFill = Themed.color(\.contrastForeground, 0.08)
        let selected = item.isChecked && !isCheckbox
        switch style {
        case .menu:
            // Radio: highlighted accent wins over the checked fill.
            box.fill = highlighted ? accent : (selected ? selectedFill : nil)
        case .select:
            // The selected rule comes after the highlighted one, so it wins.
            box.fill = selected ? selectedFill : (highlighted ? accent : nil)
        case .combobox:
            box.fill = highlighted ? accent : (selected ? selectedFill : nil)
        case .autocomplete:
            box.fill = highlighted ? accent : (selected ? Themed.color(\.accent, 0.5) : nil)
        }
        if isLabel || isSeparator { box.fill = nil }
        if isSeparator { box = BoxStyle() }
        fill.boxStyle = box

        let text: NSColor
        if isLabel { text = Themed.color(\.contrastMutedForeground) }
        else if item.isDestructive { text = Themed.color(\.destructiveForeground) }
        else if highlighted { text = Themed.color(\.contrastAccentForeground) }
        else { text = Themed.color(\.contrastForeground) }
        label.color = text
        let iconColor = item.isDestructive ? text : Themed.color(\.contrastMutedForeground)
        iconView?.strokeColor = item.iconColor ?? iconColor
        iconView?.alphaValue = item.iconColor == nil ? 0.8 : 1
        trailing?.strokeColor = Themed.color(\.contrastMutedForeground)
        trailing?.alphaValue = 0.8
        glyphView?.strokeColor = Themed.color(\.contrastMutedForeground)
        badgeView?.strokeColor = Themed.color(\.contrastMutedForeground)
        if let check { check.strokeColor = text.cgColor(in: self) }
        note?.color = item.isDestructive ? Themed.color(\.destructive) : Themed.color(\.warning)
        subtitleLabel?.color = Themed.color(\.contrastMutedForeground)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        fill.setNeedsDisplay()
        restyle()
    }

    private let separatorLine = CALayer()

    override func layout() {
        super.layout()
        if isSeparator {
            fill.boxStyle = BoxStyle()
            if separatorLine.superlayer == nil { layer?.addSublayer(separatorLine) }
            separatorLine.actions = ["position": NSNull(), "bounds": NSNull()]
            separatorLine.frame = CGRect(x: 8, y: 4, width: bounds.width - 16, height: 1)
            separatorLine.backgroundColor = Themed.color(\.contrastBorder).cgColor(in: self)
            label.isHidden = true
            return
        }
        fill.layout(boxSize: bounds.size)
        if let note {
            note.frame = NSRect(x: 8, y: 6, width: bounds.width - 16, height: bounds.height - 12)
            return
        }
        var x = paddingLeading
        var trailingX = bounds.width - paddingTrailing
        if isCheckbox {
            check?.frame = CGRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
            x += 16 + 8
        }
        if let iconView {
            iconView.frame = NSRect(x: x - 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
            x += 12 + 8
        }
        if let glyphView {
            // With a subtitle the glyph sits at the title (`items-start`, `mt-1`).
            let gy = item.subtitle != nil ? 4 + 4 : (bounds.height - item.extraBottom - 12) / 2
            glyphView.frame = NSRect(x: x, y: gy, width: 12, height: 12)
            x += 12 + 6
        }
        if let accessoryView {
            let w = item.accessoryWidth
            accessoryView.frame = NSRect(x: trailingX - w, y: (bounds.height - 24) / 2, width: w, height: 24)
            trailingX -= w + 8
        }
        if let badgeView {
            badgeView.frame = NSRect(x: trailingX - 14, y: (bounds.height - 14) / 2, width: 14, height: 14)
            trailingX -= 14 + 8
        }
        if let trailing {
            trailing.frame = NSRect(x: trailingX + 2 - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
            trailingX -= 14 + 8
        }
        if let shortcut {
            let w = shortcut.intrinsicContentSize.width
            shortcut.frame = NSRect(x: trailingX - w, y: (bounds.height - 16) / 2, width: w, height: 16)
            trailingX -= w + 8
        }
        let lh = label.lineHeight ?? 20
        if let subtitleLabel {
            label.frame = NSRect(x: x, y: 4, width: max(0, min(label.textWidth, trailingX - x)), height: lh)
            subtitleLabel.frame = NSRect(x: x, y: 4 + lh, width: max(0, trailingX - x), height: 16)
            return
        }
        label.frame = NSRect(x: x, y: (bounds.height - item.extraBottom - lh) / 2, width: max(0, min(label.textWidth, trailingX - x)), height: lh)
    }
}
