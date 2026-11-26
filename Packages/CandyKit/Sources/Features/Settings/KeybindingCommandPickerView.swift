import AppKit
import DesignSystem

/// The add-keybinding "Command" combobox's popup (`NewKeybindingCommandSelect`, KeybindingsSettings.tsx:1246-1320,
/// T3 5258, #28612): `ComboboxPopup className="w-96"` with `ComboboxSearchInput` ("Search"), "No results found."
/// and one `ComboboxItem` per command, its label on the left and its current shortcuts stacked on the right
/// (`flex shrink-0 flex-col items-end gap-1`). Typing filters by id and label; `autoHighlight` keeps the
/// highlight on the first match. The search header matches `SidebarProjectScopeView`'s `ComboboxSearchInput`.
final class KeybindingCommandPickerView: DSView, PickerPopupBody {
    static let width: CGFloat = 384, searchHeight: CGFloat = 43, maxHeight: CGFloat = 368

    let search = InputView(placeholder: "Search", size: .sm)
    private let searchIcon = IconView(name: .search, size: 16)
    private let underline = CALayer()
    private let list = DSView()
    private let emptyLabel = LabelView("No results found.", font: DSFont.ui(14))
    private let commands: [String]
    private let shortcuts: [String: [String]]
    private let selected: String?
    private(set) var shown: [String] = []
    private var rows: [CommandRow] = []
    private var scrollOffset: CGFloat = 0
    var highlighted: Int? { didSet { if highlighted != oldValue { rows.forEach { $0.needsDisplay = true }; scrollToHighlight() } } }
    var onPick: (@MainActor (String) -> Void)?

    init(commands: [String], shortcuts: [String: [String]], selected: String?) {
        self.commands = commands
        self.shortcuts = shortcuts
        self.selected = selected
        super.init(frame: .zero)
        underline.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(underline)
        search.unstyled = true
        search.paddingOverride = (20, 0)
        search.setAccessibilityLabel("Search")
        search.onChange = { [weak self] _ in self?.reload() }
        search.onStateChange = { [weak self] _ in self?.needsDisplay = true }
        addSubview(search)
        addSubview(searchIcon)
        emptyLabel.lineHeight = 20
        emptyLabel.alignment = .center
        list.addSubview(emptyLabel)
        list.layer?.masksToBounds = true
        addSubview(list)
        reload()
        highlighted = selected.flatMap { shown.firstIndex(of: $0) } ?? (shown.isEmpty ? nil : 0)
    }

    private func reload() {
        shown = commands.filter { KeybindingsLogic.commandMatches($0, query: search.text) }
        rows.forEach { $0.removeFromSuperview() }
        rows = shown.indices.map { i in
            let row = CommandRow(command: shown[i], shortcuts: shortcuts[shown[i]] ?? [], selected: shown[i] == selected)
            row.isHighlighted = { [weak self] in self?.highlighted == i }
            row.onHover = { [weak self] in self?.highlighted = i }
            row.onClick = { [weak self] in self?.choose(i) }
            list.addSubview(row)
            return row
        }
        emptyLabel.isHidden = !shown.isEmpty
        scrollOffset = 0
        highlighted = shown.isEmpty ? nil : 0
        rows.forEach { $0.needsDisplay = true }
        needsLayout = true
        if let popupView = superview?.superview as? PickerPopupView, let host = popupView.superview?.superview as? PopupHost,
           let popup = host.popups.first(where: { $0.content === popupView }) { host.reposition(popup) }
    }

    private func choose(_ i: Int) {
        guard shown.indices.contains(i) else { return }
        onPick?(shown[i])
    }

    private var listHeight: CGFloat { shown.isEmpty ? 36 : rows.reduce(0) { $0 + $1.height } + 8 }

    var naturalSize: CGSize { CGSize(width: Self.width - 2, height: min(Self.maxHeight - 2, Self.searchHeight + listHeight)) }

