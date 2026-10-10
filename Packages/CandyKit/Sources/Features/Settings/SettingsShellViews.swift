import AppKit
import DesignSystem

/// The settings pages in T3's nav order (settingsSearch.ts `SETTINGS_SECTION_LABELS`, SettingsSidebarNav.tsx
/// icons). "Project" only shows while a project scope is chosen, which CandyWrapper has no UI for yet.
public enum SettingsSection: String, CaseIterable, Sendable {
    case general, appearance, keybindings, snapShots, providers, integrations, scheduledTasks, sourceControl, storage, connections, archive

    public var label: String {
        switch self {
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
        }
    }

    var icon: IconName {
        switch self {
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
        }
    }

    /// Pages that work. The rest list like T3's and stay disabled.
    // ponytail: only Connections is built; the other pages come with milestone 7 (settings), enable them there
    public var isAvailable: Bool { self == .connections }

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
    let brand = SidebarBrandView()
    let search = SidebarSearchFieldView()
    private let searchKbd = KbdView("/")
    public private(set) var items: [SettingsSection: SidebarMenuButtonView] = [:]
    let back = SidebarMenuButtonView("Back", icon: .arrowLeft)
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
        didSet { for (section, item) in items { item.isActive = section == selected } }
    }
    public var onSelect: ((SettingsSection) -> Void)?
    public var onBack: (() -> Void)?
    public var onToggleSidebar: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(backdrop)
        addSubview(brand)
        addSubview(trigger)
        // ponytail: the settings search shows but does not search; T3 searches every setting's title (M7)
        search.field.isEditable = false
        search.field.isSelectable = false
        search.field.setAccessibilityLabel("Search settings")
        addSubview(search)
        addSubview(searchKbd)
        for section in SettingsSection.allCases {
            let item = SidebarMenuButtonView(section.label, icon: section.icon)
            if section == .snapShots { item.iconDefinition = SettingsSection.snapShotIcon }
            item.isEnabled = section.isAvailable
            item.isActive = section == selected
            item.action = { [weak self] in self?.select(section) }
            items[section] = item
            addSubview(item)
        }
        // T3 Connect's sidebar sign-in sits above the utility row (SettingsSidebarNav.tsx:352-362), WP6.4.
        back.action = { [weak self] in self?.onBack?() }
        addSubview(back)
        signIn.action = { [weak self] in self?.onSignIn?() }
        signIn.isHidden = true
        addSubview(signIn)
        avatar.action = { [weak self] in guard let self else { return }; self.onAccount?(self.avatar) }
        avatar.isHidden = true
        addSubview(avatar)
        trigger.action = { [weak self] in self?.onToggleSidebar?() }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Settings")
        applyStage()
    }

    private func select(_ section: SettingsSection) {
        guard section.isAvailable else { return }
        selected = section
        onSelect?(section)
    }

    private func applyStage() {
        backdrop.isHidden = stage != .nightly
        brand.onBackdrop = stage == .nightly
        trigger.mediaTint = stage == .nightly ? StageBackdropView.ink() : nil
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // `SidebarChromeHeader`, as in the thread sidebar.
        backdrop.frame = NSRect(x: 0, y: 0, width: w, height: 80)
        let controlsLeft = SidebarMetrics.controlsLeft(windowedMac: windowedMac)
        trigger.frame = NSRect(x: controlsLeft + 1, y: (52 - 28) / 2, width: 28, height: 28)
        let bs = brand.intrinsicContentSize
        brand.frame = NSRect(x: SidebarMetrics.titlebarContentLeft(windowedMac: windowedMac), y: 12, width: min(bs.width, max(0, w - 12 - 130)), height: 28)
        // `SidebarGroup` (p-2), `flex-col gap-2`: the h-8 search row, then `SidebarMenu` rows 4px apart.
        search.frame = NSRect(x: 8, y: 60, width: w - 16, height: 32)
        let kbd = searchKbd.intrinsicContentSize
        searchKbd.frame = NSRect(x: w - 8 - 8 - kbd.width, y: 60 + (32 - kbd.height) / 2, width: kbd.width, height: kbd.height)
        var y: CGFloat = 60 + 32 + 8
        for section in SettingsSection.allCases {
            items[section]?.frame = NSRect(x: 8, y: y, width: w - 16, height: 32)
            y += 36
        }
        // `SidebarFooter` (`px-2 py-1 gap-2`): the sign-in row above `flex items-center gap-1` of Back and the avatar.
        let row: CGFloat = avatar.isHidden ? 32 : 36
        let rowY = h - 4 - row
        back.frame = NSRect(x: 8, y: rowY + (row - 32) / 2, width: w - 16 - (avatar.isHidden ? 0 : 36 + 4), height: 32)
        avatar.frame = NSRect(x: w - 8 - 36, y: rowY, width: 36, height: 36)
        signIn.frame = NSRect(x: 8, y: rowY - 8 - 32, width: w - 16, height: 32)
    }
}

