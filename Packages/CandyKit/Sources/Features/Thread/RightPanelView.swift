import AppKit
import DesignSystem
import T3Store

/// The inline right panel (RightPanelTabs.tsx, PreviewPanelShell.tsx): a 52px tab bar (`pl-2`,
/// one tab per surface, the + menu) over the active surface, or the "Open a surface" launcher when
/// nothing is active. The window's panel controls sit at the bar's right edge while it is open;
/// `ThreadPanelView` places them. Surfaces here: the diff, the files explorer and file tabs.
final class RightPanelView: DSView {
    static let tabBarHeight: CGFloat = 52
    /// Room the tab strip leaves at its right: classic's window controls, or Glass Native's toolbar toggles with
    /// Maximize (four 28 pt segments, 140 pt on the toolbar), the toolbar's 10 pt margin and an 8 pt gap. At the
    /// narrowest default width, 420 pt beside the native sidebar, three tabs fit as they do in classic.
    static let classicReserve: CGFloat = 112, nativeToolbarReserve: CGFloat = 158
    var trailingReserve: CGFloat = classicReserve { didSet { if trailingReserve != oldValue { needsLayout = true } } }
    /// `PREVIEW_PANEL_DEFAULT_WIDTH`, `_MIN_WIDTH` and the sibling column's floor
    /// (usePreviewPanelInlineSize.ts).
    static let defaultWidth: CGFloat = 540
    static let minWidth: CGFloat = 360

    /// The inline width: the default, at most 70% of the viewport and leaving the chat column
    /// 360px, never under 360 (`getPreviewPanelMaxWidth`).
    static func width(viewport: CGFloat, container: CGFloat, preferred: CGFloat = defaultWidth) -> CGFloat {
        let maxWidth = max(minWidth, min((viewport * 0.7).rounded(.down), container.rounded(.down) - 360))
        return min(max(preferred, minWidth), maxWidth)
    }

    /// Glass Native (docs/glass-native.md, Visual spec): the panel's chrome sits on the detail's frost and its glyphs
    /// are SF Symbols. Code, diffs, the terminal, pages and device screens stay solid under a `border` hairline.
    var nativeChrome = false {
        didSet {
            guard nativeChrome != oldValue else { return }
            lazyDiff.set(\.nativeChrome, nativeChrome)
            lazyFiles.set(\.nativeChrome, nativeChrome)
            lazyFile.set(\.nativeChrome, nativeChrome)
            lazyPullRequest.set(\.nativeChrome, nativeChrome)
            lazyLauncher.set(\.nativeChrome, nativeChrome)
            browser.nativeChrome = nativeChrome
            terminal.nativeChrome = nativeChrome
            device.nativeChrome = nativeChrome
            apply(state)
        }
    }

    var onRenameDevice: ((String, String) -> Void)?
    let device = DevicePanelView()
    /// The surfaces below are built the first time they show (`LazyView`); wire and feed them
    /// through the lazy holders so a closed panel builds nothing.
    let lazyDiff = LazyView { DiffPanelView() }
    let lazyFiles = LazyView { FilesPanelView() }
    let lazyFile = LazyView { FileSurfaceView() }
    let lazyLauncher = LazyView { SurfaceLauncherView() }
    /// A `pull-request` tab's surface and the thread's linked pull requests.
    let lazyPullRequest = LazyView { PullRequestDetailView() }
    let lazyLinkedPullRequests = LazyView { ThreadPullRequestsListView() }
    var diff: DiffPanelView { lazyDiff.view }
    var files: FilesPanelView { lazyFiles.view }
    var file: FileSurfaceView { lazyFile.view }
    var launcher: SurfaceLauncherView { lazyLauncher.view }
    public var pullRequest: PullRequestDetailView { lazyPullRequest.view }
    public var linkedPullRequests: ThreadPullRequestsListView { lazyLinkedPullRequests.view }
    /// A browser tab's surface; the app shows the active tab's server stream in it.
    public let browser = BrowserPanelView()
    /// A terminal tab's surface (`PersistentThreadTerminalPanel`, ChatView.tsx:1383-1530); the
    /// terminal controller fills it with the active tab's panes.
    public let terminal: TerminalDrawerView = {
        let view = TerminalDrawerView()
        view.isPanel = true
        return view
    }()
    /// Terminal tab titles by surface id: the server's label for the tab's active terminal.
    var terminalTitles: [String: String] = [:] { didSet { if terminalTitles != oldValue { apply(state) } } }
    /// Browser tab titles and favicons by surface id (`surfaceTitle`, `PreviewFavicon`).
    var browserTitles: [String: String] = [:] { didSet { if browserTitles != oldValue { apply(state) } } }
    var browserFavicons: [String: NSImage] = [:] { didSet { if browserFavicons != oldValue { apply(state) } } }
    /// The state a pull request tab's glyph wears, by surface id (`PullRequestSurfaceIcon`).
    var pullRequestStatus: [String: PullRequestStateTone] = [:] { didSet { if pullRequestStatus != oldValue { apply(state) } } }
    let add = ButtonView(nil, icon: .plus, variant: .ghostMuted, size: .iconXs).menuTrigger()
    private var tabs: [PanelTabView] = []
    /// The tab list (`ScrollArea` with hidden scrollbars): clips at `pr-28`, the room the window's
    /// panel controls take, and keeps the active tab in view.
    private let strip = RightPanelTabStripView()
    private let scrollLeft = ButtonView(nil, icon: .chevronLeft, variant: .ghostMuted, size: .iconXs)
    private let scrollRight = ButtonView(nil, icon: .chevronRight, variant: .ghostMuted, size: .iconXs)
    private var revealActiveTab = true
    private var stripOffset: CGFloat = 0
    private let border = CALayer()
    private(set) var state = RightPanelState()

