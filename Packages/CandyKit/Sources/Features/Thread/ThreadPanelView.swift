import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The chat header (ChatView.tsx:11285-11293, ChatHeader.tsx, WorkspaceBreadcrumb.tsx): 52px,
/// 20px gutters, "favicon project / title", and the three panel toggles fixed at the right.
/// The bar drags the window.
public final class ThreadHeaderView: TopbarDragView {
    static let height: CGFloat = 52

    private let favicon = ProjectMonogramView()
    private let project = LabelView("", font: TL.font(14, .medium), color: TL.c(\.mutedForeground))
    private let slash = LabelView("/", font: TL.font(14, .medium), color: TL.c(\.iconMuted))
    private let title = LabelView("", font: TL.font(14, .medium), color: TL.c(\.foreground))
    /// Thread panel, terminal, right panel (PanelLayoutControls.tsx:76).
    public let toggles: [ToggleView] = [IconName.squareMenu, .panelBottom, .panelRight].map {
        ToggleView(nil, icon: $0, variant: .ghost, size: .sm)
    }

    public var projectTitle: String {
        get { project.text }
        set {
            project.text = newValue
            if favicon.source?.title != newValue { favicon.source = nil }
            favicon.projectTitle = newValue
            needsLayout = true
        }
    }

    /// The project's icon inputs; set after `projectTitle`. A different title clears it.
    public var projectIcon: ProjectIconSource? {
        get { favicon.source }
        set { favicon.source = newValue }
    }

