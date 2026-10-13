import AppKit
import DesignSystem

/// What Glass Native's toolbar buttons do. The app wires them to its existing commands.
@MainActor
public struct NativeToolbarActions {
    public var newThread: () -> Void = {}
    public var files: () -> Void = {}
    public var git: () -> Void = {}
    public var terminal: () -> Void = {}
    /// The sidebar's bottom Settings button.
    public var settings: () -> Void = {}
    /// Whether Files, Git and Terminal apply now: a thread or draft shows in the detail column.
    public var threadShown: () -> Bool = { false }
    /// The Git and Terminal menus (T3 Mobile ThreadGitControls.tsx:280-410), built each time one opens.
    public var gitMenu: () -> [NativeMenuEntry] = { [] }
    public var terminalMenu: () -> [NativeMenuEntry] = { [] }
    public init() {}
}

/// One item of a toolbar menu; nil title is a separator.
@MainActor
public struct NativeMenuEntry {
    public var title: String?
    public var symbol: String?
    public var isEnabled = true
    public var action: () -> Void = {}
    public init(_ title: String, symbol: String? = nil, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.isEnabled = isEnabled; self.action = action
    }
    private init() {}
    public static let separator = NativeMenuEntry()
}

/// Builds a toolbar menu from its entries when it opens, so nothing is kept or refreshed while it is closed.
@MainActor
final class NativeToolbarMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let entries: () -> [NativeMenuEntry]
    private var actions: [() -> Void] = []

    init(_ entries: @escaping () -> [NativeMenuEntry]) {
        self.entries = entries
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions = []
        // The toolbar item shows its menu as a pull-down, which keeps the first item as its title.
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        for entry in entries() {
            guard let title = entry.title else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = actions.count
            item.isEnabled = entry.isEnabled
            item.image = entry.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menu.addItem(item)
            actions.append(entry.action)
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

/// Glass Native's main window (docs/glass-native.md): a unified toolbar over a split view with the sidebar,
/// the detail and a collapsed inspector, modeled on T3 Mobile's iPad split (createWorkspaceStackNavigator.ios.tsx:
/// 184-283). The split view controller sits in a plain root view, because popups, modals and the palette add
/// themselves to the window's content view.
// ponytail: the split view's Auto Layout pulls every view in the window into the layout engine, about 4 MB at
// rest with today's custom sidebar and timeline (a split view in the theme frame or frame-based hosts beside it
// did not avoid it); measure again when phases 2 and 3 replace those views with fewer native ones
@MainActor
public final class NativeSplitPresentation: NSObject, MainPresentation, NSToolbarDelegate, NSToolbarItemValidation {
    public let split = NSSplitViewController()
    public let sidebarItem: NSSplitViewItem
    public let detailItem: NSSplitViewItem
    /// Collapsed until later phases move Files, Git, Diff and pull requests into it. A collapsed item never loads
    /// its view.
    public let inspectorItem: NSSplitViewItem
    public let toolbar: NSToolbar
    public var actions = NativeToolbarActions()
    private let rootController = NativeRootController()
    private var collapseObservation: NSKeyValueObservation?
    private weak var sidebarToggleItem: NSToolbarItem?
    private lazy var gitMenu = NativeToolbarMenu { [weak self] in self?.actions.gitMenu() ?? [] }
    private lazy var terminalMenu = NativeToolbarMenu { [weak self] in self?.actions.terminalMenu() ?? [] }
    private let sidebarColumn: NativeColumnController
    private let detailColumn: NativeColumnController
    /// The sidebar's bottom accessory with New chat and Settings (macOS 26), hidden while Settings' navigation shows.
    private var sidebarAccessory: NSViewController?

    /// T3 Mobile's column metrics (createWorkspaceStackNavigator.ios.tsx:198-203).
    public static let sidebarMinimum: CGFloat = 280, sidebarMaximum: CGFloat = 380, sidebarPreferred: CGFloat = 320
    public static let detailMinimum: CGFloat = 320

    /// `autosaveName` keeps the sidebar's width and collapsed state; nil keeps nothing (tests).
    public init(autosaveName: String? = "CandyGlassNative") {
        let sidebarColumn = NativeColumnController(detail: false), detailColumn = NativeColumnController(detail: true)
        self.sidebarColumn = sidebarColumn
        self.detailColumn = detailColumn
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarColumn)
        detailItem = NSSplitViewItem(viewController: detailColumn)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: NSViewController.empty())
        toolbar = NSToolbar(identifier: "CandyGlassNative")
        super.init()
        sidebarItem.minimumThickness = Self.sidebarMinimum
        sidebarItem.maximumThickness = Self.sidebarMaximum
        sidebarItem.canCollapse = true
        detailItem.minimumThickness = Self.detailMinimum
        inspectorItem.isCollapsed = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        split.addSplitViewItem(inspectorItem)
        if let autosaveName { split.splitView.autosaveName = autosaveName }
        if #available(macOS 26, *) {
            let accessory = NSSplitViewItemAccessoryViewController()
            accessory.view = NativeSidebarAccessoryView(newChat: { [weak self] in self?.actions.newThread() },
                                                        settings: { [weak self] in self?.actions.settings() })
            if #available(macOS 26.1, *) { accessory.preferredScrollEdgeEffectStyle = .soft }
            sidebarItem.addBottomAlignedAccessoryViewController(accessory)
            sidebarAccessory = accessory
        }
        // The toggle's glyph follows the sidebar (useThreadHeaderOptions.tsx:31-89). KVO fires only on a change.
        collapseObservation = sidebarItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateSidebarToggle() }
        }
        rootController.addChild(split)
        rootController.view.addSubview(split.view)
        split.view.frame = rootController.view.bounds
        split.view.autoresizingMask = [.width, .height]
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    // MARK: MainPresentation

    public var root: NSView { rootController.view }

    public var sidebarContent: NSView? {
        get { sidebarColumn.content }
        set {
            sidebarColumn.content = newValue
            if #available(macOS 26, *), let accessory = sidebarAccessory as? NSSplitViewItemAccessoryViewController {
                accessory.isHidden = !(newValue is SidebarContentView)
            }
        }
    }

    public var mainContent: NSView? {
        get { detailColumn.content }
        set { detailColumn.content = newValue }
    }

    public var isSidebarOpen: Bool { !sidebarItem.isCollapsed }
    public func toggleSidebar() { split.toggleSidebar(nil) }

    public func install(in window: NSWindow) {
        let frame = window.frame
        window.contentViewController = rootController
        window.setFrame(frame, display: false)
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
    }

    public func ownsChrome(_ view: NSView) -> Bool { view === split.view }

    /// The thread's title and "project · environment" (T3 Mobile ThreadRouteScreen.tsx:441-446) in the toolbar.
    public func setTitle(_ title: String, subtitle: String) {
        guard let window = root.window else { return }
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    // MARK: Toolbar

    static let sidebarToggle = NSToolbarItem.Identifier("candy.sidebar")
    static let newThread = NSToolbarItem.Identifier("candy.newThread")
    static let files = NSToolbarItem.Identifier("candy.files")
    static let git = NSToolbarItem.Identifier("candy.git")
    static let terminal = NSToolbarItem.Identifier("candy.terminal")

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggle, .flexibleSpace, Self.newThread, .sidebarTrackingSeparator, .flexibleSpace, Self.files, Self.git, Self.terminal]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        case Self.sidebarToggle:
            let toggle = item(id, "sidebar.left", "Toggle Sidebar", #selector(pressSidebar))
            sidebarToggleItem = toggle
            updateSidebarToggle()
            return toggle
        case Self.newThread: return item(id, "square.and.pencil", "New Task", #selector(pressNewThread))
        case Self.files: return item(id, "folder", "Files", #selector(pressFiles))
        case Self.git: return menuItem(id, "point.topleft.down.curvedto.point.bottomright.up", "Git", gitMenu)
        case Self.terminal: return menuItem(id, "terminal", "Terminal", terminalMenu)
        default: return nil
        }
    }

    /// "Maximize content" while the sidebar shows, "Show thread sidebar" while it is hidden.
    private func updateSidebarToggle() {
        guard let toggle = sidebarToggleItem else { return }
        let open = !sidebarItem.isCollapsed
        let label = open ? "Maximize Content" : "Show Thread Sidebar"
        toggle.image = NSImage(systemSymbolName: open ? "arrow.up.left.and.arrow.down.right" : "sidebar.left", accessibilityDescription: label)
        toggle.label = label
        toggle.toolTip = label
    }

    /// A toolbar button that opens a menu, as T3 Mobile's Git and Terminal header items do.
    private func menuItem(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String, _ menu: NativeToolbarMenu) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.showsIndicator = false
        item.menu = menu.menu
        return item
    }

    private func item(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    @objc private func pressSidebar() { toggleSidebar() }
    @objc private func pressNewThread() { actions.newThread() }
    @objc private func pressFiles() { actions.files() }

    /// AppKit asks on window updates (after events), never while idle. The Git and Terminal menus disable their
    /// own entries.
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.files: actions.threadShown()
        default: true
        }
    }
}