    /// The user picked a tab, closed one, opened a kind from the + menu or the launcher, or asked
    /// for a tab's menu action.
    var onActivate: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onAdd: ((RightPanelSurface.Kind) -> Void)?
    var onCloseOthers: ((String) -> Void)?
    var onCloseToRight: ((String) -> Void)?
    var onCloseAll: (() -> Void)?
    var onCopyPath: ((String) -> Void)?
    /// A tab was dragged to a new index (`onMoveSurface`). Tabs drag only while it is set: the owner must
    /// keep the new order (RightPanelTabs.tsx:130-131 in 2994).
    var onMove: ((String, Int) -> Void)?
    /// What the + menu and the launcher may open (`filesAvailable`, `diffAvailable`).
    var filesAvailable = true { didSet { lazyLauncher.set(\.filesAvailable, filesAvailable) } }
    var diffAvailable = true { didSet { lazyLauncher.set(\.diffAvailable, diffAvailable) } }
    var pullRequestAvailable = false { didSet { lazyLauncher.set(\.pullRequestAvailable, pullRequestAvailable) } }
    var pullRequestsAvailable = false { didSet { lazyLauncher.set(\.pullRequestsAvailable, pullRequestsAvailable) } }
    /// `browserAvailable`: the environment hosts browser tabs (`serverBrowser`).
    var browserAvailable = false { didSet { lazyLauncher.set(\.browserAvailable, browserAvailable) } }
    /// `terminalAvailable`: the thread has a project.
    var terminalAvailable = false { didSet { lazyLauncher.set(\.terminalAvailable, terminalAvailable) } }
    /// The browser profiles (`useBrowserDefaults().profiles`); with more than one the launcher's Browser row offers them.
    var browserProfiles: [(id: String, name: String)] = [] { didSet { lazyLauncher.set(\.browserProfiles, browserProfiles) } }
    var onAddBrowserInProfile: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        add.iconSize = 14
        add.setAccessibilityLabel("Add panel surface")
        add.action = { [weak self] in self?.showAddMenu() }
        border.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(border)
        lazyLauncher.configure { [weak self] launcher in
            launcher.onPick = { [weak self] kind in self?.onAdd?(kind) }
            launcher.onPickBrowserProfile = { [weak self] id in self?.onAddBrowserInProfile?(id) }
        }
        lazyFile.configure { [weak self] file in file.explorer = self?.files }
        strip.onScroll = { [weak self] delta in self?.scrollTabs(delta) }
        scrollLeft.action = { [weak self] in guard let self else { return }; self.scrollTabs(-max(120, self.strip.bounds.width * 0.75)) }
        scrollRight.action = { [weak self] in guard let self else { return }; self.scrollTabs(max(120, self.strip.bounds.width * 0.75)) }
        scrollLeft.setAccessibilityLabel("Scroll tabs left"); scrollRight.setAccessibilityLabel("Scroll tabs right")
        scrollLeft.toolTip = "Scroll tabs left"; scrollRight.toolTip = "Scroll tabs right"
        scrollLeft.iconSize = 14; scrollRight.iconSize = 14
        strip.clipsToBounds = true
        strip.addSubview(add)
        [strip, scrollLeft, scrollRight].forEach(addSubview)
        clipsToBounds = true
    }

    /// Shows `state`'s tabs and its active surface. Inactive surfaces leave the view tree, so a
    /// hidden file tab's web view or player stops.
    func apply(_ state: RightPanelState) {
        revealActiveTab = self.state.activeSurfaceId != state.activeSurfaceId || self.state.surfaces != state.surfaces
        // A tab opened or closed mid-drag (an agent closing a preview) invalidates the drag's indices: drop it.
        if drag != nil, self.state.surfaces != state.surfaces { drag = nil; setAutoScroll(0) }
        self.state = state
        tabs.forEach { $0.removeFromSuperview() }
        tabs = state.surfaces.map { surface in
            let favicon = browserFavicons[surface.id]
            let tab = PanelTabView(title: browserTitles[surface.id] ?? terminalTitles[surface.id] ?? surface.title, identity: icon(for: surface),
                                   tinted: surface.kind != .file && surface.kind != .pullRequest && favicon == nil)
            tab.isActive = surface.id == state.activeSurfaceId
            tab.onSelect = { [weak self] in self?.onActivate?(surface.id) }
            if surface.deviceTarget != nil {
                tab.onRename = { [weak self] value in self?.onRenameDevice?(surface.id, value) }
            }
            tab.close.action = { [weak self] in self?.onClose?(surface.id) }
            tab.onMenu = { [weak self, weak tab] event in if let tab { self?.showTabMenu(surface, tab: tab, event: event) } }
            tab.onMiddleClick = { [weak self] in self?.onClose?(surface.id) }
            tab.onDrag = { [weak self] phase in self?.dragTab(surface.id, phase) }
            return tab
        }
        tabs.forEach(strip.addSubview)
        let active = state.active
        // A closed panel shows nothing, so it builds nothing.
        let shown = state.isOpen ? active?.kind : nil
        show(lazyDiff, shown == .diff)
        show(lazyFile, shown == .file)
        // A file tab hosts the explorer inside it; only the files tab's own copy leaves here.
        if shown == .files { show(lazyFiles, true) } else if let files = lazyFiles.loaded, files.superview === self { files.removeFromSuperview() }
        show(lazyPullRequest, shown == .pullRequest)
        show(lazyLinkedPullRequests, shown == .pullRequests)
        show(lazyLauncher, state.isOpen && active == nil)
        if !state.isOpen {
            // A closed panel gives back what its surfaces hold; their controllers refill a rebuilt
            // one. The diff keeps its selected turn, so it stays.
            // ponytail: the diff panel stays built after its first use; release it once it can restore its turn selection
            [lazyFile.release, lazyFiles.release, lazyPullRequest.release, lazyLinkedPullRequests.release, lazyLauncher.release].forEach { $0() }
        }
        if active?.kind == .browser { if browser.superview !== self { addSubview(browser) } } else { browser.removeFromSuperview() }
        if active?.kind == .terminal { if terminal.superview !== self { addSubview(terminal) } } else { terminal.removeFromSuperview() }
        if active?.kind == .device { if device.superview !== self { addSubview(device) } } else { device.removeFromSuperview(); device.viewer.clear() }
        needsLayout = true
    }

    private func show<V: NSView>(_ surface: LazyView<V>, _ shown: Bool) {
        guard shown else { surface.loaded?.removeFromSuperview(); return }
        let view = surface.view
        if view.superview !== self { addSubview(view, positioned: .below, relativeTo: strip) }
    }

    func icon(for surface: RightPanelSurface) -> NSView {
        if case .pullRequest = surface {
            let tone = pullRequestStatus[surface.id]
            return IconView(name: tone.map(PullRequestStyle.icon) ?? .gitPullRequestArrow, size: 12,
                            strokeColor: tone.map(PullRequestStyle.color) ?? Themed.color(\.mutedForeground))
        }
        if let image = browserFavicons[surface.id] {
            // `size-3 rounded-sm object-contain`.
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 2
            view.layer?.masksToBounds = true
            view.frame = NSRect(x: 0, y: 0, width: 12, height: 12)
            return view
        }
        if nativeChrome, let symbol = Self.nativeSymbol(for: surface) { return Self.symbolView(symbol, size: 11) }
        return Self.icon(for: surface)
    }

    /// Glass Native's SF Symbol for a surface's Lucide glyph, where one means the same. Pull requests keep T3's
    /// glyph in their state color, and files keep their file type icons.
    static func nativeSymbol(for surface: RightPanelSurface) -> String? {
        switch surface {
        case .device, .deviceTarget: "iphone"
        case .diff: "plus.forwardslash.minus"
        case .files: "doc.on.doc"
        case .pullRequests: "link"
        case .browser: "globe"
        case .terminal: "terminal"
        default: nil
        }
    }

    /// The same for the launcher's Lucide names.
    static func nativeSymbol(for icon: IconName) -> String? {
        switch icon {
        case .smartphone: "iphone"
        case .fileDiff: "plus.forwardslash.minus"
        case .files: "doc.on.doc"
        case .link, .link2: "link"
        case .globe2: "globe"
        case .terminalSquare: "terminal"
        default: nil
        }
    }

    /// An SF Symbol centered in a `size + 1` point slot; its owner tints it through `contentTintColor`.
    static func symbolView(_ symbol: String, size: CGFloat) -> NSImageView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        let view = GlyphImageView(image: image ?? NSImage())
        view.imageScaling = .scaleNone
        view.contentTintColor = Themed.color(\.foreground)
        view.frame = NSRect(x: 0, y: 0, width: size + 1, height: size + 1)
        view.setAccessibilityElement(false)
        return view
    }

    static func icon(for surface: RightPanelSurface) -> IconView {
        switch surface {
        case .device, .deviceTarget: IconView(name: .smartphone, size: 12, strokeColor: Themed.color(\.foreground))
        case .diff: IconView(name: .fileDiff, size: 12, strokeColor: Themed.color(\.foreground))
        case .files: IconView(name: .files, size: 12, strokeColor: Themed.color(\.foreground))
        case .file(let path, _, _): FileTypeIcon.view(for: path, size: 12)
        case .attachment(let a): FileTypeIcon.view(for: a.name, size: 12)
        case .pullRequest: IconView(name: .gitPullRequestArrow, size: 12, strokeColor: Themed.color(\.mutedForeground))
        case .pullRequests: IconView(name: .link2, size: 12, strokeColor: Themed.color(\.foreground))
        case .browser: IconView(name: .globe2, size: 12, strokeColor: Themed.color(\.foreground))
        case .terminal: IconView(name: .terminalSquare, size: 12, strokeColor: Themed.color(\.foreground))
        }
    }

    /// The + menu (RightPanelTabs.tsx:1248-1335): every kind with its letter; only the ones this
    /// app draws are enabled. Letters pick while the menu is open.
    func showAddMenu(fromShortcut: Bool = false) {
        let actions = SurfaceLauncherView.actions(filesAvailable: filesAvailable, diffAvailable: diffAvailable,
                                                  pullRequestAvailable: pullRequestAvailable, pullRequestsAvailable: pullRequestsAvailable,
                                                  browserAvailable: browserAvailable, terminalAvailable: terminalAvailable)
        let items = actions.map { action -> MenuItem in
            var item = MenuItem(action.label, icon: action.icon, shortcut: action.shortcut, disabled: action.kind == nil)
            item.action = { [weak self] in if let kind = action.kind { self?.onAdd?(kind) } }
            return item
        }
        let menu = MenuPopupView.show(items, from: add, placement: .dropdown)
        // `rightPanel.new` opens the menu through its state (`setAddSurfaceMenuOpen(true)`,
        // RightPanelTabs.tsx:824-827), not a keyboard press on the trigger, so nothing is highlighted.
        if fromShortcut { menu?.highlightedIndex = nil }
        menu?.characterOverride = { [weak self, weak menu] c in
            guard let action = actions.first(where: { $0.shortcut.lowercased() == c.lowercased() }) else { return false }
            if let kind = action.kind { menu?.closeTree(); self?.onAdd?(kind) }
            return true
        }
    }

    /// The tab context menu (RightPanelTabs.tsx:939-1010).
    private func showTabMenu(_ surface: RightPanelSurface, tab: NSView, event: NSEvent) {
        let index = state.surfaces.firstIndex { $0.id == surface.id } ?? 0
        var items: [MenuItem] = []
        if surface.deviceTarget != nil {
            var rename = MenuItem("Rename")
            rename.action = { [weak self] in
                (tab as? PanelTabView)?.beginRename()
            }
            items.append(rename)
        }
        if let path = surface.filePath {
            var copy = MenuItem("Copy path")
            copy.action = { [weak self] in self?.onCopyPath?(path) }
            items.append(copy)
        }
        var close = MenuItem("Close"); close.action = { [weak self] in self?.onClose?(surface.id) }
        var others = MenuItem("Close others", disabled: state.surfaces.count <= 1); others.action = { [weak self] in self?.onCloseOthers?(surface.id) }
        var right = MenuItem("Close to the right", disabled: index >= state.surfaces.count - 1); right.action = { [weak self] in self?.onCloseToRight?(surface.id) }
        var all = MenuItem("Close all", disabled: state.surfaces.isEmpty); all.action = { [weak self] in self?.onCloseAll?() }
        items += [close, others, right, all]
        MenuPopupView.showContextMenu(items, in: tab, at: tab.convert(event.locationInWindow, from: nil))
    }

    /// The tab being dragged: its index, how far the pointer moved, the index it would drop at, where the tabs
    /// rest along the scrolled content and where the dragged one started in the strip.
    private var drag: (index: Int, offset: CGFloat, over: Int, rest: [NSRect], start: CGFloat)?
    /// dnd-kit's scroll intent (`useScrollIntent`): the strip scrolls only toward a side the pointer has moved to.
    private var dragIntent: (left: Bool, right: Bool) = (false, false)
    /// Where the press landed in the dragged tab.
    private var dragGrab: CGFloat = 0
    /// Auto-scroll while the pointer sits near an edge: points per 5 ms tick, signed.
    private(set) var autoScrollSpeed: CGFloat = 0
    private var autoScrollLink: CADisplayLink?
    var isAutoScrolling: Bool { autoScrollLink != nil }
    var tabStripOffset: CGFloat { stripOffset }
    private var autoScrollLast: CFTimeInterval?

    /// `SortableTabList` (RightPanelTabs.tsx:813-866 in 2994, dnd-kit): the tab follows the pointer along the
    /// strip and stays inside it (`restrictToHorizontalAxis`, `restrictToFirstScrollableAncestor`), above its
    /// neighbours (`z-10`). The drop target is the tab whose resting center is closest to the dragged tab's
    /// (`closestCenter`); the tabs in between slide aside by its width and the 4px gap
    /// (`horizontalListSortingStrategy`) over 200 ms `ease`. The order commits on release and everything
    /// lands in place at once, as dnd-kit drops without an overlay.
    private func dragTab(_ id: String, _ phase: PanelTabView.DragPhase) {
        guard let index = state.surfaces.firstIndex(where: { $0.id == id }), tabs.indices.contains(index) else { return }
        switch phase {
        case .began(let grab):
            guard onMove != nil else { return }
            drag = (index, 0, index, tabs.map { $0.frame.offsetBy(dx: stripOffset, dy: 0) }, tabs[index].frame.minX)
            dragIntent = (false, false)
            dragGrab = grab
            tabs[index].layer?.zPosition = 10
        case .moved(let dx):
            guard let current = drag, current.index == index else { return }
            if dx < current.offset { dragIntent.left = true } else if dx > current.offset { dragIntent.right = true }
            drag?.offset = dx
            layoutDrag()
            updateAutoScroll()
        case .ended:
            guard let ended = drag, ended.index == index else { return }
            drag = nil
            setAutoScroll(0)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for tab in tabs {
                tab.layer?.removeAnimation(forKey: "tab-sort")
                tab.layer?.setAffineTransform(.identity)
                tab.layer?.zPosition = 0
            }
            CATransaction.commit()
            needsLayout = true
            if ended.over != index { onMove?(id, ended.over) }
        }
    }

    /// Places the dragged tab and its neighbours for the current pointer offset. The dragged tab moves its
    /// frame, so hit testing follows it; the neighbours only slide their layers.
    private func layoutDrag() {
        guard let drag, drag.index < tabs.count, drag.rest.count == tabs.count else { return }
        let rest = drag.rest
        let dragged = rest[drag.index]
        // The tab stays under the pointer while the strip scrolls under it; targets compare along the content.
        let x = min(max(drag.start + drag.offset, 0), max(0, strip.bounds.width - dragged.width))
        let center = x + stripOffset + dragged.width / 2
        let over = rest.indices.min { abs(rest[$0].midX - center) < abs(rest[$1].midX - center) } ?? drag.index
        self.drag?.over = over
        let shift = dragged.width + 4
        tabs[drag.index].setFrameOrigin(NSPoint(x: x, y: dragged.minY))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, tab) in tabs.enumerated() where i != drag.index {
            let target: CGFloat = i > drag.index && i <= over ? -shift : i < drag.index && i >= over ? shift : 0
            guard let layer = tab.layer, layer.affineTransform().tx != target else { continue }
            let shown = (layer.presentation() ?? layer).affineTransform().tx
            layer.setAffineTransform(CGAffineTransform(translationX: target, y: 0))
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = shown
            slide.toValue = target
            slide.duration = 0.2
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1) // CSS `ease`
            layer.add(slide, forKey: "tab-sort")
        }
        CATransaction.commit()
    }

    /// dnd-kit's auto-scroller with the defaults T3 keeps (its `DndContext` sets no `autoScroll`,
    /// RightPanelTabs.tsx:833-839 in 2994). The pointer starts it inside the outer 20% of the strip
    /// (`defaultThreshold`). The speed ramps linearly from 0 at the zone's inner edge to `acceleration` 10 px at
    /// the strip's edge, applied every `interval` of 5 ms, so up to 2,000 px a second (@dnd-kit/core 6.3.1
    /// core.esm.js:827-890, 1765-1860). Only a side the pointer moved toward scrolls (`useScrollIntent`,
    /// core.esm.js:1886-1913), and it stops at either end. Here the display link steps it, scaled to 5 ms ticks,
    /// and lives only while the pointer sits in a zone.
    private func updateAutoScroll() {
        guard let drag else { return setAutoScroll(0) }
        // `AutoScrollActivator.Pointer`: the pointer itself, not the clamped tab.
        let pointer = drag.start + dragGrab + drag.offset
        let width = strip.bounds.width, threshold = width * 0.2
        guard threshold > 0 else { return setAutoScroll(0) }
        let content = tabs.reduce(0) { $0 + $1.frame.width } + CGFloat(tabs.count) * 4 + 24
        let atLeft = stripOffset <= 0, atRight = stripOffset + width >= content - 0.5
        if !atRight, dragIntent.right, pointer >= width - threshold {
            setAutoScroll(10 * abs((width - threshold - pointer) / threshold))
        } else if !atLeft, dragIntent.left, pointer <= threshold {
            setAutoScroll(-10 * abs((threshold - pointer) / threshold))
        } else {
            setAutoScroll(0)
        }
    }

    private func setAutoScroll(_ speed: CGFloat) {
        autoScrollSpeed = speed
        if speed == 0 {
            autoScrollLink?.invalidate(); autoScrollLink = nil; autoScrollLast = nil
        } else if autoScrollLink == nil, window != nil {
            let link = strip.displayLink(target: self, selector: #selector(autoScrollFired))
            link.add(to: .main, forMode: .common)
            autoScrollLink = link
        }
    }

    @objc private func autoScrollFired(_ link: CADisplayLink) {
        let dt = autoScrollLast.map { link.targetTimestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        autoScrollLast = link.targetTimestamp
        if !stepAutoScroll(dt) { setAutoScroll(0) }
    }

    /// One auto-scroll step of `dt` seconds. False once the strip is at its end. Tests call it directly.
    @discardableResult
    func stepAutoScroll(_ dt: CFTimeInterval) -> Bool {
        guard autoScrollSpeed != 0 else { return false }
        let before = stripOffset
        revealActiveTab = false
        stripOffset += autoScrollSpeed * CGFloat(dt / 0.005)
        needsLayout = true
        layoutSubtreeIfNeeded() // clamps to the ends and places the dragged tab again
        return stripOffset != before
    }

    private func scrollTabs(_ delta: CGFloat) {
        revealActiveTab = false
        stripOffset += delta
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // `border-l border-border`; the content is `width - 1` wide right of it.
        border.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        strip.frame = NSRect(x: 1 + 8, y: 0, width: max(0, bounds.width - 1 - 8 - trailingReserve), height: Self.tabBarHeight)
        let widths = tabs.map(\.preferredWidth)
        let total = widths.reduce(0, +) + CGFloat(tabs.count) * 4 + 24
        let overflow = total > strip.bounds.width
        scrollLeft.isHidden = !overflow; scrollRight.isHidden = !overflow
        if overflow { strip.frame.size.width = max(0, strip.frame.width - 48) }
        scrollLeft.frame = NSRect(x: strip.frame.maxX, y: 14, width: 24, height: 24)
        scrollRight.frame = NSRect(x: strip.frame.maxX + 24, y: 14, width: 24, height: 24)
        if revealActiveTab, let i = tabs.firstIndex(where: \.isActive) {
            let start = widths[..<i].reduce(0, +) + CGFloat(i) * 4
            let end = start + widths[i] + (i == tabs.count - 1 ? 4 + 24 : 0)
            if start < stripOffset { stripOffset = start }
            if end > stripOffset + strip.bounds.width { stripOffset = end - strip.bounds.width }
        }
        stripOffset = max(0, min(stripOffset, total - strip.bounds.width))
        revealActiveTab = false
        scrollLeft.isEnabled = stripOffset > 1
        scrollRight.isEnabled = stripOffset + strip.bounds.width < total - 1
        var x: CGFloat = -stripOffset
        for (tab, w) in zip(tabs, widths) {
            tab.frame = NSRect(x: x, y: (Self.tabBarHeight - 24) / 2, width: w, height: 24)
            x += w + 4
        }
        layoutDrag()
        add.frame = NSRect(x: x, y: (Self.tabBarHeight - 24) / 2, width: 24, height: 24)
        let content = NSRect(x: 1, y: Self.tabBarHeight, width: max(0, bounds.width - 1), height: max(0, bounds.height - Self.tabBarHeight))
        lazyDiff.loaded?.frame = content
        if let files = lazyFiles.loaded, files.superview === self { files.frame = content }
        lazyFile.loaded?.frame = content
        lazyPullRequest.loaded?.frame = content
        lazyLinkedPullRequests.loaded?.frame = content
        browser.frame = content
        terminal.frame = content
        device.frame = content
        // The launcher centers against the whole panel (`pb-(--workspace-topbar-height)`).
        lazyLauncher.loaded?.frame = NSRect(x: 1, y: Self.tabBarHeight, width: content.width, height: max(0, content.height - Self.tabBarHeight))
    }

    /// Over the thread in a narrow window, where the Glass theme's clear fill would show the thread through.
    var isSheet = false { didSet { if isSheet != oldValue { needsDisplay = true } } }

    override func updateLayer() {
        layer?.backgroundColor = (isSheet ? Themed.color(\.background) : WindowGlass.inset).cgColor(in: self)
        border.backgroundColor = Themed.color(\.border).cgColor(in: self)
    }
}

/// Glass Native's ground for a right panel surface: the detail's frost under the chrome (clear while Glass frosts
/// the window), and classic's solid `background` otherwise.
/// A glyph that leaves clicks to the control it sits in.
final class GlyphImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum NativePanelGround {
    static func color(_ native: Bool) -> NSColor { native ? WindowGlass.inset : Themed.color(\.background) }
}

/// One panel tab: `h-6 max-w-36 rounded-md pl-1.5 pr-2 gap-0.5 text-xs`, the identity glyph that
/// turns into a close button on hover, the title; `bg-accent` when active, `hover:bg-accent/60`.
final class PanelTabView: DSView {
    let close: PanelTabCloseButton
    private let title: LabelView
    private var renameInput: InputView?
    var onRename: ((String) -> Void)?
    var isActive = true { didSet { restyle() } }
    private var hovered = false { didSet { if hovered != oldValue { close.isTabHovered = hovered; restyle() } } }
    private var tracking: NSTrackingArea?
    var onSelect: (@MainActor () -> Void)?
    var onMenu: (@MainActor (NSEvent) -> Void)?
    var onMiddleClick: (@MainActor () -> Void)?
    /// `began` carries where the press landed in the tab; `moved` how far the pointer has gone since.
    enum DragPhase { case began(CGFloat), moved(CGFloat), ended }
    /// Drag to reorder. The tab starts dragging once the pointer moves 6px from the press (`PointerSensor`
    /// `activationConstraint: { distance: 6 }`, RightPanelTabs.tsx:822 in 2994); a drag selects nothing.
    var onDrag: (@MainActor (DragPhase) -> Void)?
    private var press: NSPoint?
    private var dragging = false
    /// The tab bar drags the window, its tabs don't (`[-webkit-app-region:no-drag]`, RightPanelTabs.tsx:1220).
    /// In the transparent title bar AppKit still moved the window on a drag from a view that refuses first
    /// responder (measured on macOS 27); the title is a focusable button in T3 anyway.
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// A lucide glyph, or Glass Native's SF Symbol, takes the tab's text color (`text-muted-foreground` until
    /// active); file icons keep theirs.
    private let tintedIdentity: NSView?

    init(title text: String, identity: NSView, tinted: Bool = false) {
        tintedIdentity = tinted ? identity : nil
        title = LabelView(text, font: DSFont.ui(12))
        close = PanelTabCloseButton(identity: identity, label: "Close \(text)")
        super.init(frame: .zero)
        layer?.cornerRadius = 8
        title.lineHeight = 16
        addSubview(close)
        addSubview(title)
        toolTip = text
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(text)
        restyle()
    }

    convenience init(title text: String, icon: IconName) {
        self.init(title: text, identity: IconView(name: icon, size: 12, strokeColor: Themed.color(\.foreground)), tinted: true)
    }

    var preferredWidth: CGFloat { if renameInput != nil { return 128 }; return min(144, 6 + 16 + 2 + ceil(title.textWidth) + 8) }

    private func restyle() {
        title.color = Themed.color(isActive || hovered ? \.foreground : \.mutedForeground)
        (tintedIdentity as? IconView)?.strokeColor = title.color
        (tintedIdentity as? NSImageView)?.contentTintColor = title.color
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        close.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16)
        title.frame = NSRect(x: 24, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 24 - 8), height: 16)
        renameInput?.frame = NSRect(x: 24, y: 1, width: max(0, bounds.width - 28), height: 22)
    }

    override func updateLayer() {
        let fill: NSColor? = isActive ? Themed.color(\.accent) : hovered ? Themed.color(\.accent, 0.6) : nil
        layer?.backgroundColor = fill?.cgColor(in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    func beginRename() {
        guard onRename != nil, renameInput == nil else { return }
        let input = InputView(text: title.text, size: .inline)
        input.setAccessibilityLabel("Device tab name")
        renameInput = input; title.isHidden = true; addSubview(input)
        input.onCommit = { [weak self] value in self?.finishRename(value) }
        input.onSubmit = { [weak self, weak input] in self?.finishRename(input?.text) }
        input.onCommand = { [weak self] selector in
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            self?.finishRename(nil); return true
        }
        superview?.superview?.needsLayout = true; needsLayout = true
        window?.makeFirstResponder(input)
    }
    private func finishRename(_ value: String?) {
        guard let input = renameInput else { return }
        renameInput = nil; input.onCommit = nil; input.removeFromSuperview(); title.isHidden = false
        if let value { onRename?(value) }
        superview?.superview?.needsLayout = true
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        press = nil
        if event.clickCount == 2, onRename != nil { beginRename() }
        else if event.modifierFlags.contains(.control) { onMenu?(event) } else { press = event.locationInWindow }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press, renameInput == nil else { return }
        let point = event.locationInWindow
        if !dragging {
            guard hypot(point.x - press.x, point.y - press.y) >= 6 else { return }
            dragging = true
            onDrag?(.began(convert(press, from: nil).x))
        }
        onDrag?(.moved(point.x - press.x))
    }
    /// The title is a button (`onClick`, RightPanelTabs.tsx:1305): the tab activates on release, unless it was dragged.
    override func mouseUp(with event: NSEvent) {
        defer { press = nil; dragging = false }
        if dragging { onDrag?(.ended) } else if press != nil { onSelect?() }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    // `onAuxClick`: a middle click closes the tab.
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onMiddleClick?() } }
}