    public var threadTitle: String {
        get { title.text }
        set { title.text = newValue; needsLayout = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [project, slash, title] { label.lineHeight = 20; addSubview(label) }
        addSubview(favicon)
        // ponytail: the thread details toggle only reserves its place and look; its panel comes later in M7
        toggles[0].setAccessibilityLabel("Thread panel")
        toggles[1].setAccessibilityLabel("Toggle terminal")
        toggles[2].setAccessibilityLabel("Toggle right panel")
        toggles.forEach(addSubview)
    }

    public override func layout() {
        super.layout()
        let midY = Self.height / 2
        // `size-3.5` favicon: the 16px monogram drawn at 14px.
        favicon.frame = NSRect(x: 20, y: midY - 7, width: 14, height: 14)
        favicon.bounds = NSRect(x: 0, y: 0, width: 16, height: 16)
        let projectWidth = min(160, project.textWidth)
        project.frame = NSRect(x: 40, y: midY - 10, width: ceil(projectWidth), height: 20)
        let slashX = 40 + projectWidth + 12
        slash.frame = NSRect(x: slashX, y: midY - 10, width: ceil(slash.textWidth), height: 20)
        let titleX = slashX + slash.textWidth + 12
        // `pr-24` keeps the title clear of the toggles; with the right panel open only the details
        // toggle is left and it is `pr-10`, plus the title button's hidden 14px chevron and `gap-1`
        // (ChatHeader.tsx:256-345).
        let reserve: CGFloat = toggles[2].superview === self ? 96 : 40 + 4 + 14
        title.frame = NSRect(x: titleX, y: midY - 10, width: max(0, min(ceil(title.textWidth) + 1, bounds.width - 20 - reserve - titleX)), height: 20)
        var x = bounds.width - 12 - 1
        // While the right panel is open, the terminal and panel toggles live on its tab bar.
        for toggle in toggles.reversed() where toggle.superview === self {
            let size = toggle.intrinsicContentSize
            x -= size.width
            toggle.frame = NSRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
            x -= 4
        }
    }
}

/// The read-only thread: header over the timeline, on the panel background, and the right panel
/// with the diff beside them (ChatView.tsx:11240-11970). Feed it a projection with
/// `setProjection(_:)`; the expand and collapse state lives in `model`.
///
/// The app uses:
/// - `setProjection(_:projectTitle:workspaceRoot:)` on every `ThreadStore` update,
/// - `onLoadEarlier` to page in older history (call `ThreadStore.beginLoadEarlier`),
/// - `diffPanel.loader` for `getTurnDiff`, `setRightPanelOpen` and `onRightPanelChange` to keep
///   the panel's open state per thread, `toggleDiff()` for Cmd+D,
/// - `composer`, which floats over the bottom of the timeline and sets `bottomInset`, and
///   `setDraft(projectTitle:)` for the new-thread page (hero headline, centered composer).
public final class ThreadPanelView: DSView {
    public let header = ThreadHeaderView()
    public let timeline = TimelineView()
    public let composer = ComposerView()
    /// The queued messages docked above the composer; it hides itself when empty.
    public let queue = QueuedRunsView()
    /// The runtime request docked between the queue and the composer (ChatComposer.tsx's top
    /// drawer). Show one through `drawer`; the composer controller configures them.
    public let approvalPanel = ApprovalPanelView()
    public let questionPanel = QuestionPanelView()
    /// The `/`, `@`, `$` and `#` menu, docked on the composer's top edge over the other attachments.
    public let commandMenu = ComposerCommandMenuView()
    /// Drives `commandMenu` from the composer's caret; the app supplies rows and acts on picks.
    public private(set) lazy var menus = ComposerMenuController(composer: composer, menu: commandMenu)
    /// "<label> is reconnecting|offline" (ChatView.tsx:3091-3142): the banner stack's front item, docked
    /// between the queue and the request panel. Shown through `showsEnvironmentBanner`.
    public let environmentBanner = EnvironmentBannerView()
    public var showsEnvironmentBanner = false { didSet { if showsEnvironmentBanner != oldValue { needsLayout = true } } }
    public enum Drawer: Sendable { case none, approval, question }
    public var drawer = Drawer.none { didSet { if drawer != oldValue { needsLayout = true } } }
    /// The stash count tab on the dock's right (`ComposerStashBadge`); hidden at zero and during approvals.
    public let stashBadge = ComposerStashBadgeView()
    public var showsStashBadge = false { didSet { if showsStashBadge != oldValue { needsLayout = true } } }
    /// The stash list, docked where the `/` menu goes; the `/` menu wins when both are open.
    public let stashMenu = ComposerStashMenuView()
    public var stashMenuOpen = false { didSet { if stashMenuOpen != oldValue { needsLayout = true } } }
    /// "Loading messages..." over the composer while the thread syncs (`ComposerActivityRow`).
    public let activityRow = ComposerActivityRowView()
    public var showsActivity = false { didSet { if showsActivity != oldValue { needsLayout = true } } }
    public let hero = DraftHeroView()
    /// The draft's context strip under the composer, with the "Run on" control.
    public let contextStrip = ComposerContextStripView()
    /// `shouldShowComposerContextStrip` on the draft page: the project has a machine to show
    /// (BranchToolbar.logic.ts:59-81). The checkout and branch controls are not drawn yet.
    public var showsContextStrip = false { didSet { if showsContextStrip != oldValue { needsLayout = true } } }
    /// The thread error banner over the top of the timeline (ChatView.tsx:11355-11375).
    public let errorBanner = ThreadErrorBannerView()
    /// T3's top-right toast stack (`ToastProvider`), placed against the window, above everything.
    public let toasts = ToastViewport()
    /// Showing the new-thread draft page instead of a thread.
    public private(set) var isDraft = false
    private var composerShown = false
    public let model = ThreadViewModel()
    private let fade = CAGradientLayer()
    let rightPanel = RightPanelView()
    /// `RightPanelMaximizeControl`, shown left of the window's panel toggles while the panel is open.
    let maximize = ToggleView(nil, icon: .maximize2, variant: .ghost, size: .sm)
    public var diffPanel: DiffPanelView { rightPanel.diff }
    /// The terminal drawer under the chat column; `TerminalController` fills it.
    public let terminalDrawer = TerminalDrawerView()
    public private(set) var terminalOpen = false
    /// The drawer's height while open (already clamped by the controller).
    public private(set) var terminalHeight: CGFloat = 0
    /// The header's terminal toggle was clicked (`terminal.toggle`).
    public var onTerminalToggle: (@MainActor () -> Void)?
    public private(set) var rightPanelOpen = false
    public private(set) var rightPanelMaximized = false
    /// The user opened or closed the right panel.
    public var onRightPanelChange: (@MainActor (Bool) -> Void)?
    private var summaries: [TurnDiffSummary] = []
    /// Development (`--open-diff`): open the panel on the newest run that changed files once the
    /// thread's checkpoints arrive.
    public var opensChangedTurnOnLoad = false

    /// The user scrolled near the first loaded row.
    public var onLoadEarlier: (@MainActor () -> Void)? {
        get { timeline.onNearTop }
        set { timeline.onNearTop = newValue }
    }

