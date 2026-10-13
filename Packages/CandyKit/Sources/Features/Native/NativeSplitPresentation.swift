import AppKit
import DesignSystem

/// What Glass Native's toolbar buttons do. The app wires them to its existing commands.
@MainActor
public struct NativeToolbarActions {
    /// T3's panel toggles, in its order (PanelLayoutControls.tsx:76): thread details, terminal drawer, right panel.
    public var details: () -> Void = {}
    public var terminal: () -> Void = {}
    public var rightPanel: () -> Void = {}
    /// Maximize or restore the right panel; the toolbar shows it while the right panel is open (ChatView.tsx:11211-11232).
    public var maximize: () -> Void = {}
    public var rightPanelOpen: () -> Bool = { false }
    /// The toggles' on states: thread details, terminal drawer, right panel, and whether the panel is maximized.
    public var panelStates: () -> NativePanelStates = { NativePanelStates() }
    /// Whether the panel toggles apply now: a thread or draft shows in the detail column.
    public var threadShown: () -> Bool = { false }
    public init() {}
}

/// What the toolbar's panel toggles show as on.
public struct NativePanelStates: Equatable, Sendable {
    public var details = false, terminal = false, rightPanel = false, maximized = false
    public init(details: Bool = false, terminal: Bool = false, rightPanel: Bool = false, maximized: Bool = false) {
        self.details = details; self.terminal = terminal; self.rightPanel = rightPanel; self.maximized = maximized
    }
}