/// "Open a surface" (RightPanelTabs.tsx `RightPanelEmptyState`): `max-w-xs py-6`, the heading,
/// then `h-8 gap-2.5 px-2.5 text-sm` rows with a 16px icon and the letter in a Kbd. Unavailable
/// rows are at 50%. A letter opens its surface while the launcher shows.
final class SurfaceLauncherView: DSView {
    struct Action {
        var label: String
        var icon: IconName
        var shortcut: String
        /// Nil: a kind this app does not draw yet, shown disabled.
        var kind: RightPanelSurface.Kind?
    }

    static func actions(filesAvailable: Bool, diffAvailable: Bool, pullRequestAvailable: Bool = false, pullRequestsAvailable: Bool = false,
                        browserAvailable: Bool = false, terminalAvailable: Bool = false) -> [Action] {
        [Action(label: "Browser", icon: .globe2, shortcut: "B", kind: browserAvailable ? .browser : nil),
         Action(label: "Terminal", icon: .terminalSquare, shortcut: "T", kind: terminalAvailable ? .terminal : nil),
         Action(label: "Files", icon: .files, shortcut: "F", kind: filesAvailable ? .files : nil),
         Action(label: "Diff", icon: .fileDiff, shortcut: "D", kind: diffAvailable ? .diff : nil),
         Action(label: "Pull request", icon: .gitPullRequestArrow, shortcut: "P", kind: pullRequestAvailable ? .pullRequest : nil),
         Action(label: "Linked pull requests", icon: .link, shortcut: "L", kind: pullRequestsAvailable ? .pullRequests : nil),
         Action(label: "Device", icon: .smartphone, shortcut: "M", kind: .device)]
    }

