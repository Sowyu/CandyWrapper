import AppKit
import DesignSystem

/// The settings pages in T3's nav order (settingsSearch.ts `SETTINGS_SECTION_LABELS`, SettingsSidebarNav.tsx
/// icons). "Project" only shows while a project scope is chosen (`isSettingsOverviewVisible`).
public enum SettingsSection: String, CaseIterable, Sendable {
    case projects, general, appearance, keybindings, snapShots, providers, integrations, scheduledTasks, sourceControl, storage, connections, archive
    /// Redesign's Orchestrator tab, CandyWrapper's own; never in T3's nav.
    case orchestrator
    /// Redesign's Connectors tab, CandyWrapper's own; never in T3's nav.
    case connectors
    /// CandyWrapper's own experimental switches, Redesign among them, so it sits last in T3's nav too.
    case experimental
    /// Reached from General > Diagnostics; not in the nav (`SETTINGS_BREADCRUMB_LABELS`).
    case diagnostics, licenses

    /// The page Escape goes back to: General for the pages reached from it.
    public var parent: SettingsSection? { self == .diagnostics || self == .licenses ? .general : nil }

    public var label: String {
        switch self {
        case .projects: "Project"
        case .general: "General"
        case .appearance: "Appearance"
        case .keybindings: "Keybindings"
        case .snapShots: "SnapShots"
        case .providers: "Providers"
        case .integrations: "Integrations"
        case .scheduledTasks: "Scheduled Tasks"
        case .sourceControl: "Source Control"
        case .storage: "Storage"
        case .connections: "Connections"
        case .archive: "Archive"
        case .orchestrator: "Orchestrator"
        case .connectors: "Connectors"
        case .experimental: "Experimental"
        case .diagnostics: "Diagnostics"
        case .licenses: "Open source licenses"
        }
    }

    var icon: IconName {
        switch self {
        case .projects: .panelsTopLeft
        case .general: .settings2
        case .appearance: .palette
        case .keybindings: .keyboard
        case .snapShots: .camera
        case .providers: .bot
        case .integrations: .blocks
        case .scheduledTasks: .calendarClock
        case .sourceControl: .gitBranch
        case .storage: .hardDrive
        case .connections: .link2
        case .archive: .archive
        case .orchestrator: .workflow
        case .connectors: .plug2
        case .experimental: .flaskConical
        case .diagnostics: .activity
        case .licenses: .fileText
        }
    }

    /// Pages that work.
    public var isAvailable: Bool { true }

    /// The nav lists Project only for a project scope (`isSettingsOverviewVisible`).
    static let navSections = allCases.filter { $0 != .diagnostics && $0 != .licenses && $0 != .orchestrator && $0 != .connectors }

    /// SettingsSidebarNav.tsx `SnapShotIcon` (a `createLucideIcon` glyph outside the generated set).
    static let snapShotIcon = IconDefinition(viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24), elements: [
        IconElement(.path(d: "M8 3H6a3 3 0 0 0-3 3v2M16 3h2a3 3 0 0 1 3 3v2M21 16v2a3 3 0 0 1-3 3h-2M8 21H6a3 3 0 0 1-3-3v-2")),
        IconElement(.rect(x: 7, y: 8, w: 10, h: 8, rx: 2, ry: 2)),
        IconElement(.circle(cx: 12, cy: 12, r: 1.5)),
    ])
}

/// The sidebar while settings are open (AppSidebarLayout.tsx: `SidebarChromeHeader` plus
/// `SettingsSidebarNav`): the brand row, the settings search, one row per page, and "Back" in the footer.
public final class SettingsSidebarView: DSView {
    public let trigger = SidebarTriggerView()
    let backdrop = StageBackdropView()
    private let environmentPill = BadgeView("Nightly", variant: .secondary, size: .sm)
    let brand = SidebarBrandView()
    let search = SidebarSearchFieldView()
    private let searchKbd = KbdView("/")
    public private(set) var items: [SettingsSection: SidebarMenuButtonView] = [:]
    let back = SidebarMenuButtonView("Back", icon: .arrowLeft)
    /// Dither (after Capy): the "← Settings" row under the traffic lights, its nav rows and group labels.
    let ditherHeader = DitherSettingsNavRow("Settings", icon: .arrowLeft)
    private(set) var ditherItems: [DitherSettingsSection: DitherSettingsNavRow] = [:]
    private var ditherLabels: [LabelView] = []
    let ditherBack = DitherSettingsNavRow("Back", icon: .arrowLeft)
    let ditherSignIn = DitherSettingsNavRow("Sign in to T3 Connect", icon: .logIn)
    private let searchFill = CALayer()
    private var isDither: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    /// `T3ConnectSidebarSignIn`: shown while signed out of T3 Connect.
    public let signIn = SidebarMenuButtonView("Sign in to T3 Connect", icon: .logIn)
    /// `T3ConnectSidebarAvatar`: Clerk's `UserButton`, shown while signed in. Opens the account menu.
    public let avatar = T3ConnectAvatarButton()

