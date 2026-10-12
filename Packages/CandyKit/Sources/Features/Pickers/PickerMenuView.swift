import AppKit
import DesignSystem

/// The content of a picker popup. `PickerPopupView` puts it on the glass surface and routes keys.
@MainActor
protocol PickerPopupBody: NSView {
    /// Size inside the 1px border.
    var naturalSize: CGSize { get }
    func handleKey(_ key: PopupKey) -> Bool
}

/// A picker body on T3's glass popup surface (radius 10, `before:hidden`), as one popup.
final class PickerPopupView: DSView, PopupContent {
    let surface: PopoverView
    let body: PickerPopupBody

    init(_ body: PickerPopupBody) {
        self.body = body
        surface = PopoverView(content: body, padding: .none, beforeLine: false)
        super.init(frame: .zero)
        layer?.masksToBounds = false
        addSubview(surface)
    }

    var popupSize: CGSize { CGSize(width: body.naturalSize.width + 2, height: body.naturalSize.height + 2) }
    override var intrinsicContentSize: NSSize { popupSize }
    func popupHandleKey(_ key: PopupKey) -> Bool { body.handleKey(key) }

    override func layout() {
        super.layout()
        surface.frame = bounds
    }
}

/// One entry of a traits menu or the access select.
struct PickerMenuEntry {
    enum Kind { case label, separator, option }
    var kind: Kind
    var title = ""
    var icon: IconName?
    /// The outline "Default" badge after the title (traits).
    var badge: String?
    var description: String?
    var checked = false
    var disabled = false
    /// `py-1.5` group labels (boolean descriptors) instead of `pt-1.5 pb-1`.
    var evenLabelPadding = false
    /// A radio item without `closeOnClick`: picking it updates the menu in place.
    var keepsOpen = false
    var onPick: (@MainActor () -> Void)?

    static func label(_ title: String, even: Bool = false) -> Self { Self(kind: .label, title: title, evenLabelPadding: even) }
    static var separator: Self { Self(kind: .separator) }
    static func option(_ title: String, icon: IconName? = nil, badge: String? = nil, description: String? = nil, checked: Bool,
                       disabled: Bool = false, onPick: @escaping @MainActor () -> Void) -> Self {
        Self(kind: .option, title: title, icon: icon, badge: badge, description: description, checked: checked, disabled: disabled, onPick: onPick)
    }
}

/// The list inside the traits menu (`MenuPopup` with radio groups, TraitsPicker.tsx:371-486) and
/// the access select (`SelectPopup` items, ChatComposer.tsx:1325-1350). `p-1` list padding, rows
/// `px-2 py-1 min-h-7 rounded-sm`, checked rows `foreground/8%`, highlighted rows `accent`.
final class PickerMenuView: DSView, PickerPopupBody, PressDragMenu {
    enum Style { case menu, select }

    let style: Style
    private(set) var entries: [PickerMenuEntry]
    /// Width floor of the content box, without the border.
    var minimumWidth: CGFloat
    var highlightedIndex: Int? { didSet { if highlightedIndex != oldValue { rows.forEach { $0.restyle() } } } }
    var onClose: (@MainActor () -> Void)?
    /// Fresh entries after a `keepsOpen` pick (the checked row moves).
    var refreshEntries: (@MainActor () -> [PickerMenuEntry])?

    private var rows: [PickerMenuRowView] = []
    private var tracking: NSTrackingArea?

    init(entries: [PickerMenuEntry], style: Style, minimumWidth: CGFloat) {
        self.entries = entries
        self.style = style
        self.minimumWidth = minimumWidth
        super.init(frame: .zero)
        rows = entries.indices.map { PickerMenuRowView(menu: self, index: $0) }
        rows.forEach(addSubview)
    }

    func entry(_ i: Int) -> PickerMenuEntry { entries[i] }
    func isHighlighted(_ i: Int) -> Bool { highlightedIndex == i }

    // `role="menu"` (traits) or a select's listbox; the rows are its items.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menu }

    var naturalSize: CGSize {
        let w = (max(minimumWidth, (rows.map(\.naturalWidth).max() ?? 0) + 8) * 2).rounded(.up) / 2
        return CGSize(width: w, height: rows.reduce(8) { $0 + $1.height(rowWidth: w - 8) })
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 4
        for row in rows {
            let h = row.height(rowWidth: bounds.width - 8)
            row.frame = NSRect(x: 4, y: y, width: bounds.width - 8, height: h)
            y += h
        }
    }