    var filesAvailable = true { didSet { rebuild() } }
    var diffAvailable = true { didSet { rebuild() } }
    var pullRequestAvailable = false { didSet { if pullRequestAvailable != oldValue { rebuild() } } }
    var pullRequestsAvailable = false { didSet { if pullRequestsAvailable != oldValue { rebuild() } } }
    var browserAvailable = false { didSet { if browserAvailable != oldValue { rebuild() } } }
    var terminalAvailable = false { didSet { if terminalAvailable != oldValue { rebuild() } } }
    var browserProfiles: [(id: String, name: String)] = [] { didSet { rebuild() } }
    /// Glass Native: SF Symbols in the rows.
    var nativeChrome = false { didSet { if nativeChrome != oldValue { rebuild() } } }
    var onPick: ((RightPanelSurface.Kind) -> Void)?
    var onPickBrowserProfile: ((String) -> Void)?
    private let heading = LabelView("Open a surface", font: DSFont.ui(14, weight: .medium))
    private var rows: [LauncherRow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.alignment = .center
        heading.lineHeight = 20
        addSubview(heading)
        setAccessibilityLabel("Open a surface")
        rebuild()
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = Self.actions(filesAvailable: filesAvailable, diffAvailable: diffAvailable, pullRequestAvailable: pullRequestAvailable,
                            pullRequestsAvailable: pullRequestsAvailable, browserAvailable: browserAvailable,
                            terminalAvailable: terminalAvailable).map { action in
            // The profile chooser beside the Browser row, once there is a choice (RightPanelTabs.tsx:526-555).
            let profiles = action.kind == .browser && browserProfiles.count > 1 ? browserProfiles : []
            let row = LauncherRow(action, profiles: profiles, native: nativeChrome)
            row.onClick = { [weak self] in if let kind = action.kind { self?.onPick?(kind) } }
            row.onProfile = { [weak self] id in self?.onPickBrowserProfile?(id) }
            return row
        }
        rows.forEach(addSubview)
        needsLayout = true
    }