    /// The footer's T3 Connect slot. `.unavailable` hides both, as T3 does without cloud config.
    public enum T3ConnectSlot: Equatable { case unavailable, signedOut, signedIn(String) }
    public var t3Connect: T3ConnectSlot = .unavailable {
        didSet {
            signIn.isHidden = t3Connect != .signedOut
            if case .signedIn(let identifier) = t3Connect { avatar.email = identifier; avatar.isHidden = false } else { avatar.isHidden = true }
            needsLayout = true
        }
    }
    public var onSignIn: (() -> Void)?
    public var onAccount: ((NSView) -> Void)?
    public var windowedMac = true { didSet { needsLayout = true } }
    public var stage: SidebarStage = .nightly { didSet { applyStage() } }

    public var selected: SettingsSection = .connections {
        didSet {
            for (section, item) in items { item.isActive = section == selected }
        }
    }
    /// Redesign's open section (`DitherSettingsSection`); its nav replaces T3's page list.
    public var ditherSelected: DitherSettingsSection = .general {
        didSet { for (section, item) in ditherItems { item.isActive = section == ditherSelected } }
    }
    public var onSelectDither: ((DitherSettingsSection) -> Void)?
    /// A project is picked in the scope: the nav lists Project first.
    public var showsProject = false {
        didSet { guard showsProject != oldValue else { return }; items[.projects]?.isHidden = !showsProject || isSearching; needsLayout = true }
    }
    public var onSelect: ((SettingsSection) -> Void)?
    public var onBack: (() -> Void)?
    /// The brand's link to "/" (SidebarChrome.tsx:110-123).
    public var onHome: (() -> Void)?
    public var onToggleSidebar: (() -> Void)?
    /// A search result was chosen (`handleSearchResultClick`): the page opens at its anchor.
    public var onSearchResult: ((SettingsSearchItem) -> Void)?

