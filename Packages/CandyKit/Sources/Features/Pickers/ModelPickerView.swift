import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// T3's model picker popover body (chat/ModelPickerContent.tsx, ModelPickerSidebar.tsx,
/// ModelListRow.tsx): a 44pt provider rail with Favorites, a search field and the model list.
/// 360 wide, at most 346 tall. Spec: docs/research/J-composer-visuals.md 8.1, reference 13.
final class ModelPickerView: DSView, PickerPopupBody, HoverSyncPointerClient {
    static let width: CGFloat = 360, maxHeight: CGFloat = 346, railWidth: CGFloat = 44
    static let capyWidth: CGFloat = 420, capyHeight: CGFloat = 440, capyMinHeight: CGFloat = 300
    static func width(_ capy: Bool) -> CGFloat { capy ? capyWidth : width }
    /// Redesign's docked picker is one column (the user's layout, 2026-11-20): provider tabs, search, the list, then the
    /// dock's Reasoning section and footer under it.
    static let stackedWidth: CGFloat = 335, tabsHeight: CGFloat = 40
    static let searchHeight: CGFloat = 43, rowHeight: CGFloat = 45, rowGap: CGFloat = 2

    var catalog: ProviderCatalog { didSet { if catalog != oldValue { reload() } } }
    var favorites: [ModelFavorite] { didSet { reload() } }
    /// `providerModelPreferences`: hidden models and order per instance.
    var preferences: JSONValue { didSet { reload() } }
    /// The selected model; a docked picker stays open across picks and moves its check (#28076).
    var active: ProviderInstanceId { didSet { if active != oldValue { reload() } } }
    var activeModel: String { didSet { if activeModel != oldValue { reload() } } }
    /// Docked beside the effort column: one fixed height, so a model with more options never resizes the popup
    /// (ProviderModelPicker.tsx:475-477, ModelPickerContent.tsx:944-955).
    var docked = false {
        didSet {
            guard docked != oldValue else { return }
            // Rows read the layout when they are made, so a change rebuilds them.
            rowViews.forEach { $0.removeFromSuperview() }
            rowViews = []
            if dockedCapy { search.placeholder = "Search models..."; search.paddingOverride = (20, 0) }
            reload()
        }
    }
    /// Redesign docked: tabs across the top, search under them, and the list under the search. Settings > Redesign >
    /// Stacked model picker off keeps the two-column dock.
    var stacked: Bool { docked && capy && RedesignPickerSettings.stacked }
    /// Redesign docked with Stacked model picker off (the user's layout 2, 2026-11-21): search over the rail and the list,
    /// with the dock's detail pane at the right. Rows look as in the stacked layout.
    var detailed: Bool { docked && capy && !RedesignPickerSettings.stacked }
    var dockedCapy: Bool { docked && capy }
    /// The stacked layout shows at most this many rows before it scrolls, so it never outgrows the window.
    static let stackedVisibleRows = 6
    /// Rail and list in the detail layout.
    static let detailListWidth: CGFloat = 300
    /// The highlight, or the rows under it, changed.
    var onHighlightChange: (@MainActor () -> Void)?
    /// The open provider's project models are still being scanned (ModelPickerContent.tsx:1225-1231 at 4928, #24585).
    var workspaceModelsScanning = false { didSet { emptyLabel.text = workspaceModelsScanning ? "Searching project models..." : "No models found" } }
    private(set) var rail: ModelPickerRail
    private(set) var query = ""
    private var expandedLegacy: Set<ProviderInstanceId> = []
    /// Expanded backend headings (`ModelPickerRow.subProviderKey`); the active model's opens expanded.
    private var expandedSubProviders: Set<String> = []
    private(set) var sections: ModelPickerSections
    /// Keyboard highlight in the list (`data-highlighted`). It always names a row that exists: an index past the end of a
    /// list that shrank clears here, whoever set it. v1.15.0 kept the clicked Show less row's index from the longer list
    /// and trapped on it in `scrollToHighlight`.
    var highlightedRow: Int? {
        didSet {
            if let h = highlightedRow, !(0..<min(rowViews.count, sections.rows.count)).contains(h) { highlightedRow = nil }
            if highlightedRow != oldValue { restyleHighlight(from: oldValue); scrollToHighlight(); onHighlightChange?() }
        }
    }
    /// Keyboard focus in the rail (index into `railButtons`), nil while the search field has it.
    private(set) var railFocus: Int? { didSet { allRailButtons.forEach { $0.restyle() } } }

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
    /// Redesign's card "Manage": opens the provider's settings. Nil hides the button.
    var onManage: (@MainActor (ProviderInstanceId) -> Void)? { didSet { card = nil; reload() } }
    /// Redesign follows Capy's picker (2026-10-22): search across the top over a hairline, a slim rail whose pick sits on
    /// a rounded fill, the provider's card over a "Models" label, and one-line rows with a check at the right.
    var capy: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }

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
    private var card: DitherProviderCardView?
    private let cardLine = CALayer()
    private let sectionLabel = LabelView("Models", font: DSFont.ui(12, weight: .medium))
    private let favoritesButton: RailButtonView
    private var railButtons: [RailButtonView] = []
    private(set) var rowViews: [ModelRowView] = []
    private var scrollOffset: CGFloat = 0
    /// While searching the height stays at what it was when typing started.
    private var frozenHeight: CGFloat?
    private var tallestTabHeight: CGFloat = 36
    private var tracking: NSTrackingArea?
    /// Whether the highlight follows the pointer, so a scroll, an exit or a lost key window clears it (Redesign).
    private var pointerHighlight = false
    private var resignObserver: NSObjectProtocol?

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
        // The thread's backend opens expanded, so its models show without a click (ModelPickerContent.tsx:470-476).
        if let sub = catalog.entry(active)?.model(activeModel)?.subProvider { expandedSubProviders = [ModelPickerRow.subProviderKey(active, sub)] }
        sections = ModelPickerSections(catalog: catalog, active: active, activeModel: activeModel, favorites: favorites,
                                       rail: rail, query: "", expandedLegacy: expandedLegacy, preferences: self.preferences,
                                       expandedSubProviders: expandedSubProviders)
        favoritesButton = RailButtonView(kind: .favorites)
        super.init(frame: .zero)
        clipsToBounds = true
        for l in [railFill, mainFill, mainBorder, divider, indicator, underline, cardLine] {
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
        sectionLabel.lineHeight = 16
        sectionLabel.smoothsFont = false
        if capy {
            search.placeholder = "Search models"
            search.paddingOverride = (0, 0)
            searchIcon.isHidden = true
        }
        favoritesButton.onPress = { [weak self] in self?.selectRail(.favorites) }
        addSubview(favoritesButton)
        reload()
    }

    // MARK: Model

    private func reload() {
        syncSharing()
        let highlightedKey = highlightedRow.flatMap { sections.rows.indices.contains($0) ? Self.rowKey(sections.rows[$0]) : nil }
        let visible = catalog.entries.filter(\.isVisibleInPicker)
        if railButtons.map(\.entryId) != visible.map(\.id) {
            railButtons.forEach { $0.removeFromSuperview() }
            railButtons = visible.map { e in
                // ModelPickerSidebar.tsx:161, 196-216: `size-6` box, `h-3` badge only with an accent.
                let badge = ProviderBadge.make(e, in: catalog, size: ProviderBadge.accent(e) != nil ? .small : .regular,
                                               overhang: 2, ring: Themed.color(\.muted, 0.3))
                let b = RailButtonView(kind: .instance(e), badge: ComposerDesign.uses3814(dark: effectiveAppearance.isDark) ? nil : badge)
                b.onPress = { [weak self] in self?.selectRail(.instance(e.id)) }
                addSubview(b)
                return b
            }
            // Rail focus is an index too: a tab that went away takes it with it.
            if let f = railFocus, f >= allRailButtons.count { railFocus = nil }
        }
        sections = ModelPickerSections(catalog: catalog, active: active, activeModel: activeModel, favorites: favorites,
                                       rail: rail, query: query, expandedLegacy: expandedLegacy, selectedKeys: selectedKeys, preferences: preferences,
                                       expandedSubProviders: expandedSubProviders)
        if !capy, !searching {
            // T3 3814 ModelPickerContent.tsx:583-610,832-836 fits the tallest eligible tab.
            let tabs: [ModelPickerRail] = [.favorites] + sections.rail.filter { !$0.isDisabled }.map { .instance($0.entry.id) }
            tallestTabHeight = tabs.map { tab in
                let rows = ModelPickerSections(catalog: catalog, active: active, activeModel: activeModel, favorites: favorites,
                                               rail: tab, query: "", expandedLegacy: expandedLegacy,
                                               selectedKeys: selectedKeys, preferences: preferences,
                                               expandedSubProviders: expandedSubProviders).rows
                if modern { return contentHeight(rows, mixed: tab == .favorites) }
                return rows.isEmpty ? 36 : CGFloat(rows.count) * Self.rowHeight + CGFloat(rows.count - 1) * Self.rowGap + 20
            }.max() ?? 36
        }
        // ponytail: AppKit tooltips instead of T3's TooltipPopup (left side, 8pt offset, no delay); swap for TooltipView when tooltips get a shared host
        for (b, r) in zip(railButtons, sections.rail) { b.isDisabled = r.isDisabled; b.setTooltip(r.tooltip) }
        // Reuse unchanged rows while filtering (T3 74ca17b43, ModelListRow.tsx:18-43).
        var previous = Dictionary(rowViews.map { (Self.rowKey($0.row), $0) }, uniquingKeysWith: { first, _ in first })
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
        syncCard()
        // Keep accessibility traversal in the same order as the filtered results.
        list.subviews = [emptyLabel] + [card, card == nil ? nil : sectionLabel].compactMap { $0 } + rowViews
        emptyLabel.isHidden = !sections.rows.isEmpty
        // The highlight stays on its row, not its index, as T3 keys it by the row (ModelPickerContent.tsx:989-990), so
        // Show less keeps it after the list above it shrinks, and a row that went away drops it.
        highlightedRow = highlightedKey.flatMap { key in sections.rows.firstIndex { Self.rowKey($0) == key } }
        sectionLabel.isHidden = stacked
        railButtons.forEach { $0.restyle() }
        favoritesButton.restyle()
        needsLayout = true
        needsDisplay = true
        onHighlightChange?()
    }

    /// The highlighted row's model, nil on a heading or with no highlight.
    var highlightedItem: ModelPickerItem? {
        guard let h = highlightedRow, sections.rows.indices.contains(h), case .model(let item) = sections.rows[h] else { return nil }
        return item
    }
    /// The listed model with `key` (`instance:slug`), if it is still listed.
    func listedItem(_ key: String) -> ModelPickerItem? {
        for row in sections.rows { if case .model(let item) = row, item.key == key { return item } }
        return nil
    }
    /// Every listed model, in order.
    var listedItems: [ModelPickerItem] { sections.rows.compactMap { if case .model(let item) = $0 { item } else { nil } } }

    /// Redesign's card for the rail's provider, while not searching. Rebuilt only when what it shows changes. Settings >
    /// Redesign > Account and limits turns it on; without it the tab keeps T3's status tooltip and dims while not ready.
    private func syncCard() {
        guard capy, !detailed, RedesignPickerSettings.showsAccount, !searching, case .instance(let id) = rail, let entry = catalog.entry(id) else { card = nil; return }
        let info = DitherProviderCardInfo(entry)
        if card?.info == info { return }
        card = DitherProviderCardView(info: info, onManage: onManage.map { open in { open(id) } })
    }

    /// The list's height in the stacked layout: the card and its hairline, the rows up to `stackedVisibleRows`, and the
    /// padding under them; more rows scroll.
    private func stackedListHeight(rows: Int, cardHeight: CGFloat?) -> CGFloat {
        let top = cardHeight.map { $0 + 1 + 6 } ?? 6
        return rows == 0 ? top + 36 : top + CGFloat(min(rows, Self.stackedVisibleRows)) * 32 + listBottom
    }

    private static func rowKey(_ row: ModelPickerRow) -> String {
        switch row {
        case .model(let item): "model:\(item.key)"
        case .legacy(let instance, _, _): "legacy:\(instance.rawValue)"
        case .subProvider(let instance, let name, _, _, _): "sub:\(ModelPickerRow.subProviderKey(instance, name))"
        }
    }

    private func restyleHighlight(from old: Int?) {
        for i in Set([old, highlightedRow].compactMap { $0 }) where rowViews.indices.contains(i) {
            rowViews[i].restyle()
        }
    }

    func isRailSelected(_ r: ModelPickerRail) -> Bool { rail == r }
    /// Moves keyboard focus to the selected tab, or back to the search with false.
    func focusRail(_ on: Bool) {
        railFocus = on && sections.showsRail ? (allRailButtons.firstIndex { isSelected($0) && !$0.isDisabled } ?? allRailButtons.firstIndex { !$0.isDisabled }) : nil
    }
    /// Focus left the list for the Reasoning section: a keyboard highlight goes, the pointer's stays.
    func clearKeyboardHighlight() { if !pointerHighlight { highlightedRow = nil } }

    /// Keyboard focus moved into the list: the selected model is highlighted, else the first row.
    func highlightForKeyboard() {
        pointerHighlight = false
        if highlightedRow != nil { return }
        let selected = sections.rows.indices.first { i in
            if case .model(let item) = sections.rows[i] { return item.isSelected } else { return false }
        }
        highlightedRow = selected ?? (rowViews.isEmpty ? nil : 0)
    }
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
        reloadKeepingHighlight()
    }

    func toggleSubProvider(_ key: String) {
        if expandedSubProviders.remove(key) == nil { expandedSubProviders.insert(key) }
        reloadKeepingHighlight()
    }

    private func reloadKeepingHighlight() {
        reload()
        resizePopup()
        // The rows moved under a still pointer, so Redesign's hover takes the row now under it, or none.
        if capy, pointerHighlight, let window {
            window.contentView?.layoutSubtreeIfNeeded()
            syncPointerHighlight(at: window.mouseLocationOutsideOfEventStream)
        }
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
        case .subProvider(let id, let name, _, _, let reason): if reason == nil { toggleSubProvider(ModelPickerRow.subProviderKey(id, name)) }
        case .model(let item):
            if let onToggle, NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onToggle(item.entry.id, item.model.slug)
            } else {
                onSelect?(item.entry.id, item.model.slug)
            }
        }
    }

    /// Whether row `i` is a model other than the selected one.
    func isOtherModel(_ i: Int) -> Bool {
        guard i < sections.rows.count, case .model(let item) = sections.rows[i] else { return false }
        return item.entry.id != active || item.model.slug != activeModel
    }

    func toggleFavorite(_ item: ModelPickerItem) { onToggleFavorite?(item.entry.id, item.model.slug) }

    // MARK: Size and layout

    private var modern: Bool { ComposerDesign.uses3814(dark: effectiveAppearance.isDark) }
    private var rowH: CGFloat { capy ? 32 : Self.rowHeight }
    var mixesProviders: Bool { searching || rail == .favorites }

    // 4928 ModelPickerContent.tsx:175-177, ModelListRow.tsx:57: one 32pt row shape in every tab (#28057).
    /// A backend heading is two lines in the default themes: `py-1`, the name, `mt-1` and the count (ModelPickerContent.tsx:1157-1173).
    private func height(_ row: ModelPickerRow, mixed: Bool) -> CGFloat {
        if modern, case .subProvider = row { return 48 }
        return modern ? 32 : rowH
    }

    private func contentHeight(_ rows: [ModelPickerRow], mixed: Bool) -> CGFloat {
        guard !rows.isEmpty else { return 36 }
        return rows.map { height($0, mixed: mixed) }.reduce(0, +) + CGFloat(rows.count - 1) * rowGap + 20
    }
    private var rowGap: CGFloat { capy ? 0 : Self.rowGap }
    private var searchH: CGFloat { capy ? 40 : Self.searchHeight }
    private var railW: CGFloat { capy ? 40 : Self.railWidth }
    /// The list's padding over the first row (Redesign: the card, its hairline and the "Models" label) and under the last.
    private var listTop: CGFloat {
        if stacked { return card.map { $0.preferredHeight + 1 + 6 } ?? 6 }
        return capy ? (card.map { $0.preferredHeight + 1 + 28 } ?? 6) : 10
    }
    private var tabsH: CGFloat { stacked && sections.showsRail ? Self.tabsHeight : 0 }
    private var listBottom: CGFloat { capy ? 6 : 10 }

    private var listContentHeight: CGFloat {
        sections.rows.isEmpty ? 0 : sections.rows.map { height($0, mixed: mixesProviders) }.reduce(0, +) + CGFloat(sections.rows.count - 1) * rowGap
    }

    /// Search block plus the list (rows + 20) or the empty text (`p-2`, 36), then the ChatGPT footer.
    var naturalSize: CGSize {
        if stacked {
            // Content height; the host caps the popup at the space above the composer and the list scrolls.
            if let frozenHeight { return CGSize(width: Self.stackedWidth, height: frozenHeight) }
            let list = stackedListHeight(rows: sections.rows.count, cardHeight: card?.preferredHeight)
            return CGSize(width: Self.stackedWidth, height: tabsH + searchH + list + footerHeight)
        }
        if detailed {
            // The rows' own height; the dock sets the popup's height from this and the pane, within a floor and a ceiling.
            if let frozenHeight { return CGSize(width: Self.detailListWidth, height: frozenHeight) }
            let list = sections.rows.isEmpty ? listTop + 36 : listContentHeight + listTop + listBottom
            return CGSize(width: Self.detailListWidth, height: searchH + list)
        }
        if docked { return CGSize(width: Self.width(capy), height: capy ? Self.capyHeight : Self.maxHeight) }
        if let frozenHeight { return CGSize(width: Self.width(capy), height: frozenHeight) }
        let list = sections.rows.isEmpty ? 36 + (capy ? listTop - 6 : 0) : listContentHeight + listTop + listBottom
        // Redesign fits its content between a floor, so a short list (favorites, a search) isn't squashed, and Capy's
        // 440; the host trims it further when the space above the chip is shorter.
        if capy { return CGSize(width: Self.capyWidth, height: min(max(searchH + list, Self.capyMinHeight), Self.capyHeight) + footerHeight) }
        return CGSize(width: Self.width, height: min(Self.maxHeight, searchH + max(list, tallestTabHeight)) + footerHeight)
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

    func resizePopup() {
        // Docked, the picker sits one view deeper, inside the dock.
        guard let popupView = sequence(first: superview, next: { $0?.superview }).lazy.compactMap({ $0 as? PickerPopupView }).first,
              let host = popupView.superview?.superview as? PopupHost,
              let popup = host.popups.first(where: { $0.content === popupView }) else { return }
        host.reposition(popup)
    }

    override func layout() {
        super.layout()
        if stacked { layoutStacked(); return }
        if capy { layoutCapy(); return }
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
        if let selected { indicator.frame = CGRect(x: Self.railWidth - (modern ? 7 : 3), y: selected.frame.midY - 10, width: 3, height: 20) }

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
            row.frame = NSRect(x: 12, y: y, width: list.bounds.width - 12 - 12, height: height(row.row, mixed: mixesProviders))
            y += row.frame.height + Self.rowGap
        }
        emptyLabel.frame = NSRect(x: 8, y: 8, width: list.bounds.width - 16, height: 20)
    }

    /// Redesign: search across the top over a full-width hairline, then the rail and the list under it.
    private func layoutCapy() {
        let railShown = sections.showsRail
        let mainX = railShown ? railW : 0
        for l in [railFill, mainFill, divider, indicator] { l.isHidden = true }
        sharing?.frame = NSRect(x: 0, y: bodyHeight, width: bounds.width, height: footerHeight)
        search.frame = NSRect(x: 14, y: 7, width: bounds.width - 28, height: 26)
        // The detail layout keeps the stacked picker's search with its icon.
        searchIcon.isHidden = !detailed
        if detailed { searchIcon.frame = NSRect(x: 14, y: 12, width: 16, height: 16) }
        underline.frame = CGRect(x: 0, y: searchH - 1, width: bounds.width, height: 1)
        mainBorder.isHidden = !railShown
        mainBorder.frame = CGRect(x: mainX, y: searchH, width: 1, height: max(0, bodyHeight - searchH))
        for (i, b) in allRailButtons.enumerated() {
            b.isHidden = !railShown
            b.frame = NSRect(x: 4, y: searchH + 6 + CGFloat(i) * 36, width: 32, height: 32)
        }
        let listX = mainX + (railShown ? 1 : 0)
        list.frame = NSRect(x: listX, y: searchH, width: bounds.width - listX, height: max(0, bodyHeight - searchH))
        scrollOffset = min(scrollOffset, maxScroll)
        let inner = list.bounds.width - 12
        if let card {
            let h = card.preferredHeight
            card.frame = NSRect(x: 6, y: -scrollOffset, width: inner, height: h)
            cardLine.frame = CGRect(x: list.frame.minX + 6, y: list.frame.minY + h - scrollOffset, width: inner, height: 1)
            sectionLabel.frame = NSRect(x: 14, y: h + 1 + 8 - scrollOffset, width: inner - 16, height: 16)
            // The hairline lives on the picker's layer, so it hides once it scrolls under the search.
            cardLine.isHidden = h - scrollOffset < 0
        } else {
            cardLine.isHidden = true
        }
        var y = listTop - scrollOffset
        for row in rowViews {
            row.frame = NSRect(x: 6, y: y, width: inner, height: rowH)
            y += rowH + rowGap
        }
        emptyLabel.frame = NSRect(x: 8, y: listTop + 2, width: list.bounds.width - 16, height: 20)
    }

    /// Redesign docked: a row of tabs, the search with its icon over an inset hairline, then the card and the rows.
    private func layoutStacked() {
        for l in [railFill, mainFill, divider, indicator, mainBorder] { l.isHidden = true }
        sharing?.frame = NSRect(x: 0, y: bodyHeight, width: bounds.width, height: footerHeight)
        let railShown = sections.showsRail
        for (i, b) in allRailButtons.enumerated() {
            b.isHidden = !railShown
            b.frame = NSRect(x: 6 + CGFloat(i) * 36, y: 4, width: 32, height: 32)
        }
        let top = tabsH
        searchIcon.isHidden = false
        searchIcon.frame = NSRect(x: 12, y: top + 12, width: 16, height: 16)
        search.frame = NSRect(x: 12, y: top + 7, width: bounds.width - 24, height: 26)
        underline.frame = CGRect(x: 12, y: top + searchH - 1, width: bounds.width - 24, height: 1)
        list.frame = NSRect(x: 0, y: top + searchH, width: bounds.width, height: max(0, bodyHeight - top - searchH))
        scrollOffset = min(scrollOffset, maxScroll)
        let inner = list.bounds.width - 12
        if let card {
            let h = card.preferredHeight
            card.frame = NSRect(x: 6, y: -scrollOffset, width: inner, height: h)
            cardLine.frame = CGRect(x: list.frame.minX + 6, y: list.frame.minY + h - scrollOffset, width: inner, height: 1)
            cardLine.isHidden = h - scrollOffset < 0
        } else {
            cardLine.isHidden = true
        }
        var y = listTop - scrollOffset
        for row in rowViews {
            row.frame = NSRect(x: 6, y: y, width: inner, height: rowH)
            y += rowH
        }
        emptyLabel.frame = NSRect(x: 8, y: listTop + 2, width: list.bounds.width - 16, height: 20)
    }

    private var maxScroll: CGFloat { max(0, listContentHeight + listTop + listBottom - list.bounds.height) }

    private func scrollToHighlight() {
        guard let i = highlightedRow, list.bounds.height > 0 else { return }
        let top = listTop + sections.rows.prefix(i).map { height($0, mixed: mixesProviders) + rowGap }.reduce(0, +), bottom = top + height(sections.rows[i], mixed: mixesProviders)
        // The first row brings the whole top back, Redesign's card included.
        if i == 0 { scrollOffset = 0 } else if top - listBottom < scrollOffset { scrollOffset = top - listBottom }
        else if bottom + listBottom > scrollOffset + list.bounds.height { scrollOffset = bottom + listBottom - list.bounds.height }
        needsLayout = true
    }

    override func scrollWheel(with event: NSEvent) {
        scrollOffset = min(max(0, scrollOffset - event.scrollPointsY), maxScroll)
        needsLayout = true
        // A row that scrolls out from under a still pointer loses the hover, and the one that arrives takes it.
        if capy, pointerHighlight, let window {
            layoutSubtreeIfNeeded()
            syncPointerHighlight(at: window.mouseLocationOutsideOfEventStream)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        rowViews.forEach { $0.restyle() }
        allRailButtons.forEach { $0.restyle() }
    }

    override func updateLayer() {
        if capy {
            mainBorder.backgroundColor = Themed.color(\.contrastForeground, 0.08).cgColor(in: self)
            underline.backgroundColor = Themed.color(\.contrastForeground, 0.08).cgColor(in: self)
            cardLine.backgroundColor = Themed.color(\.contrastForeground, 0.08).cgColor(in: self)
            sectionLabel.color = Themed.color(\.contrastMutedForeground)
            emptyLabel.color = Themed.color(\.contrastMutedForeground)
            searchIcon.strokeColor = Themed.color(\.contrastMutedForeground)
            return
        }
        cardLine.isHidden = true
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
            pointerHighlight = false
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
        // Redesign's stacked tabs run across: Left and Right move, Down goes back to the search.
        case .left where stacked, .right where stacked:
            if let pos = enabled.firstIndex(of: focus) { railFocus = enabled[(pos + (key == .right ? 1 : -1) + enabled.count) % enabled.count] }
            return true
        case .up where stacked:
            return true
        case .down where stacked:
            railFocus = nil
            return true
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

    private func rowIndex(at windowPoint: NSPoint) -> Int? {
        let p = list.convert(windowPoint, from: nil)
        guard list.bounds.contains(p) else { return nil }
        return rowViews.firstIndex { $0.frame.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        if capy { syncPointerHighlight(at: event.locationInWindow); return }
        if let i = rowIndex(at: event.locationInWindow) { highlightedRow = i }
    }

    /// Redesign: the highlight is the row under the pointer, or none once the pointer is off the rows. A keyboard
    /// highlight stays until the pointer reaches a row.
    func syncPointerHighlight(at windowPoint: NSPoint) {
        if let i = rowIndex(at: windowPoint) {
            pointerHighlight = true
            highlightedRow = i
        } else if pointerHighlight {
            pointerHighlight = false
            highlightedRow = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        guard let window else { return }
        // A window that stops being key leaves no pointer hover behind, as the message rail (bb98b824).
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerLeft() }
        }
    }

    /// Clears a pointer highlight; a keyboard one stays.
    func pointerLeft() {
        guard capy, pointerHighlight else { return }
        pointerHighlight = false
        highlightedRow = nil
    }
    /// HoverSync forwards every pointer move while the picker is hovered: AppKit sent Redesign's rows no `mouseMoved`
    /// after the popup built its area under the pointer, so they never lit (screen pass 2026-11-20, item 9).
    func hoverPointerMoved() {
        guard let window else { return }
        if capy { syncPointerHighlight(at: window.mouseLocationOutsideOfEventStream); return }
        guard let i = rowIndex(at: window.mouseLocationOutsideOfEventStream) else { return }
        highlightedRow = i
    }
    override func mouseExited(with event: NSEvent) { pointerHighlight = false; highlightedRow = nil }
}

/// One rail button: Favorites (filled 20pt star) or a provider instance (20pt glyph in a 24pt box).
final class RailButtonView: ControlView {
    enum Kind { case favorites, instance(ProviderInstanceEntry) }
    let kind: Kind
    var isDisabled = false { didSet { alphaValue = isDisabled ? 0.5 : 1; window?.invalidateCursorRects(for: self) } }
    final var onPress: (@MainActor () -> Void)?
    private let glyph: NSView
    private let fill = CALayer()
    /// Redesign's rail: 16pt glyphs, an outline star.
    private let capy = ThemeRuntime.isDither(dark: NSApp?.effectiveAppearance.isDark ?? true)
    private var glyphSize: CGFloat { capy ? 16 : 20 }

    var entryId: ProviderInstanceId? { if case .instance(let e) = kind { e.id } else { nil } }

    init(kind: Kind, badge: ProviderBadge? = nil) {
        self.kind = kind
        let size: CGFloat = capy ? 16 : 20
        switch kind {
        case .favorites: glyph = IconView(name: .star, size: size)
        case .instance(let e): glyph = ProviderIcon.make(driver: e.driver, displayName: e.displayName, size: size, badge: badge)
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
        glyph.frame = NSRect(x: (bounds.width - glyphSize) / 2, y: (bounds.height - glyphSize) / 2, width: glyphSize, height: glyphSize)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    func restyle() {
        if case .favorites = kind, let star = glyph as? IconView {
            let selected = (superview as? ModelPickerView)?.isRailSelected(.favorites) == true
            star.strokeColor = capy && !selected ? Themed.color(\.contrastMutedForeground) : Themed.color(\.contrastForeground)
            star.fillColor = capy ? nil : Themed.color(\.contrastForeground)
        }
        needsDisplay = true
    }

    override func updateLayer() {
        let picker = superview as? ModelPickerView
        let lit = !isDisabled && (state.hovered || picker?.isRailFocused(self) == true)
        if capy {
            // Capy's rail: the pick sits on a rounded fill, a hover on a fainter one.
            let selected = picker?.isRailSelected(entryId.map { .instance($0) } ?? .favorites) == true
            fill.cornerRadius = RedesignTokens.Radius.control
            let alpha: CGFloat? = selected ? 0.09 : lit ? 0.05 : nil
            Motion.setBackground(fill, alpha.map { Themed.color(\.contrastForeground, $0).cgColor(in: self) })
        } else {
            Motion.setBackground(fill, lit ? Themed.color(\.foreground, 0.1).cgColor(in: self) : nil)
        }
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
    private var unavailableBadge: BadgeView?
    private var kbd: KbdView?
    /// Redesign: one line, the model's glyph first, a check at the right on the selected model.
    private let capy: Bool
    /// Redesign docked (stacked or detail layout): the check right after the name and the jump key always at the right.
    private let stacked: Bool
    private var check: IconView?
    /// The stacked layout's NEW badge fits beside the name and the jump key.
    private var badgeFits = false

    init(picker: ModelPickerView, row: ModelPickerRow, index: Int, jumpLabel: String? = nil) {
        self.picker = picker
        self.row = row
        self.index = index
        self.jumpLabel = jumpLabel
        capy = picker.capy
        stacked = picker.dockedCapy
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
            name.text = ModelNames.display(item.model, preferShortName: !ComposerDesign.uses3814(dark: effectiveAppearance.isDark))
            secondary.text = item.model.subProvider.map { "\(item.entry.displayName) · \($0)" } ?? item.entry.displayName
            if item.model.badge == "new" {
                let b = NewBadgeView()
                addSubview(b)
                newBadge = b
            }
            let icon = ProviderIcon.make(driver: item.entry.driver, displayName: item.entry.displayName, size: capy ? 16 : 12,
                                         color: capy ? Themed.color(\.contrastForeground) : Themed.color(\.contrastMutedForeground), model: true)
            addSubview(icon)
            providerIcon = icon
            if let jumpLabel {
                let k = KbdView(jumpLabel)
                k.smoothsFont = false
                addSubview(k)
                kbd = k
            }
            let s = StarButtonView(favorite: item.isFavorite)
            s.setTooltip(item.isFavorite ? "Remove from favorites" : "Add to favorites")
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
        case .subProvider(_, let title, let count, let expanded, let reason):
            name.text = title
            secondary.text = reason ?? (count == 1 ? "1 model" : "\(count) models")
            if reason == nil {
                let c = IconView(name: expanded ? .chevronDown : .chevronRight, size: 16)
                addSubview(c)
                chevron = c
                setAccessibilityExpanded(expanded)
            } else {
                let b = BadgeView("Unavailable", variant: .outline, size: .sm)
                addSubview(b)
                unavailableBadge = b
                alphaValue = 0.64 // `data-disabled:opacity-64`
            }
        }
        if capy {
            name.font = DSFont.ui(13)
            name.lineHeight = 20
            secondary.lineHeight = 20
            // The provider line stays as the row's help text; a legacy group keeps its count beside the chevron.
            secondary.isHidden = chevron == nil
            if isSelected {
                let v = IconView(name: .check, size: 14)
                addSubview(v)
                check = v
            }
            if stacked, case .legacy(_, _, let expanded) = row {
                // The picture's plain Show more row trails the list, as 4928's (#28076).
                name.text = expanded ? "Show less" : "Show more"
                secondary.isHidden = true
                chevron?.removeFromSuperview(); chevron = nil
            }
        }
        if ComposerDesign.uses3814(dark: effectiveAppearance.isDark) {
            // 4928 ModelListRow.tsx:57-101 (#28057): the provider's logo, the name, the check right after it on the
            // selected model, then the sub-provider and badges on one line; the star and jump key at the end.
            name.font = DSFont.ui(14); name.lineHeight = 19.25
            secondary.font = DSFont.ui(12); secondary.lineHeight = 16
            fill.cornerRadius = 4
            if isSelected { let indicator = IconView(name: .check, size: 14); addSubview(indicator); check = indicator }
            switch row {
            case .model(let item):
                secondary.text = item.model.subProvider ?? ""
                providerIcon?.removeFromSuperview()
                let icon = ProviderIcon.make(driver: item.entry.driver, displayName: item.entry.displayName, size: 16,
                                             color: Themed.color(\.contrastMutedForeground), model: true,
                                             badge: ProviderBadge.make(item.entry, in: picker.catalog, size: .small, overhang: 2, ring: Themed.color(\.popover)))
                addSubview(icon)
                providerIcon = icon
            case .legacy(_, _, let expanded):
                // #28076: a plain Show more row trails the list.
                name.text = expanded ? "Show less" : "Show more"
                secondary.text = ""
                chevron?.removeFromSuperview(); chevron = nil
            case .subProvider:
                name.font = DSFont.ui(14, weight: .regular)
            }
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
        if stacked { layoutStacked(); return }
        if capy { layoutCapy(); return }
        let modern = ComposerDesign.uses3814(dark: effectiveAppearance.isDark)
        if modern, case .subProvider = row { layoutSubProvider(); return }
        if modern { layoutModern(); return }
        let checkWidth: CGFloat = modern && star != nil ? 20 : 0
        // The trailing group is `gap-1.5`: the jump `Kbd`, then the star.
        let kbdWidth = kbd.map { $0.intrinsicContentSize.width + 6 } ?? 0
        let trailing: CGFloat = checkWidth + (star != nil ? 24 - 4 + 6 : 16 + 8) + kbdWidth
        let nameW = min(name.textWidth, bounds.width - 16 - trailing - (newBadge.map { 8 + $0.intrinsicContentSize.width } ?? 0))
        name.frame = NSRect(x: 8, y: modern && secondary.isHidden ? (bounds.height - 19.25) / 2 : 4, width: max(0, nameW), height: modern ? 19.25 : 16.5)
        if let newBadge {
            let s = newBadge.intrinsicContentSize
            newBadge.frame = NSRect(x: 8 + nameW + 8, y: 4 + (16.5 - s.height) / 2, width: s.width, height: s.height)
        }
        var x: CGFloat = 8
        if let providerIcon {
            providerIcon.frame = NSRect(x: x, y: (modern ? 27.25 : 24.5) + (16.5 - 12) / 2, width: 12, height: 12)
            x += 12 + 6
        }
        secondary.frame = NSRect(x: x, y: modern ? 27.25 : 24.5, width: max(0, bounds.width - x - 8 - trailing), height: 16.5)
        // `icon-xs` star button with `-mr-1`; the legacy chevron sits at the end of the content box.
        star?.frame = NSRect(x: bounds.width - 8 + 4 - 24 - checkWidth, y: (bounds.height - 24) / 2, width: 24, height: 24)
        if modern { check?.frame = NSRect(x: bounds.width - 8 - 14, y: (bounds.height - 14) / 2, width: 14, height: 14); check?.isHidden = !isSelected }
        if let kbd, let star {
            let w = kbd.intrinsicContentSize.width
            kbd.frame = NSRect(x: star.frame.minX - 6 - w, y: (bounds.height - 20) / 2, width: w, height: 20)
        }
        if let chevron {
            chevron.frame = NSRect(x: bounds.width - 8 - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        }
    }

    /// A backend heading: the name and an Unavailable badge (`gap-2`) over the count or reason, the chevron at the end.
    private func layoutSubProvider() {
        let right = bounds.width - 8 - (chevron == nil ? 0 : 16 + 8)
        let badgeW = unavailableBadge.map { 8 + $0.intrinsicContentSize.width } ?? 0
        let nameW = max(0, min(ceil(name.textWidth), right - 8 - badgeW))
        name.frame = NSRect(x: 8, y: 4, width: nameW, height: 19.25)
        if let b = unavailableBadge {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: 8 + nameW + 8, y: 4 + (19.25 - s.height) / 2, width: s.width, height: s.height)
        }
        secondary.isHidden = false
        secondary.frame = NSRect(x: 8, y: 4 + 19.25 + 4, width: max(0, right - 8), height: 16)
        chevron?.frame = NSRect(x: bounds.width - 8 - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    /// `ComboboxItem` `px-2 gap-2`: logo, then name, check, sub-provider and badges (`gap-2`), then star and `Kbd` (`gap-1.5`).
    private func layoutModern() {
        let mid = bounds.height / 2
        var right = bounds.width - 8
        if let kbd {
            let w = kbd.intrinsicContentSize.width
            kbd.frame = NSRect(x: right - w, y: mid - 10, width: w, height: 20)
            right = kbd.frame.minX - 6
        }
        if let star {
            star.frame = NSRect(x: right - 24, y: mid - 12, width: 24, height: 24)
            right = star.frame.minX - 8
        }
        var x: CGFloat = 8
        if let providerIcon {
            providerIcon.frame = NSRect(x: x, y: mid - 8, width: 16, height: 16)
            x += 16 + 8
        }
        let checkW: CGFloat = check == nil ? 0 : 8 + 14
        let fixed = checkW + Self.newBadgeWidth(newBadge, name: name.textWidth, room: right - x - checkW)
        badgeFits = newBadge.map { !$0.isHidden } ?? false
        let nameW = max(0, min(ceil(name.textWidth), right - x - fixed))
        name.frame = NSRect(x: x, y: mid - 19.25 / 2, width: nameW, height: 19.25)
        x += nameW
        if let check { check.frame = NSRect(x: x + 8, y: mid - 7, width: 14, height: 14); x += 8 + 14 }
        secondary.isHidden = secondary.text.isEmpty
        if !secondary.isHidden {
            let w = max(0, min(ceil(secondary.textWidth), right - x - 8 - (newBadge.map { 8 + $0.intrinsicContentSize.width } ?? 0)))
            secondary.frame = NSRect(x: x + 8, y: mid - 8, width: w, height: 16)
            x += 8 + w
        }
        if let newBadge {
            let s = newBadge.intrinsicContentSize
            newBadge.frame = NSRect(x: x + 8, y: mid - s.height / 2, width: s.width, height: s.height)
        }
    }

    /// Redesign: glyph, name and badge on one line; at the right the check, then the star and jump key on hover.
    private func layoutCapy() {
        let mid = bounds.height / 2
        var right = bounds.width - 8
        if let check {
            check.frame = NSRect(x: right - 14, y: mid - 7, width: 14, height: 14)
            right = check.frame.minX - 4
        }
        if let chevron {
            chevron.frame = NSRect(x: right - 16, y: mid - 8, width: 16, height: 16)
            right = chevron.frame.minX - 6
            let w = ceil(secondary.textWidth)
            secondary.frame = NSRect(x: right - w, y: mid - 10, width: w, height: 20)
            right = secondary.frame.minX - 8
        }
        if let star {
            star.frame = NSRect(x: right + 4 - 24, y: mid - 12, width: 24, height: 24)
            right = star.frame.minX - 2
        }
        if let kbd {
            let w = kbd.intrinsicContentSize.width
            kbd.frame = NSRect(x: right - w, y: mid - 10, width: w, height: 20)
            right = kbd.frame.minX - 6
        }
        var x: CGFloat = 8
        if let providerIcon {
            providerIcon.frame = NSRect(x: x, y: mid - 8, width: 16, height: 16)
            x += 16 + 10
        }
        let badgeW = Self.newBadgeWidth(newBadge, name: name.textWidth, room: right - x)
        let nameW = max(0, min(ceil(name.textWidth), right - x - badgeW))
        name.frame = NSRect(x: x, y: mid - 10, width: nameW, height: 20)
        if let newBadge {
            let s = newBadge.intrinsicContentSize
            newBadge.frame = NSRect(x: x + nameW + 8, y: mid - s.height / 2, width: s.width, height: s.height)
        }
    }

    /// The room the NEW badge takes after the name, 0 when it hides: the name and the jump key keep their room, so
    /// the badge, a status, gives way first.
    static func newBadgeWidth(_ badge: NSView?, name: CGFloat, room: CGFloat) -> CGFloat {
        guard let badge else { return 0 }
        let w = 8 + badge.intrinsicContentSize.width
        badge.isHidden = ceil(name) + w > room
        return badge.isHidden ? 0 : w
    }

    /// Redesign docked: glyph, name, the check after it and the badge; the backend count and chevron, or the star on
    /// hover and the jump key, at the right.
    private func layoutStacked() {
        let mid = bounds.height / 2
        var right = bounds.width - 8
        if let kbd {
            let w = kbd.intrinsicContentSize.width
            kbd.frame = NSRect(x: right - w, y: mid - 10, width: w, height: 20)
            right = kbd.frame.minX - 4
        }
        // The star shows only on the highlighted row, so the name and badge may use its room; on that row the
        // badge hides where the star covers it (`updateColors`).
        if let star { star.frame = NSRect(x: right - 24, y: mid - 12, width: 24, height: 24) }
        if let chevron {
            chevron.frame = NSRect(x: right - 16, y: mid - 8, width: 16, height: 16)
            right = chevron.frame.minX - 6
            let w = ceil(secondary.textWidth)
            secondary.frame = NSRect(x: right - w, y: mid - 10, width: w, height: 20)
            right = secondary.frame.minX - 8
        }
        var x: CGFloat = 8
        if let providerIcon {
            providerIcon.frame = NSRect(x: x, y: mid - 8, width: 16, height: 16)
            x += 16 + 10
        }
        let checkW: CGFloat = check == nil ? 0 : 8 + 14
        let fixed = checkW + Self.newBadgeWidth(newBadge, name: name.textWidth, room: right - x - checkW)
        badgeFits = newBadge.map { !$0.isHidden } ?? false
        let nameW = max(0, min(ceil(name.textWidth), right - x - fixed))
        name.frame = NSRect(x: x, y: mid - 10, width: nameW, height: 20)
        x += nameW
        if let check { check.frame = NSRect(x: x + 8, y: mid - 7, width: 14, height: 14); x += 8 + 14 }
        if let newBadge {
            let s = newBadge.intrinsicContentSize
            newBadge.frame = NSRect(x: x + 8, y: mid - s.height / 2, width: s.width, height: s.height)
        }
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    func restyle() { needsDisplay = true; updateColors() }
    override func updateLayer() { updateColors() }

    private func updateColors() {
        let highlighted = picker.highlightedRow == index
        if capy {
            // A faint fill on the highlighted row, as Redesign's menus; the star and jump key show only there.
            fill.backgroundColor = highlighted ? Themed.color(\.contrastForeground, 0.07).cgColor(in: self) : nil
            name.color = Themed.color(\.contrastForeground)
            secondary.color = Themed.color(\.contrastMutedForeground)
            chevron?.strokeColor = Themed.color(\.contrastMutedForeground)
            check?.strokeColor = Themed.color(\.contrastForeground)
            star?.isHidden = !highlighted && !(star?.state.hovered ?? false)
            kbd?.isHidden = !highlighted && !stacked
            if stacked, let newBadge, let star {
                newBadge.isHidden = !badgeFits || !star.isHidden && newBadge.frame.maxX > star.frame.minX - 4
            }
            return
        }
        let modern = ComposerDesign.uses3814(dark: effectiveAppearance.isDark)
        // 4928 ModelListRow.tsx:47 drops the selected fill (`selectedFill={false}`); Glass retains its previous fill.
        let color: NSColor? = highlighted ? Themed.color(\.accent) : (isSelected && !modern ? Themed.color(\.contrastForeground, 0.08) : nil)
        fill.backgroundColor = color?.cgColor(in: self)
        name.color = highlighted ? Themed.color(\.contrastAccentForeground) : (isSelected ? Themed.color(\.contrastForeground) : Themed.color(\.contrastPopoverForeground))
        if modern, case .legacy = row { name.color = highlighted ? Themed.color(\.contrastForeground) : Themed.color(\.contrastMutedForeground) }
        check?.strokeColor = name.color
        if modern {
            // Favorites list every row starred, so there the star shows only on hover (`favoriteStarOnHover`).
            let favorite = { if case .model(let item) = row { return item.isFavorite }; return false }()
            star?.alphaValue = highlighted || (star?.state.hovered ?? false) || (favorite && picker.rail != .favorites) ? 1 : 0
        }
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
        // Redesign: a status, not an action, so the muted text on a hairline rim and no fill; the accent already
        // marks the selected model.
        if ThemeRuntime.isDither(dark: effectiveAppearance.isDark) {
            layer?.backgroundColor = nil
            layer?.borderColor = Themed.color(\.contrastForeground, 0.08).cgColor(in: self)
            label.color = Themed.color(\.contrastMutedForeground)
            return
        }
        layer?.backgroundColor = Themed.color(\.update, 0.15).cgColor(in: self)
        layer?.borderColor = Themed.color(\.update, 0.35).cgColor(in: self)
        label.color = Themed.color(\.updateForeground)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
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
        fill.cornerRadius = DesignGeometry.controlRadius(8, in: self)
        fill.backgroundColor = state.hovered ? Themed.color(\.accent).cgColor(in: self) : nil
        let color = favorite ? Themed.color(\.warning) : (state.hovered ? Themed.color(\.contrastForeground) : Themed.color(\.contrastMutedForeground))
        icon.strokeColor = color
        icon.fillColor = favorite ? color : nil
    }
}
