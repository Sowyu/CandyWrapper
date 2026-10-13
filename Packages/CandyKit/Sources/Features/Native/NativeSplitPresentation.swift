import AppKit
import DesignSystem

/// What Glass Native's toolbar buttons do. The app wires them to its existing commands.
@MainActor
public struct NativeToolbarActions {
    public var newThread: () -> Void = {}
    public var files: () -> Void = {}
    public var git: () -> Void = {}
    public var terminal: () -> Void = {}
    /// Whether Files, Git and Terminal apply now: a thread or draft shows in the detail column.
    public var threadShown: () -> Bool = { false }
    public init() {}
}

/// Glass Native's main window (docs/glass-native.md): a unified toolbar over a split view with the sidebar,
/// the detail and a collapsed inspector, modeled on T3 Mobile's iPad split (createWorkspaceStackNavigator.ios.tsx:
/// 184-283). The split view controller sits in a plain root view, because popups, modals and the palette add
/// themselves to the window's content view.
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
    private let sidebarColumn: NativeColumnController
    private let detailColumn: NativeColumnController

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
        set { sidebarColumn.content = newValue }
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
        case Self.sidebarToggle: return item(id, "sidebar.left", "Toggle Sidebar", #selector(pressSidebar))
        case Self.newThread: return item(id, "square.and.pencil", "New Thread", #selector(pressNewThread))
        case Self.files: return item(id, "folder", "Files", #selector(pressFiles))
        case Self.git: return item(id, "point.topleft.down.curvedto.point.bottomright.up", "Git", #selector(pressGit))
        case Self.terminal: return item(id, "terminal", "Terminal", #selector(pressTerminal))
        default: return nil
        }
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
    @objc private func pressGit() { actions.git() }
    @objc private func pressTerminal() { actions.terminal() }

    /// AppKit asks on window updates (after events), never while idle.
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.files, Self.git, Self.terminal: actions.threadShown()
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
        // The detail's page starts under the toolbar. The sidebar's content keeps its own 52pt titlebar row
        // (hidden in this mode) and lines that row up with the toolbar, so its search starts just below it.
        let y = detail ? top : top - ThreadHeaderView.height
        content?.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
    }
}