private extension NSViewController {
    static func empty() -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }
}

/// The window's content: a plain flipped view, so overlays stack over the split view.
final class NativeRootController: NSViewController {
    override func loadView() { view = DSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780)) }
}

/// One column's view controller. Its view hosts one content view and keeps the content clear of the toolbar.
final class NativeColumnController: NSViewController {
    private let detail: Bool
    init(detail: Bool) {
        self.detail = detail
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() { view = NativeColumnView(detail: detail) }

    var content: NSView? {
        get { (view as! NativeColumnView).content }
        set { (view as! NativeColumnView).content = newValue }
    }
}

/// The sidebar column is clear, so macOS gives it the sidebar's own glass. The detail column keeps Glass's frost
/// and tint behind the toolbar and the page.
final class NativeColumnView: DSView {
    private let detail: Bool
    private let surface: GrainSurfaceView?
    private var backdrop: WindowGlassBackdropView?

    var content: NSView? {
        didSet {
            guard content !== oldValue else { return }
            if oldValue?.superview === self { oldValue?.removeFromSuperview() }
            if let content {
                (content as? CustomChromeHiding)?.hidesCustomChrome = true
                addSubview(content)
            }
            needsLayout = true
        }
    }

    init(detail: Bool) {
        self.detail = detail
        surface = detail ? GrainSurfaceView(fill: WindowGlass.mainSurface) : nil
        super.init(frame: NSRect(x: 0, y: 0, width: detail ? 780 : NativeSplitPresentation.sidebarPreferred, height: 780))
        if let surface {
            surface.showsGrain = false
            addSubview(surface)
        }
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if detail { backdrop = WindowGlass.syncBackdrop(backdrop, in: self) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let wasGlass = backdrop != nil
        if detail { backdrop = WindowGlass.syncBackdrop(backdrop, in: self) }
        // Behind glass AppKit leaves box decorations with the old appearance's colors (as in `SidebarLayoutView`).
        if wasGlass || backdrop != nil || !detail { ThemeRuntime.redrawDecorations(in: self) }
    }

    override func layout() {
        super.layout()
        surface?.frame = bounds
        let top = safeAreaInsets.top
        // The thread runs up behind the toolbar and scrolls under it; other pages start below it. The sidebar's
        // content keeps its own 52pt titlebar row (hidden in this mode) and lines that row up with the toolbar, so
        // its search starts just below it.
        if detail, let page = content as? ToolbarUnderlapping {
            page.toolbarInset = top
            content?.frame = bounds
            return
        }
        let y = detail ? top : top - ThreadHeaderView.height
        content?.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
    }
}

/// The sidebar's bottom accessory: a glass "New chat" button (T3 Mobile's bottom-toolbar compose,
/// WorkspaceToolbar.ios.tsx:115-122) and a glass Settings button.
@available(macOS 26, *)
final class NativeSidebarAccessoryView: NSView {
    let newChat: NSButton
    let settings: NSButton
    private let onNewChat: () -> Void
    private let onSettings: () -> Void