    /// The items search runs over (`useAvailableSettingsSearchItems`).
    public var searchItems: [SettingsSearchItem] = SettingsSearch.available(SettingsSearchAvailability()) { didSet { runSearch() } }
    public private(set) var results: [SettingsSearchItem] = []
    public private(set) var activeResult = 0
    private var resultRows: [SettingsSearchResultRow] = []
    private let noResults = LabelView("No settings found", font: DSFont.ui(12), color: Themed.color(\.sidebarMutedForeground, sidebar: true))
    private var isSearching: Bool { !search.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(backdrop)
        addSubview(environmentPill)
        ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains("environmentIdentificationMode") { self?.applyStage() }
        }
        OrchestratorStore.shared.observe { [weak self] in self?.needsLayout = true }
        addSubview(brand)
        addSubview(trigger)
        search.field.setAccessibilityLabel("Search settings")
        search.clearButton.setAccessibilityLabel("Clear settings search")
        search.onChange = { [weak self] _ in self?.activeResult = 0; self?.runSearch() }
        search.onCommand = { [weak self] selector in self?.searchCommand(selector) ?? false }
        addSubview(search)
        addSubview(searchKbd)
        noResults.alignment = .center
        noResults.lineHeight = 16
        noResults.isHidden = true
        addSubview(noResults)
        for section in SettingsSection.navSections {
            let item = SidebarMenuButtonView(section.label, icon: section.icon)
            if section == .snapShots { item.iconDefinition = SettingsSection.snapShotIcon }
            item.isEnabled = section.isAvailable
            item.isActive = section == selected
            item.isHidden = section == .projects && !showsProject
            item.action = { [weak self] in self?.select(section) }
            items[section] = item
            addSubview(item)
        }
        // T3 Connect's sidebar sign-in sits above the utility row (SettingsSidebarNav.tsx:352-362), WP6.4.
        back.action = { [weak self] in self?.onBack?() }
        brand.action = { [weak self] in self?.onHome?() }
        addSubview(back)
        signIn.action = { [weak self] in self?.onSignIn?() }
        signIn.isHidden = true
        addSubview(signIn)
        avatar.action = { [weak self] in guard let self else { return }; self.onAccount?(self.avatar) }
        avatar.isHidden = true
        addSubview(avatar)
        trigger.action = { [weak self] in self?.onToggleSidebar?() }
        searchFill.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(), "hidden": NSNull()]
        searchFill.cornerRadius = DitherChrome.controlRadius
        searchFill.borderWidth = 0.5
        layer?.insertSublayer(searchFill, at: 0)
        for (label, sections) in DitherSettingsSection.groups {
            if let label {
                let l = LabelView(label, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.sidebarMutedForeground, sidebar: true))
                l.lineHeight = 16
                ditherLabels.append(l)
                addSubview(l)
            }
            for section in sections {
                let row = DitherSettingsNavRow(section.label, icon: section.icon)
                row.isActive = section == ditherSelected
                row.action = { [weak self] in self?.ditherSelected = section; self?.onSelectDither?(section) }
                ditherItems[section] = row
                addSubview(row)
            }
        }
        ditherHeader.action = { [weak self] in self?.onBack?() }
        ditherBack.action = { [weak self] in self?.onBack?() }
        ditherSignIn.action = { [weak self] in self?.onSignIn?() }
        for v in [ditherHeader, ditherBack, ditherSignIn] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Settings")
        applyStage()
    }

    private func select(_ section: SettingsSection) {
        guard section.isAvailable else { return }
        selected = section
        onSelect?(section)
    }

    /// `/` focuses and selects the search (SettingsSidebarNav.tsx:139-167).
    public func focusSearch() {
        window?.makeFirstResponder(search.field)
        search.field.currentEditor()?.selectAll(nil)
    }

    /// Sets the query as if typed (tests, captures).
    func setQuery(_ query: String) { search.text = query; activeResult = 0; runSearch() }

    private func runSearch() {
        results = isSearching ? SettingsSearch.search(search.text, in: searchItems) : []
        activeResult = min(activeResult, max(results.count - 1, 0))
        while resultRows.count < results.count {
            let row = SettingsSearchResultRow()
            addSubview(row)
            resultRows.append(row)
        }
        for (i, row) in resultRows.enumerated() {
            row.isHidden = i >= results.count
            guard i < results.count else { continue }
            let item = results[i]
            row.configure(item, dither: isDither)
            row.isActive = i == activeResult
            row.action = { [weak self] in self?.choose(item) }
            row.onHover = { [weak self] in self?.setActive(i) }
        }
        noResults.isHidden = !(isSearching && results.isEmpty)
        searchKbd.isHidden = isSearching
        for (section, item) in items { item.isHidden = isSearching || (section == .projects && !showsProject) }
        needsLayout = true
    }

    private func setActive(_ i: Int) {
        guard i != activeResult, results.indices.contains(i) else { return }
        activeResult = i
        for (j, row) in resultRows.enumerated() { row.isActive = j == i }
    }

    private func choose(_ item: SettingsSearchItem) {
        search.text = ""
        activeResult = 0
        runSearch()
        onSearchResult?(item)
    }

    /// `handleSearchKeyDown`: Escape clears, arrows move the active result, Return opens it.
    private func searchCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            guard isSearching else { return false }
            search.text = ""
            activeResult = 0
            runSearch()
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard !results.isEmpty else { return false }
            setActive((activeResult + 1) % results.count)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return false }
            setActive((activeResult - 1 + results.count) % results.count)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard results.indices.contains(activeResult) else { return false }
            choose(results[activeResult])
            return true
        default:
            return false
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStage()
        needsDisplay = true
    }

    public override func updateLayer() {
        super.updateLayer()
        // Capy's search field: a `--section` fill under a `--border-1` hairline.
        searchFill.backgroundColor = Themed.color(light: \.foreground, 0.04, dark: \.foreground, 0.035).cgColor(in: self)
        searchFill.borderColor = Themed.color(light: \.foreground, 0.08, dark: \.foreground, 0.08).cgColor(in: self)
    }

    private func applyStage() {
        let mode = ClientSettingsStore.shared.current.string("environmentIdentificationMode")
        // Dither keeps Capy's plain sidebar.
        let artwork = mode == "artwork" && stage == .nightly && !isDither
        backdrop.isHidden = !artwork
        brand.onBackdrop = artwork
        trigger.mediaTint = artwork ? StageBackdropView.ink() : nil
        environmentPill.title = stage == .dev ? "Dev" : "Nightly"
        environmentPill.isHidden = mode != "pill" || stage == .none
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let dither = isDither
        brand.isHidden = dither
        searchKbd.isHidden = dither || isSearching
        back.isHidden = dither
        for (section, item) in items { item.isHidden = dither || isSearching || (section == .projects && !showsProject) }
        signIn.isHidden = dither || t3Connect != .signedOut
        for v in [ditherHeader, ditherBack] as [NSView] + Array(ditherItems.values) + ditherLabels { v.isHidden = !dither }
        ditherSignIn.isHidden = !dither || t3Connect != .signedOut
        searchFill.isHidden = !dither
        if dither { layoutDither(); return }
        let w = bounds.width, h = bounds.height
        // `SidebarChromeHeader`, as in the thread sidebar.
        backdrop.frame = NSRect(x: 0, y: 0, width: w, height: 80)
        let controlsLeft = SidebarMetrics.controlsLeft(windowedMac: windowedMac)
        trigger.frame = NSRect(x: controlsLeft + 1, y: (52 - 28) / 2, width: 28, height: 28)
        let bs = brand.intrinsicContentSize
        brand.frame = NSRect(x: SidebarMetrics.titlebarContentLeft(windowedMac: windowedMac), y: 12, width: min(bs.width, max(0, w - 12 - 130)), height: 28)
        let pillSize = environmentPill.intrinsicContentSize
        environmentPill.frame = NSRect(x: brand.frame.maxX + 12, y: 18, width: pillSize.width, height: pillSize.height)
        environmentPill.alphaValue = environmentPill.frame.maxX <= w - 12 ? 1 : 0
        // `SidebarGroup` (p-2), `flex-col gap-2`: the h-8 search row, then `SidebarMenu` rows 4px apart.
        search.frame = NSRect(x: 8, y: 60, width: w - 16, height: 32)
        let kbd = searchKbd.intrinsicContentSize
        searchKbd.frame = NSRect(x: w - 8 - 8 - kbd.width, y: 60 + (32 - kbd.height) / 2, width: kbd.width, height: kbd.height)
        var y: CGFloat = 60 + 32 + 8
        if isSearching {
            // "No settings found" (`px-2 py-6 text-center text-xs`), then the results (`min-h-10`, p-2, gap-1).
            noResults.frame = NSRect(x: 16, y: y + 24, width: w - 32, height: 16)
            if results.isEmpty { y += 64 + 8 }
            for row in resultRows where !row.isHidden {
                row.frame = NSRect(x: 8, y: y, width: w - 16, height: SettingsSearchResultRow.height)
                y += SettingsSearchResultRow.height + 4
            }
        } else {
            for section in SettingsSection.navSections where section != .projects || showsProject {
                items[section]?.frame = NSRect(x: 8, y: y, width: w - 16, height: 32)
                y += 36
            }
        }
        // `SidebarFooter` (`px-2 py-1 gap-2`): the sign-in row above `flex items-center gap-1` of Back and the avatar.
        let row: CGFloat = avatar.isHidden ? 32 : 36
        let rowY = h - 4 - row
        back.frame = NSRect(x: 8, y: rowY + (row - 32) / 2, width: w - 16 - (avatar.isHidden ? 0 : 36 + 4), height: 32)
        avatar.frame = NSRect(x: w - 8 - 36, y: rowY, width: 36, height: 36)
        signIn.frame = NSRect(x: 8, y: rowY - 8 - 32, width: w - 16, height: 32)
    }

    /// Dither, after Capy's settings sidebar: the traffic lights keep the 52pt titlebar row (the window draws back and
    /// forward at its right end), then "← Settings" with the collapse button, a filled search field and 28pt nav rows
    /// in labelled groups; Sign in and Back as rows in the footer.
    private func layoutDither() {
        let w = bounds.width, h = bounds.height
        let rowH = DitherSettingsNavRow.height
        var y: CGFloat = DitherChrome.band
        ditherHeader.frame = NSRect(x: 8, y: y, width: max(0, w - 16 - 28 - 4), height: rowH)
        trigger.frame = NSRect(x: w - 8 - 28, y: y, width: 28, height: 28)
        y += rowH + 6
        search.frame = NSRect(x: 8, y: y, width: max(0, w - 16), height: rowH)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        searchFill.frame = search.frame
        CATransaction.commit()
        y += rowH + 10
        if isSearching {
            noResults.frame = NSRect(x: 16, y: y + 24, width: w - 32, height: 16)
            if results.isEmpty { y += 64 + 8 }
            for row in resultRows where !row.isHidden {
                row.frame = NSRect(x: 8, y: y, width: w - 16, height: SettingsSearchResultRow.height)
                y += SettingsSearchResultRow.height + 4
            }
        }
        var labels = ditherLabels.makeIterator()
        for (label, sections) in DitherSettingsSection.groups {
            if label != nil, let l = labels.next() {
                l.isHidden = isSearching
                if !isSearching {
                    // Capy's group header: `h-7 px-2 text-xs font-medium text-muted-foreground-2`, 12pt above it.
                    y += 12
                    l.frame = NSRect(x: 16, y: y + (rowH - 16) / 2, width: max(0, w - 32), height: 16)
                    y += rowH
                }
            }
            for section in sections {
                guard let row = ditherItems[section] else { continue }
                row.isHidden = isSearching || (section == .project && !showsProject) || (section == .orchestrator && !OrchestratorStore.shared.config.enabled)
                if row.isHidden { continue }
                row.frame = NSRect(x: 8, y: y, width: max(0, w - 16), height: rowH)
                y += rowH + 2
            }
        }
        let footer: CGFloat = avatar.isHidden ? rowH : 36
        let rowY = h - 8 - footer
        ditherBack.frame = NSRect(x: 8, y: rowY + (footer - rowH) / 2, width: w - 16 - (avatar.isHidden ? 0 : 36 + 4), height: rowH)
        avatar.frame = NSRect(x: w - 8 - 36, y: rowY, width: 36, height: 36)
        ditherSignIn.frame = NSRect(x: 8, y: rowY - 2 - rowH, width: w - 16, height: rowH)
    }
}

