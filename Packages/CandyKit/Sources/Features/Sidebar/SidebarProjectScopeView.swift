import AppKit
import DesignSystem
import T3Store

/// The project scope picker's popup (Sidebar.tsx:4990-5122): a `ComboboxPopup` anchored to the search
/// field, at least as wide as it and at most 18rem, holding `ComboboxSearchInput` ("Search projects...")
/// and the list: "All projects" with a folder icon, then every project group with its favicon, label
/// and a settings button. Typing filters by label (base-ui's `contains`) and drops "All projects";
/// `autoHighlight` puts the highlight on the first match while filtering. Focus stays in the input.
final class SidebarProjectScopeView: DSView, PickerPopupBody {
    struct Item: Equatable {
        /// nil for "All projects".
        var key: String?
        var label: String
        var projectTitle: String?
        var projectIcon: ProjectIconSource? = nil
        /// `ProjectEnvironmentBadge`: a remote member's machine and its "On" or "Also on" text.
        var badge: Badge? = nil
    }

    struct Badge: Equatable { var machine: String; var description: String }

    static let maxWidth: CGFloat = 288, searchHeight: CGFloat = 43, maxHeight: CGFloat = 368

    let items: [Item]
    let selectedKey: String?
    let minimumWidth: CGFloat
    private(set) var shown: [Item]
    private(set) var query = ""
    var highlighted: Int? { didSet { if highlighted != oldValue { rows.forEach { $0.restyle() }; scrollToHighlight() } } }

    var onSelect: (@MainActor (String?) -> Void)?
    var onSettings: (@MainActor (String) -> Void)?

    let search = InputView(placeholder: "Search projects...", size: .sm)
    private let searchIcon = IconView(name: .search, size: 16)
    private let underline = CALayer()
    private let list = DSView()
    private let emptyLabel = LabelView("No matching projects.", font: DSFont.ui(14))
    private var rows: [ScopeRowView] = []
    private var scrollOffset: CGFloat = 0

    init(groups: [SidebarModel.ProjectGroup], selectedKey: String?, minimumWidth: CGFloat,
         environments: SidebarEnvironments = SidebarEnvironments()) {
        // Badges only while the projects span environments (Sidebar.tsx:2608-2611).
        let badges = SidebarEnvironments.span(groups)
        items = [Item(key: nil, label: "All projects")] + groups.map { group in
            Item(key: group.key, label: group.label, projectTitle: group.representative.title,
                 projectIcon: ProjectIconSource(group.representative),
                 badge: badges ? environments.badge(group).map { Badge(machine: $0.machine, description: $0.description) } : nil)
        }
        // `selectedProjectScopeItem` falls back to "All projects" when the key's group is gone.
        self.selectedKey = groups.contains { $0.key == selectedKey } ? selectedKey : nil
        self.minimumWidth = minimumWidth
        shown = items
        super.init(frame: .zero)
        clipsToBounds = true
        underline.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(underline)
        list.clipsToBounds = true
        addSubview(list)
        search.unstyled = true
        search.paddingOverride = (20, 0)
        search.setAccessibilityLabel("Search projects")
        search.onChange = { [weak self] text in self?.setQuery(text) }
        search.onStateChange = { [weak self] _ in self?.needsDisplay = true }
        addSubview(search)
        addSubview(searchIcon)
        emptyLabel.lineHeight = 20
        emptyLabel.alignment = .center
        list.addSubview(emptyLabel)
        reload()
    }