    /// The letter keys (`surfaceShortcutActionForKey`), outside typing contexts.
    func handleKey(_ characters: String) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, window != nil,
              let action = Self.actions(filesAvailable: filesAvailable, diffAvailable: diffAvailable, pullRequestAvailable: pullRequestAvailable,
                                        pullRequestsAvailable: pullRequestsAvailable, browserAvailable: browserAvailable,
                            terminalAvailable: terminalAvailable)
                .first(where: { $0.shortcut.lowercased() == characters.lowercased() }), let kind = action.kind else { return false }
        onPick?(kind)
        return true
    }

    override func layout() {
        super.layout()
        let width = min(320, max(0, bounds.width - 48))
        let height = 24 + 20 + 12 + CGFloat(rows.count) * 32 + CGFloat(max(0, rows.count - 1)) * 2 + 24
        var y = max(0, (bounds.height - height) / 2) + 24
        let x = (bounds.width - width) / 2
        heading.frame = NSRect(x: x, y: y, width: width, height: 20)
        y += 20 + 12
        for row in rows {
            row.frame = NSRect(x: x, y: y, width: width, height: 32)
            y += 34
        }
    }

    override func updateLayer() {
        heading.color = Themed.color(\.foreground)
    }
}

final class LauncherRow: DSView {
    let action: SurfaceLauncherView.Action
    private let icon: NSView
    private let label: LabelView
    private let kbd: KbdView
    private let profiles: [(id: String, name: String)]
    /// `size="icon-xs" variant="ghost-muted"` with a 14px chevron, `right-8` and centered.
    private lazy var chooser: ButtonView = {
        let b = ButtonView(icon: .chevronDown, variant: .ghostMuted, size: .iconXs)
        b.setAccessibilityLabel("Open browser in a profile")
        b.action = { [weak self] in self?.showProfiles() }
        return b
    }()
    var onProfile: ((String) -> Void)?
    // `transition-colors group-hover:bg-accent/60` (RightPanelTabs.tsx:511).
    private var hovered = false { didSet { if hovered != oldValue { redisplay(transitioning: .colors) } } }
    private var tracking: NSTrackingArea?
    var onClick: (() -> Void)?