    /// Height of whatever floats over the bottom of the timeline (the composer).
    public var bottomInset: CGFloat {
        get { timeline.bottomInset }
        set { timeline.bottomInset = newValue }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(timeline)
        addSubview(header)
        hero.isHidden = true
        addSubview(hero)
        composer.isHidden = true
        queue.isHidden = true
        approvalPanel.isHidden = true
        questionPanel.isHidden = true
        // Back to front: queue, request panel, composer (each slides under the next).
        addSubview(queue)
        environmentBanner.isHidden = true
        addSubview(environmentBanner)
        activityRow.isHidden = true
        addSubview(activityRow)
        stashBadge.isHidden = true
        addSubview(stashBadge)
        addSubview(approvalPanel)
        addSubview(questionPanel)
        contextStrip.isHidden = true
        addSubview(contextStrip)
        addSubview(commandMenu)
        stashMenu.isHidden = true
        addSubview(stashMenu)
        addSubview(composer)
        composer.onHeightChange = { [weak self] in self?.needsLayout = true }
        menus.onLayoutChange = { [weak self] in self?.needsLayout = true }
        queue.onHeightChange = { [weak self] in self?.needsLayout = true }
        // `topbar-scroll-fade` (index.css:439-475): the first 25px of the scroller fade out; drawn as
        // a background-colored overlay instead of a mask, so scrolling doesn't render offscreen.
        fade.locations = [0, 0.1, 0.24, 0.42, 0.62, 0.82, 1]
        layer?.addSublayer(fade)
        timeline.context.model = model
        model.onChange = { [weak self] change in
            guard let self else { return }
            self.timeline.setItems(self.model.items, change: change)
        }
        // Banners overlay the timeline without changing its content height (`z-20`).
        addSubview(errorBanner)
        terminalDrawer.isHidden = true
        addSubview(terminalDrawer)
        rightPanel.isHidden = true
        addSubview(rightPanel)
        maximize.setAccessibilityLabel("Maximize panel")
        maximize.isHidden = true
        maximize.onPressedChange = { [weak self] _ in self?.toggleMaximized() }
        addSubview(maximize)
        addSubview(toasts)
        header.toggles[2].onPressedChange = { [weak self] _ in self?.userSetRightPanel(!(self?.rightPanelOpen ?? true)) }
        header.toggles[1].onPressedChange = { [weak self] _ in
            guard let self else { return }
            header.toggles[1].isPressed = terminalOpen // the controller decides
            onTerminalToggle?()
        }
        rightPanel.tab.close.action = { [weak self] in self?.userSetRightPanel(false) }
        model.onOpenTurnDiff = { [weak self] run, path in
            guard let self else { return }
            if !rightPanelOpen { userSetRightPanel(true) }
            diffPanel.open(runId: run, filePath: path)
        }
    }

    // MARK: Right panel

    /// Opens or closes the right panel without telling `onRightPanelChange` (restoring a thread's state).
    public func setRightPanelOpen(_ open: Bool) {
        guard open != rightPanelOpen else { return }
        rightPanelOpen = open
        if !open { rightPanelMaximized = false; maximize.isPressed = false }
        rightPanel.isHidden = !open
        maximize.isHidden = !open
        header.toggles[2].isPressed = open
        // The terminal and panel toggles move to the panel's tab bar and back, at the same place.
        for toggle in header.toggles.dropFirst() { (open ? self : header).addSubview(toggle) }
        // The panel asks for a diff only while it shows.
        if open { diffPanel.setSummaries(summaries) }
        needsLayout = true
        header.needsLayout = true
    }

    /// Shows or hides the terminal drawer at `height`.
    public func setTerminal(open: Bool, height: CGFloat) {
        guard open != terminalOpen || height != terminalHeight else { return }
        terminalOpen = open
        terminalHeight = height
        terminalDrawer.isHidden = !open
        header.toggles[1].isPressed = open
        needsLayout = true
    }

    /// Cmd+D (`diff.toggle`): the panel on the diff, or closed.
    public func toggleDiff() {
        guard model.projection != nil else { return }
        userSetRightPanel(!rightPanelOpen)
    }

    /// `rightPanel.close`: closes the panel as its tab's close button does.
    public func closeRightPanel() {
        guard rightPanelOpen else { return }
        userSetRightPanel(false)
    }

