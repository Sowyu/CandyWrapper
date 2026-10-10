import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// T3's model picker popover body (chat/ModelPickerContent.tsx, ModelPickerSidebar.tsx,
/// ModelListRow.tsx): a 44pt provider rail with Favorites, a search field and the model list.
/// 360 wide, at most 346 tall. Spec: docs/research/J-composer-visuals.md 8.1, reference 13.
final class ModelPickerView: DSView, PickerPopupBody {
    static let width: CGFloat = 360, maxHeight: CGFloat = 346, railWidth: CGFloat = 44
    static let searchHeight: CGFloat = 43, rowHeight: CGFloat = 45, rowGap: CGFloat = 2

    var catalog: ProviderCatalog { didSet { reload() } }
    var favorites: [ModelFavorite] { didSet { reload() } }
    let active: ProviderInstanceId
    let activeModel: String
    private(set) var rail: ModelPickerRail
    private(set) var query = ""
    private var expandedLegacy: Set<ProviderInstanceId> = []
    private(set) var sections: ModelPickerSections
    /// Keyboard highlight in the list (`data-highlighted`).
    var highlightedRow: Int? { didSet { if highlightedRow != oldValue { rowViews.forEach { $0.restyle() }; scrollToHighlight() } } }
    /// Keyboard focus in the rail (index into `railButtons`), nil while the search field has it.
    private(set) var railFocus: Int? { didSet { railButtons.forEach { $0.restyle() } } }

    var onSelect: (@MainActor (ProviderInstanceId, String) -> Void)?
    var onToggleFavorite: (@MainActor (ProviderInstanceId, String) -> Void)?

    let search = InputView(placeholder: "Search models...", size: .sm)
    private let railFill = CALayer()
    private let mainFill = CALayer()
    private let mainBorder = CALayer()
    private let divider = CALayer()
    private let indicator = CALayer()
    private let underline = CALayer()
    private let searchIcon = IconView(name: .search, size: 16)
    private let list = DSView()
    private let emptyLabel = LabelView("No models found", font: DSFont.ui(14))
    private let favoritesButton: RailButtonView
    private var railButtons: [RailButtonView] = []
    private(set) var rowViews: [ModelRowView] = []
    private var scrollOffset: CGFloat = 0
    /// While searching the height stays at what it was when typing started.
    private var frozenHeight: CGFloat?
    private var tracking: NSTrackingArea?

    init(catalog: ProviderCatalog, favorites: [ModelFavorite], active: ProviderInstanceId, activeModel: String) {
        self.catalog = catalog
        self.favorites = favorites
        self.active = active
        self.activeModel = activeModel
        rail = ModelPickerSections.initialRail(active: active, favorites: favorites, catalog: catalog)
        if let model = catalog.entry(active)?.model(activeModel), model.isLegacy == true { expandedLegacy = [active] }
        sections = ModelPickerSections(catalog: catalog, active: active, activeModel: activeModel, favorites: favorites,
                                       rail: rail, query: "", expandedLegacy: expandedLegacy)
        favoritesButton = RailButtonView(kind: .favorites)
        super.init(frame: .zero)
        clipsToBounds = true
        for l in [railFill, mainFill, mainBorder, divider, indicator, underline] {
            l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
        }
        indicator.cornerRadius = 1.5
        indicator.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        list.clipsToBounds = true
        addSubview(list)
        search.unstyled = true
        search.paddingOverride = (20, 0)
        search.onChange = { [weak self] text in self?.setQuery(text) }
        search.onStateChange = { [weak self] _ in self?.needsDisplay = true }
        addSubview(search)
        addSubview(searchIcon)
        emptyLabel.lineHeight = 20
        emptyLabel.smoothsFont = false
        emptyLabel.alignment = .center
        list.addSubview(emptyLabel)
        favoritesButton.onPress = { [weak self] in self?.selectRail(.favorites) }
        addSubview(favoritesButton)
        reload()
    }

    // MARK: Model