/// Dither's settings nav row (after Capy's sidebar nav): 28pt, a 16pt icon and a 13pt medium label, 6pt corners,
/// Capy's translucent fill on hover and when selected.
final class DitherSettingsNavRow: ControlView {
    static let height: CGFloat = 28
    private var icon: IconView
    private let label: LabelView
    var isActive = false { didSet { setAccessibilitySelected(isActive); needsDisplay = true } }
    var iconDefinition: IconDefinition? {
        didSet {
            guard let iconDefinition else { return }
            icon.removeFromSuperview()
            icon = IconView(definition: iconDefinition, size: 16, color: Themed.color(\.sidebarMutedForeground, sidebar: true))
            addSubview(icon)
            needsLayout = true
            needsDisplay = true
        }
    }

    init(_ text: String, icon name: IconName) {
        icon = IconView(name: name, size: 16)
        label = LabelView(text, font: DSFont.ui(13, weight: .medium), color: Themed.color(\.sidebarForeground, sidebar: true))
        super.init(frame: .zero)
        scalesWhenPressed = false
        label.lineHeight = 20
        addSubview(icon)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 32, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 40), height: 20)
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }

    override func updateLayer() {
        layer?.cornerRadius = DitherChrome.controlRadius
        let fill: NSColor? = isActive ? Themed.color(\.sidebarRowSelected, sidebar: true)
            : state.hoverOrPressed ? Themed.color(\.sidebarRowHover, sidebar: true) : nil
        layer?.backgroundColor = fill?.cgColor(in: self)
        // Keyboard focus shows T3's ring (`focus-visible:ring-2 ring-ring`), as Dither's tabs do.
        layer?.borderWidth = state.focusVisible ? 2 : 0
        layer?.borderColor = state.focusVisible ? Themed.color(\.ring).cgColor(in: self) : nil
        // Capy: muted labels that brighten on hover and selection; icons stay muted.
        let lit = isActive || state.hoverOrPressed
        label.color = Themed.color(\.sidebarForeground, lit ? 1 : 0.82, sidebar: true)
        if iconDefinition == nil { icon.strokeColor = Themed.color(\.sidebarMutedForeground, sidebar: true) }
    }
}

