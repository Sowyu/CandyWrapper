import AppKit
import DesignSystem
import T3Store

/// The inline right panel (RightPanelTabs.tsx, PreviewPanelShell.tsx): a 52px tab bar (`pl-2`,
/// one tab per surface, the + menu) over the active surface, or the "Open a surface" launcher when
/// nothing is active. The window's panel controls sit at the bar's right edge while it is open;
/// `ThreadPanelView` places them. Surfaces here: the diff, the files explorer and file tabs.
final class RightPanelView: DSView {
    static let tabBarHeight: CGFloat = 52
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

    var onRenameDevice: ((String, String) -> Void)?
    let device = DevicePanelView()
    let diff = DiffPanelView()
    let files = FilesPanelView()
    let file = FileSurfaceView()
    let launcher = SurfaceLauncherView()
    /// A `pull-request` tab's surface and the thread's linked pull requests.
    public let pullRequest = PullRequestDetailView()
    public let linkedPullRequests = ThreadPullRequestsListView()
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
    let add = ButtonView(nil, icon: .plus, variant: .ghostMuted, size: .iconXs)
    private var tabs: [PanelTabView] = []
    /// The tab list (`ScrollArea` with hidden scrollbars): clips at `pr-28`, the room the window's
    /// panel controls take, and keeps the active tab in view.
    // ponytail: no left and right scroll buttons or wheel scrolling; the strip follows the active
    // tab. Add T3's "Scroll tabs" buttons when people keep many tabs open
    private let strip = DSView()
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
    /// What the + menu and the launcher may open (`filesAvailable`, `diffAvailable`).
    var filesAvailable = true { didSet { launcher.filesAvailable = filesAvailable } }
    var diffAvailable = true { didSet { launcher.diffAvailable = diffAvailable } }
    var pullRequestAvailable = false { didSet { launcher.pullRequestAvailable = pullRequestAvailable } }
    var pullRequestsAvailable = false { didSet { launcher.pullRequestsAvailable = pullRequestsAvailable } }
    /// `browserAvailable`: the environment hosts browser tabs (`serverBrowser`).
    var browserAvailable = false { didSet { launcher.browserAvailable = browserAvailable } }
    /// `terminalAvailable`: the thread has a project.
    var terminalAvailable = false { didSet { launcher.terminalAvailable = terminalAvailable } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        add.iconSize = 14
        add.setAccessibilityLabel("Add panel surface")
        add.action = { [weak self] in self?.showAddMenu() }
        border.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(border)
        launcher.onPick = { [weak self] kind in self?.onAdd?(kind) }
        file.explorer = files
        strip.clipsToBounds = true
        strip.addSubview(add)
        [diff, launcher, strip].forEach(addSubview)
        clipsToBounds = true
    }

    /// Shows `state`'s tabs and its active surface. Inactive surfaces leave the view tree, so a
    /// hidden file tab's web view or player stops.
    func apply(_ state: RightPanelState) {
        self.state = state
        tabs.forEach { $0.removeFromSuperview() }
        tabs = state.surfaces.map { surface in
            let favicon = browserFavicons[surface.id]
            let tab = PanelTabView(title: browserTitles[surface.id] ?? terminalTitles[surface.id] ?? surface.title, identity: icon(for: surface),
                                   tinted: surface.kind != .file && surface.kind != .pullRequest && favicon == nil)
            tab.isActive = surface.id == state.activeSurfaceId
            tab.onSelect = { [weak self] in self?.onActivate?(surface.id) }
            tab.close.action = { [weak self] in self?.onClose?(surface.id) }
            tab.onMenu = { [weak self, weak tab] event in if let tab { self?.showTabMenu(surface, tab: tab, event: event) } }
            tab.onMiddleClick = { [weak self] in self?.onClose?(surface.id) }
            return tab
        }
        tabs.forEach(strip.addSubview)
        let active = state.active
        diff.isHidden = active?.kind != .diff
        let showFiles = active?.kind == .files
        let showFile = active?.kind == .file
        if showFile { if file.superview !== self { addSubview(file) } } else { file.removeFromSuperview() }
        if showFiles {
            if files.superview !== self { addSubview(files) }
        } else if files.superview === self {
            files.removeFromSuperview()
        }
        if active?.kind == .pullRequest { if pullRequest.superview !== self { addSubview(pullRequest) } } else { pullRequest.removeFromSuperview() }
        if active?.kind == .pullRequests { if linkedPullRequests.superview !== self { addSubview(linkedPullRequests) } } else { linkedPullRequests.removeFromSuperview() }
        if active?.kind == .browser { if browser.superview !== self { addSubview(browser) } } else { browser.removeFromSuperview() }
        if active?.kind == .terminal { if terminal.superview !== self { addSubview(terminal) } } else { terminal.removeFromSuperview() }
        if active?.kind == .device { if device.superview !== self { addSubview(device) } } else { device.removeFromSuperview(); device.viewer.clear() }
        launcher.isHidden = active != nil
        needsLayout = true
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
        return Self.icon(for: surface)
    }