/// Clerk's `UserButton` trigger (`rounded-lg p-1 hover:bg-sidebar-row-hover`, avatar `size-7`).
// ponytail: draws the email's initial on a muted circle; Clerk shows the account image, load it if users set one
public final class T3ConnectAvatarButton: ControlView {
    private let circle = CALayer()
    private let initial = LabelView("", font: DSFont.ui(12, weight: .semibold), color: Themed.color(\.foreground))
    public var email = "" {
        didSet {
            initial.text = email.first.map { String($0).uppercased() } ?? ""
            setAccessibilityLabel("Open user button")
            toolTip = email
            needsLayout = true
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        layer?.cornerRadius = 10
        circle.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(circle)
        initial.lineHeight = 16
        initial.alignment = .center
        addSubview(initial)
        setAccessibilityRole(.button)
    }

    public override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }

    public override func updateLayer() {
        layer?.backgroundColor = state.hoverOrPressed ? Themed.color(\.sidebarRowHover, sidebar: true).cgColor(in: self) : nil
        circle.backgroundColor = Themed.color(\.primary, 0.18).cgColor(in: self)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        circle.frame = CGRect(x: 4, y: 4, width: 28, height: 28)
        circle.cornerRadius = 14
        CATransaction.commit()
        initial.frame = NSRect(x: 4, y: 10, width: 28, height: 16)
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
    /// Escape goes back (`useEscapeToGoBack`).
    public var onEscape: (() -> Void)?

    public var page: (NSView & SettingsGroupRow)? {
        didSet {
            oldValue?.removeFromSuperview()
            if let page { document.addSubview(page) }
            header.section = page == nil ? nil : header.section
            needsLayout = true
        }
    }

    public override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: document)
        super.init(frame: frameRect)
        addSubview(scroll)
        addSubview(header)
        addSubview(toasts)
        toasts.layer?.zPosition = 3
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Lays the page out again after its content changed height.
    public func pageChanged() { needsLayout = true; layoutSubtreeIfNeeded() }

    public override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: SettingsHeaderView.height)
        scroll.frame = NSRect(x: 0, y: SettingsHeaderView.height, width: bounds.width, height: max(0, bounds.height - SettingsHeaderView.height))
        let gutter: CGFloat = 6
        let inner = max(0, bounds.width - 2 * gutter)
        let container = min(1024, inner)
        let contentWidth = max(0, container - 48)
        let x = gutter + (inner - container) / 2 + 24
        let pageHeight = page?.height(forWidth: contentWidth) ?? 0
        document.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: max(scroll.bounds.height, 24 + pageHeight + 48))
        page?.frame = NSRect(x: x.rounded(), y: 24, width: contentWidth, height: pageHeight)
        toasts.frame = ToastViewport.frame(in: bounds)
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

    public var section: SettingsSection? = .connections {
        didSet { current.text = section?.label ?? "Settings"; needsLayout = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [root, slash, current] { l.lineHeight = 20; addSubview(l) }
        current.text = section?.label ?? "Settings"
        setAccessibilityLabel("Settings breadcrumb")
    }

    public override func layout() {
        super.layout()
        let y = (Self.height - 20) / 2
        var x: CGFloat = 20
        root.isHidden = section == nil
        slash.isHidden = section == nil
        if section != nil {
            root.frame = NSRect(x: x, y: y, width: ceil(root.textWidth), height: 20)
            x += ceil(root.textWidth) + 12
            slash.frame = NSRect(x: x, y: y, width: ceil(slash.textWidth), height: 20)
            x += ceil(slash.textWidth) + 12
        }
        current.frame = NSRect(x: x, y: y, width: max(0, min(ceil(current.textWidth) + 1, bounds.width - 20 - x)), height: 20)
    }
}