    private func userSetRightPanel(_ open: Bool) {
        header.toggles[2].isPressed = rightPanelOpen // a toggle flips itself; the state decides
        setRightPanelOpen(open)
        onRightPanelChange?(open)
    }

    private func toggleMaximized() {
        rightPanelMaximized.toggle()
        maximize.isPressed = rightPanelMaximized
        maximize.icon = rightPanelMaximized ? .minimize2 : .maximize2
        let label = rightPanelMaximized ? "Restore panel size" : "Maximize panel"
        maximize.setAccessibilityLabel(label)
        maximize.toolTip = label
        needsLayout = true
    }

    /// The window's width, or the outermost view's without a window (tests).
    private var viewportWidth: CGFloat {
        if let window { return window.frame.width }
        var view: NSView = self
        while let parent = view.superview { view = parent }
        return view.bounds.width
    }

    /// The new-thread page: header "{project} / New thread", the hero and the centered composer.
    /// Pass nil to leave it.
    public func setDraft(projectTitle: String?) {
        isDraft = projectTitle != nil
        hero.isHidden = !isDraft
        hero.projectTitle = projectTitle ?? ""
        if let projectTitle {
            setProjection(nil, projectTitle: projectTitle, workspaceRoot: nil)
            header.projectIcon = projectIconForTitle?(projectTitle)
            header.threadTitle = "New thread"
            for view in header.subviews { view.isHidden = false }
        }
        updateComposerShown()
    }

    /// The header icon for a draft, which only names its project by title.
    // ponytail: by title, so two projects with one title can show the wrong icon on a draft; pass the project to setDraft when ComposerController changes next
    public var projectIconForTitle: ((String) -> ProjectIconSource?)?

    /// Shows a thread. Pass nil to clear.
    public func setProjection(_ projection: ThreadProjection?, projectTitle: String, workspaceRoot: String?) {
        model.projectTitle = projectTitle
        model.workspaceRoot = workspaceRoot
        header.projectTitle = projectTitle
        header.threadTitle = projection?.thread.title ?? ""
        // With no thread the bar stays, empty, so it still drags the window.
        for view in header.subviews { view.isHidden = projection == nil }
        if projection?.thread.id != model.projection?.thread.id {
            timeline.context.forgetDocuments()
            if rightPanelMaximized { toggleMaximized() }
        }
        diffPanel.threadId = projection?.thread.id
        summaries = projection.map(TurnDiffs.summaries) ?? []
        if opensChangedTurnOnLoad, let changed = TurnDiffs.sortedForPanel(summaries).first(where: { !$0.files.isEmpty }) {
            opensChangedTurnOnLoad = false
            setRightPanelOpen(true)
            diffPanel.open(runId: changed.runId, filePath: nil)
        }
        if rightPanelOpen { diffPanel.setSummaries(summaries) }
        model.setProjection(projection)
        if projection != nil, isDraft { setDraft(projectTitle: nil) }
        updateComposerShown()
    }

    /// The composer shows with a thread, a draft, or a just-sent first message. Call after
    /// changing `model.optimisticMessages`.
    public func updateComposerShown() {
        composerShown = isDraft || model.projection != nil || !model.optimisticMessages.isEmpty
        needsLayout = true
    }