    static func icon(for surface: RightPanelSurface) -> IconView {
        switch surface {
        case .device, .deviceTarget: IconView(name: .smartphone, size: 12, strokeColor: Themed.color(\.foreground))
        case .diff: IconView(name: .fileDiff, size: 12, strokeColor: Themed.color(\.foreground))
        case .files: IconView(name: .files, size: 12, strokeColor: Themed.color(\.foreground))
        case .file(let path, _, _): FileTypeIcon.view(for: path, size: 12)
        case .pullRequest: IconView(name: .gitPullRequestArrow, size: 12, strokeColor: Themed.color(\.mutedForeground))
        case .pullRequests: IconView(name: .link2, size: 12, strokeColor: Themed.color(\.foreground))
        case .browser: IconView(name: .globe2, size: 12, strokeColor: Themed.color(\.foreground))
        case .terminal: IconView(name: .terminalSquare, size: 12, strokeColor: Themed.color(\.foreground))
        }
    }

    /// The + menu (RightPanelTabs.tsx:1248-1335): every kind with its letter; only the ones this
    /// app draws are enabled. Letters pick while the menu is open.
    func showAddMenu() {
        let actions = SurfaceLauncherView.actions(filesAvailable: filesAvailable, diffAvailable: diffAvailable,
                                                  pullRequestAvailable: pullRequestAvailable, pullRequestsAvailable: pullRequestsAvailable,
                                                  browserAvailable: browserAvailable, terminalAvailable: terminalAvailable)
        let items = actions.map { action -> MenuItem in
            var item = MenuItem(action.label, icon: action.icon, shortcut: action.shortcut, disabled: action.kind == nil)
            item.action = { [weak self] in if let kind = action.kind { self?.onAdd?(kind) } }
            return item
        }
        let menu = MenuPopupView.show(items, from: add, placement: .dropdown)
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
                guard let self, let window = self.window else { return }
                let dialog = DialogView(title: "Rename device")
                let input = InputView(text: surface.title)
                let save = ButtonView("Save"), cancel = ButtonView("Cancel", variant: .ghost)
                dialog.panelContent = [input]; dialog.footerButtons = [cancel, save]
                let modal = ModalHost.present(dialog, in: window)
                cancel.action = { [weak modal] in modal?.close() }
                save.action = { [weak self, weak input, weak modal] in self?.onRenameDevice?(surface.id, input?.text ?? ""); modal?.close() }
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

    override func layout() {
        super.layout()
        // `border-l border-border`; the content is `width - 1` wide right of it.
        border.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        strip.frame = NSRect(x: 1 + 8, y: 0, width: max(0, bounds.width - 1 - 8 - 112), height: Self.tabBarHeight)
        let widths = tabs.map(\.preferredWidth)
        let total = widths.reduce(0, +) + CGFloat(tabs.count) * 4 + 24
        if let i = tabs.firstIndex(where: \.isActive) {
            let start = widths[..<i].reduce(0, +) + CGFloat(i) * 4
            let end = start + widths[i] + (i == tabs.count - 1 ? 4 + 24 : 0)
            if start < stripOffset { stripOffset = start }
            if end > stripOffset + strip.bounds.width { stripOffset = end - strip.bounds.width }
        }
        stripOffset = max(0, min(stripOffset, total - strip.bounds.width))
        var x: CGFloat = -stripOffset
        for (tab, w) in zip(tabs, widths) {
            tab.frame = NSRect(x: x, y: (Self.tabBarHeight - 24) / 2, width: w, height: 24)
            x += w + 4
        }
        add.frame = NSRect(x: x, y: (Self.tabBarHeight - 24) / 2, width: 24, height: 24)
        let content = NSRect(x: 1, y: Self.tabBarHeight, width: max(0, bounds.width - 1), height: max(0, bounds.height - Self.tabBarHeight))
        diff.frame = content
        files.superview === self ? (files.frame = content) : ()
        file.frame = content
        pullRequest.frame = content
        linkedPullRequests.frame = content
        browser.frame = content
        terminal.frame = content
        device.frame = content
        // The launcher centers against the whole panel (`pb-(--workspace-topbar-height)`).
        launcher.frame = NSRect(x: 1, y: Self.tabBarHeight, width: content.width, height: max(0, content.height - Self.tabBarHeight))
    }

    override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        border.backgroundColor = Themed.color(\.border).cgColor(in: self)
    }
}