    /// `filterSidebarProjectScopeItems` (Sidebar.logic.ts:1113-1121).
    static func filter(_ items: [Item], query: String) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { $0.key != nil && $0.label.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    func setQuery(_ text: String) {
        query = text
        shown = Self.filter(items, query: text)
        scrollOffset = 0
        reload()
        highlighted = query.trimmingCharacters(in: .whitespaces).isEmpty || shown.isEmpty ? nil : 0
        resizePopup()
    }

    private func reload() {
        rows.forEach { $0.removeFromSuperview() }
        rows = shown.indices.map { i in
            let row = ScopeRowView(item: shown[i], selected: shown[i].key == selectedKey)
            row.isHighlighted = { [weak self] in self?.highlighted == i }
            row.onHover = { [weak self] in self?.highlighted = i }
            row.action = { [weak self] in self?.choose(i) }
            row.onSettings = { [weak self] key in self?.onSettings?(key) }
            list.addSubview(row)
            return row
        }
        emptyLabel.isHidden = !shown.isEmpty
        if let h = highlighted, h >= rows.count { highlighted = nil }
        needsLayout = true
    }

    private func choose(_ i: Int) {
        guard shown.indices.contains(i) else { return }
        onSelect?(shown[i].key)
    }

    // MARK: Size and layout

    private var listHeight: CGFloat { shown.isEmpty ? 36 : rows.reduce(0) { $0 + $1.height } + 8 }

    /// `min-w-(--anchor-width) max-w-[min(18rem,var(--available-width))]`, sized to the widest row.
    var naturalSize: CGSize {
        let widest = rows.map(\.naturalWidth).max() ?? 0
        let width = max(minimumWidth - 2, min(Self.maxWidth - 2, widest + 8))
        return CGSize(width: ceil(width), height: min(Self.maxHeight - 2, Self.searchHeight + listHeight))
    }

    private func resizePopup() {
        guard let popupView = superview?.superview as? PickerPopupView, let host = popupView.superview?.superview as? PopupHost,
              let popup = host.popups.first(where: { $0.content === popupView }) else { return }
        host.reposition(popup)
    }

    override func layout() {
        super.layout()
        // `px-3 pt-2.5`, the inner block lifted 1pt, a 26pt input with 20pt start padding, `pb-1.5 border-b`.
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
        guard let i = highlighted, list.bounds.height > 0 else { return }
        guard i < rows.count else { return }
        let top = 4 + rows[..<i].reduce(0) { $0 + $1.height }, bottom = top + rows[i].height
        if top - 4 < scrollOffset { scrollOffset = top - 4 } else if bottom + 4 > scrollOffset + list.bounds.height { scrollOffset = bottom + 4 - list.bounds.height }
        needsLayout = true
    }

    override func scrollWheel(with event: NSEvent) {
        scrollOffset = min(max(0, scrollOffset - event.scrollingDeltaY), maxScroll)
        needsLayout = true
    }

    override func updateLayer() {
        underline.backgroundColor = (search.state.focused ? Themed.color(\.ring) : Themed.color(\.border, 0.7)).cgColor(in: self)
        searchIcon.strokeColor = Themed.color(\.contrastMutedForeground, 0.55)
        emptyLabel.color = Themed.color(\.contrastMutedForeground)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        rows.forEach { $0.restyle() }
    }

    // MARK: Keyboard (base-ui Combobox: arrows wrap, Enter picks, Escape closes through the host)

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

/// `ComboboxItem` with `hideIndicator` (combobox.tsx:186-212): `min-h-7 px-2 py-1 rounded-sm text-sm`, content
/// `gap-2`. Selected `bg-foreground/8`, highlighted `bg-accent text-accent-foreground`. Project rows end in a
/// ghost-muted `icon-xs` settings button (`ml-auto`, `size-3.5` icon).
final class ScopeRowView: ControlView {
    let item: SidebarProjectScopeView.Item
    let selected: Bool
    private let fill = CALayer()
    private let folder = IconView(name: .folder, size: 16)
    private let monogram = ProjectMonogramView()
    private let label = LabelView()
    private let badge: EnvironmentMachineGlyphView?
    private let settings: ButtonView?
    var isHighlighted: () -> Bool = { false }
    var onHover: (@MainActor () -> Void)?
    var onSettings: (@MainActor (String) -> Void)?

    init(item: SidebarProjectScopeView.Item, selected: Bool) {
        self.item = item
        self.selected = selected
        settings = item.key == nil ? nil : ButtonView(nil, icon: .settings, variant: .ghostMuted, size: .iconXs)
        badge = item.badge.map { _ in EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 14, height: 14)) }
        super.init(frame: .zero)
        scalesWhenPressed = false
        fill.cornerRadius = 6
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        if item.key == nil { addSubview(folder) } else { addSubview(monogram); monogram.projectTitle = item.projectTitle ?? item.label; monogram.source = item.projectIcon }
        label.text = item.label
        label.font = DSFont.ui(14)
        label.lineHeight = 20
        addSubview(label)
        if let badge, let info = item.badge {
            badge.kind = info.machine
            badge.toolTip = info.description
            badge.setAccessibilityElement(true)
            badge.setAccessibilityRole(.image)
            badge.setAccessibilityLabel(info.description)
            addSubview(badge)
        }
        if let settings, let key = item.key {
            settings.iconSize = 14
            settings.toolTip = "Project settings for \(item.label)"
            settings.setAccessibilityElement(false)
            settings.action = { [weak self] in self?.onSettings?(key) }
            addSubview(settings)
        }
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.label)
        restyle()
    }

    var naturalWidth: CGFloat { 16 + 16 + 8 + ceil(label.textWidth) + (badge == nil ? 0 : 8 + 14) + (settings == nil ? 0 : 8 + 24) }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if state.hovered && !old.hovered { onHover?() }
        restyle()
    }

    /// `py-1` around the 24pt settings button makes project rows 32pt; "All projects" stays at `min-h-7`.
    var height: CGFloat { settings == nil ? 28 : 32 }

    func restyle() {
        needsDisplay = true
        applyColors()
    }

    // Colors resolve again at display time, under the appearance the row finally draws in.
    override func updateLayer() { applyColors() }

    private func applyColors() {
        let lit = isHighlighted()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = lit ? Themed.color(\.accent).cgColor(in: self)
            : selected ? Themed.color(\.contrastForeground, 0.08).cgColor(in: self) : nil
        CATransaction.commit()
        label.color = lit ? Themed.color(\.contrastAccentForeground) : Themed.color(\.contrastForeground)
        folder.strokeColor = Themed.color(\.contrastMutedForeground)
        badge?.color = Themed.color(\.contrastMutedForeground)
        setAccessibilitySelected(selected)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        fill.frame = bounds
        folder.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        monogram.frame = folder.frame
        var right = bounds.width - 8
        if let settings { settings.frame = NSRect(x: right - 24, y: (h - 24) / 2, width: 24, height: 24); right -= 24 + 8 }
        if let badge { badge.frame = NSRect(x: right - 14, y: (h - 14) / 2, width: 14, height: 14); right -= 14 + 8 }
        label.frame = NSRect(x: 32, y: (h - 20) / 2, width: max(0, right - 32), height: 20)
    }
}
