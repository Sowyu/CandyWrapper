import AppKit
import DesignSystem
import T3Protocol
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
        var pinned = false
        /// `canPinProjectGroup`: every member's server keeps pins and this connection may change it.
        var canPin = false
    }

    struct Badge: Equatable { var machine: String; var description: String }

    static let maxWidth: CGFloat = 288, searchHeight: CGFloat = 43, maxHeight: CGFloat = 368

    private(set) var selectedKeys: Set<String> = []
    var selectedKey: String? { selectedKeys.first }
    let minimumWidth: CGFloat
    private(set) var shown: [Item]
    private(set) var query = ""
    var highlighted: Int? { didSet { if highlighted != oldValue { rows.forEach { $0.restyle() }; scrollToHighlight() } } }

    var onSelect: (@MainActor (String?) -> Void)?
    var onSettings: (@MainActor (String) -> Void)?
    /// A row's pin button or the pin shortcut: the group's key and whether it should now be pinned.
    var onTogglePin: (@MainActor (String, Bool) -> Void)?

    let search = InputView(placeholder: "Search projects...", size: .sm)
    private let searchIcon = IconView(name: .search, size: 16)
    private let underline = CALayer()
    private let list = DSView()
    private let emptyLabel = LabelView("No matching projects.", font: DSFont.ui(14))
    private var rows: [ScopeRowView] = []
    private var scrollOffset: CGFloat = 0

    /// The row with no project: the sidebar's leading "All projects", or the draft picker's trailing "Add project"
    /// (DraftHeroHeadline.tsx:184-190 in 2994), which has no settings buttons and is never the selection.
    enum Extra { case allProjects, addProject }
    let extra: Extra
    /// The rows in the order they had when the popup opened; pinning from a row keeps them in place
    /// (`useOrderWhileOpen`, Sidebar.tsx at 4928).
    private(set) var items: [Item]

    init(groups: [SidebarModel.ProjectGroup], selectedKey: String?, minimumWidth: CGFloat,
         environments: SidebarEnvironments = SidebarEnvironments(), extra: Extra = .allProjects, selectedKeys: [String]? = nil,
         canPin: (SidebarModel.ProjectGroup) -> Bool = { _ in false }) {
        self.extra = extra
        // Archived projects leave the picker and pinned ones lead it (`pickableProjectGroups`, #26154).
        let groups = ProjectOrganization.pickable(groups)
        // Badges only while the projects span environments (Sidebar.tsx:2608-2611).
        let badges = SidebarEnvironments.span(groups)
        let projects = groups.map { group in
            Item(key: group.key, label: group.label, projectTitle: group.representative.title,
                 projectIcon: ProjectIconSource(group.representative),
                 badge: badges ? environments.badge(group).map { Badge(machine: $0.machine, description: $0.description) } : nil,
                 pinned: group.pinned, canPin: canPin(group))
        }
        items = extra == .allProjects ? [Item(key: nil, label: "All projects")] + projects : projects + [Item(key: nil, label: "Add project")]
        // `selectedProjectScopeItem` falls back to "All projects" when the key's group is gone; an archived
        // project's scope reads as all projects.
        self.selectedKeys = Set((selectedKeys ?? selectedKey.map { [$0] } ?? []).filter { key in groups.contains { $0.key == key } })
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
            let row = ScopeRowView(item: shown[i], selected: (shown[i].key.map { selectedKeys.contains($0) } ?? (selectedKeys.isEmpty && extra == .allProjects)),
                                   extra: extra)
            row.isHighlighted = { [weak self] in self?.highlighted == i }
            row.onHover = { [weak self] in self?.highlighted = i }
            row.action = { [weak self] in self?.choose(i) }
            row.onSettings = { [weak self] key in self?.onSettings?(key) }
            row.onTogglePin = { [weak self] key in self?.togglePin(key) }
            list.addSubview(row)
            return row
        }
        emptyLabel.isHidden = !shown.isEmpty
        if let h = highlighted, h >= rows.count { highlighted = nil }
        needsLayout = true
    }

    /// The open project picker the pin shortcut works on (`isProjectPinShortcut`, ProjectPinButton.tsx:11-22 at 4928).
    fileprivate static weak var open: SidebarProjectScopeView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.open = self } else if Self.open === self { Self.open = nil }
    }

    /// Flips a row's pin in place and asks the owner to write it.
    func togglePin(_ key: String) {
        guard let i = items.firstIndex(where: { $0.key == key }), items[i].canPin else { return }
        items[i].pinned.toggle()
        let pinned = items[i].pinned
        shown = Self.filter(items, query: query)
        reload()
        onTogglePin?(key, pinned)
    }

    private func choose(_ i: Int) {
        guard shown.indices.contains(i) else { return }
        let key = shown[i].key
        if extra == .allProjects {
            if let key { if !selectedKeys.insert(key).inserted { selectedKeys.remove(key) } } else { selectedKeys.removeAll() }
            reload()
        }
        onSelect?(key)
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
        scrollOffset = min(max(0, scrollOffset - event.scrollPointsY), maxScroll)
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
/// `gap-2`. Selected `bg-foreground/8`, highlighted `bg-accent text-accent-foreground`. In the sidebar a project row
/// is the favicon, the label, the machine badge, then `ProjectRowActions` at the end: the settings button, shown on
/// the highlighted row, and the pin column, which keeps its 24pt whether or not the project can pin, so rows line up
/// and "All projects" is as tall as the rest (Sidebar.tsx:3120-3190, ProjectComboboxRow.tsx, #29639, #29704). The
/// draft picker's rows end in the pin, then the badge (DraftHeroHeadline.tsx:276-307).
final class ScopeRowView: ControlView {
    let item: SidebarProjectScopeView.Item
    let selected: Bool
    private let fill = CALayer()
    private let selectedMark = IconView(name: .check, size: 8, strokeColor: Themed.color(\.primaryForeground))
    private let selectedCircle = CALayer()
    private let folder: IconView
    private let monogram = ProjectMonogramView()
    private let label = LabelView()
    private let badge: EnvironmentMachineGlyphView?
    private let settings: ButtonView?
    private let pin: ProjectPinSlot?
    /// The sidebar's `ProjectRowActions` column: a pin slot on every row, kept even when there is no pin.
    private let actionsColumn: Bool
    /// A plain choice (Settled's range picker): its own glyph, and a check at the right on the current one.
    private let check: IconView?
    var isHighlighted: () -> Bool = { false }
    var onHover: (@MainActor () -> Void)?
    var onSettings: (@MainActor (String) -> Void)?
    var onTogglePin: (@MainActor (String) -> Void)?

    init(item: SidebarProjectScopeView.Item, selected: Bool, extra: SidebarProjectScopeView.Extra = .allProjects, icon: IconName? = nil) {
        self.item = item
        self.selected = selected
        folder = IconView(name: icon ?? (extra == .allProjects ? .folder : .folderPlus), size: 16)
        settings = item.key == nil || extra == .addProject || icon != nil ? nil : ButtonView(nil, icon: .settings, variant: .ghostMuted, size: .iconXs)
        pin = item.key != nil && item.canPin && icon == nil ? ProjectPinSlot(name: item.label, pinned: item.pinned) : nil
        actionsColumn = extra == .allProjects && icon == nil
        check = icon == nil ? nil : IconView(name: .check, size: 14)
        badge = item.badge.map { _ in EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 14, height: 14)) }
        super.init(frame: .zero)
        scalesWhenPressed = false
        fill.cornerRadius = 6
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        selectedCircle.actions = ["backgroundColor": NSNull(), "borderColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        selectedMark.strokeWidth = 4
        if let check { addSubview(check); check.isHidden = !selected }
        if item.key == nil || check != nil { addSubview(folder) } else { addSubview(monogram); monogram.projectTitle = item.projectTitle ?? item.label; monogram.source = item.projectIcon }
        label.text = item.label
        label.font = DSFont.ui(14)
        label.lineHeight = 20
        addSubview(label)
        if let badge, let info = item.badge {
            badge.kind = info.machine
            badge.setTooltip(info.description)
            badge.setAccessibilityElement(true)
            badge.setAccessibilityRole(.image)
            badge.setAccessibilityLabel(info.description)
            addSubview(badge)
        }
        if let settings, let key = item.key {
            settings.iconSize = 14
            settings.setTooltip("Project settings for \(item.label)")
            settings.setAccessibilityElement(false)
            settings.action = { [weak self] in self?.onSettings?(key) }
            addSubview(settings)
        }
        if let pin, let key = item.key {
            pin.onToggle = { [weak self] in self?.onTogglePin?(key) }
            addSubview(pin)
        }
        layer?.addSublayer(selectedCircle)
        addSubview(selectedMark)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.label)
        restyle()
    }

    var naturalWidth: CGFloat {
        let actions: CGFloat = actionsColumn ? (settings == nil ? 24 : 48) : (pin == nil ? 0 : 24) + (check == nil ? 0 : 14)
        return 16 + 16 + 8 + ceil(label.textWidth) + (badge == nil ? 0 : 8 + 14) + (actions == 0 ? 0 : 8 + actions)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if state.hovered && !old.hovered { onHover?() }
        restyle()
    }

    /// `py-1` around the 24pt actions makes rows 32pt; a draft picker row with no pin stays at `min-h-7`.
    var height: CGFloat { actionsColumn || pin != nil ? 32 : 28 }

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
        let classic = DesignGeometry.usesClassic(self)
        fill.cornerRadius = DesignGeometry.radius(6, in: self)
        fill.backgroundColor = lit ? (classic ? Themed.color(\.accent) : Themed.color(\.contrastForeground, 0.09)).cgColor(in: self)
            : selected ? Themed.color(\.contrastForeground, classic ? 0.08 : 0.06).cgColor(in: self) : nil
        selectedCircle.isHidden = classic || !selected
        selectedMark.isHidden = classic || !selected
        selectedCircle.backgroundColor = Themed.color(\.primary).cgColor(in: self)
        selectedCircle.borderColor = Themed.color(\.popover).cgColor(in: self)
        selectedCircle.borderWidth = 2
        selectedCircle.cornerRadius = 8
        CATransaction.commit()
        label.color = lit ? Themed.color(\.contrastAccentForeground) : Themed.color(\.contrastForeground)
        // `pointer-fine:invisible pointer-fine:in-data-highlighted:visible`; an unpinned pin is `opacity-0` off the highlight.
        settings?.isHidden = !lit
        pin?.revealed = lit
        folder.strokeColor = Themed.color(\.contrastMutedForeground)
        check?.strokeColor = lit ? Themed.color(\.contrastAccentForeground) : Themed.color(\.contrastForeground)
        if check != nil { selectedCircle.isHidden = true; selectedMark.isHidden = true }
        badge?.color = Themed.color(\.contrastMutedForeground)
        setAccessibilitySelected(selected)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        fill.frame = bounds
        folder.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        monogram.frame = folder.frame
        selectedCircle.frame = CGRect(x: 14, y: (h - 16) / 2 + 6, width: 16, height: 16)
        selectedMark.frame = CGRect(x: 18, y: (h - 16) / 2 + 10, width: 8, height: 8)
        var right = bounds.width - 8
        let y24 = (h - 24) / 2
        if actionsColumn {
            // `ml-auto flex`: settings, then the pin or its `size-6` stand-in.
            pin?.frame = NSRect(x: right - 24, y: y24, width: 24, height: 24)
            right -= 24
            if let settings { settings.frame = NSRect(x: right - 24, y: y24, width: 24, height: 24); right -= 24 }
            right -= 8
            // The label is `min-w-0 truncate` and the badge follows it (`gap-2`).
            let badgeRoom: CGFloat = badge == nil ? 0 : 8 + 14
            let labelW = max(0, min(ceil(label.textWidth), right - 32 - badgeRoom))
            label.frame = NSRect(x: 32, y: (h - 20) / 2, width: labelW, height: 20)
            badge?.frame = NSRect(x: 32 + labelW + 8, y: (h - 14) / 2, width: 14, height: 14)
            return
        }
        if let check { check.frame = NSRect(x: right - 14, y: (h - 14) / 2, width: 14, height: 14); right -= 14 + 8 }
        if let badge { badge.frame = NSRect(x: right - 14, y: (h - 14) / 2, width: 14, height: 14); right -= 14 + 8 }
        if let pin { pin.frame = NSRect(x: right - 24, y: y24, width: 24, height: 24); right -= 24 + 8 }
        label.frame = NSRect(x: 32, y: (h - 20) / 2, width: max(0, right - 32), height: 20)
    }
}