/// Glass Native's main window (docs/glass-native.md): a unified toolbar over a split view with the sidebar,
/// the detail and a collapsed inspector, modeled on T3 Mobile's iPad split (createWorkspaceStackNavigator.ios.tsx:
/// 184-283). The split view controller sits in a plain root view, because popups, modals and the palette add
/// themselves to the window's content view.
// ponytail: the split view's Auto Layout puts every view in the window into one layout engine, about 1.3 MB plus
// 3 KB per view (2.7 MB and 15 to 20 ms at launch with the window's 780 views, half of them hidden; docs/glass-native.md
// "Perf audit"); create the thread panel's hidden panels on first use, or lay the split out by frames, if that matters
@MainActor
public final class NativeSplitPresentation: NSObject, MainPresentation, NSToolbarDelegate {
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
        window.titleVisibility = .hidden
    }

    public func ownsChrome(_ view: NSView) -> Bool { view === split.view }

    /// The window's title, for the Window menu and Mission Control. The toolbar shows `breadcrumb` instead.
    public func setTitle(_ title: String) {
        guard let window = root.window else { return }
        if window.title != title { window.title = title }
        if !window.subtitle.isEmpty { window.subtitle = "" }
    }

    /// T3's thread breadcrumb in the toolbar, after the sidebar (ChatHeader.tsx:262-375). The app sets it.
    public var breadcrumb: NSView? {
        didSet { breadcrumbItem?.view = breadcrumb }
    }
    private weak var breadcrumbItem: NSToolbarItem?
    private weak var panels: NSSegmentedControl?
    private weak var panelsItem: NSToolbarItem?
    private var maximizeShown = false
    /// The states the panel toggles last showed, to tell which segment a click flipped.
    private var shownStates = NativePanelStates()

    /// Maximize shows only while the right panel is open, as T3's does (ChatView.tsx:11211-11232). The toggles'
    /// group swaps for one with the extra segment.
    public func setMaximizeShown(_ shown: Bool) {
        guard shown != maximizeShown else { return }
        maximizeShown = shown
        guard let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.panels || $0.itemIdentifier == Self.panelsWithMaximize })
        else { return }
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: shown ? Self.panelsWithMaximize : Self.panels, at: index)
    }

    /// Shows the toggles' on states. The app calls it when a panel opens or closes; AppKit's validation after
    /// each event calls it too.
    public func syncPanelStates() {
        guard let control = panels else { return }
        let states = actions.panelStates()
        shownStates = states
        let segments = panelSegments
        for (index, segment) in segments.enumerated() where index < control.segmentCount {
            let selected = states[keyPath: segment.state]
            if control.isSelected(forSegment: index) != selected { control.setSelected(selected, forSegment: index) }
        }
        if let i = segments.firstIndex(where: { $0.state == \.maximized }), i < control.segmentCount {
            let label = states.maximized ? "Restore panel" : "Maximize panel"
            if control.toolTip(forSegment: i) != label {
                let symbol = states.maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                control.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: i)
                control.setToolTip(label, forSegment: i)
            }
        }
        // T3 shows the toggles only over a thread or draft; Settings and the utility pages have none.
        let shown = actions.threadShown()
        if #available(macOS 15, *), let item = panelsItem, item.isHidden == shown { item.isHidden = !shown }
        // A maximized panel covers the chat and runs its tabs where the breadcrumb sits; T3 hides the header then.
        if #available(macOS 15, *), let item = breadcrumbItem, item.isHidden != states.maximized { item.isHidden = states.maximized }
    }

    // MARK: Toolbar

    static let sidebarToggle = NSToolbarItem.Identifier("candy.sidebar")
    static let title = NSToolbarItem.Identifier("candy.breadcrumb")
    static let panels = NSToolbarItem.Identifier("candy.panels")
    static let panelsWithMaximize = NSToolbarItem.Identifier("candy.panelsWithMaximize")

    private struct PanelSegment {
        let symbol: String, label: String, state: KeyPath<NativePanelStates, Bool>
        let action: @MainActor (NativeToolbarActions) -> Void
    }

    /// T3's panel toggles in its order (PanelLayoutControls.tsx:61-127, Lucide square-menu, panel-bottom and
    /// panel-right with T3's words), with Maximize before the terminal while the right panel is open.
    private var panelSegments: [PanelSegment] {
        var segments = [
            PanelSegment(symbol: "list.bullet.rectangle", label: "Toggle thread details", state: \.details) { $0.details() },
            PanelSegment(symbol: "rectangle.bottomhalf.inset.filled", label: "Toggle terminal drawer", state: \.terminal) { $0.terminal() },
            PanelSegment(symbol: "sidebar.right", label: "Toggle right panel", state: \.rightPanel) { $0.rightPanel() },
        ]
        if maximizeShown {
            segments.insert(PanelSegment(symbol: "arrow.up.left.and.arrow.down.right", label: "Maximize panel", state: \.maximized) { $0.maximize() }, at: 1)
        }
        return segments
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggle, .sidebarTrackingSeparator, Self.title, .flexibleSpace, maximizeShown ? Self.panelsWithMaximize : Self.panels]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggle, .sidebarTrackingSeparator, Self.title, .flexibleSpace, Self.panels, Self.panelsWithMaximize]
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        case Self.sidebarToggle:
            // T3's plain panel-left glyph beside the traffic lights, not a glass button.
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.label = "Toggle Sidebar"
            item.toolTip = "Toggle Sidebar"
            item.isBordered = false
            item.target = self
            item.action = #selector(pressSidebar)
            return item
        case Self.title:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = breadcrumb
            item.label = "Thread"
            // Plain text like T3's header, not a glass button.
            item.isBordered = false
            item.visibilityPriority = .high
            breadcrumbItem = item
            return item
        case Self.panels, Self.panelsWithMaximize:
            // A plain segmented control, not an `NSToolbarItemGroup`: the group's control draws its on segments in
            // the system's saturated accent, and T3 marks an on toggle with the subtle `accent` tint
            // (`data-pressed:bg-accent`).
            let segments = panelSegments
            let control = NSSegmentedControl(images: segments.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label)! },
                                             trackingMode: .selectAny, target: self, action: #selector(pressPanel(_:)))
            // T3's 4% `accent` tint vanishes on the toolbar's glass, and AppKit picks the glyph color from the bezel's
            // own color, so the tint is an opaque equivalent that keeps the glyph in the foreground color.
            control.selectedSegmentBezelColor = Themed.pick(light: NSColor(srgbRed: 0xe4 / 255, green: 0xe4 / 255, blue: 0xe7 / 255, alpha: 1),
                                                            dark: NSColor(white: 0.30, alpha: 1))
            for (i, segment) in segments.enumerated() { control.setToolTip(segment.label, forSegment: i) }
            control.setAccessibilityLabel("Panels")
            let item = NativeValidatedToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = "Panels"
            item.onValidate = { [weak self] in self?.syncPanelStates() }
            panels = control
            panelsItem = item
            syncPanelStates()
            return item
        default: return nil
        }
    }

    @objc private func pressSidebar() { toggleSidebar() }

    /// The segment whose selection the click flipped runs its toggle; the panel's real state then decides what shows.
    @objc private func pressPanel(_ sender: Any?) {
        guard let control = panels else { return }
        let segments = panelSegments
        if let index = segments.indices.first(where: { control.isSelected(forSegment: $0) != shownStates[keyPath: segments[$0].state] }) {
            segments[index].action(actions)
        }
        syncPanelStates()
    }

}

/// A custom-view toolbar item that AppKit's validation, after events and never while idle, reaches.
final class NativeValidatedToolbarItem: NSToolbarItem {
    var onValidate: (() -> Void)?
    override func validate() { onValidate?() }
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