/// One panel tab: `h-6 max-w-36 rounded-md pl-1.5 pr-2 gap-0.5 text-xs`, the identity glyph that
/// turns into a close button on hover, the title; `bg-accent` when active, `hover:bg-accent/60`.
final class PanelTabView: DSView {
    let close: PanelTabCloseButton
    private let title: LabelView
    var isActive = true { didSet { restyle() } }
    private var hovered = false { didSet { if hovered != oldValue { close.isTabHovered = hovered; restyle() } } }
    private var tracking: NSTrackingArea?
    var onSelect: (@MainActor () -> Void)?
    var onMenu: (@MainActor (NSEvent) -> Void)?
    var onMiddleClick: (@MainActor () -> Void)?

    /// A lucide glyph takes the tab's text color (`text-muted-foreground` until active); file icons keep theirs.
    private let tintedIdentity: IconView?

    init(title text: String, identity: NSView, tinted: Bool = false) {
        tintedIdentity = tinted ? identity as? IconView : nil
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

    var preferredWidth: CGFloat { min(144, 6 + 16 + 2 + ceil(title.textWidth) + 8) }

    private func restyle() {
        title.color = Themed.color(isActive || hovered ? \.foreground : \.mutedForeground)
        tintedIdentity?.strokeColor = title.color
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        close.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16)
        title.frame = NSRect(x: 24, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 24 - 8), height: 16)
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

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?(event) } else { onSelect?() }
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
    var onPick: ((RightPanelSurface.Kind) -> Void)?
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
            let row = LauncherRow(action)
            row.onClick = { [weak self] in if let kind = action.kind { self?.onPick?(kind) } }
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
    private let icon: IconView
    private let label: LabelView
    private let kbd: KbdView
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    var onClick: (() -> Void)?

    init(_ action: SurfaceLauncherView.Action) {
        self.action = action
        icon = IconView(name: action.icon, size: 16, strokeColor: Themed.color(\.foreground))
        label = LabelView(action.label, font: DSFont.ui(14), color: Themed.color(\.foreground))
        kbd = KbdView(action.shortcut)
        super.init(frame: .zero)
        label.lineHeight = 20
        layer?.cornerRadius = 8
        [icon, label, kbd].forEach(addSubview)
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
        label.frame = NSRect(x: 36, y: 6, width: max(0, kbd.frame.minX - 10 - 36), height: 20)
    }

    override func updateLayer() {
        layer?.backgroundColor = hovered && action.kind != nil ? Themed.color(\.accent, 0.6).cgColor(in: self) : nil
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