/// `ProjectPinButton` (ProjectPinButton.tsx:24-73): a ghost-muted `icon-xs` button with a 14pt pin. A pinned project
/// always shows it and turns it to pin-off under the pointer (`group-hover/pin`); an unpinned one shows it only on the
/// highlighted row. It stays out of the tab order and keeps the press from choosing the row.
final class ProjectPinSlot: DSView {
    let button = ButtonView(nil, icon: .pin, variant: .ghostMuted, size: .iconXs)
    let pinned: Bool
    var onToggle: (@MainActor () -> Void)?
    /// The row is highlighted.
    var revealed = false { didSet { if revealed != oldValue { sync() } } }
    private(set) var hovered = false { didSet { if hovered != oldValue { sync() } } }
    private var area: NSTrackingArea?

    init(name: String, pinned: Bool) {
        self.pinned = pinned
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.iconSize = 14
        // `{action} ({shortcut})` with the thread pin shortcut, which pins the highlighted row (ProjectPinButton.tsx:36-55).
        let action = pinned ? "Unpin \(name)" : "Pin \(name)"
        button.setTooltip(action, shortcut: ActiveKeymap.label(for: "thread.pin", context: KeybindingContext(["editableFocus": true])))
        button.setAccessibilityElement(false)
        button.action = { [weak self] in self?.onToggle?() }
        addSubview(button)
        sync()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func sync() {
        button.icon = pinned && hovered ? .pinOff : .pin
        button.alphaValue = pinned || revealed ? 1 : 0
    }

    override func layout() {
        super.layout()
        button.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    // A row rebuilt or a popup closed under a still pointer, or the window losing focus, ends the hover.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { hovered = false }
    }
}

/// The thread pin shortcut (Mod+Shift+P) inside an open project picker pins its highlighted row instead of the open
/// thread (DraftHeroHeadline.tsx:262-271 and Sidebar.tsx's project combobox at 4928).
@MainActor
public enum ProjectPickerPinShortcut {
    /// True when an open picker took the key.
    public static func run() -> Bool {
        guard let view = SidebarProjectScopeView.open, view.window != nil, let h = view.highlighted,
              view.shown.indices.contains(h), view.shown[h].canPin, let key = view.shown[h].key else { return false }
        view.togglePin(key)
        return true
    }
}