    private func reload() {
        let visible = catalog.entries.filter(\.isVisibleInPicker)
        if railButtons.map(\.entryId) != visible.map(\.id) {
            railButtons.forEach { $0.removeFromSuperview() }
            railButtons = visible.map { e in
                let b = RailButtonView(kind: .instance(e))
                b.onPress = { [weak self] in self?.selectRail(.instance(e.id)) }
                addSubview(b)
                return b
            }
        }
        sections = ModelPickerSections(catalog: catalog, active: active, activeModel: activeModel, favorites: favorites,
                                       rail: rail, query: query, expandedLegacy: expandedLegacy)
        // ponytail: AppKit tooltips instead of T3's TooltipPopup (left side, 8pt offset, no delay); swap for TooltipView when tooltips get a shared host
        for (b, r) in zip(railButtons, sections.rail) { b.isDisabled = r.isDisabled; b.toolTip = r.tooltip }
        // ponytail: every row is a view, rebuilt on each change (about 15 here); recycle rows like the timeline past ~100 models
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = sections.rows.indices.map { ModelRowView(picker: self, row: sections.rows[$0], index: $0) }
        rowViews.forEach(list.addSubview)
        emptyLabel.isHidden = !sections.rows.isEmpty
        if let h = highlightedRow, h >= rowViews.count { highlightedRow = nil }
        railButtons.forEach { $0.restyle() }
        favoritesButton.restyle()
        needsLayout = true
        needsDisplay = true
    }

    func isRailSelected(_ r: ModelPickerRail) -> Bool { rail == r }
    func isRailFocused(_ b: RailButtonView) -> Bool { railFocus.map { $0 < allRailButtons.count && allRailButtons[$0] === b } ?? false }
    private var allRailButtons: [RailButtonView] { [favoritesButton] + railButtons }

    func selectRail(_ r: ModelPickerRail) {
        rail = r
        query = ""
        search.text = ""
        frozenHeight = nil
        highlightedRow = nil
        scrollOffset = 0
        railFocus = nil
        reload()
        window?.makeFirstResponder(search)
        resizePopup()
    }

    func setQuery(_ text: String) {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { frozenHeight = bounds.height > 0 ? bounds.height : naturalSize.height }
        query = text
        if query.trimmingCharacters(in: .whitespaces).isEmpty { frozenHeight = nil }
        scrollOffset = 0
        railFocus = nil
        reload()
        // `autoHighlight`: the first match is highlighted while filtering.
        highlightedRow = searching && !rowViews.isEmpty ? 0 : nil
        resizePopup()
    }

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func toggleLegacy(_ id: ProviderInstanceId) {
        if expandedLegacy.contains(id) { expandedLegacy.remove(id) } else { expandedLegacy.insert(id) }
        let keep = highlightedRow
        reload()
        highlightedRow = keep
        resizePopup()
    }

    func activate(_ i: Int) {
        guard i < sections.rows.count else { return }
        switch sections.rows[i] {
        case .legacy(let id, _, _): toggleLegacy(id)
        case .model(let item): onSelect?(item.entry.id, item.model.slug)
        }
    }

    func toggleFavorite(_ item: ModelPickerItem) { onToggleFavorite?(item.entry.id, item.model.slug) }

    // MARK: Size and layout

    private var listContentHeight: CGFloat {
        sections.rows.isEmpty ? 0 : CGFloat(sections.rows.count) * Self.rowHeight + CGFloat(sections.rows.count - 1) * Self.rowGap
    }

    /// Search block plus the list (rows + 20) or the empty text (`p-2`, 36).
    var naturalSize: CGSize {
        if let frozenHeight { return CGSize(width: Self.width, height: frozenHeight) }
        let list = sections.rows.isEmpty ? 36 : listContentHeight + 20
        return CGSize(width: Self.width, height: min(Self.maxHeight, Self.searchHeight + list))
    }

    private func resizePopup() {
        guard let popupView = superview?.superview as? PickerPopupView, let host = popupView.superview?.superview as? PopupHost,
              let popup = host.popups.first(where: { $0.content === popupView }) else { return }
        host.reposition(popup)
    }