    /// The composer lane (J-composer-visuals 1.1 to 1.4): 48px side padding (12 below a 640
    /// viewport), at most 736 wide, 20px above the bottom; the timeline keeps the overlay's height
    /// (`pt-2` + composer + spacer) clear. On the draft page the composer, a 32px context strip and
    /// the spacer are centered in the column below the header, with the hero 16px above.
    private func layoutComposer(chat: CGFloat, height chatHeight: CGFloat) {
        let lane: CGFloat = viewportWidth < 640 ? 12 : 48
        let width = max(0, min(Tokens.LengthRem.chatContentMaxWidth * 16, chat - 2 * lane))
        let height = composer.preferredHeight
        let x = ((chat - width) / 2).rounded()
        let y: CGFloat
        if isDraft {
            // ponytail: the strip holds only "Run on"; the checkout and branch pickers come with the branch toolbar
            let block = height + 32 + 20
            let top = ThreadHeaderView.height + (chatHeight - ThreadHeaderView.height - block) / 2
            y = top.rounded()
            hero.frame = NSRect(x: x, y: y - 16 - DraftHeroView.height, width: width, height: DraftHeroView.height)
        } else {
            y = chatHeight - 20 - height
        }
        composer.frame = NSRect(x: x, y: y, width: width, height: height)
        composer.isHidden = !composerShown || chat == 0
        let strip = isDraft && showsContextStrip && !composer.isHidden
        contextStrip.isHidden = !strip
        composer.joinsContextStrip = strip
        let stripInset = ComposerContextStripView.inset
        contextStrip.frame = NSRect(x: x + stripInset, y: y + height - ComposerContextStripView.overlap,
                                    width: max(0, width - 2 * stripInset), height: ComposerContextStripView.height)
        // Attachments, 22pt in from each side, each sliding 17pt under the one below it: the
        // request panel under the composer, the queue under the panel (ComposerBanner.Column).
        // The menu (`ComposerCommandMenuLayer`): its bottom 17 under the composer's top, 22 in from
        // each side, at most as tall as the room above (`rect.top - 24 + overlap`, at least 96).
        let menuShown = menus.isOpen && !composer.isHidden
        commandMenu.isHidden = !menuShown
        if menuShown {
            let h = min(commandMenu.preferredHeight, max(96, y - 24 + ComposerBannerView.overlap))
            commandMenu.frame = NSRect(x: x + ComposerBannerView.drawerInset, y: y + ComposerBannerView.overlap - h,
                                       width: max(0, width - 2 * ComposerBannerView.drawerInset), height: h)
        }
        let stashShown = !menuShown && stashMenuOpen && !composer.isHidden && drawer != .approval
        stashMenu.isHidden = !stashShown
        if stashShown {
            let maxList = min(384, (window?.contentView?.bounds.height ?? bounds.height) * 0.4)
            let h = min(stashMenu.preferredHeight(maxList: maxList), max(96, y - 24 + ComposerBannerView.overlap))
            stashMenu.frame = NSRect(x: x + ComposerBannerView.drawerInset, y: y + ComposerBannerView.overlap - h,
                                     width: max(0, width - 2 * ComposerBannerView.drawerInset), height: h)
        }
        let docked = !composer.isHidden && !isDraft
        // The dock (`ComposerBanner.Dock`, `flex items-end gap-1`): the column of attachments, then
        // the stash tab at the right, both ending 17pt under the composer's top.
        let badgeShown = showsStashBadge && !composer.isHidden && drawer != .approval
        stashBadge.isHidden = !badgeShown
        let badgeWidth = badgeShown ? stashBadge.preferredWidth : 0
        let dockRight = x + width - ComposerBannerView.drawerInset
        if badgeShown {
            stashBadge.frame = NSRect(x: dockRight - badgeWidth, y: y + ComposerBannerView.overlap - stashBadge.preferredHeight,
                                      width: badgeWidth, height: stashBadge.preferredHeight)
        }
        let bannerX = x + ComposerBannerView.drawerInset
        let bannerWidth = max(0, width - 2 * ComposerBannerView.drawerInset - (badgeShown ? badgeWidth + 4 : 0))
        let overlap = ComposerBannerView.overlap
        var top = y
        let shown: ComposerBannerView? = !docked ? nil : drawer == .approval ? approvalPanel : drawer == .question ? questionPanel : nil
        approvalPanel.isHidden = shown !== approvalPanel
        questionPanel.isHidden = shown !== questionPanel
        if let shown {
            // `max-h-[min(24rem,40dvh)]` for the question body.
            questionPanel.maxBodyHeight = min(384, (window?.contentView?.bounds.height ?? bounds.height) * 0.4)
            let h = shown === approvalPanel ? approvalPanel.preferredHeight(width: bannerWidth) : questionPanel.preferredHeight(width: bannerWidth)
            shown.frame = NSRect(x: bannerX, y: top + overlap - h, width: bannerWidth, height: h)
            top = shown.frame.minY
        }
        let activityShown = docked && showsActivity
        activityRow.isHidden = !activityShown
        if activityShown {
            let h = activityRow.preferredHeight
            activityRow.frame = NSRect(x: bannerX, y: top + overlap - h, width: bannerWidth, height: h)
            top = activityRow.frame.minY
        }
        activityRow.joinsAbove = false
        let bannerShown = docked && showsEnvironmentBanner
        environmentBanner.isHidden = !bannerShown
        if bannerShown {
            let h = EnvironmentBannerView.height
            environmentBanner.frame = NSRect(x: bannerX, y: top + overlap - h, width: bannerWidth, height: h)
            top = environmentBanner.frame.minY
        }
        let queueHeight = docked ? queue.preferredHeight : 0
        queue.isHidden = queueHeight == 0
        queue.frame = NSRect(x: bannerX, y: top + overlap - queueHeight, width: bannerWidth, height: queueHeight)
        if queueHeight > 0 { top = queue.frame.minY }
        environmentBanner.joinsAbove = queueHeight > 0
        activityRow.joinsAbove = queueHeight > 0 || bannerShown
        approvalPanel.joinsAbove = queueHeight > 0 || bannerShown || activityShown
        questionPanel.joinsAbove = queueHeight > 0 || bannerShown || activityShown
        let above = max(y - top, badgeShown ? stashBadge.preferredHeight - overlap : 0)
        let inset = docked ? 8 + above + height + 20 : 0
        if timeline.bottomInset != inset { timeline.bottomInset = inset }
        if isDraft { timeline.isHidden = true }
    }