    override func layout() {
        super.layout()
        let contentW = bounds.width - 24
        search.frame = NSRect(x: 12, y: 9, width: contentW, height: 26)
        searchIcon.frame = NSRect(x: 12, y: 15, width: 16, height: 16)
        underline.frame = CGRect(x: 12, y: 41, width: contentW, height: 1)
        list.frame = NSRect(x: 0, y: Self.searchHeight, width: bounds.width, height: max(0, bounds.height - Self.searchHeight))
        scrollOffset = min(scrollOffset, maxScroll)
        var y = 4 - scrollOffset
        for row in rows {
            row.frame = NSRect(x: 4, y: y, width: list.bounds.width - 8, height: row.height)
            y += row.height
        }
        emptyLabel.frame = NSRect(x: 8, y: 8, width: list.bounds.width - 16, height: 20)
    }


    private var maxScroll: CGFloat { max(0, listHeight - list.bounds.height) }

    private func scrollToHighlight() {
        guard let i = highlighted, i < rows.count, list.bounds.height > 0 else { return }
        let top = 4 + rows[..<i].reduce(0) { $0 + $1.height }, bottom = top + rows[i].height
        if top - 4 < scrollOffset { scrollOffset = top - 4 } else if bottom + 4 > scrollOffset + list.bounds.height { scrollOffset = bottom + 4 - list.bounds.height }
        needsLayout = true
    }

    override func scrollWheel(with event: NSEvent) {
        scrollOffset = min(max(0, scrollOffset - event.scrollPointsY), maxScroll)
        needsLayout = true
    }

    override func updateLayer() {
        underline.backgroundColor = (search.state.focused ? Themed.color(\.ring) : Themed.color(\.border, 0.7)).cgColor(in: self)
        searchIcon.strokeColor = Themed.color(\.contrastMutedForeground, 0.55)
        emptyLabel.color = Themed.color(\.contrastMutedForeground)
    }

    func handleKey(_ key: PopupKey) -> Bool {
        switch key {
        case .down, .up:
            guard !rows.isEmpty else { return true }
            let n = rows.count
            if let h = highlighted { highlighted = (h + (key == .down ? 1 : -1) + n) % n } else { highlighted = key == .down ? 0 : n - 1 }
            return true
        case .enter:
            if let h = highlighted { choose(h) }
            return true
        default:
            return false
        }
    }
}

/// `ComboboxItem` (combobox.tsx:188-217): `min-h-7 px-2 py-1 rounded-sm text-sm`, selected `bg-foreground/6`,
/// hovered or highlighted `bg-foreground/9`. Its content is `justify-between gap-3`.
private final class CommandRow: DSView {
    let command: String
    private let label: LabelView
    private let keys: [KbdView]
    private let selected: Bool
    var isHighlighted: () -> Bool = { false }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?

    init(command: String, shortcuts: [String], selected: Bool) {
        self.command = command
        self.selected = selected
        label = LabelView(KeybindingsLogic.commandLabel(command), font: DSFont.ui(14), color: Themed.color(\.foreground))
        label.lineHeight = 20
        keys = shortcuts.map { KbdView($0) }
        super.init(frame: .zero)
        addSubview(label)
        keys.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(label.text)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    var height: CGFloat {
        guard !keys.isEmpty else { return 28 }
        return max(28, 8 + CGFloat(keys.count) * 20 + CGFloat(keys.count - 1) * 4)
    }


    override func layout() {
        super.layout()
        var y: CGFloat = 4
        var keysW: CGFloat = 0
        for k in keys {
            let s = k.intrinsicContentSize
            k.frame = NSRect(x: bounds.width - 8 - s.width, y: y, width: s.width, height: s.height)
            keysW = max(keysW, s.width)
            y += s.height + 4
        }
        let lw = bounds.width - 16 - (keys.isEmpty ? 0 : keysW + 12)
        label.frame = NSRect(x: 8, y: (bounds.height - 20) / 2, width: max(0, lw), height: 20)
    }

    override func updateLayer() {
        layer?.cornerRadius = 4
        let fill: NSColor? = isHighlighted() ? Themed.color(\.foreground, 0.09) : selected ? Themed.color(\.foreground, 0.06) : nil
        layer?.backgroundColor = fill?.cgColor(in: self)
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { if !isHighlighted() { onHover?() } }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func mouseDown(with event: NSEvent) {}
}