    override func layout() {
        super.layout()
        let railShown = sections.showsRail
        let mainX = railShown ? Self.railWidth : 0
        railFill.isHidden = !railShown
        railFill.frame = CGRect(x: 0, y: 0, width: Self.railWidth, height: bounds.height)
        mainFill.frame = CGRect(x: mainX, y: 0, width: bounds.width - mainX, height: bounds.height)
        mainBorder.isHidden = !railShown
        mainBorder.frame = CGRect(x: mainX, y: 0, width: 1, height: bounds.height)

        // Rail: `p-1 gap-1`, 36pt buttons, a divider under Favorites.
        favoritesButton.isHidden = !railShown
        favoritesButton.frame = NSRect(x: 4, y: 4, width: 36, height: 36)
        divider.isHidden = !railShown
        divider.frame = CGRect(x: 4, y: 44, width: 36, height: 1)
        for (i, b) in railButtons.enumerated() {
            b.isHidden = !railShown
            b.frame = NSRect(x: 4, y: 49 + CGFloat(i) * 40, width: 36, height: 36)
        }
        let selected = allRailButtons.first { b in
            switch (b.kind, rail) {
            case (.favorites, .favorites): true
            case (.instance(let e), .instance(let id)): e.id == id
            default: false
            }
        }
        indicator.isHidden = !railShown || selected == nil
        if let selected { indicator.frame = CGRect(x: Self.railWidth - 3, y: selected.frame.midY - 10, width: 3, height: 20) }

        // Search: `px-3 pt-2.5`, the inner block lifted 1pt, 26pt input with a 20pt start padding.
        let contentX = mainX + (railShown ? 1 : 0) + 12
        let contentW = bounds.width - contentX - 12
        search.frame = NSRect(x: contentX, y: 9, width: contentW, height: 26)
        searchIcon.frame = NSRect(x: contentX, y: 15, width: 16, height: 16)
        underline.frame = CGRect(x: contentX, y: 41, width: contentW, height: 1)

        // List: `px-1 py-1` plus LegendList `py-1.5 pl-2 pr-px`, 6pt scrollbar gutter, outer `pr-px`.
        list.frame = NSRect(x: mainX + (railShown ? 1 : 0), y: Self.searchHeight, width: bounds.width - mainX - (railShown ? 1 : 0),
                            height: max(0, bounds.height - Self.searchHeight))
        scrollOffset = min(scrollOffset, maxScroll)
        var y = 10 - scrollOffset
        for row in rowViews {
            row.frame = NSRect(x: 12, y: y, width: list.bounds.width - 12 - 12, height: Self.rowHeight)
            y += Self.rowHeight + Self.rowGap
        }
        emptyLabel.frame = NSRect(x: 8, y: 8, width: list.bounds.width - 16, height: 20)
    }

    private var maxScroll: CGFloat { max(0, listContentHeight + 20 - list.bounds.height) }

    private func scrollToHighlight() {
        guard let i = highlightedRow, list.bounds.height > 0 else { return }
        let top = 10 + CGFloat(i) * (Self.rowHeight + Self.rowGap), bottom = top + Self.rowHeight
        if top - 10 < scrollOffset { scrollOffset = top - 10 } else if bottom + 10 > scrollOffset + list.bounds.height { scrollOffset = bottom + 10 - list.bounds.height }
        needsLayout = true
    }

    override func scrollWheel(with event: NSEvent) {
        scrollOffset = min(max(0, scrollOffset - event.scrollingDeltaY), maxScroll)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        rowViews.forEach { $0.restyle() }
        allRailButtons.forEach { $0.restyle() }
    }

    override func updateLayer() {
        railFill.backgroundColor = Themed.color(\.muted, 0.3).cgColor(in: self)
        mainFill.backgroundColor = Themed.color(\.muted, 0.4).cgColor(in: self)
        mainBorder.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
        divider.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
        indicator.backgroundColor = Themed.color(\.primary).cgColor(in: self)
        underline.backgroundColor = (search.state.focused ? Themed.color(\.ring) : Themed.color(\.border, 0.7)).cgColor(in: self)
        searchIcon.strokeColor = Themed.color(\.contrastMutedForeground, 0.55)
        emptyLabel.color = Themed.color(\.contrastMutedForeground)
    }

    // MARK: Keyboard (ModelPickerContent.tsx:921-960, ModelPickerSidebar.tsx:96-103)