/// One settings search result (SettingsSidebarNav.tsx:296-322): `SidebarMenuButton size="sm"` with
/// `h-auto min-h-10 items-start`, the page's icon (`size-3.5 h-5`, centered on the title's line, muted at 60%), the title (14px
/// medium) over the page label (`text-2xs`, muted at 75%). The active result is `data-active`.
final class SettingsSearchResultRow: ControlView {
    static let height: CGFloat = 8 + 20 + 16 + 8
    private let decoration = BoxDecorationLayer()
    private var icon = IconView(name: .settings2, size: 14)
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.sidebarForeground, sidebar: true))
    private let subtitle = LabelView("", font: DSFont.ui(11), color: Themed.color(\.sidebarMutedForeground, 0.75, sidebar: true))
    var isActive = false { didSet { restyle() } }
    var onHover: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        decoration.host = self
        layer?.addSublayer(decoration)
        title.lineHeight = 20
        subtitle.lineHeight = 16
        for v in [icon, title, subtitle] as [NSView] { addSubview(v) }
        icon.strokeColor = Themed.color(\.sidebarMutedForeground, 0.6, sidebar: true)
        setAccessibilityRole(.button)
        restyle()
    }

    /// Under Redesign the result names the section it opens in.
    func configure(_ item: SettingsSearchItem, dither: Bool = false) {
        let home = dither ? DitherSettingsSection.home(of: item.to, anchor: item.anchor) : nil
        let label = home?.label ?? item.to.label
        title.text = item.title
        subtitle.text = label
        icon.removeFromSuperview()
        let color = Themed.color(\.sidebarMutedForeground, 0.6, sidebar: true)
        icon = home.map { IconView(name: $0.icon, size: 14, strokeColor: color) }
            ?? (item.to == .snapShots ? IconView(definition: SettingsSection.snapShotIcon, size: 14, color: color)
                : IconView(name: item.to.icon, size: 14, strokeColor: color))
        addSubview(icon)
        restyle()
        needsLayout = true
        setAccessibilityLabel("\(item.title), \(label)")
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if state.hovered && !old.hovered { onHover?() }
        restyle()
    }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 10
        if state.hovered { box.fill = Themed.color(\.sidebarRowHover, sidebar: true) }
        if isActive { box.fill = Themed.color(\.sidebarRowSelected, sidebar: true) }
        decoration.boxStyle = box
        // `hover:[&>svg]` and `data-[active=true]:[&>svg]:text-sidebar-foreground` beat the icon's own muted class.
        icon.strokeColor = isActive || state.hovered ? Themed.color(\.sidebarForeground, sidebar: true)
            : Themed.color(\.sidebarMutedForeground, 0.6, sidebar: true)
    }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        icon.frame = NSRect(x: 8, y: 11, width: 14, height: 14)
        title.frame = NSRect(x: 30, y: 8, width: max(0, bounds.width - 38), height: 20)
        subtitle.frame = NSRect(x: 30, y: 28, width: max(0, bounds.width - 38), height: 16)
    }
}