    var selectable: [Int] { entries.indices.filter { entries[$0].kind == .option && !entries[$0].disabled } }

    func handleKey(_ key: PopupKey) -> Bool {
        let s = selectable
        switch key {
        case .down, .up:
            guard !s.isEmpty else { return true }
            if let h = highlightedIndex, let pos = s.firstIndex(of: h) {
                highlightedIndex = s[(pos + (key == .down ? 1 : -1) + s.count) % s.count]
            } else {
                highlightedIndex = key == .down ? s.first : s.last
            }
            return true
        case .home: highlightedIndex = s.first; return true
        case .end: highlightedIndex = s.last; return true
        case .enter, .space:
            if let h = highlightedIndex { pick(h) }
            return true
        default:
            return false
        }
    }

    func pick(_ i: Int) {
        guard entries[i].kind == .option, !entries[i].disabled else { return }
        let keepsOpen = entries[i].keepsOpen
        entries[i].onPick?()
        guard keepsOpen, let refreshEntries else { onClose?(); return }
        entries = refreshEntries()
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.indices.map { PickerMenuRowView(menu: self, index: $0) }
        rows.forEach(addSubview)
        needsLayout = true
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func row(at event: NSEvent) -> Int? { pressDragRow(at: event.locationInWindow) }

    func pressDragRow(at windowPoint: NSPoint) -> Int? {
        let p = convert(windowPoint, from: nil)
        return rows.firstIndex { $0.frame.contains(p) }.flatMap { selectable.contains($0) ? $0 : nil }
    }

    override func mouseMoved(with event: NSEvent) { if let i = row(at: event) { highlightedIndex = i } }
    override func mouseExited(with event: NSEvent) { highlightedIndex = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if let i = row(at: event) { pick(i) } }
    override func resetCursorRects() { for i in selectable { addCursorRect(rows[i].frame, cursor: .pointingHand) } }
}

/// One row of `PickerMenuView`.
final class PickerMenuRowView: DSView {
    private unowned let owner: PickerMenuView
    private let index: Int
    private let fill = CALayer()
    private let title = LabelView()
    private var icon: IconView?
    private var badge: BadgeView?
    private var detail: TextBlockView?
    private var line: CALayer?

    init(menu: PickerMenuView, index: Int) {
        self.owner = menu
        self.index = index
        super.init(frame: .zero)
        let e = owner.entry(index)
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        fill.cornerRadius = 6
        layer?.addSublayer(fill)
        title.smoothsFont = false // glass popups are backdrop-filter layers
        switch e.kind {
        case .separator:
            let l = CALayer()
            l.actions = fill.actions
            layer?.addSublayer(l)
            line = l
        case .label:
            title.text = e.title
            title.font = DSFont.ui(12, weight: .medium)
            title.lineHeight = 16
            addSubview(title)
        case .option:
            title.text = e.title
            // Select rows put the label in `font-medium text-foreground`.
            title.font = DSFont.ui(14, weight: owner.style == .select ? .medium : .regular)
            title.lineHeight = 20
            addSubview(title)
            if let name = e.icon {
                let v = IconView(name: name, size: 14)
                addSubview(v)
                icon = v
            }
            if let b = e.badge {
                let v = BadgeView(b, variant: .outline, size: .sm)
                addSubview(v)
                badge = v
            }
            if let d = e.description {
                let v = TextBlockView(d, font: DSFont.ui(12), lineHeight: 16)
                v.balanced = owner.style == .menu // `text-pretty`
                v.smoothsFont = false
                addSubview(v)
                detail = v
            }
            alphaValue = e.disabled ? 0.64 : 1
        }
        restyle()
    }

    // `menuitemradio` with `aria-checked`, or a group label read as text.
    override func isAccessibilityElement() -> Bool { owner.entry(index).kind != .separator }
    override func accessibilityRole() -> NSAccessibility.Role? { owner.entry(index).kind == .label ? .staticText : .menuItem }
    override func accessibilityTitle() -> String? {
        let e = owner.entry(index)
        guard e.kind == .option else { return nil }
        return e.badge.map { "\(e.title), \($0)" } ?? e.title
    }
    override func accessibilityValue() -> Any? { owner.entry(index).kind == .label ? owner.entry(index).title : nil }
    override func accessibilityHelp() -> String? { owner.entry(index).description }
    override func isAccessibilityEnabled() -> Bool { !owner.entry(index).disabled }
    override func isAccessibilitySelected() -> Bool { owner.isHighlighted(index) }
    override func accessibilityPerformPress() -> Bool {
        guard owner.entry(index).kind == .option, !owner.entry(index).disabled else { return false }
        owner.pick(index)
        return true
    }
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard attribute.rawValue == "AXMenuItemMarkChar" else { return super.accessibilityAttributeValue(attribute) }
        return owner.entry(index).checked ? "\u{2713}" : nil
    }