    /// No fill of its own: the main panel's grain surface (`bg-background surface-grain`) shows
    /// through. Only the top fade uses the background color.
    public override func updateLayer() {
        let bg = TL.c(\.background).cgColor(in: self)
        fade.colors = [1, 0.9, 0.7, 0.42, 0.18, 0.04, 0].map { bg.copy(alpha: $0)! }
    }

    public override func layout() {
        super.layout()
        // ponytail: always inline; T3 shows the panel as a sheet over the chat below a 980px
        // viewport and animates the width. Add both when windows that narrow matter
        let panelWidth = !rightPanelOpen ? 0 : rightPanelMaximized ? bounds.width
            : RightPanelView.width(viewport: viewportWidth, container: bounds.width)
        let chat = max(0, bounds.width - panelWidth)
        header.isHidden = chat == 0
        timeline.isHidden = chat == 0
        header.frame = NSRect(x: 0, y: 0, width: chat, height: ThreadHeaderView.height)
        // The drawer sits under the chat column, left of the right panel (ChatView.tsx:11905-11921);
        // the column above it keeps at least the header.
        let drawer = terminalOpen && chat > 0 ? max(0, min(terminalHeight, bounds.height - ThreadHeaderView.height)) : 0
        let chatHeight = bounds.height - drawer
        terminalDrawer.isHidden = drawer == 0
        terminalDrawer.frame = NSRect(x: 0, y: chatHeight, width: chat, height: drawer)
        timeline.frame = NSRect(x: 0, y: ThreadHeaderView.height, width: chat, height: max(0, chatHeight - ThreadHeaderView.height))
        rightPanel.frame = NSRect(x: chat, y: 0, width: panelWidth, height: bounds.height)
        if rightPanelOpen {
            // The window's panel controls: `mr-px` and 12px from the right, `gap-1`.
            var x = bounds.width - 12 - 1
            for control in [header.toggles[2], header.toggles[1], maximize] {
                let size = control.intrinsicContentSize
                x -= size.width
                control.frame = NSRect(x: x, y: ThreadHeaderView.height / 2 - size.height / 2, width: size.width, height: size.height)
                x -= 4
            }
        }
        layoutComposer(chat: chat, height: chatHeight)
        // `mx-auto w-fit max-w-[min(48rem,calc(100%-2rem))] pt-3` in the chat column.
        if !errorBanner.isHidden {
            let w = errorBanner.fittingWidth(max: max(0, min(768, chat - 32)))
            let h = errorBanner.height(forWidth: w)
            errorBanner.frame = NSRect(x: ((chat - w) / 2).rounded(), y: ThreadHeaderView.height + 12, width: w, height: h)
        }
        if let content = window?.contentView {
            toasts.frame = convert(ToastViewport.frame(in: content.bounds), from: content)
        } else {
            toasts.frame = ToastViewport.frame(in: bounds)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The last 6px column (the scrollbar) stays unmasked. No fade under a top banner (`topFadeEnabled`).
        fade.frame = CGRect(x: 0, y: ThreadHeaderView.height, width: max(0, chat - 6), height: 25)
        fade.zPosition = 1
        fade.isHidden = !errorBanner.isHidden
        errorBanner.layer?.zPosition = 2
        toasts.layer?.zPosition = 3
        CATransaction.commit()
    }
}