    init(newChat: @escaping () -> Void, settings: @escaping () -> Void) {
        onNewChat = newChat
        onSettings = settings
        self.newChat = NSButton(title: "New chat", image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)!,
                                target: nil, action: nil)
        self.settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: NativeSplitPresentation.sidebarPreferred, height: Self.height))
        for button in [self.newChat, self.settings] {
            button.bezelStyle = .glass
            button.controlSize = .large
            addSubview(button)
        }
        self.newChat.imagePosition = .imageLeading
        self.newChat.borderShape = .capsule
        self.newChat.target = self
        self.newChat.action = #selector(pressNewChat)
        self.newChat.toolTip = "New chat"
        self.settings.borderShape = .circle
        self.settings.target = self
        self.settings.action = #selector(pressSettings)
        self.settings.toolTip = "Settings"
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let height: CGFloat = 52

    @objc private func pressNewChat() { onNewChat() }
    @objc private func pressSettings() { onSettings() }

    override func layout() {
        super.layout()
        let h = bounds.height, size: CGFloat = 34
        settings.frame = NSRect(x: 12, y: (h - size) / 2, width: size, height: size)
        let width = max(size, newChat.fittingSize.width + 8)
        newChat.frame = NSRect(x: bounds.width - 12 - width, y: (h - size) / 2, width: width, height: size)
    }
}
