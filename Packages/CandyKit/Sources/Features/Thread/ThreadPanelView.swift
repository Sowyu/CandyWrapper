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
    private let titleHit = ThreadHeaderTitleView()
    private let parentCrumb = ThreadHeaderParentCrumb()
    private let projectButton = ThreadHeaderProjectButton()
    /// The project crumb's click: a new thread in this project (`onNewThreadInProject`, ChatView.tsx:2605-2607).
    public var onNewThreadInProject: (@MainActor () -> Void)? { didSet { projectButton.action = onNewThreadInProject } }
    private let parentSlash = LabelView("/", font: TL.font(14, .medium), color: TL.c(\.iconMuted))
    /// The open subagent's parent title, nil for any other thread (ChatHeader.tsx:343-375 in 2994).
    public var parentThreadTitle: String? {
        didSet {
            guard parentThreadTitle != oldValue else { return }
            parentCrumb.title = parentThreadTitle ?? ""
            updateParentVisibility()
            needsLayout = true
            onTitlesChange?()
        }
    }
    public var onOpenParent: (@MainActor () -> Void)? { didSet { parentCrumb.action = onOpenParent } }
    private var threadVisible = true
    private func updateParentVisibility() {
        let hidden = !threadVisible || parentThreadTitle == nil
        parentCrumb.isHidden = hidden
        parentSlash.isHidden = hidden
    }
    private let titleEditor = InputView(placeholder: "Thread title", size: .inline)
    public var onThreadMenu: ((NSEvent, NSView) -> Void)?
    public var onRenameThread: ((String) -> Void)?
    public var onEmptyTitle: (() -> Void)?
    /// The project or thread title changed, for a toolbar that shows them in place of this header.
    public var onTitlesChange: (@MainActor () -> Void)?
    /// Glass Native's toolbar breadcrumb edits the title in its own field while this header is hidden.
    public var renameInPlace: (@MainActor () -> Void)?
    /// A rename typed elsewhere (the toolbar breadcrumb): empty asks `onEmptyTitle`, a new title `onRenameThread`.
    public func commitRename(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { onEmptyTitle?() } else if value != threadTitle { onRenameThread?(value) }
    }
    public func beginTitleRename() {
        guard onRenameThread != nil else { return }
        if let renameInPlace, isHidden { return renameInPlace() }
        titleEditor.text = threadTitle
        titleEditor.isHidden = false
        needsLayout = true
        window?.makeFirstResponder(titleEditor)
        (window?.firstResponder as? NSTextView)?.selectAll(nil)
    }
    private func finishTitleRename() {
        guard !titleEditor.isHidden else { return }
        let value = titleEditor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        titleEditor.isHidden = true
        if value.isEmpty { onEmptyTitle?() } else if value != threadTitle { onRenameThread?(value) }
    }
    private let title = LabelView("", font: TL.font(14, .medium), color: TL.c(\.foreground))
    /// Thread panel, terminal, right panel (PanelLayoutControls.tsx:76).
    public let toggles: [ToggleView] = [IconName.squareMenu, .panelBottom, .panelRight].map {
        ToggleView(nil, icon: $0, variant: .ghost, size: .sm)
    }

    public var projectTitle: String {
        get { project.text }
        set {
            guard newValue != project.text else { return }
            project.text = newValue
            projectButton.project = newValue
            if favicon.source?.title != newValue { favicon.source = nil }
            favicon.projectTitle = newValue
            needsLayout = true
            onTitlesChange?()
        }
    }

    /// The project's icon inputs; set after `projectTitle`. A different title clears it.
    public var projectIcon: ProjectIconSource? {
        get { favicon.source }
        set {
            guard newValue != favicon.source else { return }
            favicon.source = newValue
            onTitlesChange?()
        }
    }

    public func setThreadVisible(_ visible: Bool) {
        for view in subviews where view !== titleEditor { view.isHidden = !visible }
        if !visible { titleEditor.isHidden = true }
        threadVisible = visible
        updateParentVisibility()
    }
    public func cancelTitleRename() { titleEditor.isHidden = true; titleHit.cancelPendingMenu() }

    private var toggleTips: [TooltipController] = []

    /// PanelLayoutControls.tsx:61-127: each toggle's words and its shortcut. Every thread and draft here has a project, so T3's "is unavailable"
    /// texts (`activeProject === null`) never apply.
    private func refreshToggleTooltips() {
        func tip(_ text: String, _ command: String) -> String {
            ActiveKeymap.label(for: command).map { "\(text) (\($0))" } ?? text
        }
        guard toggleTips.count == 3 else { return }
        toggleTips[0].text = tip("Toggle thread details", "threadPanel.toggle")
        toggleTips[1].text = tip("Toggle terminal drawer", "terminal.toggle")
        toggleTips[2].text = tip("Toggle right panel", "rightPanel.toggle")
    }

    public var threadTitle: String {
        get { title.text }
        set {
            guard newValue != title.text else { return }
            title.text = newValue
            titleHit.setAccessibilityLabel("Thread actions for \(newValue)")
            needsLayout = true
            onTitlesChange?()
        }
    }

    /// The `nav` named "Thread breadcrumb" (ChatHeader.tsx:262-264): the project, then the title button
    /// ("Thread actions for ...", :325-327).
    private let breadcrumb = NSAccessibilityElement()

    public override func accessibilityChildren() -> [Any]? {
        // The header itself is ignored, so its own children are its unignored descendants.
        let others = NSAccessibility.unignoredChildren(from: subviews.filter { $0 !== titleHit && $0 !== parentCrumb && $0 !== projectButton && !$0.isHidden })
        guard !title.isHidden, let window else { return others }
        func screen(_ rect: NSRect) -> NSRect { window.convertToScreen(convert(rect, to: nil)) }
        breadcrumb.setAccessibilityFrame(screen(project.frame.union(titleHit.frame)))
        var crumbs: [Any] = project.text.isEmpty ? [] : [projectButton]
        if !parentCrumb.isHidden { crumbs.append(parentCrumb) }
        crumbs.append(titleHit)
        breadcrumb.setAccessibilityChildren(crumbs)
        return [breadcrumb] + others
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [project, slash, parentSlash, title] { label.lineHeight = 20; addSubview(label) }
        addSubview(parentCrumb)
        parentCrumb.accessibilityGroup = breadcrumb
        updateParentVisibility()
        addSubview(favicon)
        projectButton.label = project
        addSubview(projectButton)
        toggles[0].setAccessibilityLabel("Toggle thread details panel")
        toggles[1].setAccessibilityLabel("Toggle terminal drawer")
        toggles[2].setAccessibilityLabel("Toggle right panel")
        toggles.forEach(addSubview)
        toggleTips = toggles.map { TooltipController.attach(to: $0, text: "", placement: PopupPlacement(side: .bottom, align: .center, sideOffset: 4)) }
        refreshToggleTooltips()
        // The header lives as long as the window: the observer is never removed.
        ActiveKeymap.observe { [weak self] in self?.refreshToggleTooltips() }
        addSubview(titleHit)
        breadcrumb.setAccessibilityRole(.group)
        breadcrumb.setAccessibilityLabel("Thread breadcrumb")
        breadcrumb.setAccessibilityParent(self)
        titleHit.setAccessibilityElement(true)
        titleHit.setAccessibilityRole(.button)
        titleHit.accessibilityGroup = breadcrumb
        titleHit.onMenu = { [weak self] event, view in self?.onThreadMenu?(event, view) }
        titleHit.onRename = { [weak self] in self?.beginTitleRename() }
        addSubview(titleEditor)
        titleEditor.isHidden = true
        titleEditor.onSubmit = { [weak self] in self?.finishTitleRename() }
        titleEditor.onCommit = { [weak self] _ in self?.finishTitleRename() }
        titleEditor.onCommand = { [weak self] command in
            guard command == #selector(NSResponder.cancelOperation(_:)) else { return false }
            self?.titleEditor.isHidden = true; return true
        }
    }

    public override func layout() {
        super.layout()
        let midY = Self.height / 2
        let start = contentStart
        // `size-3.5` favicon: the 16px monogram drawn at 14px.
        favicon.frame = NSRect(x: start, y: midY - 7, width: 14, height: 14)
        favicon.bounds = NSRect(x: 0, y: 0, width: 16, height: 16)
        let projectWidth = min(160, project.textWidth)
        project.frame = NSRect(x: start + 20, y: midY - 10, width: ceil(projectWidth), height: 20)
        let slashX = start + 20 + projectWidth + 12
        projectButton.frame = NSRect(x: start, y: midY - 10, width: 20 + ceil(projectWidth), height: 20)
        projectButton.isHidden = project.text.isEmpty || !threadVisible
        slash.frame = NSRect(x: slashX, y: midY - 10, width: ceil(slash.textWidth), height: 20)
        var titleX = slashX + slash.textWidth + 12
        // `pr-24` keeps the title clear of the toggles; with the right panel open only the details
        // toggle is left and it is `pr-10`, plus the title button's hidden 14px chevron and `gap-1`
        // (ChatHeader.tsx:256-345).
        let reserve: CGFloat = toggles[2].superview === self ? 96 : 40 + 4 + 14
        let titleRight = bounds.width - 38 - reserve
        if !parentCrumb.isHidden {
            // The parent shows in full unless the whole breadcrumb would then overflow; then it collapses
            // to "..." (ChatHeader.tsx:130-164 in 2994).
            let slashWidth = ceil(parentSlash.textWidth)
            parentCrumb.collapsed = titleX + parentCrumb.fullWidth + 12 + slashWidth + 12 + ceil(title.textWidth) + 1 > titleRight
            parentCrumb.frame = NSRect(x: titleX, y: midY - 10, width: parentCrumb.width, height: 20)
            parentSlash.frame = NSRect(x: parentCrumb.frame.maxX + 12, y: midY - 10, width: slashWidth, height: 20)
            titleX = parentSlash.frame.maxX + 12
        }
        title.frame = NSRect(x: titleX, y: midY - 10, width: max(0, min(ceil(title.textWidth) + 1, titleRight - titleX)), height: 20)
        titleHit.frame = title.frame.insetBy(dx: 0, dy: 0)
        titleHit.frame.size.width += 18
        titleEditor.frame = NSRect(x: title.frame.minX - 4, y: midY - 11, width: max(80, title.frame.width + 8), height: 22)
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
    /// Built the first time thread search opens; wire it through `lazyFindBar`.
    public let lazyFindBar = LazyView { ThreadFindBarView() }
    public var findBar: ThreadFindBarView { lazyFindBar.view }
    public var findOpen = false { didSet {
        // The details card makes room under the bar: inline it slides down and returns at once, as a popover it
        // slides both ways; the bar fades in (ThreadDetailsCard.tsx:163-170, popover.tsx:79-83, ThreadFindBar.tsx:62-66
        // in 2994, f92afe79c).
        let changed = findOpen != oldValue
        if changed, detailsOpen, let card = lazyDetailsCard.loaded, !card.isHidden, findOpen || timeline.detailsCardLeft == nil { detailsSlideFrom = card.frame.minY }
        if findOpen {
            findBar.isHidden = false
            if changed { Self.fadeIn(findBar) }
        } else { lazyFindBar.release() }
        if !findOpen { pendingFindMatch = nil; model.closeThreadFind(); timeline.threadFindMatch = nil }
        needsLayout = true
    } }
    /// `THREAD_FIND_BAR_RESERVED_HEIGHT`: the find bar's `top-3` and 36px height push the details card down.
    private var findInset: CGFloat { findOpen ? 48 : 0 }
    private var detailsSlideFrom: CGFloat?
    /// `transition-[top] duration-150 ease-out`, as an additive offset so the frame is final at once.
    private static func slide(_ view: NSView, by offset: CGFloat) {
        guard !Motion.reduced, let layer = view.layer else { return }
        let a = CABasicAnimation(keyPath: "transform.translation.y")
        a.fromValue = offset
        a.toValue = 0
        a.isAdditive = true
        a.duration = Motion.Durations.default
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
        layer.add(a, forKey: "findSlide")
    }
    /// `transition-opacity duration-150 ease-out starting:opacity-0`.
    private static func fadeIn(_ view: NSView) {
        guard !Motion.reduced, let layer = view.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = Motion.Durations.default
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
        layer.add(a, forKey: "findFade")
    }
    private var pendingFindMatch: ThreadFindResult.Match?
    public func revealThreadFind(_ match: ThreadFindResult.Match) {
        pendingFindMatch = match
        timeline.threadFindMatch = match
        model.prepareThreadFind(match)
        if timeline.revealFindEntry(match.entryId) { pendingFindMatch = nil }
        else { onLoadEarlier?() }
    }
    public let timeline = TimelineView()
    public let composer = ComposerView()
    /// The queued messages docked above the composer; it hides itself when empty.
    public let queue = QueuedRunsView()
    /// The runtime request docked between the queue and the composer (ChatComposer.tsx's top
    /// drawer). Show one through `drawer`; the composer controller configures them.
    public let approvalPanel = ApprovalPanelView()
    /// The pending question's card, built the first time a question shows. Wire it through `lazyQuestionPanel`.
    public let lazyQuestionPanel = LazyView { QuestionPanelView() }
    public var questionPanel: QuestionPanelView { lazyQuestionPanel.view }
    /// The `/`, `@`, `$` and `#` menu, docked on the composer's top edge over the other attachments.
    public let commandMenu = ComposerCommandMenuView()
    /// Drives `commandMenu` from the composer's caret; the app supplies rows and acts on picks.
    public private(set) lazy var menus = ComposerMenuController(composer: composer, menu: commandMenu)
    /// "<label> is reconnecting|offline" (ChatView.tsx:3091-3142): the banner stack's front item, docked
    /// between the queue and the request panel. Shown through `showsEnvironmentBanner`.
    public let environmentBanner = EnvironmentBannerView()
    public var showsEnvironmentBanner = false { didSet { if showsEnvironmentBanner != oldValue { needsLayout = true } } }
    /// Glass Native's toolbar shows the title and the panel buttons, so the chat column starts at the top.
    /// It also turns on Glass Native's material: the native row style and solid request panels with native buttons.
    public var hidesCustomChrome = false { didSet { if hidesCustomChrome != oldValue { applyPresentation() } } }
    /// The height of the window's toolbar over this view (Glass Native). The timeline scrolls under it; the rest
    /// of the chat column starts below it.
    public var toolbarInset: CGFloat = 0 { didSet { if toolbarInset != oldValue { needsLayout = true } } }
    private var chatTop: CGFloat { hidesCustomChrome ? toolbarInset : ThreadHeaderView.height }

    /// The right panel can maximize now (open, not a sheet): Glass Native's toolbar shows its Maximize button.
    public var onMaximizableChange: ((Bool) -> Void)?
    /// Thread details, the terminal drawer, the right panel or its maximized state changed: Glass Native's
    /// toolbar toggles show their on states.
    public var onPanelTogglesChange: (() -> Void)?
    private var reportedMaximizable = false
    /// The soft edge where the rows scroll under the toolbar, made while Glass Native shows.
    private var scrollFade: ToolbarScrollFade?

    private func applyPresentation() {
        let native = hidesCustomChrome
        timeline.style = native ? .native : .classic
        approvalPanel.nativeCard = native
        lazyQuestionPanel.set(\.nativeCard, native)
        composer.nativeGlass = native
        rightPanel.nativeChrome = native
        lazyTerminalDrawer.set(\.nativeChrome, native)
        if native, scrollFade == nil {
            scrollFade = ToolbarScrollFade(on: timeline.scrollView)
        } else if !native {
            scrollFade?.remove()
            scrollFade = nil
        }
        needsLayout = true
    }
    /// A notice from the banner stack (the project clone's progress or failure), docked over the
    /// composer on drafts and threads alike. Shown through `showsNoticeBanner`.
    /// The notice banners are built the first time they show; wire them through the lazy holders.
    public let lazyNoticeBanner = LazyView { ComposerNoticeBannerView() }
    public let lazyGoalBanner = LazyView { ComposerNoticeBannerView() }
    public let lazyRecoveryBanner = LazyView { ComposerNoticeBannerView() }
    public var noticeBanner: ComposerNoticeBannerView { lazyNoticeBanner.view }
    public var goalBanner: ComposerNoticeBannerView { lazyGoalBanner.view }
    public var recoveryBanner: ComposerNoticeBannerView { lazyRecoveryBanner.view }
    public var showsGoal = false { didSet { if showsGoal != oldValue { needsLayout = true } } }
    /// "Branch changed — was <branch>" (ChatView.tsx:7801-7837), keyed like T3's `branch-mismatch:<key>`.
    public let lazyBranchBanner = LazyView { ComposerNoticeBannerView() }
    public var branchBanner: ComposerNoticeBannerView { lazyBranchBanner.view }
    public var branchMismatchKey: String? { didSet { if branchMismatchKey != oldValue { needsLayout = true } } }
    public var showsRecovery = false { didSet { if showsRecovery != oldValue { needsLayout = true } } }
    public let tasksView = ThreadTasksView()
    public let lazyPlanFollowUpBanner = LazyView { ComposerNoticeBannerView() }
    public var planFollowUpBanner: ComposerNoticeBannerView { lazyPlanFollowUpBanner.view }
    public var showsPlanFollowUp = false { didSet { if showsPlanFollowUp != oldValue { needsLayout = true } } }
    private let threadFileDrop = ComposerFileDrop()
    private let fileDropOverlay = ThreadFileDropOverlay()

    private let lazyServerUpdateBanner = LazyView { ComposerNoticeBannerView() }
    private var serverUpdateBanner: ComposerNoticeBannerView { lazyServerUpdateBanner.view }
    /// Fed by the server updater. Hidden views hold no update task or subscription.
    // ponytail: the M9 updater has no operation state yet; connect its per-environment state here when it lands
    public var serverUpdateNotice: ComposerServerUpdateNotice? {
        didSet {
            guard serverUpdateNotice != oldValue else { return }
            if let notice = serverUpdateNotice {
                serverUpdateBanner.apply(notice.content)
                serverUpdateBanner.toolTip = notice.title + ": " + notice.detail
                // The failed notice's X ("Dismiss update notice", ChatView.tsx:3209-3220).
                serverUpdateBanner.onAction = { [weak self] index in if index == nil { self?.serverUpdateNotice = nil } }
            }
            needsLayout = true
        }
    }
    public var showsNoticeBanner = false { didSet { if showsNoticeBanner != oldValue { needsLayout = true } } }
    /// The `/usage-limits` result, a notice in the banner stack. Its X plays the stack's exit, then clears it.
    public var usageLimitsBanner: UsageLimitsBannerView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let b = usageLimitsBanner {
                addSubview(b, positioned: .above, relativeTo: queue)
                b.dismiss.action = { [weak self, weak b] in
                    guard let self, let b else { return }
                    bannerStack.requestDismiss(Self.usageLimitsId(b))
                }
            }
            needsLayout = true
        }
    }
    /// The notices behind the front banner: the peek, and the floating cards it opens on hover.
    public let bannerStack = ComposerBannerStackView()
    static func usageLimitsId(_ banner: UsageLimitsBannerView) -> String { "usage-limits:\(ObjectIdentifier(banner).hashValue)" }

    /// `composerBannerItems` (ChatView.tsx:7776-7839) in T3's order: limit recovery, usage limits, the
    /// project clone, the system items (environment, server update; ChatView.tsx:3091-3224), then the
    /// goal, then the branch change notice. Not built yet: Codex feedback, background work, auto balance updates.
    func bannerStackItems(docked: Bool, composerVisible: Bool) -> [ComposerBannerStackItem] {
        var items: [ComposerBannerStackItem] = []
        let notice = { (id: String, view: ComposerNoticeBannerView) -> ComposerBannerStackItem in
            var item = ComposerBannerStackItem(id: id, view: view, priority: view.content?.priority, height: { _ in ComposerNoticeBannerView.height })
            if view.content?.dismissible == true {
                view.onDismissRequest = { [weak self] in self?.bannerStack.requestDismiss(id) }
                item.onDismiss = { [weak view] in view?.onAction?(nil) }
            } else {
                view.onDismissRequest = nil
            }
            return item
        }
        if docked && showsRecovery {
            items.append(ComposerBannerStackItem(id: "usage-limit-recovery", view: recoveryBanner, priority: .urgent,
                                                 height: { _ in ComposerNoticeBannerView.height }))
        }
        if docked, let usage = usageLimitsBanner {
            items.append(ComposerBannerStackItem(id: Self.usageLimitsId(usage), view: usage, priority: .notice,
                                                 height: { [usage] in usage.height(forWidth: $0) },
                                                 onDismiss: { [weak self, weak usage] in
                                                     if let self, usageLimitsBanner === usage { usageLimitsBanner = nil }
                                                 }))
        }
        // Thread-scoped ids, like T3's `goal:${threadId}`: a thread switch drops the old item, which
        // cancels a dismiss still playing instead of running it against the new thread's banner.
        let thread = model.projection?.thread.id.rawValue ?? ""
        if showsNoticeBanner && composerVisible { items.append(notice("project-clone:" + thread, noticeBanner)) }
        if docked && showsEnvironmentBanner {
            items.append(ComposerBannerStackItem(id: "environment-unavailable", view: environmentBanner,
                                                 height: { _ in EnvironmentBannerView.height }))
        }
        if serverUpdateNotice != nil && composerVisible { items.append(notice("server-version", serverUpdateBanner)) }
        if docked && showsGoal { items.append(notice("goal:" + thread, goalBanner)) }
        if docked, let key = branchMismatchKey { items.append(notice("branch-mismatch:" + key, branchBanner)) }
        return items
    }

    public enum Drawer: Sendable { case none, approval, question }
    public var drawer = Drawer.none { didSet { if drawer != oldValue { needsLayout = true } } }
    /// The stash count tab on the dock's right (`ComposerStashBadge`); hidden at zero and during approvals.
    public let stashBadge = ComposerStashBadgeView()
    public var showsStashBadge = false { didSet { if showsStashBadge != oldValue { needsLayout = true } } }
    /// The stash list, docked where the `/` menu goes; the `/` menu wins when both are open.
    /// Built the first time it opens. Wire it and push entries through `lazyStashMenu`.
    public let lazyStashMenu = LazyView { ComposerStashMenuView() }
    public var stashMenu: ComposerStashMenuView { lazyStashMenu.view }
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
    /// The composer provider's status (ProviderStatusBanner.tsx), above the error banner in the
    /// same top column (ChatView.tsx:11356-11362).
    public let providerBanner = ThreadErrorBannerView()
    /// T3's top-right toast stack (`ToastProvider`), placed against the window, above everything.
    public let toasts = ToastViewport()
    /// Showing the new-thread draft page instead of a thread.
    public private(set) var isDraft = false
    private var composerShown = false
    public let model = ThreadViewModel()
    private var applyingProjection = false
    private var proactivePanels = SettingsProactivePanels()
    private var panelActionRevision = 0
    public var proactiveRepositoryIsGit: Bool? { didSet { if proactiveRepositoryIsGit != oldValue { evaluateProactivePanels() } } }
    public var proactiveLinkedPullRequestKey: String? { didSet { if proactiveLinkedPullRequestKey != oldValue { evaluateProactivePanels() } } }
    public var onProactivePullRequest: (() -> Void)?
    /// A timeline click opens the diff on its own turn, not on Changes.
    private var explicitDiffOpen = false

    public func evaluateProactivePanels() {
        guard !applyingProjection, !switchingThread, window != nil, !isDraft, let projection = model.projection else { return }
        let latest = projection.runs.max { $0.ordinal < $1.ordinal }
        let running = projection.runs.last { $0.status == .running || $0.status == .waiting }
        let summary = summaries.first { $0.runId == latest?.id }
        let action = proactivePanels.update(thread: projection.thread.id.rawValue, running: running?.id.rawValue,
            settled: latest?.id.rawValue, completed: latest?.status == .completed, linkedTarget: proactiveLinkedPullRequestKey,
            // The plan sheet layout (a window up to 980 wide) turns proactive panels off (ChatView.tsx:5763).
            revision: panelActionRevision, enabled: ClientSettingsStore.shared.current.bool("proactivePanelsEnabled") && viewportWidth > 980,
            checkpointStatus: summary?.status, fileCount: summary?.files.count ?? 0,
            changedLines: summary?.files.reduce(0) { $0 + ($1.additions ?? 0) + ($1.deletions ?? 0) } ?? 0,
            isRepository: proactiveRepositoryIsGit, activeSurface: panelState.active?.kind.rawValue)
        switch action {
        case .none: break
        case .pullRequest: onProactivePullRequest?()
        case .diff:
            // The panel opens on Changes (`selectGitScope(activeThreadRef, "branch")`, ChatView.tsx:5828-5833);
            // without git scopes, on the finished turn.
            var next = panelState; next.open(.diff)
            setPanelState(next, animated: true); onPanelChange?(next, [])
            if diffPanel.selectsGitScopes { diffPanel.selectGitScope(.branch) }
            else if let run = latest?.id { diffPanel.open(runId: run, filePath: nil) }
        }
    }
    private let fade = CAGradientLayer()
    private weak var sheetPreviousResponder: NSResponder?
    private var sheetWasOpen = false
    public var rightPanelSheetOpen: Bool { rightPanelOpen && viewportWidth <= 980 && !rightPanelMaximized }

    /// SheetPopup uses a modal focus scope. Routed by the existing app key dispatcher.
    public func handleRightPanelSheetKey(_ event: NSEvent) -> Bool {
        guard rightPanelSheetOpen, event.window === window,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        var responderView = window?.firstResponder as? NSView
        while let current = responderView {
            if current is ModalHost { return false }
            responderView = current.superview
        }
        if event.keyCode == 53 {
            if lazyDiffPanel.loaded?.handleReviewEscape() == true { return true }
            mutatePanel { $0.isOpen = false; return [] }
            return true
        }
        guard event.keyCode == 48 else { return false }
        let controls = rightPanelSheetFocusTargets()
        guard !controls.isEmpty else { window?.makeFirstResponder(rightPanel); return true }
        var focused = window?.firstResponder as? NSView
        if let editor = focused as? NSTextView, editor.isFieldEditor { focused = editor.delegate as? NSView }
        let index = controls.firstIndex { control in focused === control || focused?.isDescendant(of: control) == true }
        let reverse = event.modifierFlags.contains(.shift)
        let next = index.map { ($0 + (reverse ? controls.count - 1 : 1)) % controls.count } ?? (reverse ? controls.count - 1 : 0)
        window?.makeFirstResponder(controls[next])
        return true
    }
    private func rightPanelSheetFocusTargets() -> [NSView] {
        func collect(_ view: NSView) -> [NSView] {
            guard !view.isHiddenOrHasHiddenAncestor else { return [] }
            if let control = view as? ControlView, !control.isEnabled { return [] }
            if view.acceptsFirstResponder { return [view] }
            return view.subviews.flatMap(collect)
        }
        return rightPanel.subviews.flatMap(collect)
    }
    private let rightPanelBackdrop = RightPanelSheetBackdropView()
    let rightPanel = RightPanelView()
    /// `RightPanelMaximizeControl`, shown left of the window's panel toggles while the panel is open.
    let maximize = ToggleView(nil, icon: .maximize2, variant: .ghost, size: .sm)
    /// The diff surface; `diffPanel` builds it. Wire and feed it through `lazyDiffPanel`.
    public var diffPanel: DiffPanelView { rightPanel.diff }
    public var lazyDiffPanel: LazyView<DiffPanelView> { rightPanel.lazyDiff }
    /// The terminal drawer under the chat column; `TerminalController` fills it.
    /// Built the first time it opens. Wire it through `lazyTerminalDrawer`.
    public let lazyTerminalDrawer = LazyView { TerminalDrawerView() }
    public var terminalDrawer: TerminalDrawerView { lazyTerminalDrawer.view }
    public private(set) var terminalOpen = false
    /// The drawer's height while open (already clamped by the controller).
    public private(set) var terminalHeight: CGFloat = 0
    /// The header's terminal toggle was clicked (`terminal.toggle`).
    public var onTerminalToggle: (@MainActor () -> Void)?
    /// The thread details card (`ThreadDetailsPanel`): workspace, branch and git actions.
    /// Built the first time it opens. Controllers wire it with `lazyDetailsCard.configure` and fill it there
    /// and while it is loaded.
    public let lazyDetailsCard = LazyView { ThreadDetailsCardView() }
    public var detailsCard: ThreadDetailsCardView { lazyDetailsCard.view }
    /// T3 keeps the card's inline and popover visibility apart (rightPanelStore.ts:117-120 and 200-203). Inline, it
    /// stays as the user left it. As a popover over a narrow chat it opens on demand and closes on an outside
    /// press or Escape (ThreadDetailsCard.tsx:137-176), so it never sits over the thread for good.
    private var detailsInlineOpen = false
    private var detailsPopoverOpen = false
    /// The card pins inline beside the chat lane (true) or pops over the chat (false), as of the last layout.
    public private(set) var detailsInline = false
    public var detailsOpen: Bool { detailsInline ? detailsInlineOpen : detailsPopoverOpen }
    private var detailsPopoverMonitor: Any?
    /// The header's details toggle was clicked.
    public var onDetailsToggle: (@MainActor () -> Void)?
    /// `rightPanelState.maximized` (ChatView.tsx:2390 in 2994, 71f6f1db8): the thread's panel asked to fill the
    /// window. A narrow window shows the panel as a sheet and cannot maximize; widening it again restores the
    /// maximized panel. It stays with the thread through a close, a thread switch and a relaunch.
    public var rightPanelMaximized: Bool { panelState.maximized == true && canMaximizeRightPanel }
    /// `canMaximizeRightPanel = rightPanelOpen && !shouldUsePlanSidebarSheet`.
    var canMaximizeRightPanel: Bool { rightPanelOpen && viewportWidth > 980 }
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
        // Back to front: queue, request panel, composer (each slides under the next).
        addSubview(queue)
        tasksView.isHidden = true; addSubview(tasksView)
        tasksView.onHeightChange = { [weak self] in self?.needsLayout = true }
        environmentBanner.isHidden = true
        addSubview(environmentBanner)
        activityRow.isHidden = true
        addSubview(activityRow)
        stashBadge.isHidden = true
        addSubview(stashBadge)
        // Above every attachment (`z-20`), under the drawers and menus.
        bannerStack.isHidden = true
        bannerStack.onLayoutChange = { [weak self] in self?.needsLayout = true }
        addSubview(bannerStack)
        addSubview(approvalPanel)
        contextStrip.isHidden = true
        addSubview(contextStrip)
        addSubview(commandMenu)
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
            if let match = self.pendingFindMatch { self.revealThreadFind(match) }
        }
        // Banners overlay the timeline without changing its content height (`z-20`).
        addSubview(errorBanner)
        addSubview(providerBanner)
        rightPanel.isHidden = true
        rightPanelBackdrop.isHidden = true
        addSubview(rightPanelBackdrop)
        rightPanelBackdrop.onClose = { [weak self] in self?.toggleRightPanel() }
        addSubview(rightPanel)
        maximize.setAccessibilityLabel("Maximize panel")
        maximize.isHidden = true
        maximize.onPressedChange = { [weak self] _ in self?.toggleMaximized() }
        addSubview(maximize)
        for slide in [panelSlide, terminalSlide] {
            slide.onFrame = { [weak self] _ in self?.layoutNow() }
            slide.onEnd = { [weak self] in self?.slideEnded() }
        }
        addSubview(toasts)
        addSubview(fileDropOverlay); fileDropOverlay.isHidden = true; fileDropOverlay.layer?.zPosition = 40
        // Each banner goes where it always sat back to front: queue, goal, recovery, plan, tasks;
        // server update, notice, environment banner.
        lazyBranchBanner.onLoad = { [weak self] in self?.insertAccessory($0, under: [self?.lazyGoalBanner.loaded, self?.lazyRecoveryBanner.loaded, self?.lazyPlanFollowUpBanner.loaded, self?.tasksView]) }
        lazyGoalBanner.onLoad = { [weak self] in self?.insertAccessory($0, under: [self?.lazyRecoveryBanner.loaded, self?.lazyPlanFollowUpBanner.loaded, self?.tasksView]) }
        lazyRecoveryBanner.onLoad = { [weak self] in self?.insertAccessory($0, under: [self?.lazyPlanFollowUpBanner.loaded, self?.tasksView]) }
        lazyPlanFollowUpBanner.onLoad = { [weak self] in self?.insertAccessory($0, under: [self?.tasksView]) }
        lazyServerUpdateBanner.onLoad = { [weak self] in self?.insertAccessory($0, under: [self?.lazyNoticeBanner.loaded, self?.environmentBanner]) }
        lazyNoticeBanner.onLoad = { [weak self] in self?.insertAccessory($0, under: [self?.environmentBanner]) }
        // The panels go where they always sat back to front: question panel, context strip, command menu, stash
        // menu, composer; banners, terminal drawer, right panel; maximize, details card, toasts.
        lazyQuestionPanel.onLoad = { [weak self] in self?.insertAccessory($0, under: [self?.contextStrip]) }
        lazyStashMenu.onLoad = { [weak self] in self?.insertAccessory($0, under: [self?.composer]) }
        lazyTerminalDrawer.onLoad = { [weak self] in self?.insertAccessory($0, under: [self?.rightPanelBackdrop]) }
        lazyDetailsCard.onLoad = { [weak self] card in
            self?.insertAccessory(card, under: [self?.toasts])
            card.layer?.zPosition = 2
        }
        lazyFindBar.onLoad = { [weak self] bar in
            guard let self else { return }
            bar.isHidden = true
            addSubview(bar, positioned: .below, relativeTo: fileDropOverlay)
        }
        registerForDraggedTypes([.fileURL])
        threadFileDrop.onFiles = { [weak self] urls in self?.composer.onFiles?(urls.map { ComposerIncomingFile(url: $0) }) }
        threadFileDrop.onHighlight = { [weak self] highlighted in self?.fileDropOverlay.isHidden = !highlighted }
        ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains("chatWidth") || keys.contains("persistComposerContextStrip") { self?.needsLayout = true }
        }
        header.toggles[0].onPressedChange = { [weak self] _ in
            guard let self else { return }
            header.toggles[0].isPressed = detailsOpen // the controller decides
            onDetailsToggle?()
        }
        header.toggles[2].onPressedChange = { [weak self] _ in
            guard let self else { return }
            header.toggles[2].isPressed = rightPanelOpen // a toggle flips itself; the state decides
            toggleRightPanel()
        }
        header.toggles[1].onPressedChange = { [weak self] _ in
            guard let self else { return }
            header.toggles[1].isPressed = terminalOpen // the controller decides
            onTerminalToggle?()
        }
        rightPanel.onMove = { [weak self] id, index in self?.moveSurface(id, to: index) }
        rightPanel.onRenameDevice = { [weak self] id, title in self?.mutatePanel { $0.renameDevice(id, title: title); return [] } }
        rightPanel.onActivate = { [weak self] id in self?.mutatePanel { $0.activate(id); return [] } }
        rightPanel.onClose = { [weak self] id in self?.closeSurface(id) }
        rightPanel.onCloseOthers = { [weak self] id in self?.mutatePanel { $0.closeOthers(id) } }
        rightPanel.onCloseToRight = { [weak self] id in self?.mutatePanel { $0.closeToRight(id) } }
        rightPanel.onCloseAll = { [weak self] in self?.mutatePanel { $0.closeAll() } }
        rightPanel.onAdd = { [weak self] kind in
            if kind == .pullRequest { self?.onAddPullRequest?(); return }
            if kind == .browser, let add = self?.onAddBrowser { add(); return }
            if kind == .terminal { self?.onAddTerminal?(); return }
            self?.mutatePanel { $0.open(kind); return [] }
        }
        rightPanel.onCopyPath = { path in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        model.onOpenTurnDiff = { [weak self] run, path in
            guard let self else { return }
            explicitDiffOpen = true
            mutatePanel { $0.open(.diff); return [] }
            explicitDiffOpen = false
            diffPanel.open(runId: run, filePath: path)
        }
    }

    /// Adds a lazily built accessory, hidden, under the first of `above` that is already a subview.
    private func insertAccessory(_ view: NSView, under above: [NSView?]) {
        view.isHidden = true
        addSubview(view, positioned: .below, relativeTo: above.lazy.compactMap { $0 }.first { $0.superview === self })
    }

    // MARK: Thread details

    /// Shows or hides the details card in its current presentation (`toggleThreadPanel`, rightPanelStore.ts:980-991).
    public func setDetailsOpen(_ open: Bool) {
        if detailsInline { detailsInlineOpen = open } else { detailsPopoverOpen = open }
        detailsVisibilityChanged()
    }

    /// The inline card's stored visibility, restored at launch.
    public func setDetailsInlineOpen(_ open: Bool) {
        detailsInlineOpen = open
        detailsVisibilityChanged()
    }

    private func detailsVisibilityChanged() {
        let open = detailsOpen
        header.toggles[0].isPressed = open
        if open { detailsCard.isHidden = false } else { lazyDetailsCard.loaded?.isHidden = true }
        syncDetailsPopoverMonitor()
        needsLayout = true
        onPanelTogglesChange?()
    }

    /// Watches for the outside press or Escape that closes the popover, only while it shows.
    private func syncDetailsPopoverMonitor() {
        let watch = detailsPopoverOpen && !detailsInline
        if watch, detailsPopoverMonitor == nil {
            detailsPopoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.dismissDetailsPopover(on: event) }
                return event
            }
        } else if !watch, let monitor = detailsPopoverMonitor {
            NSEvent.removeMonitor(monitor)
            detailsPopoverMonitor = nil
        }
    }

    private func dismissDetailsPopover(on event: NSEvent) {
        guard detailsPopoverOpen, !detailsInline, let window, event.window === window else { return }
        // A menu or popover the card opened takes the press or the key first, as Base UI nests them.
        if let host = window.contentView?.subviews.lazy.compactMap({ $0 as? PopupHost }).first, !host.popups.isEmpty { return }
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return } // Escape
        } else {
            // The toolbar's controls, the details toggle among them, handle their own presses.
            if event.locationInWindow.y > window.contentLayoutRect.maxY { return }
            if let card = lazyDetailsCard.loaded, !card.isHidden, card.bounds.contains(card.convert(event.locationInWindow, from: nil)) { return }
            let toggle = header.toggles[0]
            if toggle.window === window, toggle.bounds.contains(toggle.convert(event.locationInWindow, from: nil)) { return }
        }
        setDetailsOpen(false)
    }

    /// The card's presentation follows the chat column's width (ThreadDetailsCard.tsx:37-46); layout calls this.
    private func updateDetailsPresentation(inline: Bool) {
        guard inline != detailsInline else { return }
        detailsInline = inline
        if inline { detailsPopoverOpen = false }
        header.toggles[0].isPressed = detailsOpen
        if !detailsOpen { lazyDetailsCard.loaded?.isHidden = true }
        syncDetailsPopoverMonitor()
        onPanelTogglesChange?()
    }

    /// T3 closes the popover when the card turns inline (ThreadDetailsCard.tsx:81-85), and on another thread it
    /// starts closed.
    public func closeDetailsPopover() {
        guard detailsPopoverOpen else { return }
        detailsPopoverOpen = false
        detailsVisibilityChanged()
    }

    // MARK: Right panel

    /// The open thread's panel (rightPanelStore.ts `ThreadRightPanelState`).
    public private(set) var panelState = RightPanelState()
    public var rightPanelOpen: Bool { panelState.isOpen }
    /// The user changed the panel: the new state and the tabs that closed (the active one last),
    /// for the store and the reopen stack.
    public var onPanelChange: (@MainActor (RightPanelState, [RightPanelSurface]) -> Void)?
    /// The files surfaces, for the app to fill.
    public var filesPanel: FilesPanelView { rightPanel.files }
    public var fileSurface: FileSurfaceView { rightPanel.file }
    public var lazyFilesPanel: LazyView<FilesPanelView> { rightPanel.lazyFiles }
    public var lazyFileSurface: LazyView<FileSurfaceView> { rightPanel.lazyFile }
    /// The launcher's letters (`B`, `F`, `D`...) while it shows.
    public func launcherKey(_ characters: String) -> Bool { rightPanel.lazyLauncher.loaded?.handleKey(characters) ?? false }
    public var filesAvailable: Bool {
        get { rightPanel.filesAvailable }
        set { rightPanel.filesAvailable = newValue }
    }
    /// Opens the + menu (`rightPanel.new`).
    public func showAddSurfaceMenu(fromShortcut: Bool = false) { rightPanel.showAddMenu(fromShortcut: fromShortcut) }
    /// The pull request surfaces, for the app to fill.
    public var pullRequestView: PullRequestDetailView { rightPanel.pullRequest }
    public var linkedPullRequestsView: ThreadPullRequestsListView { rightPanel.linkedPullRequests }
    public var lazyPullRequestView: LazyView<PullRequestDetailView> { rightPanel.lazyPullRequest }
    public var lazyLinkedPullRequestsView: LazyView<ThreadPullRequestsListView> { rightPanel.lazyLinkedPullRequests }
    /// Whether the + menu and launcher offer "Pull request" and "Linked pull requests"
    /// (`pullRequestSurfaceAvailable`, `pullRequestsSurfaceAvailable`, ChatView.tsx:5453, 7124).
    public var pullRequestAvailable: Bool {
        get { rightPanel.pullRequestAvailable }
        set { rightPanel.pullRequestAvailable = newValue }
    }
    public var pullRequestsAvailable: Bool {
        get { rightPanel.pullRequestsAvailable }
        set { rightPanel.pullRequestsAvailable = newValue }
    }
    /// The state each pull request tab's glyph wears.
    public var pullRequestStatus: [String: PullRequestStateTone] {
        get { rightPanel.pullRequestStatus }
        set { rightPanel.pullRequestStatus = newValue }
    }
    /// "Pull request" from the + menu or launcher: the app opens the thread's current one.
    public var onAddPullRequest: (@MainActor () -> Void)?

    // MARK: Terminal tabs

    /// A terminal tab's view, for the terminal controller to fill.
    public var terminalPanel: TerminalDrawerView { rightPanel.terminal }
    /// Whether the + menu and launcher offer "Terminal" (`terminalAvailable`).
    public var terminalAvailable: Bool {
        get { rightPanel.terminalAvailable }
        set { rightPanel.terminalAvailable = newValue }
    }
    /// Terminal tab titles by surface id.
    public var terminalTitles: [String: String] {
        get { rightPanel.terminalTitles }
        set { rightPanel.terminalTitles = newValue }
    }
    /// "Terminal" from the + menu or launcher (`addTerminalSurface`).
    public var onAddTerminal: (@MainActor () -> Void)?
    /// A terminal tab asks before it closes (`confirmTerminalClose`); `close` finishes it.
    public var confirmCloseTerminalTab: (@MainActor (TerminalPanelSurface, _ close: @escaping @MainActor () -> Void) -> Void)?

    /// Closes one tab, asking first for a terminal tab (`closeRightPanelSurface`).
    private func closeSurface(_ id: String) {
        if let terminal = panelState.surfaces.first(where: { $0.id == id })?.terminal, let confirm = confirmCloseTerminalTab {
            confirm(terminal) { [weak self] in self?.mutatePanel { $0.close(id) } }
            return
        }
        mutatePanel { $0.close(id) }
    }

    // MARK: Browser

    /// The browser surface, for the app to fill.
    private let panelResize = RightPanelResizeView()
    private var preferredPanelWidth: CGFloat = {
        let value = UserDefaults.standard.double(forKey: "t3code:preview-panel-width")
        return value > 0 ? value : RightPanelView.defaultWidth
    }()
    public var devicePanel: DevicePanelView { rightPanel.device }
    public var browserPanel: BrowserPanelView { rightPanel.browser }
    /// Whether the + menu and launcher offer "Browser" (`browserAvailable`).
    public var browserAvailable: Bool {
        get { rightPanel.browserAvailable }
        set { rightPanel.browserAvailable = newValue }
    }
    /// Browser tab titles and favicons by surface id.
    public var browserTitles: [String: String] {
        get { rightPanel.browserTitles }
        set { rightPanel.browserTitles = newValue }
    }
    public var browserFavicons: [String: NSImage] {
        get { rightPanel.browserFavicons }
        set { rightPanel.browserFavicons = newValue }
    }
    /// "Browser" from the + menu or launcher: the app opens a server tab (`createBrowserSurface`).
    public var onAddBrowser: (@MainActor () -> Void)?
    /// The browser profiles by id and name; with more than one the launcher's Browser row offers a chooser.
    public var browserProfiles: [(id: String, name: String)] {
        get { rightPanel.browserProfiles }
        set { rightPanel.browserProfiles = newValue }
    }
    /// A profile from that chooser (`onAddBrowserInProfile`).
    public var onAddBrowserInProfile: (@MainActor (String) -> Void)? {
        didSet { rightPanel.onAddBrowserInProfile = onAddBrowserInProfile.map { f in { f($0) } } }
    }
    /// The floating browser over the chat column; the app shows it and feeds its viewer.
    public let deviceMiniPlayer = BrowserMiniPlayerView()
    public var deviceMiniPlayerOrigin: CGPoint? { didSet { needsLayout = true } }
    public var deviceMiniPlayerSize = CGSize(width: 148, height: 320) { didSet { needsLayout = true } }
    public var deviceMiniPlayerShown = false {
        didSet {
            if deviceMiniPlayerShown, deviceMiniPlayer.superview !== self { addSubview(deviceMiniPlayer) }
            if !deviceMiniPlayerShown { deviceMiniPlayer.removeFromSuperview() }
            needsLayout = true
        }
    }
    public let miniPlayer = BrowserMiniPlayerView()
    /// The page size the player mirrors, and where the user dragged it.
    public var miniPlayerSource: CGSize? { didSet { if miniPlayerSource != oldValue { needsLayout = true } } }
    public var miniPlayerSize: CGSize? { didSet { needsLayout = true } }
    public var miniPlayerOrigin: CGPoint? { didSet { needsLayout = true } }
    public var miniPlayerShown = false {
        didSet {
            if miniPlayerShown, miniPlayer.superview !== self { addSubview(miniPlayer) }
            if !miniPlayerShown { miniPlayer.removeFromSuperview() }
            needsLayout = true
        }
    }

    /// Shows `state` without telling `onPanelChange` (restoring a thread's state). `animated`: a user
    /// action, so an inline panel that opens or closes slides; restored state shows at once
    /// (`usePanelNavigationSuppression`, panelAnimations.ts:11-32).
    public func setPanelState(_ state: RightPanelState, animated: Bool = false) {
        let wasOpen = rightPanel.isHidden == false
        let diffWasShown = wasOpen && panelState.active?.kind == .diff
        let open = state.isOpen
        let slides = animated && open != wasOpen && viewportWidth > 980
        // A closing panel gives back its surfaces at once (`RightPanelView.apply`); a still image of it slides away.
        if slides, !open { panelGhost = ghost(of: rightPanel, replacing: panelGhost) }
        if open { dropGhost(&panelGhost) }
        panelState = state
        updateMaximizeControl()
        rightPanel.isHidden = !open
        rightPanel.apply(state)
        header.toggles[2].isPressed = open
        placePanelToggles()
        // The panel asks for a diff only while it shows. Generic openings show Changes; a timeline click
        // opens its own turn instead (ChatView.tsx:2304-2313).
        if open, state.active?.kind == .diff {
            if !diffWasShown, !explicitDiffOpen { diffPanel.selectGitScope(.branch) }
            diffPanel.setSummaries(summaries)
        }
        needsLayout = true
        header.needsLayout = true
        if open != wasOpen || panelSlide.isRunning {
            panelSlide.run(to: open ? 1 : 0, duration: slides ? SettingsPanelMotion.duration : 0, in: self)
            layoutNow()
        }
    }

    /// The terminal and panel toggles sit on the panel's tab bar while the panel shows, closing slide
    /// included, and in the header otherwise, at the same place: T3 pins them to the window's top right
    /// (`panelLayoutControls`, `fixed`, ChatView.tsx:11203-11211).
    private func placePanelToggles() {
        let inPanel = rightPanelOpen || panelGhost != nil
        guard (header.toggles[2].superview === self) != inPanel else { return }
        // A thread switch hides the header's subviews until its projection arrives; the toggles leaving
        // the header must not stay hidden.
        for toggle in header.toggles.dropFirst() {
            (inPanel ? self : header).addSubview(toggle)
            toggle.isHidden = !inPanel && model.projection == nil
        }
        header.needsLayout = true
    }

    /// How far open the inline right panel and the terminal drawer show, 0 to 1. T3 transitions the panel's
    /// `width` (PreviewPanelShell.tsx:118-127) and the drawer's `grid-template-rows` (ChatView.tsx:1321-1326)
    /// with `ease-out` over `panelAnimationDurationMs`; the chat column is `flex-1` beside and above them
    /// (ChatView.tsx:11273-11277), so it reflows every frame. The panel's content keeps its width and rides
    /// the moving left edge (a `calc(width - 1px)` box in an `overflow-clip` host, PreviewPanelShell.tsx:135-139);
    /// the drawer's keeps its height under its moving top edge (`min-h-0 overflow-clip`, ChatView.tsx:1328).
    let panelSlide = PanelSlide(value: 0)
    let terminalSlide = PanelSlide(value: 0)
    /// A still image of the closing panel or drawer, which gives back its content at once.
    private var panelGhost: CALayer?
    private var terminalGhost: CALayer?

    private func ghost(of view: NSView, replacing old: CALayer?) -> CALayer? {
        if let old { return old } // closing again mid-close keeps the image it has
        guard !view.isHidden, view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let ghost = CALayer()
        ghost.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        ghost.contents = bitmap.cgImage
        ghost.contentsScale = window?.backingScaleFactor ?? 2
        ghost.frame = view.frame
        // Under every subview: the toggles stay on top, and nothing else covers the room the panel leaves.
        ghost.zPosition = -1
        layer?.addSublayer(ghost)
        return ghost
    }

    private func dropGhost(_ ghost: inout CALayer?) {
        ghost?.removeFromSuperlayer()
        ghost = nil
    }

    private func layoutNow() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func slideEnded() {
        if !panelSlide.isRunning { dropGhost(&panelGhost) }
        if !terminalSlide.isRunning { dropGhost(&terminalGhost) }
        placePanelToggles()
        layoutNow()
        HoverSync.setNeedsSync(window)
    }

    /// A panel leaving its window mid-slide lands where it was going; the display links stop with it.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        for slide in [panelSlide, terminalSlide] where slide.isRunning { slide.jump(to: slide.target) }
    }

    /// A user action on the panel: applies it and reports the new state.
    public func mutatePanel(_ change: (inout RightPanelState) -> [RightPanelSurface]) {
        var next = panelState
        let closed = change(&next)
        guard next != panelState || !closed.isEmpty else { return }
        panelActionRevision += 1
        let duration = SettingsPanelMotion.duration
        let animateSheet = viewportWidth <= 980 && !rightPanelMaximized && next.isOpen != panelState.isOpen && duration > 0
        if animateSheet, !next.isOpen { animateClosingSheet(duration: duration) }
        setPanelState(next, animated: !animateSheet)
        if animateSheet, next.isOpen {
            layoutSubtreeIfNeeded()
            animateSheetLayer(rightPanel.layer, opening: true, duration: duration)
            animateSheetLayer(rightPanelBackdrop.layer, opening: true, duration: duration, translate: false)
        }
        onPanelChange?(next, closed)
    }

    /// RightPanelSheet.tsx and sheet.tsx: a 32px translation plus opacity. Restored routes do not animate.
    private func animateSheetLayer(_ target: CALayer?, opening: Bool, duration: Double, translate: Bool = true) {
        guard let target else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = opening ? 0 : 1; opacity.toValue = opening ? 1 : 0
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = opening ? 32 : 0; move.toValue = opening ? 0 : 32
        let group = CAAnimationGroup(); group.animations = translate ? [opacity, move] : [opacity]
        group.duration = duration; group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.fillMode = .forwards; group.isRemovedOnCompletion = opening
        target.add(group, forKey: "right-panel-sheet")
    }
    private func animateClosingSheet(duration: Double) {
        // Keep only a still frame during exit so hidden device and browser transports stop immediately.
        guard rightPanel.bounds.width > 0, let bitmap = rightPanel.bitmapImageRepForCachingDisplay(in: rightPanel.bounds) else { return }
        rightPanel.cacheDisplay(in: rightPanel.bounds, to: bitmap)
        let ghost = CALayer(); ghost.contents = bitmap.cgImage; ghost.frame = rightPanel.frame; ghost.zPosition = 21
        let backdrop = CALayer(); backdrop.frame = bounds; backdrop.zPosition = 20
        backdrop.backgroundColor = Themed.color(\.background, 0.6).cgColor(in: self)
        layer?.addSublayer(backdrop); layer?.addSublayer(ghost)
        animateSheetLayer(ghost, opening: false, duration: duration)
        animateSheetLayer(backdrop, opening: false, duration: duration, translate: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { ghost.removeFromSuperlayer(); backdrop.removeFromSuperlayer() }
    }

    /// Opens or closes the panel without telling `onPanelChange`.
    public func setRightPanelOpen(_ open: Bool) {
        var next = panelState
        next.isOpen = open
        setPanelState(next)
    }

    /// Shows or hides the terminal drawer at `height`. Opening or closing slides, except on a thread switch,
    /// which shows the new thread's drawer at once (`usePanelNavigationSuppression`).
    public func setTerminal(open: Bool, height: CGFloat) {
        guard open != terminalOpen || height != terminalHeight else { return }
        let wasOpen = terminalOpen
        let slides = open != wasOpen && !switchingThread
        // The controller empties a closed drawer right after this; a still image of it slides down.
        if slides, !open, let drawer = lazyTerminalDrawer.loaded { terminalGhost = ghost(of: drawer, replacing: terminalGhost) }
        if open { dropGhost(&terminalGhost) }
        terminalOpen = open
        terminalHeight = height
        if open { terminalDrawer.isHidden = false } else { lazyTerminalDrawer.loaded?.isHidden = true }
        header.toggles[1].isPressed = open
        needsLayout = true
        onPanelTogglesChange?()
        if open != wasOpen || terminalSlide.isRunning {
            terminalSlide.run(to: open ? 1 : 0, duration: slides ? SettingsPanelMotion.duration : 0, in: self)
            layoutNow()
        }
    }

    /// Cmd+D (`diff.toggle`, `toggle(ref, "diff")`): the panel on the diff, or closed.
    public func toggleDiff() {
        guard model.projection != nil else { return }
        mutatePanel { $0.toggle(.diff); return [] }
    }

    /// `rightPanel.toggle` (`toggleRightPanel`, ChatView.tsx:6047-6054): hides an open panel, else
    /// shows what it had, or the launcher.
    public func toggleRightPanel() {
        guard model.projection != nil else { return }
        mutatePanel { s in
            if s.isOpen { s.isOpen = false } else { s.toggleVisibility() }
            return []
        }
    }

    /// `rightPanel.close` (ChatView.tsx:8093-8100): closes the active tab. False with nothing open.
    @discardableResult
    public func closeRightPanel() -> Bool {
        guard panelState.isOpen, let id = panelState.activeSurfaceId else { return false }
        closeSurface(id)
        return true
    }

    /// `toggleRightPanelMaximized` (ChatView.tsx:6059-6064): the control, and `rightPanel.toggleMaximized`.
    public func toggleMaximized() {
        guard canMaximizeRightPanel else { return }
        // `setMaximized` is layout only: no user-action revision, so proactive panels still apply
        // (rightPanelStore.ts:976-984 in 2994).
        var next = panelState
        next.maximized = rightPanelMaximized ? nil : true
        panelState = next
        updateMaximizeControl()
        onPanelChange?(next, [])
    }

    /// A tab dragged to `index` (`moveSurface`, rightPanelStore.ts:901-912 in 2994): not a choice about what
    /// the panel shows, so it leaves the user-action revision alone too.
    func moveSurface(_ id: String, to index: Int) {
        var next = panelState
        next.move(id, to: index)
        guard next != panelState else { return }
        setPanelState(next)
        onPanelChange?(next, [])
    }

    private func updateMaximizeControl() {
        let on = panelState.maximized == true
        maximize.isPressed = on
        maximize.icon = on ? .minimize2 : .maximize2
        let label = on ? "Restore panel size" : "Maximize panel"
        maximize.setAccessibilityLabel(label)
        maximize.toolTip = label
        needsLayout = true
        onPanelTogglesChange?()
    }

    /// A press that nothing under it takes (empty timeline, header or page space) blurs the prompt, as a
    /// click on a non-focusable element does in the browser. `editableFocus` then clears, so Mod+Z reaches
    /// `thread.undo` (keybindings.ts:191) instead of the editor.
    public override func mouseDown(with event: NSEvent) {
        if let focused = window?.firstResponder as? NSView, focused.isDescendant(of: composer) { window?.makeFirstResponder(nil) }
        super.mouseDown(with: event)
    }

    /// The window's width, or the outermost view's without a window (tests).
    /// Full reference viewport when this panel is rendered alone in the component gallery.
    var referenceViewportWidth: CGFloat?
    private var viewportWidth: CGFloat {
        if let referenceViewportWidth { return referenceViewportWidth }
        if let window { return window.frame.width }
        var view: NSView = self
        while let parent = view.superview { view = parent }
        return view.bounds.width
    }

    /// The new-thread page: header "{project} / New thread", the hero and the centered composer.
    /// Pass nil to leave it.
    public func setDraft(projectTitle: String?, isScratch: Bool = false) {
        isDraft = projectTitle != nil
        hero.isHidden = !isDraft
        hero.projectTitle = projectTitle ?? ""
        hero.isScratch = isScratch
        if let projectTitle {
            setProjection(nil, projectTitle: projectTitle, workspaceRoot: nil)
            header.projectIcon = projectIconForTitle?(projectTitle)
            header.threadTitle = "New thread"
            header.setThreadVisible(true)
            header.cancelTitleRename()
        }
        updateComposerShown()
    }

    /// The header icon for a draft, which only names its project by title.
    // ponytail: by title, so two projects with one title can show the wrong icon on a draft; pass the project to setDraft when ComposerController changes next
    public var projectIconForTitle: ((String) -> ProjectIconSource?)?

    /// Another thread is opening and its first projection has not arrived (see `beginThreadSwitch`).
    public private(set) var switchingThread = false

    /// Starts showing another thread before its first projection, so no frame shows an empty panel.
    /// T3 keeps one ChatView across thread routes (ThreadRouteView.tsx:27-35): the header names the
    /// new thread from its shell at once, the composer stays, and the timeline paints the last
    /// thread's rows while the new one loads with no rows of its own (`resolveThreadSwitchTimeline`,
    /// ChatView.logic.ts:411-438, ChatView.tsx:3964-3974), only within one environment
    /// (`threadKeysShareEnvironment`). The next `setProjection` swaps everything in one pass.
    /// Without `keepRows` the timeline empties: T3's loading state (header and composer, no
    /// placeholder, ChatView.tsx:11474).
    public func beginThreadSwitch(projectTitle: String, threadTitle: String, keepRows: Bool) {
        if isDraft { setDraft(projectTitle: nil) }
        if !keepRows { setProjection(nil, projectTitle: projectTitle, workspaceRoot: nil) }
        switchingThread = true
        timeline.isInert = true
        header.projectTitle = projectTitle
        header.threadTitle = threadTitle
        header.setThreadVisible(true)
        header.cancelTitleRename()
        updateComposerShown()
    }

    /// Shows a thread. Pass nil to clear.
    /// `onlyStreamingText`: the update only grew a streaming answer's or reasoning text. Nothing the
    /// panel lays out, the diff summaries or the proactive panels read changed, so only the
    /// timeline updates.
    public func setProjection(_ projection: ThreadProjection?, projectTitle: String, workspaceRoot: String?, onlyStreamingText: Bool = false) {
        if onlyStreamingText, let projection, projection.thread.id == model.projection?.thread.id, !switchingThread, !isDraft,
           !timeline.isInert, projectTitle == model.projectTitle, workspaceRoot == model.workspaceRoot {
            model.setProjection(projection)
            return
        }
        switchingThread = false
        timeline.isInert = false
        applyingProjection = true
        defer { applyingProjection = false; evaluateProactivePanels() }
        model.projectTitle = projectTitle
        model.workspaceRoot = workspaceRoot
        header.projectTitle = projectTitle
        header.threadTitle = projection?.thread.title ?? ""
        // With no thread the bar stays, empty, so it still drags the window.
        header.setThreadVisible(projection != nil)
        if projection?.thread.id != model.projection?.thread.id {
            proactivePanels = SettingsProactivePanels()
            proactiveLinkedPullRequestKey = nil
            proactiveRepositoryIsGit = nil
            timeline.context.forgetDocuments()
            header.cancelTitleRename()
        }
        lazyDiffPanel.set(\.workspaceRoot, workspaceRoot)
        lazyDiffPanel.set(\.threadId, projection?.thread.id)
        summaries = projection.map(TurnDiffs.summaries) ?? []
        if opensChangedTurnOnLoad, let changed = TurnDiffs.sortedForPanel(summaries).first(where: { !$0.files.isEmpty }) {
            opensChangedTurnOnLoad = false
            var next = panelState
            next.open(.diff)
            explicitDiffOpen = true
            setPanelState(next)
            explicitDiffOpen = false
            diffPanel.open(runId: changed.runId, filePath: nil)
        }
        if rightPanelOpen, panelState.active?.kind == .diff { diffPanel.setSummaries(summaries) }
        model.setProjection(projection)
        evaluateProactivePanels()
        if projection != nil, isDraft { setDraft(projectTitle: nil) }
        updateComposerShown()
    }

    /// The composer shows with a thread, a draft, or a just-sent first message. Call after
    /// changing `model.optimisticMessages`.
    public func updateComposerShown() {
        composerShown = isDraft || switchingThread || model.projection != nil || !model.optimisticMessages.isEmpty
        // `hideEmptyPlaceholder={isDraftHeroState || threadDetailLoading}` (ChatView.tsx:11474).
        timeline.allowsEmptyPlaceholder = !isDraft && !switchingThread && model.projection != nil
        needsLayout = true
    }

    /// The composer lane (J-composer-visuals 1.1 to 1.4): 48px side padding (12 below a 640
    /// viewport), at most 736 wide, 20px above the bottom; the timeline keeps the overlay's height
    /// (`pt-2` + composer + spacer) clear. On the draft page the composer, a 32px context strip and
    /// the spacer are centered in the column below the header, with the hero 16px above.
    private func layoutComposer(chat: CGFloat, height chatHeight: CGFloat) {
        let lane: CGFloat = viewportWidth < 640 ? 12 : 48
        let placement = ThreadDetailsPlacement.lane(width: chat, maximum: ThreadChatWidth.maximum(ClientSettingsStore.shared.current.string("chatWidth")), padding: lane, cardLeft: timeline.detailsCardLeft)
        let width = placement.width
        let height = composer.preferredHeight
        let x = placement.x.rounded()
        let y: CGFloat
        if isDraft {
            // ponytail: the strip holds only "Run on"; the checkout and branch pickers come with the branch toolbar
            // A draft without the strip (a scratch project has no checkout) centers without its 32px.
            let block = height + (showsContextStrip ? 32 : 0) + 20
            let top = chatTop + (chatHeight - chatTop - block) / 2
            y = top.rounded()
            // The banner stack sits between the hero and the composer: the front notice and the peek.
            let stack = composerShown && chat > 0 ? ComposerBannerStackItem.ordered(bannerStackItems(docked: false, composerVisible: true)) : []
            let notice = (stack.first.map { $0.height(width) - ComposerBannerView.overlap } ?? 0)
                + (stack.count > 1 ? ComposerBannerStackView.peekHeight : 0)
            hero.frame = NSRect(x: x, y: y - 16 - notice - DraftHeroView.height, width: width, height: DraftHeroView.height)
        } else {
            y = chatHeight - 20 - height
        }
        composer.frame = NSRect(x: x, y: y, width: width, height: height)
        composer.isHidden = !composerShown || chat == 0
        let strip = (isDraft || ClientSettingsStore.shared.current.bool("persistComposerContextStrip")) && showsContextStrip && !composer.isHidden
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
        lazyStashMenu.loaded?.isHidden = !stashShown
        if stashShown {
            stashMenu.isHidden = false
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
        lazyQuestionPanel.loaded?.isHidden = shown !== lazyQuestionPanel.loaded
        if let shown {
            // `max-h-[min(24rem,40dvh)]` for the question body.
            lazyQuestionPanel.loaded?.maxBodyHeight = min(384, (window?.contentView?.bounds.height ?? bounds.height) * 0.4)
            let h = shown === approvalPanel ? approvalPanel.preferredHeight(width: bannerWidth) : questionPanel.preferredHeight(width: bannerWidth)
            shown.frame = NSRect(x: bannerX, y: top + overlap - h, width: bannerWidth, height: h)
            top = shown.frame.minY
        }
        tasksView.isHidden = !docked || tasksView.steps.isEmpty
        if !tasksView.isHidden {
            tasksView.frame = NSRect(x: bannerX, y: top + overlap - tasksView.height, width: bannerWidth, height: tasksView.height)
            top = tasksView.frame.minY
        }
        let planShown = docked && showsPlanFollowUp
        if planShown { planFollowUpBanner.isHidden = false } else { lazyPlanFollowUpBanner.loaded?.isHidden = true }
        if planShown {
            let h = ComposerNoticeBannerView.height
            planFollowUpBanner.frame = NSRect(x: bannerX, y: top + overlap - h, width: bannerWidth, height: h)
            top = planFollowUpBanner.frame.minY
        }
        // The banner stack (ChatComposer.tsx:6713-6735): with banner items, the sync row is the stack's
        // activity item and stays attached; without, it is its own strip under the stack.
        var items = bannerStackItems(docked: docked, composerVisible: !composer.isHidden)
        let activityShown = docked && showsActivity
        let activityInStack = activityShown && !items.isEmpty
        if activityInStack {
            items.insert(ComposerBannerStackItem(id: "composer-activity", view: activityRow, priority: .activity,
                                                 height: { [activityRow] _ in activityRow.preferredHeight }), at: 0)
        }
        activityRow.isHidden = !activityShown
        activityRow.joinsAbove = false
        if activityShown && !activityInStack {
            let h = activityRow.preferredHeight
            activityRow.frame = NSRect(x: bannerX, y: top + overlap - h, width: bannerWidth, height: h)
            top = activityRow.frame.minY
        }
        let ordered = ComposerBannerStackItem.ordered(items)
        let candidates: [ComposerBannerView?] = [environmentBanner, lazyNoticeBanner.loaded, lazyServerUpdateBanner.loaded,
                                                 lazyGoalBanner.loaded, lazyRecoveryBanner.loaded, lazyBranchBanner.loaded, usageLimitsBanner]
        for case let view? in candidates where !ordered.contains(where: { $0.view === view }) { view.isHidden = true }
        bannerStack.update(ordered)
        let front = ordered.first
        if let front {
            let view = front.view
            // Back to front: queue, the front item, then the strips and drawers below it.
            if view.superview !== self || subviews.firstIndex(of: view) != subviews.firstIndex(of: queue).map({ $0 + 1 }) {
                addSubview(view, positioned: .above, relativeTo: queue)
            }
            view.placement = .attached
            view.isHidden = false
            let h = front.height(bannerWidth)
            view.frame = NSRect(x: bannerX, y: top + overlap - h, width: bannerWidth, height: h)
            top = view.frame.minY
        }
        let queueHeight = docked ? queue.preferredHeight : 0
        queue.isHidden = queueHeight == 0
        queue.frame = NSRect(x: bannerX, y: top + overlap - queueHeight, width: bannerWidth, height: queueHeight)
        if queueHeight > 0 { top = queue.frame.minY }
        // The other notices peek above the whole column, never from between two attachments.
        if bannerStack.hasStack {
            let h = bannerStack.height(width: bannerWidth)
            bannerStack.frame = NSRect(x: bannerX, y: top - h, width: bannerWidth, height: h)
        }
        // Adjacent attachments share their outline (ComposerBanner.tsx `Attachment`).
        front?.view.joinsAbove = queueHeight > 0
        let attachedAbove = queueHeight > 0 || front != nil
        if activityShown && !activityInStack { activityRow.joinsAbove = attachedAbove }
        let stripAbove = attachedAbove || (activityShown && !activityInStack)
        approvalPanel.joinsAbove = stripAbove
        lazyQuestionPanel.loaded?.joinsAbove = stripAbove
        // ponytail: the timeline keeps room for the collapsed stack only; an open stack overlays it, reserve it if T3's inset jump matters
        let stackCap = bannerStack.hasStack ? ComposerBannerStackView.peekHeight : 0
        let above = max(y - top + stackCap, badgeShown ? stashBadge.preferredHeight - overlap : 0)
        let inset = docked ? 8 + above + height + 20 : 0
        if timeline.bottomInset != inset { timeline.bottomInset = inset }
        if isDraft { timeline.isHidden = true }
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard ComposerFileDrop.hasFiles(sender), composer.onFiles != nil else { return [] }
        return threadFileDrop.entered(sender)
    }
    public override func draggingExited(_ sender: (any NSDraggingInfo)?) { threadFileDrop.exited() }
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { threadFileDrop.perform(sender) }

    /// No fill of its own: the main panel's grain surface (`bg-background surface-grain`) shows
    /// through. Only the top fade uses the background color.
    public override func updateLayer() {
        let bg = TL.c(\.background).cgColor(in: self)
        fade.colors = [1, 0.9, 0.7, 0.42, 0.18, 0.04, 0].map { bg.copy(alpha: $0)! }
        // A colored overlay over the Glass theme's translucent surface reads as a band, so Glass drops the fade.
        // ponytail: hard scroll edge under the header in Glass; a gradient mask on the timeline would match T3
        // but renders offscreen on every scroll frame, add it if the edge is missed
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let sheet = viewportWidth <= 980 && !rightPanelMaximized
        let panelWidth = !rightPanelOpen ? 0 : rightPanelMaximized ? bounds.width
            : sheet ? RightPanelSheetBackdropView.width(viewport: viewportWidth, container: bounds.width)
            : RightPanelView.width(viewport: viewportWidth, container: bounds.width, preferred: preferredPanelWidth)
        // Mid-slide the panel shows the open share of its width, on whole device pixels so the chat stays sharp.
        let scale = window?.backingScaleFactor ?? 2
        let shownPanel = sheet || !panelSlide.isRunning ? panelWidth
            : ((rightPanelOpen ? panelWidth : panelGhost?.bounds.width ?? 0) * panelSlide.value * scale).rounded() / scale
        let chat = sheet ? bounds.width : max(0, bounds.width - shownPanel)
        rightPanelBackdrop.isHidden = !sheet || !rightPanelOpen
        rightPanelBackdrop.frame = bounds
        // Glass Native: the right panel starts below the toolbar, its tabs clear of it.
        // Glass Native: the panel runs up under the toolbar, so its tabs share the toolbar's row as T3's share the
        // header row with the panel toggles; the toggles' room at the right stays clear.
        let panelTop: CGFloat = 0
        rightPanel.trailingReserve = hidesCustomChrome ? RightPanelView.nativeToolbarReserve : RightPanelView.classicReserve
        rightPanelBackdrop.layer?.zPosition = sheet ? 20 : 0
        rightPanel.layer?.zPosition = sheet ? 21 : 0
        rightPanel.isSheet = sheet
        header.isHidden = chat == 0 || hidesCustomChrome
        timeline.isHidden = chat == 0
        header.frame = NSRect(x: 0, y: 0, width: chat, height: ThreadHeaderView.height)
        fileDropOverlay.frame = NSRect(x: 8, y: chatTop + 8, width: max(0, chat - 16), height: max(0, bounds.height - chatTop - 16))
        // The drawer sits under the chat column, left of the right panel (ChatView.tsx:11905-11921);
        // the column above it keeps at least the header.
        let drawer = terminalOpen && chat > 0 ? max(0, min(terminalHeight, bounds.height - chatTop)) : 0
        let shownDrawer = !terminalSlide.isRunning ? drawer
            : ((terminalOpen ? drawer : terminalGhost?.bounds.height ?? 0) * terminalSlide.value * scale).rounded() / scale
        let chatHeight = bounds.height - shownDrawer
        if let terminalDrawer = drawer > 0 ? self.terminalDrawer : lazyTerminalDrawer.loaded {
            terminalDrawer.isHidden = drawer == 0
            // Mid-slide the drawer keeps its height and hangs below the window's edge, so its terminal keeps its grid.
            terminalDrawer.frame = NSRect(x: 0, y: chatHeight, width: chat, height: drawer)
        }
        terminalGhost?.frame.origin.y = chatHeight
        // Glass Native: the rows scroll under the toolbar and start below it.
        let timelineTop = hidesCustomChrome ? 0 : chatTop
        timeline.chromeTop = hidesCustomChrome ? toolbarInset : 0
        timeline.frame = NSRect(x: 0, y: timelineTop, width: chat, height: max(0, chatHeight - timelineTop))
        // The timeline's scroll view fills the timeline.
        scrollFade?.update(toolbar: toolbarInset - timeline.frame.minY, size: timeline.frame.size)
        // Mid-slide the panel keeps its width and runs past the window's right edge.
        rightPanel.frame = NSRect(x: sheet ? bounds.width - panelWidth : chat, y: panelTop, width: panelWidth, height: max(0, bounds.height - panelTop))
        panelGhost?.frame.origin.x = chat
        if rightPanelSheetOpen != sheetWasOpen {
            sheetWasOpen = rightPanelSheetOpen
            if sheetWasOpen {
                sheetPreviousResponder = window?.firstResponder
                rightPanel.layoutSubtreeIfNeeded()
                window?.makeFirstResponder(rightPanelSheetFocusTargets().first ?? rightPanel)
            } else {
                if let previous = sheetPreviousResponder { window?.makeFirstResponder(previous) }
                sheetPreviousResponder = nil
            }
        }
        if panelResize.superview == nil {
            addSubview(panelResize)
            panelResize.onDrag = { [weak self] delta in
                guard let self else { return }
                self.preferredPanelWidth = RightPanelView.width(viewport: self.viewportWidth, container: self.bounds.width, preferred: self.rightPanel.frame.width + delta)
                UserDefaults.standard.set(Double(self.preferredPanelWidth), forKey: "t3code:preview-panel-width")
                self.needsLayout = true
            }
        }
        panelResize.isHidden = !rightPanelOpen || rightPanelMaximized || sheet
        // The sheet has no maximize control (ChatView.tsx:11211-11232). It fades with the slide, `transition-opacity`
        // over the same duration and curve (ChatView.tsx:11213-11224).
        // Glass Native's toolbar holds the panel toggles and Maximize, so the in-panel copies stay hidden.
        maximize.isHidden = sheet || (!rightPanelOpen && panelGhost == nil) || hidesCustomChrome
        let maximizable = !sheet && rightPanelOpen
        if maximizable != reportedMaximizable {
            reportedMaximizable = maximizable
            onMaximizableChange?(maximizable)
        }
        if hidesCustomChrome { for toggle in header.toggles where toggle.superview === self { toggle.isHidden = true } }
        else { header.toggles.forEach { $0.isHidden = false } }
        maximize.alphaValue = panelSlide.isRunning ? panelSlide.value : 1
        panelResize.frame = NSRect(x: chat - 4, y: panelTop, width: 8, height: max(0, bounds.height - panelTop))
        if rightPanelOpen || panelGhost != nil {
            // The window's panel controls: `mr-px` and 12px from the right, `gap-1`.
            var x = bounds.width - 12 - 1
            for control in [header.toggles[2], header.toggles[1], maximize] {
                let size = control.intrinsicContentSize
                x -= size.width
                control.frame = NSRect(x: x, y: ThreadHeaderView.height / 2 - size.height / 2, width: size.width, height: size.height)
                x -= 4
            }
        }
        let inlinePlacement = ThreadDetailsPlacement.inlineCard(width: chat, height: chatHeight - chatTop, topInset: findInset)
        updateDetailsPresentation(inline: inlinePlacement != nil)
        let inlineDetails = detailsOpen ? inlinePlacement : nil
        timeline.detailsCardLeft = inlineDetails?.minX
        layoutComposer(chat: chat, height: chatHeight)
        if let findBar = lazyFindBar.loaded {
            // `top-3 right-3 w-[min(var(--thread-details-panel-width),calc(100%-1.5rem))]`: as wide as the
            // details card and lined up with it (ThreadFindBar.tsx:62-66 in 2994, f92afe79c).
            let w = max(0, min(280, chat - 24))
            findBar.frame = NSRect(x: chat - 12 - w, y: chatTop + 12, width: w, height: 36)
            findBar.layer?.zPosition = 4
        }
        if detailsOpen {
            let detailsCard = self.detailsCard
            // The card folds to the height it has: inline, the placement's height; as a popover, the
            // canvas minus 52 (ThreadDetailsCard.tsx:62-63).
            let canvasHeight = max(0, chatHeight - chatTop)
            detailsCard.density = detailsCard.density(fitting: inlineDetails?.height ?? max(0, canvasHeight - 52))
            if let inlineDetails {
                detailsCard.frame = NSRect(x: inlineDetails.minX, y: chatTop + inlineDetails.minY,
                    width: inlineDetails.width, height: min(detailsCard.preferredHeight, inlineDetails.height))
                detailsCard.isHidden = false
            } else {
                // The popover sits 12px in from the right like the find bar, and under it while find is
                // open (ThreadDetailsCard.tsx:185-193 and popover.tsx:75-83 in 2994, f92afe79c).
                let w = min(280, chat - 24), top = chatTop + 8 + findInset
                detailsCard.frame = NSRect(x: chat - 12 - w, y: top,
                    width: w, height: min(detailsCard.preferredHeight, max(0, chatHeight - top - 8)))
                detailsCard.isHidden = w <= 0
            }
            if let from = detailsSlideFrom, !detailsCard.isHidden, from != detailsCard.frame.minY {
                Self.slide(detailsCard, by: from - detailsCard.frame.minY)
            }
        }
        detailsSlideFrom = nil
        // The floating browser keeps to the chat canvas, top right by default (previewMiniPlayerLayout.ts).
        // ponytail: no composer or details-card obstacles and no resize handles; add them from
        // previewMiniPlayerLayout.ts when the player is used beside long threads
        if deviceMiniPlayerShown {
            deviceMiniPlayer.frame = BrowserMiniPlayerView.frame(size: deviceMiniPlayerSize, origin: deviceMiniPlayerOrigin,
                container: NSRect(x: 0, y: chatTop, width: chat, height: max(0, chatHeight - chatTop)))
            deviceMiniPlayer.layer?.zPosition = 2
        }
        if miniPlayerShown {
            let canvas = NSRect(x: 0, y: chatTop, width: chat, height: max(0, chatHeight - chatTop))
            let size = miniPlayerSize ?? BrowserMiniPlayerView.size(source: miniPlayerSource)
            miniPlayer.frame = BrowserMiniPlayerView.frame(size: size, origin: miniPlayerOrigin, container: canvas)
            miniPlayer.isHidden = chat < size.width + 24
            miniPlayer.layer?.zPosition = 2
        }
        // `mx-auto w-fit max-w-[min(48rem,calc(100%-2rem))] pt-3` in the chat column.
        // Each banner has its own `pt-3` in a `flex-col`.
        var bannerTop = chatTop + 12
        for banner in [providerBanner, errorBanner] where !banner.isHidden {
            let w = banner.fittingWidth(max: max(0, min(768, chat - 32)))
            let h = banner.height(forWidth: w)
            banner.frame = NSRect(x: ((chat - w) / 2).rounded(), y: bannerTop, width: w, height: h)
            bannerTop = banner.frame.maxY + 12
        }
        if let content = window?.contentView {
            toasts.frame = convert(ToastViewport.frame(in: content.bounds), from: content)
        } else {
            toasts.frame = ToastViewport.frame(in: bounds)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The last 6px column (the scrollbar) stays unmasked. No fade under a top banner (`topFadeEnabled`).
        fade.frame = CGRect(x: 0, y: chatTop, width: max(0, chat - 6), height: 25)
        fade.zPosition = 1
        fade.isHidden = !errorBanner.isHidden || !providerBanner.isHidden || WindowGlass.isActive(for: self)
        errorBanner.layer?.zPosition = 2
        providerBanner.layer?.zPosition = 2
        toasts.layer?.zPosition = 3
        CATransaction.commit()
    }
}
