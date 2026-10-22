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

    var catalog: ProviderCatalog { didSet { if catalog != oldValue { reload() } } }
    var favorites: [ModelFavorite] { didSet { reload() } }
    /// `providerModelPreferences`: hidden models and order per instance.
    var preferences: JSONValue { didSet { reload() } }
    let active: ProviderInstanceId
    let activeModel: String
    private(set) var rail: ModelPickerRail
    private(set) var query = ""
    private var expandedLegacy: Set<ProviderInstanceId> = []
    private(set) var sections: ModelPickerSections
    /// Keyboard highlight in the list (`data-highlighted`).
    var highlightedRow: Int? { didSet { if highlightedRow != oldValue { restyleHighlight(from: oldValue); scrollToHighlight() } } }
    /// Keyboard focus in the rail (index into `railButtons`), nil while the search field has it.
    private(set) var railFocus: Int? { didSet { railButtons.forEach { $0.restyle() } } }

    var onSelect: (@MainActor (ProviderInstanceId, String) -> Void)?
    /// Shift-click or Shift-Return on a model while the draft can fan out (`onToggleModel`).
    var onToggle: (@MainActor (ProviderInstanceId, String) -> Void)?
    /// The fan-out's models (`instance:slug`), each drawn selected.
    var selectedKeys: Set<String>? { didSet { if selectedKeys != oldValue { reload() } } }
    var onToggleFavorite: (@MainActor (ProviderInstanceId, String) -> Void)?
    /// The `modelPicker.jump.N` key label for the Nth model (0-based), drawn as a `Kbd` on its row
    /// (ModelPickerContent.tsx:669-687, 751-767; ModelListRow.tsx:107). Nil draws none, as T3's web
    /// build does (the bindings need `isDesktop`), which the web reference captures show.
    var jumpLabel: (@MainActor (Int) -> String?)? { didSet { reload() } }

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

    init(catalog: ProviderCatalog, favorites: [ModelFavorite], active: ProviderInstanceId, activeModel: String, preferences: JSONValue? = nil) {
        self.catalog = catalog
        self.preferences = preferences ?? ClientSettingsStore.shared.current["providerModelPreferences"]
        self.favorites = favorites
        self.active = active
        self.activeModel = activeModel
        rail = ModelPickerSections.initialRail(active: active, favorites: favorites, catalog: catalog)
        // Opens the legacy group on an active legacy model unless it is a favorite (ModelPickerContent.tsx:433-440).
        if let model = catalog.entry(active)?.model(activeModel), model.isLegacy == true,
           !favorites.contains(ModelFavorite(provider: active, model: activeModel)) { expandedLegacy = [active] }
        sections = ModelPickerSections(catalog: catalog, active: active, activeModel: activeModel, favorites: favorites,
                                       rail: rail, query: "", expandedLegacy: expandedLegacy, preferences: self.preferences)
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
        syncSharing()
        let visible = catalog.entries.filter(\.isVisibleInPicker)
        if railButtons.map(\.entryId) != visible.map(\.id) {
            railButtons.forEach { $0.removeFromSuperview() }
            railButtons = visible.map { e in
                // ModelPickerSidebar.tsx:161, 196-216: `size-6` box, `h-3` badge only with an accent.
                let badge = ProviderBadge.make(e, in: catalog, size: ProviderBadge.accent(e) != nil ? .small : .regular,
                                               overhang: 2, ring: Themed.color(\.muted, 0.3))
                let b = RailButtonView(kind: .instance(e), badge: badge)
                b.onPress = { [weak self] in self?.selectRail(.instance(e.id)) }
                addSubview(b)
                return b
            }
        }
        sections = ModelPickerSections(catalog: catalog, active: active, activeModel: activeModel, favorites: favorites,
                                       rail: rail, query: query, expandedLegacy: expandedLegacy, selectedKeys: selectedKeys, preferences: preferences)
        // ponytail: AppKit tooltips instead of T3's TooltipPopup (left side, 8pt offset, no delay); swap for TooltipView when tooltips get a shared host
        for (b, r) in zip(railButtons, sections.rail) { b.isDisabled = r.isDisabled; b.toolTip = r.tooltip }
        // Reuse unchanged rows while filtering (T3 74ca17b43, ModelListRow.tsx:18-43).
        var previous = Dictionary(uniqueKeysWithValues: rowViews.map { (Self.rowKey($0.row), $0) })
        var modelIndex = 0
        rowViews = sections.rows.indices.map { i in
            let row = sections.rows[i]
            var label: String?
            if case .model = row {
                if modelIndex < 9 { label = jumpLabel?(modelIndex) }
                modelIndex += 1
            }
            if let view = previous.removeValue(forKey: Self.rowKey(row)) {
                if view.row == row && view.jumpLabel == label {
                    let wasHighlighted = highlightedRow == view.index
                    view.index = i
                    if wasHighlighted != (highlightedRow == i) { view.restyle() }
                    return view
                }
                view.removeFromSuperview()
            }
            let view = ModelRowView(picker: self, row: row, index: i, jumpLabel: label)
            list.addSubview(view)
            return view
        }
        previous.values.forEach { $0.removeFromSuperview() }
        // Keep accessibility traversal in the same order as the filtered results.
        list.subviews = [emptyLabel] + rowViews
        emptyLabel.isHidden = !sections.rows.isEmpty
        if let h = highlightedRow, h >= rowViews.count { highlightedRow = nil }
        railButtons.forEach { $0.restyle() }
        favoritesButton.restyle()
        needsLayout = true
        needsDisplay = true
    }

    private static func rowKey(_ row: ModelPickerRow) -> String {
        switch row {
        case .model(let item): "model:\(item.key)"
        case .legacy(let instance, _, _): "legacy:\(instance.rawValue)"
        }
    }

    private func restyleHighlight(from old: Int?) {
        for i in Set([old, highlightedRow].compactMap { $0 }) where rowViews.indices.contains(i) {
            rowViews[i].restyle()
        }
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

    /// `modelPicker.previousProvider` / `nextProvider`: the adjacent provider, search cleared
    /// (ModelPickerContent.tsx:783-795).
    func selectAdjacentProvider(_ direction: Int) {
        selectRail(ModelPickerSections.adjacentRail(rail, direction: direction, catalog: catalog))
    }

    /// `modelPicker.jump.N`: picks the Nth model in the list (ModelPickerContent.tsx:797-811).
    public func jump(_ index: Int) {
        let models = sections.rows.indices.filter { if case .model = sections.rows[$0] { true } else { false } }
        if index < models.count { activate(models[index]) }
    }

    func activate(_ i: Int) {
        guard i < sections.rows.count else { return }
        switch sections.rows[i] {
        case .legacy(let id, _, _): toggleLegacy(id)
        case .model(let item):
            if let onToggle, NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onToggle(item.entry.id, item.model.slug)
            } else {
                onSelect?(item.entry.id, item.model.slug)
            }
        }
    }

    func toggleFavorite(_ item: ModelPickerItem) { onToggleFavorite?(item.entry.id, item.model.slug) }

    // MARK: Size and layout

    private var listContentHeight: CGFloat {
        sections.rows.isEmpty ? 0 : CGFloat(sections.rows.count) * Self.rowHeight + CGFloat(sections.rows.count - 1) * Self.rowGap
    }

    /// Search block plus the list (rows + 20) or the empty text (`p-2`, 36), then the ChatGPT footer.
    var naturalSize: CGSize {
        if let frozenHeight { return CGSize(width: Self.width, height: frozenHeight) }
        let list = sections.rows.isEmpty ? 36 : listContentHeight + 20
        return CGSize(width: Self.width, height: min(Self.maxHeight, Self.searchHeight + list) + footerHeight)
    }

    /// `ChatGptSharingControl` (ProviderModelPicker.tsx:317-319): under the picker while the composer's instance
    /// uses a ChatGPT plan, and not while the draft fans out to several models.
    var showsSharing: Bool {
        selectedKeys == nil && catalog.entry(active).map { UsageLimitsLogic.usesChatGptSharing($0.provider) } == true
    }
    private var footerHeight: CGFloat { showsSharing ? ChatGptSharingControlView.height : 0 }
    private var bodyHeight: CGFloat { bounds.height - footerHeight }
    private var sharing: ChatGptSharingControlView?

    private func syncSharing() {
        if showsSharing, sharing == nil {
            let s = ChatGptSharingControlView { NSWorkspace.shared.open($0) }
            addSubview(s)
            sharing = s
        } else if !showsSharing {
            sharing?.removeFromSuperview()
            sharing = nil
        }
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
        railFill.frame = CGRect(x: 0, y: 0, width: Self.railWidth, height: bodyHeight)
        sharing?.frame = NSRect(x: 0, y: bodyHeight, width: bounds.width, height: footerHeight)
        mainFill.frame = CGRect(x: mainX, y: 0, width: bounds.width - mainX, height: bodyHeight)
        mainBorder.isHidden = !railShown
        mainBorder.frame = CGRect(x: mainX, y: 0, width: 1, height: bodyHeight)

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
                            height: max(0, bodyHeight - Self.searchHeight))
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
        // `modelPicker.previousProvider` / `nextProvider` (mod+shift+arrowup / arrowdown by default).
        if let event = NSApp.currentEvent,
           let command = ActiveKeymap.resolve(event, context: KeybindingContext(["modelPickerOpen": true])),
           command == "modelPicker.previousProvider" || command == "modelPicker.nextProvider" {
            selectAdjacentProvider(command == "modelPicker.nextProvider" ? 1 : -1)
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

    init(kind: Kind, badge: ProviderBadge? = nil) {
        self.kind = kind
        switch kind {
        case .favorites: glyph = IconView(name: .star, size: 20)
        case .instance(let e): glyph = ProviderIcon.make(driver: e.driver, displayName: e.displayName, size: 20, badge: badge)
        }
        super.init(frame: .zero)
        scalesWhenPressed = false
        transitions = .colors // ModelPickerSidebar.tsx:126,174
        fill.cornerRadius = 8
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        addSubview(glyph)
        action = { [weak self] in if self?.isDisabled == false { self?.onPress?() } }
        // ModelPickerSidebar.tsx:130 "Favorites", :191 the instance's name (a tooltip replaces it when unavailable).
        switch kind {
        case .favorites: setAccessibilityLabel("Favorites")
        case .instance(let e): setAccessibilityTitle(badge == nil ? e.displayName : "\(e.displayName), new")
        }
        restyle()
    }

    /// `aria-pressed` on the selected rail entry.
    override func isAccessibilitySelected() -> Bool {
        (superview as? ModelPickerView)?.isRailSelected(entryId.map { .instance($0) } ?? .favorites) == true
    }
    override func isAccessibilityEnabled() -> Bool { !isDisabled }

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
        Motion.setBackground(fill, lit ? Themed.color(\.foreground, 0.1).cgColor(in: self) : nil)
        // The badge's ring takes the surface under it (ModelPickerSidebar.tsx:206-212).
        if let badged = glyph as? ProviderBadgedIconView {
            let selected = picker?.isRailSelected(entryId.map { .instance($0) } ?? .favorites) == true
            badged.ring = state.hovered && !isDisabled ? Themed.color(\.muted) : selected ? Themed.color(\.background) : Themed.color(\.muted, 0.3)
        }
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
    var index: Int
    let jumpLabel: String?
    private let fill = CALayer()
    private let name = LabelView()
    private let secondary = LabelView()
    private var newBadge: NewBadgeView?
    private var providerIcon: NSView?
    private var star: StarButtonView?
    private var chevron: IconView?
    private var kbd: KbdView?

    init(picker: ModelPickerView, row: ModelPickerRow, index: Int, jumpLabel: String? = nil) {
        self.picker = picker
        self.row = row
        self.index = index
        self.jumpLabel = jumpLabel
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
            let icon = ProviderIcon.make(driver: item.entry.driver, displayName: item.entry.displayName, size: 12, color: Themed.color(\.contrastMutedForeground),
                                         model: true)
            addSubview(icon)
            providerIcon = icon
            if let jumpLabel {
                let k = KbdView(jumpLabel)
                k.smoothsFont = false
                addSubview(k)
                kbd = k
            }
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
            setAccessibilityExpanded(expanded) // ModelPickerContent.tsx:1001
        }
        restyle()
    }

    private var isSelected: Bool { if case .model(let item) = row { item.isSelected } else { false } }

    // A `ComboboxItem` option: the model name, its provider line as help, selected and (legacy) expanded state.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    override func accessibilityTitle() -> String? { newBadge == nil ? name.text : "\(name.text), New model" } // ModelListRow.tsx:75
    override func accessibilityHelp() -> String? { secondary.text }
    override func isAccessibilitySelected() -> Bool { isSelected }
    override func accessibilityPerformPress() -> Bool { picker.activate(index); return true }

    override func layout() {
        super.layout()
        fill.frame = bounds
        // The trailing group is `gap-1.5`: the jump `Kbd`, then the star.
        let kbdWidth = kbd.map { $0.intrinsicContentSize.width + 6 } ?? 0
        let trailing: CGFloat = (star != nil ? 24 - 4 + 6 : 16 + 8) + kbdWidth
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
        if let kbd, let star {
            let w = kbd.intrinsicContentSize.width
            kbd.frame = NSRect(x: star.frame.minX - 6 - w, y: (bounds.height - 20) / 2, width: w, height: 20)
        }
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