/// Clerk's `UserButton` trigger (`rounded-lg p-1 hover:bg-sidebar-row-hover`, avatar `size-7`).
public final class T3ConnectAvatarButton: ControlView {
    private let avatar = ClerkAvatarView(size: 28)
    public var email = "" {
        didSet {
            setAccessibilityLabel("Open user button")
            toolTip = email
        }
    }
    /// The account image, decoded at display size, or nil for the initials.
    public var image: CGImage? { get { avatar.image } set { avatar.image = newValue } }
    public var initials: String { get { avatar.initials } set { avatar.initials = newValue } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        layer?.cornerRadius = 10
        addSubview(avatar)
        setAccessibilityRole(.button)
    }

    public override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }

    public override func updateLayer() {
        layer?.backgroundColor = state.hoverOrPressed ? Themed.color(\.sidebarRowHover, sidebar: true).cgColor(in: self) : nil
    }

    public override func layout() {
        super.layout()
        avatar.frame = NSRect(x: 4, y: 4, width: 28, height: 28)
    }
}

/// Clerk's `Avatar` (clerk-js `ui/elements/Avatar.tsx`): the user's image in a circle, or their initials
/// when there is no image or it failed to load.
public final class ClerkAvatarView: DSView {
    private let circle = CALayer()
    private let initialsLabel: LabelView
    private let size: CGFloat
    public var image: CGImage? { didSet { circle.contents = image; initialsLabel.isHidden = image != nil; needsDisplay = true } }
    public var initials = "" { didSet { initialsLabel.text = initials } }

