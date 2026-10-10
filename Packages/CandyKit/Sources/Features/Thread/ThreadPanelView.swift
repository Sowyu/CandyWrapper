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
        set { project.text = newValue; favicon.projectTitle = newValue; needsLayout = true }
    }

    public var threadTitle: String {
        get { title.text }
        set { title.text = newValue; needsLayout = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [project, slash, title] { label.lineHeight = 20; addSubview(label) }
        addSubview(favicon)
        // ponytail: the thread details and terminal toggles only reserve their place and look; their panels come with M5 and M7
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
    public let hero = DraftHeroView()
    /// Showing the new-thread draft page instead of a thread.
    public private(set) var isDraft = false
    private var composerShown = false
    public let model = ThreadViewModel()
    private let fade = CAGradientLayer()
    let rightPanel = RightPanelView()
    /// `RightPanelMaximizeControl`, shown left of the window's panel toggles while the panel is open.
    let maximize = ToggleView(nil, icon: .maximize2, variant: .ghost, size: .sm)
    public var diffPanel: DiffPanelView { rightPanel.diff }
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
        addSubview(queue)
        addSubview(composer)
        composer.onHeightChange = { [weak self] in self?.needsLayout = true }
        queue.onHeightChange = { [weak self] in self?.needsLayout = true }
        // `topbar-scroll-fade` (index.css:439-475): the first 25px of the scroller fade out; drawn as
        // a background-colored overlay instead of a mask, so scrolling doesn't render offscreen.
        fade.locations = [0, 0.1, 0.24, 0.42, 0.62, 0.82, 1]
        layer?.addSublayer(fade)
        timeline.context.model = model
        model.onChange = { [weak self] in
            guard let self else { return }
            self.timeline.setItems(self.model.items)
        }
        rightPanel.isHidden = true
        addSubview(rightPanel)
        maximize.setAccessibilityLabel("Maximize panel")
        maximize.isHidden = true
        maximize.onPressedChange = { [weak self] _ in self?.toggleMaximized() }
        addSubview(maximize)
        header.toggles[2].onPressedChange = { [weak self] _ in self?.userSetRightPanel(!(self?.rightPanelOpen ?? true)) }
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

    /// Cmd+D (`diff.toggle`): the panel on the diff, or closed.
    public func toggleDiff() {
        guard model.projection != nil else { return }
        userSetRightPanel(!rightPanelOpen)
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
            header.threadTitle = "New thread"
            for view in header.subviews { view.isHidden = false }
        }
        updateComposerShown()
    }

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
    private func layoutComposer(chat: CGFloat) {
        let lane: CGFloat = viewportWidth < 640 ? 12 : 48
        let width = max(0, min(Tokens.LengthRem.chatContentMaxWidth * 16, chat - 2 * lane))
        let height = composer.preferredHeight
        let x = ((chat - width) / 2).rounded()
        let y: CGFloat
        if isDraft {
            // ponytail: the context strip (checkout and branch pickers) is not drawn; it comes with the branch toolbar
            let block = height + 32 + 20
            let top = ThreadHeaderView.height + (bounds.height - ThreadHeaderView.height - block) / 2
            y = top.rounded()
            hero.frame = NSRect(x: x, y: y - 16 - DraftHeroView.height, width: width, height: DraftHeroView.height)
        } else {
            y = bounds.height - 20 - height
        }
        composer.frame = NSRect(x: x, y: y, width: width, height: height)
        composer.isHidden = !composerShown || chat == 0
        // The queue slides 17pt under the composer, 22pt in from each side (ComposerBanner.Attachment).
        let queueHeight = composer.isHidden || isDraft ? 0 : queue.preferredHeight
        queue.isHidden = queueHeight == 0
        queue.frame = NSRect(x: x + QueuedRunsView.inset, y: y - queueHeight + QueuedRunsView.overlap,
                             width: max(0, width - 2 * QueuedRunsView.inset), height: queueHeight)
        let above = queueHeight == 0 ? 0 : queueHeight - QueuedRunsView.overlap
        let inset = composer.isHidden || isDraft ? 0 : 8 + above + height + 20
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
        timeline.frame = NSRect(x: 0, y: ThreadHeaderView.height, width: chat, height: max(0, bounds.height - ThreadHeaderView.height))
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
        layoutComposer(chat: chat)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The last 6px column (the scrollbar) stays unmasked.
        fade.frame = CGRect(x: 0, y: ThreadHeaderView.height, width: max(0, chat - 6), height: 25)
        fade.zPosition = 1
        CATransaction.commit()
    }
}