    init(_ action: SurfaceLauncherView.Action, profiles: [(id: String, name: String)] = [], native: Bool = false) {
        self.action = action
        self.profiles = profiles
        icon = native ? RightPanelView.nativeSymbol(for: action.icon).map { RightPanelView.symbolView($0, size: 14) }
            ?? IconView(name: action.icon, size: 16, strokeColor: Themed.color(\.foreground))
            : IconView(name: action.icon, size: 16, strokeColor: Themed.color(\.foreground))
        label = LabelView(action.label, font: DSFont.ui(14), color: Themed.color(\.foreground))
        kbd = KbdView(action.shortcut)
        super.init(frame: .zero)
        label.lineHeight = 20
        layer?.cornerRadius = 8
        [icon, label, kbd].forEach(addSubview)
        if !profiles.isEmpty { addSubview(chooser) }
        alphaValue = action.kind == nil ? 0.5 : 1
        setAccessibilityRole(.button)
        setAccessibilityLabel(action.label)
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 8, width: 16, height: 16)
        let k = kbd.intrinsicContentSize
        kbd.frame = NSRect(x: bounds.width - 10 - k.width, y: (32 - k.height) / 2, width: k.width, height: k.height)
        // `pr-7` keeps the label clear of the chooser.
        label.frame = NSRect(x: 36, y: 6, width: max(0, kbd.frame.minX - 10 - 36 - (profiles.isEmpty ? 0 : 28)), height: 20)
        if !profiles.isEmpty { chooser.frame = NSRect(x: bounds.width - 32 - 24, y: 4, width: 24, height: 24) }
    }

    /// `MenuPopup align="end" side="bottom" sideOffset={6}`, one item per profile.
    // ponytail: no `max-w-56` cap, so a 48-character profile name widens the menu; cap MenuPopupView if one shows up
    private func showProfiles() {
        let items = profiles.map { profile -> MenuItem in
            var item = MenuItem(profile.name)
            item.action = { [weak self] in self?.onProfile?(profile.id) }
            return item
        }
        MenuPopupView.show(items, from: chooser, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 6, fallbackAxisSide: .none))
    }

    override func updateLayer() {
        Motion.setBackground(layer, hovered && action.kind != nil ? Themed.color(\.accent, 0.6).cgColor(in: self) : nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}

/// Wheel scrolling belongs to the tab strip, not the active surface.
private final class RightPanelTabStripView: DSView {
    var onScroll: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        onScroll?(-delta * (event.hasPreciseScrollingDeltas ? 1 : 16))
    }
}