    /// Traits descriptions wrap inside `max-w-56`; select descriptions stay on one line.
    private func detailHeight(rowWidth: CGFloat) -> CGFloat {
        guard let detail else { return 0 }
        guard owner.style == .menu else { return 16 }
        let width = min(224, rowWidth - 16)
        return TextBlockLayout(NSAttributedString(string: detail.text, attributes: [.font: detail.font]), width: width, lineHeight: 16, balanced: true).height
    }

    func height(rowWidth: CGFloat) -> CGFloat {
        let e = owner.entry(index)
        switch e.kind {
        case .separator: return 9
        case .label: return e.evenLabelPadding ? 28 : 26
        case .option:
            guard detail != nil else { return 28 }
            // Select: `grid gap-0.5` (20 + 2 + 16); traits: the description line follows the label.
            return 8 + 20 + (owner.style == .select ? 2 : 0) + detailHeight(rowWidth: rowWidth)
        }
    }

    var naturalWidth: CGFloat {
        let e = owner.entry(index)
        switch e.kind {
        case .separator: return 16
        case .label: return 16 + title.textWidth
        case .option:
            var first = title.textWidth + (icon == nil ? 0 : 14 + 6)
            if let badge { first += spaceWidth + badge.intrinsicContentSize.width }
            // The traits description wraps at `max-w-56` (224).
            let second = detail.map { d -> CGFloat in
                let w = TextLine(NSAttributedString(string: d.text, attributes: [.font: d.font])).width
                return owner.style == .menu ? min(224, w) : w
            } ?? 0
            return 16 + max(first, second)
        }
    }

    private var spaceWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: title.font]).width }

    override func layout() {
        super.layout()
        fill.frame = bounds
        let e = owner.entry(index)
        switch e.kind {
        case .separator:
            line?.frame = CGRect(x: 8, y: 4, width: bounds.width - 16, height: 1)
        case .label:
            title.frame = NSRect(x: 8, y: 6, width: bounds.width - 16, height: 16)
        case .option:
            let top: CGFloat = detail == nil ? (bounds.height - 20) / 2 : 4
            var x: CGFloat = 8
            if let icon {
                icon.frame = NSRect(x: x, y: top + 3, width: 14, height: 14)
                x += 14 + 6
            }
            let w = min(title.textWidth, bounds.width - 8 - x - (badge.map { spaceWidth + $0.intrinsicContentSize.width } ?? 0))
            title.frame = NSRect(x: x, y: top, width: max(0, w), height: 20)
            if let badge {
                let size = badge.intrinsicContentSize
                badge.frame = NSRect(x: x + w + spaceWidth, y: top + (20 - size.height) / 2, width: size.width, height: size.height)
            }
            detail?.frame = NSRect(x: 8, y: top + 20 + (owner.style == .select ? 2 : 0), width: owner.style == .menu ? min(224, bounds.width - 16) : bounds.width - 16,
                                   height: detailHeight(rowWidth: bounds.width))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    func restyle() { needsDisplay = true; updateColors() }

    override func updateLayer() { updateColors() }

    private func updateColors() {
        let e = owner.entry(index)
        let highlighted = owner.highlightedIndex == index
        switch e.kind {
        case .separator:
            line?.backgroundColor = Themed.color(\.contrastBorder).cgColor(in: self)
        case .label:
            title.color = Themed.color(\.contrastMutedForeground)
        case .option:
            let checked = Themed.color(\.contrastForeground, 0.08), accent = Themed.color(\.accent)
            // Menus: the highlighted fill beats the checked one. Selects: the selected rule wins.
            let color: NSColor? = owner.style == .menu
                ? (highlighted ? accent : (e.checked ? checked : nil))
                : (e.checked ? checked : (highlighted ? accent : nil))
            fill.backgroundColor = color?.cgColor(in: self)
            title.color = highlighted ? Themed.color(\.contrastAccentForeground) : Themed.color(\.contrastForeground)
            icon?.strokeColor = Themed.color(\.contrastMutedForeground)
            detail?.color = Themed.color(\.contrastMutedForeground, owner.style == .menu ? 0.8 : 1)
        }
    }
}