    public init(size: CGFloat) {
        self.size = size
        initialsLabel = LabelView("", font: DSFont.ui(size * 0.43, weight: .semibold), color: Themed.color(\.foreground))
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        circle.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "backgroundColor": NSNull()]
        circle.contentsGravity = .resizeAspectFill
        circle.masksToBounds = true
        layer?.addSublayer(circle)
        initialsLabel.lineHeight = ceil(size * 0.57)
        initialsLabel.alignment = .center
        addSubview(initialsLabel)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func updateLayer() {
        circle.backgroundColor = image == nil ? Themed.color(\.primary, 0.18).cgColor(in: self) : nil
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        circle.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        circle.cornerRadius = bounds.width / 2
        circle.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        let lh = initialsLabel.lineHeight ?? 16
        initialsLabel.frame = NSRect(x: 0, y: (bounds.height - lh) / 2, width: bounds.width, height: lh)
    }
}

/// The settings content area (settings.tsx `SettingsContentLayout`): the 52px `WorkspacePageHeader` with
/// the `Settings / <page>` breadcrumb, then the page in a scroll view (`SettingsPageContainer`,
/// `WorkspacePageContainer`: `scrollbar-gutter: stable both-edges` of 6px, `max-w-5xl` for "wide",
/// `px-6 pt-6 pb-12`, sections `gap-8`).
public final class SettingsPageView: DSView {
    public let header = SettingsHeaderView()
    public let toasts = ToastViewport()
    private let document = PageDocument()
    private let scroll: ScrollAreaView
    /// Dither (after Capy's settings): the page's own large title at the top of the column, in place of the breadcrumb.
    let ditherTitle = LabelView("", font: DSFont.ui(22, weight: .medium), color: Themed.color(\.foreground))
    /// Capy's line under the title (`text-sm text-muted-foreground`), for a Redesign section.
    let ditherSubtitle = LabelView("", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    /// A Redesign section's title and description; nil titles the page with its T3 label.
    public var ditherHeading: (title: String, subtitle: String)? { didSet { needsLayout = true } }
    /// Escape goes back (`useEscapeToGoBack`).
    public var onEscape: (() -> Void)?
    /// `WorkspacePageContainer` width: `max-w-4xl` (readable), `max-w-5xl` (wide), `max-w-6xl` (expanded).
    public var containerWidth: CGFloat = 896 { didSet { needsLayout = true } }

    public var page: (NSView & SettingsGroupRow)? {
        didSet {
            oldValue?.removeFromSuperview()
            if let page { document.addSubview(page) }
            header.section = page == nil ? nil : header.section
            needsLayout = true
        }
    }

    public override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: document, scrollbars: .native) // `scrollbar-gutter-both overflow-y-auto` (settingsLayout.tsx:574)
        super.init(frame: frameRect)
        addSubview(scroll)
        addSubview(header)
        addSubview(toasts)
        ditherTitle.lineHeight = 28
        ditherTitle.isHidden = true
        document.addSubview(ditherTitle)
        ditherSubtitle.lineHeight = 20
        ditherSubtitle.isHidden = true
        document.addSubview(ditherSubtitle)
        toasts.layer?.zPosition = 3
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Lays the page out again after its content changed height.
    public func pageChanged() { needsLayout = true; layoutSubtreeIfNeeded() }

    /// Scrolls `target` (a row or section of the page) to the middle and pulses it, as a search jump does
    /// (settingsLayout.tsx `scrollAndFocusSettingsTarget`, `block: "center"`).
    public func reveal(_ target: NSView, highlight: Bool = true) {
        pageChanged()
        let rect = document.convert(target.bounds, from: target)
        let visible = scroll.scrollView.contentView.bounds.height
        let y = max(0, min(rect.midY - visible / 2, document.frame.height - visible))
        scroll.scroll(to: NSPoint(x: 0, y: y))
        if highlight { pulseSettingsTarget(target) }
    }