    func handleKey(_ key: PopupKey) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags.intersection([.command, .shift, .option, .control]) ?? []
        // `modelPicker.previousProvider` / `nextProvider`: mod+shift+arrowup / arrowdown.
        if flags == [.command, .shift], key == .up || key == .down {
            selectRail(ModelPickerSections.adjacentRail(rail, direction: key == .down ? 1 : -1, catalog: catalog))
            return true
        }
        if let focus = railFocus { return handleRailKey(key, focus: focus) }
        switch key {
        case .down, .up:
            guard !rowViews.isEmpty else { return true }
            let n = rowViews.count
            if let h = highlightedRow { highlightedRow = (h + (key == .down ? 1 : -1) + n) % n } else { highlightedRow = key == .down ? 0 : n - 1 }
            return true
        case .enter:
            if let h = highlightedRow { activate(h) }
            return true
        case .left where query.isEmpty && sections.showsRail, .tab where flags == .shift && sections.showsRail:
            railFocus = allRailButtons.firstIndex { isSelected($0) && !$0.isDisabled } ?? allRailButtons.firstIndex { !$0.isDisabled }
            return true
        default:
            return false
        }
    }

    private func isSelected(_ b: RailButtonView) -> Bool {
        switch (b.kind, rail) {
        case (.favorites, .favorites): true
        case (.instance(let e), .instance(let id)): e.id == id
        default: false
        }
    }

    private func handleRailKey(_ key: PopupKey, focus: Int) -> Bool {
        let enabled = allRailButtons.indices.filter { !allRailButtons[$0].isDisabled }
        switch key {
        case .up, .down:
            if let pos = enabled.firstIndex(of: focus) { railFocus = enabled[(pos + (key == .down ? 1 : -1) + enabled.count) % enabled.count] }
            return true
        case .enter, .space:
            allRailButtons[focus].onPress?()
            return true
        case .right, .tab:
            railFocus = nil
            return true
        case .escape:
            return false
        default:
            railFocus = nil
            return false
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func rowIndex(_ event: NSEvent) -> Int? {
        let p = list.convert(event.locationInWindow, from: nil)
        guard list.bounds.contains(p) else { return nil }
        return rowViews.firstIndex { $0.frame.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) { if let i = rowIndex(event) { highlightedRow = i } }
    override func mouseExited(with event: NSEvent) { highlightedRow = nil }
}

/// One rail button: Favorites (filled 20pt star) or a provider instance (20pt glyph in a 24pt box).
final class RailButtonView: ControlView {
    enum Kind { case favorites, instance(ProviderInstanceEntry) }
    let kind: Kind
    var isDisabled = false { didSet { alphaValue = isDisabled ? 0.5 : 1; window?.invalidateCursorRects(for: self) } }
    final var onPress: (@MainActor () -> Void)?
    private let glyph: NSView
    private let fill = CALayer()

    var entryId: ProviderInstanceId? { if case .instance(let e) = kind { e.id } else { nil } }

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .favorites: glyph = IconView(name: .star, size: 20)
        case .instance(let e): glyph = ProviderIcon.make(driver: e.driver, displayName: e.displayName, size: 20)
        }
        super.init(frame: .zero)
        scalesWhenPressed = false
        fill.cornerRadius = 8
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        addSubview(glyph)
        action = { [weak self] in if self?.isDisabled == false { self?.onPress?() } }
        restyle()
    }

    override var acceptsFirstResponder: Bool { false }
    override func resetCursorRects() { if !isDisabled { addCursorRect(bounds, cursor: .pointingHand) } }

    override func layout() {
        super.layout()
        fill.frame = bounds
        glyph.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    func restyle() {
        if case .favorites = kind, let star = glyph as? IconView {
            star.strokeColor = Themed.color(\.contrastForeground)
            star.fillColor = Themed.color(\.contrastForeground)
        }
        needsDisplay = true
    }

    override func updateLayer() {
        let picker = superview as? ModelPickerView
        let lit = !isDisabled && (state.hovered || picker?.isRailFocused(self) == true)
        fill.backgroundColor = lit ? Themed.color(\.foreground, 0.1).cgColor(in: self) : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// One list row: a model (`ModelListRow`) or the "Legacy models" expander. 45pt tall,
/// `px-2 py-1 rounded-sm`, name 12/16.5 medium, provider line 12/16.5 at `muted/70`.
final class ModelRowView: DSView {
    private unowned let picker: ModelPickerView
    let row: ModelPickerRow
    let index: Int
    private let fill = CALayer()
    private let name = LabelView()
    private let secondary = LabelView()
    private var newBadge: NewBadgeView?
    private var providerIcon: NSView?
    private var star: StarButtonView?
    private var chevron: IconView?

    init(picker: ModelPickerView, row: ModelPickerRow, index: Int) {
        self.picker = picker
        self.row = row
        self.index = index
        super.init(frame: .zero)
        fill.cornerRadius = 6
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        name.smoothsFont = false // glass popups are backdrop-filter layers
        secondary.smoothsFont = false
        name.font = DSFont.ui(12, weight: .medium)
        name.lineHeight = 16.5
        secondary.font = DSFont.ui(12)
        secondary.lineHeight = 16.5
        addSubview(name)
        addSubview(secondary)
        switch row {
        case .model(let item):
            name.text = ModelNames.display(item.model, preferShortName: true)
            secondary.text = item.model.subProvider.map { "\(item.entry.displayName) · \($0)" } ?? item.entry.displayName
            if item.model.badge == "new" {
                let b = NewBadgeView()
                addSubview(b)
                newBadge = b
            }
            let icon = ProviderIcon.make(driver: item.entry.driver, displayName: item.entry.displayName, size: 12, color: Themed.color(\.contrastMutedForeground))
            addSubview(icon)
            providerIcon = icon
            let s = StarButtonView(favorite: item.isFavorite)
            s.toolTip = item.isFavorite ? "Remove from favorites" : "Add to favorites"
            s.action = { [weak picker] in picker?.toggleFavorite(item) }
            addSubview(s)
            star = s
        case .legacy(_, let count, let expanded):
            name.text = "Legacy models"
            secondary.text = "\(count) models"
            // `rotate-90` when open: chevron-right turned a quarter is chevron-down.
            let c = IconView(name: expanded ? .chevronDown : .chevronRight, size: 16)
            addSubview(c)
            chevron = c
        }
        restyle()
    }

    private var isSelected: Bool { if case .model(let item) = row { item.isSelected } else { false } }

    override func layout() {
        super.layout()
        fill.frame = bounds
        let trailing: CGFloat = star != nil ? 24 - 4 + 6 : 16 + 8
        let nameW = min(name.textWidth, bounds.width - 16 - trailing - (newBadge.map { 8 + $0.intrinsicContentSize.width } ?? 0))
        name.frame = NSRect(x: 8, y: 4, width: max(0, nameW), height: 16.5)
        if let newBadge {
            let s = newBadge.intrinsicContentSize
            newBadge.frame = NSRect(x: 8 + nameW + 8, y: 4 + (16.5 - s.height) / 2, width: s.width, height: s.height)
        }
        var x: CGFloat = 8
        if let providerIcon {
            providerIcon.frame = NSRect(x: x, y: 24.5 + (16.5 - 12) / 2, width: 12, height: 12)
            x += 12 + 6
        }
        secondary.frame = NSRect(x: x, y: 24.5, width: max(0, bounds.width - x - 8 - trailing), height: 16.5)
        // `icon-xs` star button with `-mr-1`; the legacy chevron sits at the end of the content box.
        star?.frame = NSRect(x: bounds.width - 8 + 4 - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
        if let chevron {
            chevron.frame = NSRect(x: bounds.width - 8 - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    func restyle() { needsDisplay = true; updateColors() }
    override func updateLayer() { updateColors() }

    private func updateColors() {
        let highlighted = picker.highlightedRow == index
        // `data-selected` foreground/8%; highlighted (alone or with selected) `accent`.
        let color: NSColor? = highlighted ? Themed.color(\.accent) : (isSelected ? Themed.color(\.contrastForeground, 0.08) : nil)
        fill.backgroundColor = color?.cgColor(in: self)
        name.color = highlighted ? Themed.color(\.contrastAccentForeground) : (isSelected ? Themed.color(\.contrastForeground) : Themed.color(\.contrastPopoverForeground))
        secondary.color = Themed.color(\.contrastMutedForeground, 0.7)
        chevron?.strokeColor = Themed.color(\.contrastMutedForeground)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { picker.activate(index) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The `NEW` chip: `rounded border border-update/35 bg-update/15 px-0.5 py-px text-3xs font-bold
/// uppercase leading-none tracking-wide text-update-foreground`.
final class NewBadgeView: DSView {
    private let label = LabelView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        label.text = "NEW"
        label.smoothsFont = false
        label.font = DSFont.ui(10, weight: .bold)
        label.tracking = 0.25
        label.lineHeight = 10
        addSubview(label)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: (label.textWidth * 2).rounded(.up) / 2 + 6, height: 14) }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 3, y: 2, width: bounds.width - 6, height: 10)
    }

    override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.update, 0.15).cgColor(in: self)
        layer?.borderColor = Themed.color(\.update, 0.35).cgColor(in: self)
        label.color = Themed.color(\.updateForeground)
    }
}

/// The row's favorite toggle: `Button size="icon-xs" variant="ghost-muted"`, a 12pt star,
/// filled `text-warning` when it is a favorite.
final class StarButtonView: ControlView {
    let favorite: Bool
    private let icon = IconView(name: .star, size: 12)
    private let fill = CALayer()

    init(favorite: Bool) {
        self.favorite = favorite
        super.init(frame: .zero)
        fill.cornerRadius = 8
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        addSubview(icon)
    }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        fill.frame = bounds
        icon.frame = NSRect(x: (bounds.width - 12) / 2, y: (bounds.height - 12) / 2, width: 12, height: 12)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    override func updateLayer() {
        fill.backgroundColor = state.hovered ? Themed.color(\.accent).cgColor(in: self) : nil
        let color = favorite ? Themed.color(\.warning) : (state.hovered ? Themed.color(\.contrastForeground) : Themed.color(\.contrastMutedForeground))
        icon.strokeColor = color
        icon.fillColor = favorite ? color : nil
    }
}