    /// Back to the top for a newly opened page.
    public func scrollToTop() { scroll.scroll(to: .zero) }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }

    /// Dither shows its art under Settings, dimmer than under a thread (`DitherArtView`).
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DitherArtView.setEmphasis(window == nil ? nil : .settings, from: self)
    }

    public override func layout() {
        super.layout()
        let dither = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: SettingsHeaderView.height)
        scroll.frame = NSRect(x: 0, y: SettingsHeaderView.height, width: bounds.width, height: max(0, bounds.height - SettingsHeaderView.height))
        let gutter: CGFloat = 6
        let inner = max(0, bounds.width - 2 * gutter)
        // Dither: Capy's centred column, about 800pt of content; the two-pane pages keep their width.
        let container = min(dither && containerWidth <= 896 ? 848 : containerWidth, inner)
        let contentWidth = max(0, container - 48)
        let x = gutter + (inner - container) / 2 + 24
        let pageHeight = page?.height(forWidth: contentWidth) ?? 0
        ditherTitle.isHidden = !dither || page == nil
        ditherTitle.text = ditherHeading?.title ?? header.plainTitle ?? header.section?.label ?? ""
        ditherSubtitle.text = ditherHeading?.subtitle ?? ""
        ditherSubtitle.isHidden = ditherTitle.isHidden || ditherHeading == nil
        // Capy's title (`text-xl font-medium`) and its description, then 28pt to the first section.
        let subtitleHeight: CGFloat = ditherSubtitle.isHidden ? 0 : 2 + 20
        let top: CGFloat = dither ? 8 + 28 + subtitleHeight + 28 : 24
        ditherTitle.frame = NSRect(x: (x + 16).rounded(), y: 8, width: max(0, contentWidth - 32), height: 28)
        ditherSubtitle.frame = NSRect(x: (x + 16).rounded(), y: 8 + 28 + 2, width: max(0, contentWidth - 32), height: 20)
        document.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: max(scroll.bounds.height, top + pageHeight + 48))
        page?.frame = NSRect(x: x.rounded(), y: top, width: contentWidth, height: pageHeight)
        toasts.frame = ToastViewport.frame(in: bounds, dither: ThemeRuntime.isDither(dark: effectiveAppearance.isDark))
    }

    final class PageDocument: DSView {}
}

/// `WorkspacePageHeader` with `SettingsBreadcrumb`: "Settings / Connections", 14px medium, `gap-3`,
/// 20px gutter. The bar drags the window.
public final class SettingsHeaderView: TopbarDragView {
    static let height: CGFloat = 52
    private let root = LabelView("Settings", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.mutedForeground))
    private let slash = LabelView("/", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.iconMuted))
    private let current = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    /// "Restore device defaults" (settings.tsx `RestoreDeviceDefaultsButton`), on General only: `xs ghost`
    /// with a 14pt rotate-ccw glyph in `mx-1`.
    public let restore = ButtonView("Restore device defaults", icon: .rotateCcw, variant: .ghost, size: .xs)

    public var section: SettingsSection? = .connections {
        didSet { current.text = plainTitle ?? section?.label ?? "Settings"; needsLayout = true }
    }
    /// A one-crumb page such as "Pull Requests" (`WorkspaceBreadcrumbItem current`).
    public var plainTitle: String? {
        didSet { if plainTitle != nil { section = nil }; current.text = plainTitle ?? section?.label ?? "Settings"; needsLayout = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [root, slash, current] { l.lineHeight = 20; addSubview(l) }
        current.text = section?.label ?? "Settings"
        setAccessibilityLabel("Settings breadcrumb")
        restore.iconSize = 14
        restore.isHidden = true
        addSubview(restore)
    }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }

    public override func layout() {
        super.layout()
        let y = (Self.height - 20) / 2
        var x = contentStart
        // Dither: Capy's settings have no breadcrumb, the page shows its own title (`SettingsPageView.ditherTitle`).
        let crumbless = section != nil && ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        current.isHidden = crumbless
        root.isHidden = section == nil || crumbless
        slash.isHidden = section == nil || crumbless
        if section != nil {
            root.frame = NSRect(x: x, y: y, width: ceil(root.textWidth), height: 20)
            x += ceil(root.textWidth) + 12
            slash.frame = NSRect(x: x, y: y, width: ceil(slash.textWidth), height: 20)
            x += ceil(slash.textWidth) + 12
        }
        current.frame = NSRect(x: x, y: y, width: max(0, min(ceil(current.textWidth) + 1, bounds.width - 20 - x)), height: 20)
        let rw = restore.intrinsicContentSize.width + 8
        restore.frame = NSRect(x: bounds.width - 20 - rw, y: (Self.height - 24) / 2, width: rw, height: 24)
    }
}
