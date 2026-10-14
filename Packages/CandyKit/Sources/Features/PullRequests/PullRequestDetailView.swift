import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The pull request surface (PullRequestDetailPanel.tsx with PullRequestDetailLayout.tsx): the
/// header (repository, `#n` in the state's tone, the actions), the title, author and update time,
/// `base ← head` with the file count and diff counts, then the Summary, Timeline and Code tabs.
/// The controller feeds `detail`, the activity state, the patch and the viewed marks, and runs the
/// callbacks; nothing here talks to a server.
public final class PullRequestDetailView: DSView {
    public enum Tab: Int, Sendable { case summary, timeline, code }
    public enum Phase: Equatable, Sendable {
        /// Nothing read yet: the ghost, seeded from the list row when there is one.
        case loading(number: Int)
        case failed(title: String, message: String)
        case loaded
    }
    /// Where the panel sits: beside its thread, or on the Pull Requests page (which adds Check out).
    public enum Context: Sendable { case thread, page }

    public var context: Context = .thread { didSet { rebuild() } }
    public private(set) var phase: Phase = .loading(number: 0)
    private var failureRetry = true
    public private(set) var detail: PullRequestDetail?
    public var activityPending = true { didSet { if activityPending != oldValue { rebuildTabs() } } }
    public var activityError: String? { didSet { if activityError != oldValue { rebuildTabs() } } }
    public var tab: Tab = .summary {
        didSet {
            guard tab != oldValue else { return }
            tabs.selectedIndex = tab.rawValue
            // Each tab remembers its own scroll chrome; a short tab cannot scroll to reopen it.
            condensed = condensedByTab[tab] ?? false
            showTab()
        }
    }
    public var refreshing = false { didSet { more.icon = refreshing ? .refreshCw : .ellipsis } }
    public var actionPending = false { didSet { composer?.actionPending = actionPending; rebuildActions() } }
    public var nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) { didSet { rebuild() } }
    /// The merge method the reader last picked (`pullRequestMergeMethod` in the UI state store).
    public var preferredMergeMethod = "merge" { didSet { rebuildActions() } }
    /// This pull request's own pick (`mergeMethodSelection`), cleared when another one shows.
    public var currentMergeMethod: String? { didSet { rebuildActions() } }
    /// The project's `pullRequestMergeMethod` setting (Settings > Source Control > Default merge method).
    public var projectDefaultMergeMethod: String? { didSet { rebuildActions() } }

    // Callbacks.
    public var onTab: ((Tab) -> Void)?
    public var onOpenURL: ((String) -> Void)?
    public var onCopy: ((_ text: String, _ label: String) -> Void)?
    public var onRefresh: (() -> Void)?
    public var onRetry: (() -> Void)?
    /// `perform(action, mergeMethod)` after its confirmation where T3 asks for one.
    public var onAction: ((_ action: String, _ mergeMethod: String?) -> Void)?
    public var onLinkThread: (() -> Void)?
    /// The ⋯ menu's thread link item, nil where there is no thread to link to.
    public var linkItemTitle: String?
    public var onCheckout: ((_ worktree: Bool) -> Void)?
    public var onMergeMethod: ((String) -> Void)?
    public var onComment: ((String) -> Void)?
    /// "Close with comment" or "Reopen with comment": post, then run the action.
    public var onCommentAction: ((_ body: String, _ action: String) -> Void)?
    public var onReview: ((_ verdict: String, _ body: String, _ comments: [PullRequestReviewCommentDraft]) -> Void)?
    /// The review store's key for this pull request (`pullRequestReviewKey`); set with the detail.
    public var reviewKey: String?
    /// The composer for the pull request on screen; it outlives its popover so drafts survive.
    public private(set) var composer: PullRequestComposerView?
    private var composerPopup: OpenPopup?
    private let pendingBadge = LabelView("", font: DSFont.ui(10, weight: .semibold))
    /// The Summary's reviewer and label triggers (the caller opens the picker under the anchor).
    public var onPickReviewers: ((NSView) -> Void)? { get { summary.onPickReviewers } set { summary.onPickReviewers = newValue } }
    public var onPickLabels: ((NSView) -> Void)? { get { summary.onPickLabels } set { summary.onPickLabels = newValue } }
    /// The description's Save, then `finishBodyEdit` once the host took it.
    public var onSaveBody: ((String) -> Void)? { get { summary.onSaveBody } set { summary.onSaveBody = newValue } }
    public var bodySaving: Bool { get { summary.bodySaving } set { summary.bodySaving = newValue } }
    public func finishBodyEdit() { summary.finishBodyEdit() }
    /// A comment's Save (`pullRequests.updateComment`), then `finishCommentEdit`.
    public var onSaveComment: ((PullRequestComment, String) -> Void)? { get { summary.onSaveComment } set { summary.onSaveComment = newValue } }
    public var commentSaving: Bool { get { summary.commentSaving } set { summary.commentSaving = newValue } }
    public func finishCommentEdit() { summary.finishCommentEdit() }
    /// A reaction pressed: (subject id, content, reacted, the bar to tell of a refusal).
    public var onReact: ((String?, String, Bool, PullRequestReactionBarView) -> Void)?
    /// The Code tab asked for a scope: nil is all commits.
    public var onCommit: ((String?) -> Void)?
    public var onSetViewed: ((_ path: String, _ viewed: Bool) -> Void)?

    // Header.
    private let headerBox = HeaderBox()
    private let repo = LinkLabel()
    private let numberLink = LinkLabel()
    private let numberIcon = IconView(name: .externalLink, size: 10)
    private let checkout = ButtonView("Check out", icon: .gitBranch, variant: .outline, size: .xs).menuTrigger()
    private var primary: NSView?
    /// The merge or auto-merge button's width before a relabel, which the next layout animates from (`AnimatedWidth`,
    /// `transition-[width] duration-150 ease-out`, T3 3105 6a68bee34 and 9c9ae43d8).
    private var primaryWidthFrom: CGFloat?
    /// Merge, auto-merge, close and revert confirm in place (`useInlineActionConfirm`).
    let inlineConfirm = InlineActionConfirm()
    let more = ButtonView(nil, icon: .ellipsis, variant: .ghostMuted, size: .iconXs).menuTrigger()
    private let titleLabel = LabelView("", font: DSFont.ui(16, weight: .semibold))
    private let authorAvatar = PullRequestAvatarView()
    private let authorLogin = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let dot = LabelView("·", font: DSFont.ui(12))
    private let updated = LabelView("", font: DSFont.ui(12))
    private let checkoutCommand = LinkLabel()
    private let base = LabelView("", font: DSFont.mono(12))
    private let arrow = IconView(name: .arrowLeft, size: 14)
    private let head = LabelView("", font: DSFont.mono(12))
    private let filesIcon = IconView(name: .fileDiff, size: 14)
    private let files = LabelView("", font: DSFont.ui(12))
    private let diffStat = PullRequestDiffStatView()
    let tabs = ToggleGroupView(variant: .segmented, items: [("Summary", nil), ("Timeline", nil), ("Code", nil)], selected: 0)
    private let checksIcon = CheckStatusGlyph()
    private let checksLabel = LabelView("", font: DSFont.ui(12))
    private let timelineMeta = LabelView("", font: DSFont.ui(11))
    private let orderButton = ButtonView("Newest first", icon: .arrowDownUp, variant: .ghostMuted, size: .xs)
    private let tabRule = CALayer()
    private let headerRule = CALayer()
    private let condensedRule = CALayer()

    // Content.
    let summary = PullRequestSummaryView()
    let timeline = PullRequestTimelineView()
    let code = PullRequestCodeView()
    private var ghost: PullRequestDetailGhostView?
    private var failure: EmptyView?
    private let composerButton = ButtonView(nil, icon: .messageSquare, variant: .glass, size: .icon)
    private var reviewObserver: NSObjectProtocol?
    isolated deinit { if let reviewObserver { NotificationCenter.default.removeObserver(reviewObserver) } }

    // Title editing (PullRequestDetailPanel.tsx:2382-2445).
    private let titleEditButton = ButtonView(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs)
    private let titleInput = InputView(placeholder: "", size: .sm)
    private let titleCancel = ButtonView("Cancel", variant: .ghost, size: .xs)
    private let titleSave = ButtonView("Save", variant: .outline, size: .xs)
    private var titleTracking: NSTrackingArea?
    /// The title draft while the editor is open, nil while it is closed.
    public private(set) var titleDraft: String?
    public var titleSaving = false { didSet { updateTitleEditor() } }
    /// Save pressed with a changed title (`saveTitle`); the caller sends `pullRequests.update`.
    public var onSaveTitle: ((String) -> Void)?
    /// The source control write scope (`canWriteSourceControl`).
    public var canWrite = true { didSet { updateTitleEditor() } }

    // Native stack (PullRequestStackMenu.tsx).
    private let stackButton = ButtonView("", icon: .layers, variant: .ghost, size: .xs).menuTrigger()
    private let stackMergeButton = ButtonView("Merge stack", icon: .gitMerge, variant: .default, size: .xs)
    /// The host's stack for this pull request, nil without one.
    public var stack: PullRequestStackDetail? { didSet { rebuildActions() } }
    /// "Stack data may be stale…" or "Refreshing stack…", shown in the menu and the tooltip.
    public var stackNotice: String? { didSet { rebuildActions() } }
    /// The stack read failed: the menu offers "Retry stack refresh" and the button wears a warning.
    public var stackFailed = false { didSet { rebuildActions() } }
    /// Stack merge and rebase are allowed (`canMerge`, `canRebase` of the menu).
    public var stackCanMerge = false { didSet { rebuildActions() } }
    public var stackCanRebase = false { didSet { rebuildActions() } }
    public var stackPending = false { didSet { rebuildActions() } }
    /// With stack actions, a single merge waits for the stack read (`allowsSinglePullRequestMerge`).
    public var allowsSingleMerge = true { didSet { rebuildActions() } }
    public var onStackRetry: (() -> Void)?
    public var onStackAction: ((_ action: String) -> Void)?
    /// A stack layer picked: open that pull request.
    public var onSelectPullRequest: ((Int) -> Void)?

    // Condensed chrome (PullRequestDetailPanel.tsx:545-563, 1759-1800, 2245-2356).
    public private(set) var condensed = false
    private var condensedByTab: [Tab: Bool] = [:]
    private let condensedNumber = LinkLabel()
    private let condensedTitle = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let condensedAvatar = PullRequestAvatarView()
    private let condensedTime = LabelView("", font: DSFont.ui(12))
    private let condensedBase = LabelView("", font: DSFont.mono(10))
    private let condensedArrow = IconView(name: .arrowLeft, size: 12)
    private let condensedHead = LabelView("", font: DSFont.mono(10))
    private let condensedFilesIcon = IconView(name: .fileDiff, size: 12)
    private let condensedFiles = LabelView("", font: DSFont.ui(10))
    private let condensedStat = PullRequestDiffStatView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(headerBox)
        [repo, numberLink, numberIcon, checkout, more, titleLabel, authorAvatar, authorLogin, dot, updated, checkoutCommand, base, arrow, head,
         filesIcon, files, diffStat, tabs, checksIcon, checksLabel, timelineMeta, orderButton].forEach(headerBox.addSubview)
        for l in [authorLogin, dot, updated, files, checksLabel] { l.lineHeight = 16 }
        timelineMeta.lineHeight = 16
        base.lineHeight = 16; head.lineHeight = 16
        base.truncation = .middle; head.truncation = .middle
        titleLabel.lineHeight = 22
        repo.font = DSFont.ui(12, weight: .medium)
        numberLink.font = DSFont.ui(12, weight: .medium)
        checkoutCommand.font = DSFont.mono(12)
        diffStat.font = DSFont.mono(12)
        diffStat.lineHeight = 16
        checkout.trailingIcon = .chevronDown
        checkout.iconSize = 14
        more.iconSize = 16
        more.setAccessibilityLabel("More pull request actions")
        orderButton.iconSize = 12
        for l in [tabRule, headerRule, condensedRule] { l.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]; headerBox.layer?.addSublayer(l) }
        [summary, timeline, code].forEach(addSubview)
        addSubview(composerButton)
        composerButton.setAccessibilityLabel("Comment on pull request")
        composerButton.action = { [weak self] in self?.showComposer() }
        pendingBadge.lineHeight = 14
        pendingBadge.alignment = .center
        pendingBadge.wantsLayer = true
        pendingBadge.layer?.cornerRadius = 7
        pendingBadge.isHidden = true
        addSubview(pendingBadge)
        reviewObserver = NotificationCenter.default.addObserver(forName: PullRequestReviewStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePendingCount() }
        }
        checksIcon.onClick = { [weak self] glyph in self?.showChecks(from: glyph) }
        titleEditButton.iconSize = 12
        titleEditButton.setAccessibilityLabel("Edit title")
        titleEditButton.alphaValue = 0
        titleEditButton.action = { [weak self] in self?.beginTitleEdit() }
        titleInput.setAccessibilityLabel("Pull request title")
        titleInput.onSubmit = { [weak self] in self?.saveTitle() }
        titleInput.onCommand = { [weak self] sel in
            guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
            self?.cancelTitleEdit()
            return true
        }
        titleCancel.action = { [weak self] in self?.cancelTitleEdit() }
        titleSave.action = { [weak self] in self?.saveTitle() }
        titleInput.onChange = { [weak self] _ in self?.updateTitleEditor() }
        [titleEditButton, titleInput, titleCancel, titleSave].forEach(headerBox.addSubview)
        stackButton.iconSize = 14
        stackButton.action = { [weak self] in self?.showStackMenu() }
        stackMergeButton.iconSize = 14
        stackMergeButton.action = { [weak self] in self?.confirmStack("merge") }
        [stackButton, stackMergeButton].forEach(headerBox.addSubview)
        for v in [condensedNumber, condensedTitle, condensedAvatar, condensedTime, condensedBase, condensedArrow, condensedHead, condensedFiles, condensedFilesIcon, condensedStat] as [NSView] {
            headerBox.addSubview(v)
        }
        condensedNumber.font = DSFont.ui(12, weight: .medium)
        condensedNumber.onClick = { [weak self] in if let d = self?.detail { self?.onOpenURL?(d.url) } }
        condensedNumber.onMenu = { [weak self] event in self?.showNumberMenu(event) }
        for l in [condensedTitle, condensedTime] { l.lineHeight = 16 }
        for l in [condensedBase, condensedHead, condensedFiles] { l.lineHeight = 14 }
        condensedBase.truncation = .middle; condensedHead.truncation = .middle
        condensedStat.font = DSFont.mono(10)
        condensedStat.lineHeight = 14
        for t in [summary.scrollTarget, timeline.scrollTarget, code.scrollTarget] {
            t.onScroll = { [weak self] top in self?.scrolled(top) }
        }
        tabs.onChange = { [weak self] index in
            guard let self, let index, let t = Tab(rawValue: index) else { return }
            self.tab = t
            self.onTab?(t)
        }
        repo.onClick = { [weak self] in if let d = self?.detail { self?.onOpenURL?(Self.repositoryURL(d)) } }
        numberLink.onClick = { [weak self] in if let d = self?.detail { self?.onOpenURL?(d.url) } }
        numberLink.onMenu = { [weak self] event in self?.showNumberMenu(event) }
        checkoutCommand.onClick = { [weak self] in
            guard let self, let d = self.detail, let c = PullRequestDetailLogic.checkoutCommand(provider: d.provider, number: d.number) else { return }
            self.onCopy?(c, "Checkout command")
        }
        checkout.action = { [weak self] in self?.showCheckoutMenu() }
        more.action = { [weak self] in self?.showMoreMenu() }
        orderButton.action = { [weak self] in
            guard let self else { return }
            self.timeline.newestFirst.toggle()
            self.orderButton.title = self.timeline.newestFirst ? "Newest first" : "Oldest first"
            self.needsLayout = true
        }
        summary.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        summary.onReact = { [weak self] id, content, reacted, bar in self?.onReact?(id, content, reacted, bar) }
        timeline.onOpenCommit = { [weak self] oid in self?.tab = .code; self?.onTab?(.code); self?.onCommit?(oid) }
        code.onCommit = { [weak self] oid in self?.onCommit?(oid) }
        code.onSetViewed = { [weak self] path, viewed in self?.onSetViewed?(path, viewed) }
        setAccessibilityLabel("Pull request")
        rebuild()
    }

    /// The repository's web page: the pull request URL up to `/pull/`, `/pulls/`, `/-/merge_requests/`.
    static func repositoryURL(_ d: PullRequestDetail) -> String {
        for marker in ["/pull/", "/pulls/", "/-/merge_requests/", "/pull-requests/", "/pullrequest/"] {
            if let r = d.url.range(of: marker) { return String(d.url[..<r.lowerBound]) }
        }
        return d.url
    }

    // MARK: Data

    public func showLoading(number: Int) {
        phase = .loading(number: number)
        detail = nil
        rebuild()
    }

    /// `retry` false drops the Retry button, for a state no retry can fix (an old server).
    public func showFailure(title: String, message: String, retry: Bool = true) {
        phase = .failed(title: title, message: message)
        failureRetry = retry
        detail = nil
        rebuild()
    }

    public func show(_ detail: PullRequestDetail) {
        let sameIdentity = self.detail?.url == detail.url
        self.detail = detail
        phase = .loaded
        if !sameIdentity {
            // Another pull request: nothing stays armed (the hook's `scopeKey`).
            inlineConfirm.disarm()
            code.reset()
            titleDraft = nil
            condensed = false
            condensedByTab = [:]
            closeComposer()
            composer = nil
            stack = nil
            stackNotice = nil
            stackFailed = false
        }
        rebuild()
    }

    /// The Code tab's slices so far, or its state; `nextCursor` says more is owed.
    public func setDiff(patches: [String], loading: Bool, error: String?, nextCursor: String? = nil, moreLoading: Bool = false,
                        moreError: String? = nil, commit: String?) {
        code.set(patches: patches, loading: loading, error: error, nextCursor: nextCursor, moreLoading: moreLoading, moreError: moreError,
                 commit: commit, commits: detail?.commits ?? [])
    }

    /// The Code tab wants the next slice.
    public var onLoadMoreDiff: (() -> Void)? { get { code.onLoadMore } set { code.onLoadMore = newValue } }

    /// What the conversation cards ask of the host; set once, used for every pull request.
    public var reviewActions: PullRequestReviewThreadActions? { didSet { syncReview() } }

    private func syncReview() {
        guard let d = detail, let reviewActions else { return }
        code.setReview(d, reviewKey: reviewKey ?? d.url, actions: reviewActions, nowMs: nowMs)
    }

    /// The viewed marks (`pullRequests.filesViewed` plus presses not confirmed yet). Nil hides them.
    public func setViewed(states: [String: String]?, overlay: [String: Bool], store: String?) {
        code.setViewed(states: states, overlay: overlay, store: store)
    }

    private func rebuild() {
        ghost?.removeFromSuperview(); ghost = nil
        failure?.removeFromSuperview(); failure = nil
        let loaded = phase == .loaded && detail != nil
        headerBox.isHidden = !loaded
        [summary, timeline, code].forEach { $0.isHidden = !loaded }
        composerButton.isHidden = true
        switch phase {
        case .loading:
            let g = PullRequestDetailGhostView()
            addSubview(g)
            ghost = g
        case .failed(let title, let message):
            let e = EmptyView(title: title, message: message, icon: .gitPullRequestArrow)
            if failureRetry {
                let retry = ButtonView("Retry", icon: .refreshCw, variant: .outline, size: .sm)
                retry.action = { [weak self] in self?.onRetry?() }
                e.content = ButtonRow([retry])
            }
            addSubview(e)
            failure = e
        case .loaded:
            guard let d = detail else { break }
            let tone = PullRequestStateTone(state: d.state, isDraft: d.isDraft)
            repo.text = d.repository
            repo.toolTip = "Open \(d.repository) repository"
            numberLink.text = "#\(d.number)"
            numberLink.toolTip = PullRequestDetailLogic.openOnHostLabel(d.provider)
            numberLink.color = PullRequestStyle.color(tone)
            numberIcon.strokeColor = PullRequestStyle.color(tone)
            checkout.isHidden = context != .page
            condensedNumber.text = "#\(d.number)"
            condensedNumber.color = PullRequestStyle.color(tone)
            condensedNumber.toolTip = PullRequestDetailLogic.openOnHostLabel(d.provider)
            condensedTitle.text = d.title
            condensedTitle.toolTip = d.title
            condensedAvatar.actor = d.author
            condensedAvatar.toolTip = d.author?.login ?? "ghost"
            condensedTime.text = TimestampFormat.formatRelativeTimeLabel(d.updatedAt, nowMs: nowMs)
            condensedBase.text = d.baseBranch
            condensedBase.toolTip = d.baseBranch
            condensedHead.text = d.headBranch
            condensedHead.toolTip = d.headBranch
            condensedFiles.text = d.changedFiles.formatted()
            condensedStat.additions = d.additions
            condensedStat.deletions = d.deletions
            updateTitleEditor()
            titleLabel.text = d.title
            titleLabel.toolTip = d.title
            authorAvatar.actor = d.author
            authorLogin.text = d.author?.login ?? "ghost"
            updated.text = "updated " + TimestampFormat.formatRelativeTimeLabel(d.updatedAt, nowMs: nowMs)
            let command = PullRequestDetailLogic.checkoutCommand(provider: d.provider, number: d.number)
            checkoutCommand.text = command ?? ""
            checkoutCommand.isHidden = command == nil
            checkoutCommand.toolTip = "Copy checkout command"
            base.text = d.baseBranch
            head.text = d.headBranch
            files.text = "\(d.changedFiles.formatted()) \(d.changedFiles == 1 ? "file" : "files")"
            diffStat.additions = d.additions
            diffStat.deletions = d.deletions
            // Tabs: a host without a patch has no Code tab.
            tabs.items[2].isHidden = !d.capabilities.diff
            if !d.capabilities.diff && tab == .code { tab = .summary }
            let canComment = d.capabilities.comment && d.viewerPermissions.comment
            let verdicts = d.capabilities.review.verdicts.filter { d.viewerPermissions.verdicts.contains($0) }
            composerButton.isHidden = !canComment && verdicts.isEmpty
            updatePendingCount()
            syncReview()
            rebuildActions()
            rebuildTabs()
        }
        showTab()
        restyle()
        needsLayout = true
    }

    private func rebuildTabs() {
        guard let d = detail else { return }
        // Summary's trailing checks line (`PullRequestChecksStatusLine`).
        let state = PullRequestDetailLogic.effectiveChecksState(d)
        if let state {
            let p = PullRequestStyle.checksState(state)
            checksIcon.set(icon: p.icon, color: p.color)
        } else {
            checksIcon.set(icon: .circleDot, color: Themed.color(\.mutedForeground))
        }
        checksLabel.text = PullRequestDetailLogic.summarizeChecks(d.checks)
        // Timeline's counts.
        let comments = activityError != nil ? "—" : activityPending ? "…" : d.commentCount.formatted()
        let commits = activityError != nil ? "—" : activityPending ? "…" : d.commits.count.formatted()
        timelineMeta.text = "\(comments)   ·   \(commits)"
        // `transition-opacity`, `opacity-35` while the activity loads or failed (PullRequestDetailPanel.tsx:2602).
        HoverReveal.fade(timelineMeta, to: activityPending || activityError != nil ? 0.35 : 1)
        summary.set(d, activityPending: activityPending, activityError: activityError, nowMs: nowMs)
        timeline.set(d, pending: activityPending, error: activityError, nowMs: nowMs)
        needsLayout = true
    }

    private func showTab() {
        guard phase == .loaded else { return }
        summary.isHidden = tab != .summary
        timeline.isHidden = tab != .timeline
        code.isHidden = tab != .code
        tabs.selectedIndex = tab.rawValue
        checksIcon.isHidden = tab != .summary
        checksLabel.isHidden = tab != .summary
        timelineMeta.isHidden = tab != .timeline
        orderButton.isHidden = tab != .timeline
        needsLayout = true
    }

    /// The header's merge slot (`resolvePullRequestPrimaryControl`).
    private func rebuildActions() {
        let previous = (primary as? ButtonView).flatMap { b in b.reservedTitles.isEmpty ? nil : (b.reservedTitles, b.frame.width) }
        defer {
            // The same confirm button relabeled (armed, pending or back): its width animates.
            if let previous, let b = primary as? ButtonView, b.reservedTitles == previous.0 {
                primaryWidthFrom = previous.1
            }
        }
        primary?.removeFromSuperview()
        primary = nil
        guard let d = detail else { stackButton.isHidden = true; stackMergeButton.isHidden = true; return }
        let allowed = PullRequestDetailLogic.allowedMergeMethods(d)
        let method = PullRequestDetailLogic.selectedMergeMethod(allowed, current: currentMergeMethod, projectDefault: projectDefaultMergeMethod,
                                                                preferred: preferredMergeMethod)
        updateStackControls(d)
        var control = PullRequestDetailLogic.primaryControl(d)
        // ponytail: a stack gates only the merge and auto-merge controls here; T3 feeds `canMerge` and
        // `canEnableAutoMerge` into `resolvePullRequestPrimaryControl`. Port the full resolver if a stacked
        // pull request shows a different control than T3
        if !allowsSingleMerge && (control == "merge" || control == "enable-auto-merge") { control = nil }
        switch control {
        case "resolve":
            let b = ButtonView("Resolve conflicts", icon: .triangleAlert, variant: .destructiveOutline, size: .xs)
            b.iconSize = 14
            b.isEnabled = false
            b.toolTip = "Resolve conflicts"
            primary = b
        case "ready":
            let b = ButtonView("Ready for review", icon: .gitPullRequestArrow, variant: .default, size: .xs)
            b.iconSize = 14
            b.isEnabled = !actionPending
            b.action = { [weak self] in self?.onAction?("ready", nil) }
            primary = b
        case "enable-auto-merge":
            let normal = "Auto-merge (\(PullRequestDetailLogic.mergeMethodLabel(method).lowercased()))"
            primary = confirmButton("enable-auto-merge", method: method, normal: normal, armed: "Confirm auto-merge?", pending: "Enabling...")
        case "auto-merge-armed":
            let label = d.autoMergeMethod.map { "Auto-merge (\(PullRequestDetailLogic.mergeMethodLabel($0).lowercased()))" } ?? "Auto-merge"
            let badge = BadgeView(label, variant: .info, size: .control, icon: .gitMerge)
            badge.toolTip = "\(label): the host will merge this on its own once its requirements are met"
            primary = badge
        case "merge":
            primary = confirmButton("merge", method: method, normal: PullRequestDetailLogic.mergeMethodLabel(method), armed: "Confirm merge?", pending: "Merging...")
        case "merged", "closed":
            let tone = PullRequestStateTone(state: d.state, isDraft: d.isDraft)
            let badge = StateBadge(tone: tone)
            primary = badge
        default:
            break
        }
        if let primary { headerBox.addSubview(primary) }
        needsLayout = true
    }

    // MARK: Menus and dialogs

    /// The stack button (`⧉ 2/3`, a warning while stale) and "Merge stack" beside it.
    private func updateStackControls(_ d: PullRequestDetail) {
        guard let stack else { stackButton.isHidden = true; stackMergeButton.isHidden = true; return }
        let plan = PullRequestWriteLogic.stackPlan(stack, current: d.number, pending: stackPending)
        stackButton.isHidden = false
        stackButton.title = "\(plan.position)/\(stack.layers.count)"
        stackButton.trailingIcon = stackFailed ? .triangleAlert : nil
        stackButton.setAccessibilityLabel("Stack \(stack.number), layer \(plan.position) of \(stack.layers.count)")
        stackButton.toolTip = "View stack #\(stack.number), layer \(plan.position) of \(stack.layers.count)" + (stackNotice.map { " · \($0)" } ?? "")
        stackMergeButton.isHidden = !(stackCanMerge && plan.selectedIsOpen)
        stackMergeButton.isEnabled = !plan.mergeDisabled
        let n = plan.mergeLayers.count
        stackMergeButton.toolTip = "Merge stack through #\(d.number) into \(stack.base) (\(n) \(n == 1 ? "pull request" : "pull requests"))"
    }

    /// The header's merge or auto-merge button, confirmed in place (2994 PullRequestDetailPanel.tsx:2025-2141):
    /// the first press relabels it "Confirm …?", the second runs it. Its label slot holds both labels' width.
    private func confirmButton(_ action: String, method: String, normal: String, armed: String, pending: String) -> ButtonView {
        let label = actionPending ? pending : inlineConfirm.isArmed(action, slot: "header") ? armed : normal
        let b = ButtonView(label, icon: .gitMerge, variant: .default, size: .xs)
        b.iconSize = 14
        // The method label holds the width; a longer label widens it (T3 3105 6a68bee34, 9c9ae43d8).
        b.reservedTitles = [normal]
        b.isEnabled = !actionPending
        b.toolTip = label
        b.setAccessibilityLabel(label)
        b.action = { [weak self, weak b] in
            guard let self else { return }
            let confirmed = self.inlineConfirm.press(action, slot: "header",
                                                     contains: { [weak self] e in InlineActionConfirm.hits(e, self?.primary) },
                                                     onDisarm: { [weak self] in self?.rebuildActions() })
            if confirmed { self.onAction?(action, method); self.rebuildActions(); return }
            // Relabel in place: a rebuilt button would drop the hover under the pointer.
            self.primaryWidthFrom = b?.frame.width
            self.needsLayout = true
            b?.title = armed
            b?.toolTip = armed
            b?.setAccessibilityLabel(armed)
        }
        return b
    }

    /// A ⋯ menu row confirmed in place (`closeOnClick={isArmed}`, PullRequestDetailPanel.tsx:2265-2416): the first
    /// press relabels the row and keeps the menu open, the second closes the menu and runs the action.
    private func confirmMenuItem(_ action: String, method: String? = nil, title: String, armed: String, icon: IconName,
                                 destructive: Bool = false, armedDestructive: Bool = false, index: Int, menu: WeakMenu) -> MenuItem {
        var item = MenuItem(title, icon: icon, destructive: destructive, disabled: actionPending)
        item.runsInPlace = true
        // The row relabels itself from the menu's copy, so no closure holds the item that holds it.
        let relabel = { (popup: MenuPopupView, isArmed: Bool) in
            guard index < popup.items.count else { return }
            var row = popup.items[index]
            row.title = isArmed ? armed : title
            row.isDestructive = destructive || (isArmed && armedDestructive)
            popup.replaceItem(at: index, with: row)
        }
        item.action = { [weak self] in
            guard let self, let popup = menu.popup else { return }
            let confirmed = self.inlineConfirm.press(action, slot: "menu:\(action)",
                                                     contains: { [weak popup] e in InlineActionConfirm.hits(e, popup?.rowView(at: index)) },
                                                     onDisarm: { [weak popup] in
                                                         menu.armedIndex = nil
                                                         if let popup { relabel(popup, false) }
                                                     })
            if confirmed {
                popup.closeTree()
                self.onAction?(action, method)
            } else {
                relabel(popup, true)
                menu.armedIndex = index
            }
        }
        return item
    }

    /// The open ⋯ menu and its armed row, shared by the rows' actions.
    final class WeakMenu { weak var popup: MenuPopupView?; var armedIndex: Int? }

    private func showNumberMenu(_ event: NSEvent) {
        guard let d = detail else { return }
        var copy = MenuItem("Copy link", icon: .copy)
        copy.action = { [weak self] in self?.onCopy?(d.url, "PR link") }
        var open = MenuItem(PullRequestDetailLogic.openOnHostLabel(d.provider))
        open.action = { [weak self] in self?.onOpenURL?(d.url) }
        MenuPopupView.showContextMenu([copy, open], in: numberLink, at: numberLink.convert(event.locationInWindow, from: nil))
    }

    /// Check out (page only): in a separate worktree, or in this repository.
    private func showCheckoutMenu() {
        var worktree = MenuItem("In a separate worktree", icon: .gitBranch)
        worktree.subtitle = "Its own folder and thread. Nothing you have open moves."
        worktree.action = { [weak self] in self?.onCheckout?(true) }
        var local = MenuItem("In this repository", icon: .folderGit2)
        local.subtitle = "Switches the branch you are working in, like `gh pr checkout`."
        local.action = { [weak self] in self?.onCheckout?(false) }
        MenuPopupView.show([worktree, local], from: checkout, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    /// The ⋯ menu (PullRequestDetailPanel.tsx:2052-2235).
    private func showMoreMenu() {
        guard let d = detail else { return }
        var items: [MenuItem] = []
        let menuRef = WeakMenu()
        // `PullRequestThreadLinks display="menu-item"`: "Link to this thread" or "Unlink from this thread".
        if let title = linkItemTitle {
            var link = MenuItem(title, icon: title.hasPrefix("Unlink") ? .unlink2 : .link2)
            link.action = { [weak self] in self?.onLinkThread?() }
            items.append(link)
        }
        var refresh = MenuItem("Refresh", icon: .refreshCw, disabled: refreshing)
        refresh.action = { [weak self] in self?.onRefresh?() }
        items.append(refresh)
        items.append(.separator)
        let can = { (a: String) in PullRequestDetailLogic.can(d, a) }
        let allowed = PullRequestDetailLogic.allowedMergeMethods(d)
        let primaryControl = PullRequestDetailLogic.primaryControl(d)
        let conflicting = d.mergeability == "conflicting"
        if d.state == "open" {
            let showsDraftToggle = can(d.isDraft ? "ready" : "draft") && !(d.isDraft && primaryControl == "ready")
            if showsDraftToggle {
                var item = MenuItem(d.isDraft ? "Ready for review" : "Convert to draft", icon: d.isDraft ? .gitPullRequestArrow : .gitPullRequestDraft, disabled: actionPending)
                item.action = { [weak self] in self?.onAction?(d.isDraft ? "ready" : "draft", nil) }
                items.append(item)
            }
            let method = PullRequestDetailLogic.selectedMergeMethod(allowed, current: currentMergeMethod, projectDefault: projectDefaultMergeMethod,
                                                                preferred: preferredMergeMethod)
            let showsMergeNow = (primaryControl == "enable-auto-merge" || primaryControl == "auto-merge-armed") && can("merge") && !d.isDraft && !conflicting && !allowed.isEmpty
            if showsMergeNow {
                items.append(confirmMenuItem("merge", method: method, title: "Merge now", armed: "Confirm merge?", icon: .gitMerge,
                                             index: items.count, menu: menuRef))
            }
            let armed = d.autoMergeEnabled == true
            let showsAutoMerge = (armed && can("disable-auto-merge"))
                || (!armed && primaryControl != "enable-auto-merge" && !d.isDraft && !conflicting && can("enable-auto-merge") && !allowed.isEmpty)
            if armed && can("disable-auto-merge") {
                var item = MenuItem("Disable auto-merge", icon: .gitMerge, disabled: actionPending)
                item.action = { [weak self] in self?.onAction?("disable-auto-merge", nil) }
                items.append(item)
            } else if showsAutoMerge {
                items.append(confirmMenuItem("enable-auto-merge", method: method, title: "Enable auto-merge", armed: "Confirm auto-merge?",
                                             icon: .gitMerge, index: items.count, menu: menuRef))
            }
            let showsMethods = can("merge") && !d.isDraft && !conflicting && allowed.count > 1
            if showsMethods {
                if showsDraftToggle || showsMergeNow || showsAutoMerge { items.append(.separator) }
                for m in allowed {
                    var item = MenuItem.radio(PullRequestDetailLogic.mergeMethodLabel(m), checked: m == method) { [weak self] _ in
                        self?.currentMergeMethod = m
                        self?.preferredMergeMethod = m
                        self?.onMergeMethod?(m)
                    }
                    item.icon = .gitMerge
                    item.closesOnClick = true
                    items.append(item)
                }
            }
            if showsDraftToggle || showsAutoMerge || showsMergeNow || showsMethods { items.append(.separator) }
        }
        var open = MenuItem(PullRequestDetailLogic.openOnHostLabel(d.provider), icon: .arrowUpRight)
        open.action = { [weak self] in self?.onOpenURL?(d.url) }
        var copyLink = MenuItem("Copy link", icon: .link, shortcut: "⇧⌘C")
        copyLink.action = { [weak self] in self?.onCopy?(d.url, "PR link") }
        var copyNumber = MenuItem("Copy PR number", icon: .copy, shortcut: "⇧⌘K")
        copyNumber.action = { [weak self] in self?.onCopy?("#\(d.number)", "PR number") }
        items += [open, copyLink, copyNumber]
        if d.state == "open" && can("close") {
            items.append(.separator)
            items.append(confirmMenuItem("close", title: "Close pull request", armed: "Confirm close?", icon: .gitPullRequestClosed,
                                         destructive: true, index: items.count, menu: menuRef))
        } else if d.state == "closed" && can("reopen") {
            var reopen = MenuItem("Reopen pull request", icon: .gitPullRequestArrow, disabled: actionPending)
            reopen.action = { [weak self] in self?.onAction?("reopen", nil) }
            items += [.separator, reopen]
        } else if d.state == "merged" && can("revert") {
            items.append(.separator)
            items.append(confirmMenuItem("revert", title: "Revert changes", armed: "Confirm revert?", icon: .rotateCcw,
                                         armedDestructive: true, index: items.count, menu: menuRef))
        }
        let popup = MenuPopupView.show(items, from: more, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
        menuRef.popup = popup
        // base-ui focuses the highlighted row, which blurs an armed one and disarms it.
        popup?.onHighlight = { [weak self] i in
            guard let self, let i, let armed = menuRef.armedIndex, i != armed else { return }
            self.inlineConfirm.disarm()
        }
        // Escape on an armed row disarms it and leaves the menu open (the hook's capture-phase `keydown`).
        popup?.escapeOverride = { [weak self] in
            guard let self, menuRef.armedIndex != nil else { return false }
            self.inlineConfirm.disarm()
            return true
        }
    }

    /// `PullRequestComposer`: Comment, or Review with a verdict, in a popover over the glass button
    /// (`side="top" align="end" sideOffset={8} width="lg"`).
    private func showComposer() {
        guard let d = detail else { return }
        let key = reviewKey ?? d.url
        if composer?.reviewKey != key {
            let c = PullRequestComposerView(detail: d, reviewKey: key)
            c.onComment = { [weak self] body in self?.onComment?(body) }
            c.onCommentAction = { [weak self] body, action in self?.onCommentAction?(body, action) }
            c.onReview = { [weak self] verdict, body, comments in self?.onReview?(verdict, body, comments) }
            c.onClose = { [weak self] in self?.closeComposer() }
            composer = c
        }
        guard let composer else { return }
        composer.actionPending = actionPending
        composer.prepareToOpen()
        composerPopup = PopoverView(content: composer, width: .lg)
            .show(from: composerButton, placement: PopupPlacement(side: .top, align: .end, sideOffset: 8, fallbackAxisSide: .none))
        DispatchQueue.main.async { [weak composer] in composer?.focusBox() }
    }

    /// Closes the composer popover (a comment posted or a review sent, or the close button).
    public func closeComposer() {
        if let composerPopup { composerButton.popupHost?.close(composerPopup) }
        composerPopup = nil
    }

    /// The pending line comments' count on the composer button (`bg-info`, `text-3xs`).
    public func updatePendingCount() {
        let count = reviewKey.map { PullRequestReviewStore.shared.comments($0).count } ?? 0
        pendingBadge.text = "\(count)"
        pendingBadge.isHidden = count == 0 || composerButton.isHidden
        if let d = detail {
            let offer = PullRequestWriteLogic.composerOffer(d)
            let started = count > 0 || !(reviewKey.map { PullRequestReviewStore.shared.summary($0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            composerButton.setAccessibilityLabel(PullRequestWriteLogic.composerLabel(pending: count, reviewStarted: started, canComment: offer.canComment))
        }
        needsLayout = true
    }

    // MARK: Checks

    /// The checks indicator's popover over the checks the detail holds (PullRequestDetailPanel.tsx:2581-2590).
    private func showChecks(from glyph: NSView) {
        guard let d = detail, let state = PullRequestDetailLogic.effectiveChecksState(d) else { return }
        let view = PullRequestChecksPopoverView(checksState: state, summary: PullRequestDetailLogic.summarizeChecks(d.checks), body: .checks(d.checks))
        view.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        view.present(from: glyph)
    }

    // MARK: Title

    private var canEditTitle: Bool { detail.map(PullRequestWriteLogic.canEditChangeRequest) ?? false }

    private func beginTitleEdit() {
        guard let d = detail, canEditTitle else { return }
        titleDraft = d.title
        titleInput.text = d.title
        updateTitleEditor()
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.titleInput)
        }
    }

    public func cancelTitleEdit() {
        titleDraft = nil
        updateTitleEditor()
        needsLayout = true
    }

    /// `saveTitle`: blank or unchanged closes the editor; otherwise the caller sends it and calls
    /// `cancelTitleEdit` once the host took it (a failure keeps the words).
    private func saveTitle() {
        guard let d = detail, titleDraft != nil, !titleSaving, canWrite else { return }
        guard let title = PullRequestWriteLogic.titleToSave(titleInput.text, current: d.title) else { cancelTitleEdit(); return }
        onSaveTitle?(title)
    }

    private func updateTitleEditor() {
        let editing = titleDraft != nil
        if editing { titleDraft = titleInput.text }
        titleLabel.isHidden = editing
        titleEditButton.isHidden = editing || !canEditTitle
        [titleInput, titleCancel, titleSave].forEach { $0.isHidden = !editing }
        titleInput.isEnabled = !titleSaving
        titleCancel.isEnabled = !titleSaving
        titleSave.isEnabled = canWrite && !titleSaving && !titleInput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        titleSave.title = titleSaving ? "Saving..." : "Save"
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let titleTracking { removeTrackingArea(titleTracking) }
        titleTracking = NSTrackingArea(rect: titleRowRect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(titleTracking!)
    }
    // `PullRequestEditButton` (PullRequestEditButton.tsx:16): `opacity-0 transition-opacity group-hover:opacity-100`.
    public override func mouseEntered(with event: NSEvent) { HoverReveal.fade([titleEditButton], visible: true) }
    public override func mouseExited(with event: NSEvent) { HoverReveal.fade([titleEditButton], visible: false) }

    private var titleRowRect: NSRect { NSRect(x: 0, y: 28 + 4, width: bounds.width, height: 24) }

    // MARK: Stack

    private func showStackMenu() {
        guard let stack, let d = detail else { return }
        let plan = PullRequestWriteLogic.stackPlan(stack, current: d.number, pending: stackPending)
        var items = PullRequestStackMenu.header(number: stack.number, notice: stackNotice, stale: stackFailed,
                                                onRetry: { [weak self] in self?.onStackRetry?() })
        var select: (@MainActor (Int) -> Void)?
        if onSelectPullRequest != nil { select = { [weak self] n in self?.onSelectPullRequest?(n) } }
        items += PullRequestStackMenu.layers(stack, current: d.number, pending: stackPending, onSelect: select)
        if stackCanMerge || stackCanRebase {
            items.append(.separator)
            if stackCanMerge {
                var merge = MenuItem("Merge stack (\(plan.mergeLayers.count))", icon: .gitMerge, disabled: plan.mergeDisabled)
                merge.action = { [weak self] in self?.confirmStack("merge") }
                items.append(merge)
            }
            if stackCanRebase {
                var rebase = MenuItem("Rebase stack", icon: .refreshCw, disabled: plan.rebaseDisabled)
                rebase.action = { [weak self] in self?.confirmStack("update-branch") }
                items.append(rebase)
            }
            if plan.showsReadyNote { items.append(.label("Every layer being merged must be open and ready for review.")) }
        }
        MenuPopupView.show(items, from: stackButton, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none))
    }

    /// The stack confirmation (PullRequestStackMenu.tsx:220-260): the layers it touches, Cancel, go.
    private func confirmStack(_ action: String) {
        guard let stack, let d = detail, let window else { return }
        let method = PullRequestDetailLogic.selectedMergeMethod(PullRequestDetailLogic.allowedMergeMethods(d), current: currentMergeMethod,
                                                                projectDefault: projectDefaultMergeMethod, preferred: preferredMergeMethod)
        let copy = PullRequestWriteLogic.stackConfirmation(stack, current: d.number, action: action, mergeMethod: method)
        let plan = PullRequestWriteLogic.stackPlan(stack, current: d.number, pending: stackPending)
        let dialog = DialogView(kind: .dialog, title: copy.title, message: copy.message)
        dialog.maxWidth = 448
        dialog.panelContent = [PullRequestStackLayerListView(action == "merge" ? plan.mergeLayers : plan.unmerged)]
        let cancel = ButtonView("Cancel", variant: .outline, size: .default)
        let go = ButtonView(copy.button, variant: .default, size: .default)
        dialog.footerButtons = [cancel, go]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { host.close() }
        go.action = { [weak self] in host.close(); self?.onStackAction?(action) }
    }

    // MARK: Condensed chrome

    private var activeScroll: PullRequestScrollWatcher {
        switch tab { case .summary: summary.scrollTarget; case .timeline: timeline.scrollTarget; case .code: code.scrollTarget }
    }

    /// The fold under the top row: the title block, the author row and the branches row.
    private var foldHeight: CGFloat { 4 + (titleDraft != nil ? 28 + 8 + 24 : 24) + 8 + 20 + 16 + 20 + 16 }
    static let condensedRowHeight: CGFloat = 28

    private func scrolled(_ top: CGFloat) {
        guard phase == .loaded else { return }
        let (next, refund) = PullRequestWriteLogic.condensed(previous: condensed, scrollTop: top, foldHeight: foldHeight,
                                                              condensedRowHeight: Self.condensedRowHeight)
        condensedByTab[tab] = next
        guard next != condensed else { return }
        let oldRule = tabRule.frame.minY
        condensed = next
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let refund { activeScroll.adjust(by: refund) }
        animateChrome(oldRule: oldRule)
    }

    /// PullRequestDetailPanel.tsx:1687-1690, 1759-1766, 2245-2260, 2362-2376: the two top lines and the
    /// two rows under them cross-fade, the leaving one `opacity-0` with a 4px slide over 100 ms, the
    /// arriving one back over 150 ms after 50 ms, all `ease-out`. Condensing collapses the fold at once;
    /// reopening runs `grid-template-rows` over 200 ms `ease-out`, so the tab bar and the content slide
    /// down while the fold shows from the top. Off under Reduce Motion.
    private func animateChrome(oldRule: CGFloat) {
        guard window != nil, !Motion.reduced, let box = headerBox.layer else { return }
        let easeOut = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
        let fold: [NSView] = [titleLabel, titleEditButton, titleInput, titleCancel, titleSave, authorAvatar, authorLogin, dot, updated,
                              checkoutCommand, base, arrow, head, filesIcon, files, diffStat].filter { !$0.isHidden && $0.frame.width > 0 }
        let condensedRow: [NSView] = [condensedAvatar, condensedTime, condensedBase, condensedArrow, condensedHead, condensedFilesIcon,
                                      condensedFiles, condensedStat]
        let fullLine: [NSView] = [repo, numberLink], shortLine: [NSView] = [condensedNumber, condensedTitle]
        func arrive(_ views: [NSView], from dy: CGFloat) {
            for layer in views.compactMap(\.layer) {
                for (key, from, to) in [("opacity", 0.0, 1.0), ("position.y", Double(dy), 0.0)] {
                    let a = CABasicAnimation(keyPath: key)
                    a.fromValue = from
                    a.toValue = to
                    a.isAdditive = key == "position.y"
                    a.beginTime = CACurrentMediaTime() + 0.05
                    a.duration = 0.15
                    a.fillMode = .backwards
                    a.timingFunction = easeOut
                    layer.add(a, forKey: "chrome.\(key)")
                }
            }
        }
        // The leaving views are hidden by now; their layers show for the fade, then follow the view again.
        func leave(_ views: [NSView], to dy: CGFloat) {
            let layers = views.compactMap(\.layer)
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated { for v in views { v.layer?.isHidden = v.isHidden } }
            }
            for layer in layers {
                layer.isHidden = false
                for (key, from, to) in [("opacity", 1.0, 0.0), ("position.y", 0.0, Double(dy))] {
                    let a = CABasicAnimation(keyPath: key)
                    a.fromValue = from
                    a.toValue = to
                    a.isAdditive = key == "position.y"
                    a.duration = 0.1
                    a.fillMode = .forwards
                    a.isRemovedOnCompletion = false
                    a.timingFunction = easeOut
                    layer.add(a, forKey: "chrome.\(key)")
                }
            }
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                MainActor.assumeIsolated { for l in layers { l.removeAnimation(forKey: "chrome.opacity"); l.removeAnimation(forKey: "chrome.position.y") } }
            }
        }
        if condensed {
            leave(fullLine, to: -4)
            arrive(shortLine + condensedRow, from: 4)
            return
        }
        leave(shortLine + condensedRow, to: 4)
        arrive(fullLine + fold, from: -4)
        let dy = tabRule.frame.minY - oldRule
        guard dy > 0 else { return }
        let movers = [tabRule, headerRule] + ([tabs, checksIcon, checksLabel, timelineMeta, orderButton, summary, timeline, code] as [NSView]).compactMap(\.layer)
        for layer in movers {
            let a = CABasicAnimation(keyPath: "position.y")
            a.fromValue = -dy
            a.toValue = 0
            a.isAdditive = true
            a.duration = 0.2
            a.timingFunction = easeOut
            layer.add(a, forKey: "chrome.slide")
        }
        // The fold's track grows with the slide: nothing of it shows below the moving tab bar.
        CollapseMotion.clipBelow(fold.compactMap(\.layer), in: box, from: oldRule, to: tabRule.frame.minY, duration: 0.2, timing: easeOut)
    }

    // MARK: Layout

    /// The header's height: the 28pt top row, the fold (or the condensed row) and the tab bar.
    public var headerHeight: CGFloat { 28 + (condensed ? Self.condensedRowHeight : foldHeight) + 1 + 44 }

    public override func layout() {
        super.layout()
        let w = bounds.width
        ghost?.frame = bounds
        failure?.frame = bounds
        guard phase == .loaded else { return }
        let hh = headerHeight
        headerBox.frame = NSRect(x: 0, y: 0, width: w, height: hh + 1)
        // Top row (`h-7`, `pl-4`, actions `mr-4 gap-1`).
        var r = w - 16
        let mw: CGFloat = 24
        more.frame = NSRect(x: r - mw, y: 2, width: mw, height: 24); r -= mw + 4
        // Check out sits beside the menu, so a host action arriving on its left can't move another
        // action under the pointer (2994 PullRequestDetailPanel.tsx:2152-2154).
        if !checkout.isHidden {
            let cw = ceil(checkout.intrinsicContentSize.width)
            checkout.frame = NSRect(x: r - cw, y: 2, width: cw, height: 24); r -= cw + 4
        }
        if let primary {
            let pw = ceil(primary.intrinsicContentSize.width)
            let target = NSRect(x: r - pw, y: 2, width: pw, height: 24)
            if let from = primaryWidthFrom, from != pw, window != nil, !Motion.reduced {
                primary.frame = NSRect(x: r - from, y: 2, width: from, height: 24)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1) // Tailwind 4 `ease-out`
                    primary.animator().frame = target
                }
            } else {
                primary.frame = target
            }
            primaryWidthFrom = nil
            r -= pw + 4
        }
        if !stackMergeButton.isHidden {
            let sw = ceil(stackMergeButton.intrinsicContentSize.width)
            stackMergeButton.frame = NSRect(x: r - sw, y: 2, width: sw, height: 24); r -= sw + 4
        }
        if !stackButton.isHidden {
            let sw = ceil(stackButton.intrinsicContentSize.width)
            stackButton.frame = NSRect(x: r - sw, y: 2, width: sw, height: 24); r -= sw + 4
        }
        // The two top rows share the line: repository and number, or number and title while condensed.
        [repo, numberLink, numberIcon].forEach { $0.isHidden = condensed }
        [condensedNumber, condensedTitle].forEach { $0.isHidden = !condensed }
        let nw = ceil(numberLink.textWidth) + 1
        if condensed {
            condensedNumber.frame = NSRect(x: 16, y: 6, width: nw, height: 16)
            numberIcon.isHidden = false
            numberIcon.frame = NSRect(x: 16 + nw + 2, y: 9, width: 10, height: 10)
            let tx = 16 + nw + 2 + 10 + 4
            condensedTitle.frame = NSRect(x: tx, y: 6, width: max(0, r - 8 - tx), height: 16)
        } else {
            let repoWidth = min(ceil(repo.textWidth) + 1, max(0, r - 8 - 16 - nw - 2 - 10 - 4))
            repo.frame = NSRect(x: 16, y: 6, width: repoWidth, height: 16)
            numberLink.frame = NSRect(x: 16 + repoWidth + 4, y: 6, width: nw, height: 16)
            numberIcon.frame = NSRect(x: numberLink.frame.maxX + 2, y: 9, width: 10, height: 10)
        }
        // The fold (`mt-1 px-4 pb-4`), hidden while condensed.
        let fold: [NSView] = [titleLabel, titleEditButton, titleInput, titleCancel, titleSave, authorAvatar, authorLogin, dot, updated,
                              checkoutCommand, base, arrow, head, filesIcon, files, diffStat]
        let condensedRow: [NSView] = [condensedAvatar, condensedTime, condensedBase, condensedArrow, condensedHead, condensedFilesIcon,
                                      condensedFiles, condensedStat]
        for v in condensedRow { v.isHidden = !condensed }
        var y: CGFloat = 28 + 4
        if condensed {
            for v in fold { v.frame = .zero }
            layoutCondensedRow(y: 28 + 4, width: w)
            y = 28 + Self.condensedRowHeight
        } else {
            if titleDraft != nil {
                titleInput.frame = NSRect(x: 16, y: y, width: max(0, w - 32), height: 28)
                let sw = ceil(titleSave.intrinsicContentSize.width), cw = ceil(titleCancel.intrinsicContentSize.width)
                titleSave.frame = NSRect(x: w - 16 - sw, y: y + 36, width: sw, height: 24)
                titleCancel.frame = NSRect(x: w - 16 - sw - 8 - cw, y: y + 36, width: cw, height: 24)
                y += 28 + 8 + 24 + 8
            } else {
                let ew: CGFloat = titleEditButton.isHidden ? 0 : 24 + 4
                titleLabel.frame = NSRect(x: 16, y: y + 1, width: max(0, w - 32 - ew), height: 22)
                titleEditButton.frame = NSRect(x: w - 16 - 24, y: y, width: 24, height: 24)
                y += 24 + 8
            }
            authorAvatar.frame = NSRect(x: 16, y: y + 2, width: 16, height: 16)
            var x: CGFloat = 16 + 16 + 6
            let lw = ceil(authorLogin.textWidth) + 1
            authorLogin.frame = NSRect(x: x, y: y + 2, width: lw, height: 16); x += lw + 6
            dot.frame = NSRect(x: x, y: y + 2, width: ceil(dot.textWidth) + 1, height: 16); x += ceil(dot.textWidth) + 6
            let uw = ceil(updated.textWidth) + 1
            updated.frame = NSRect(x: x, y: y + 2, width: uw, height: 16); x += uw + 8
            if !checkoutCommand.isHidden {
                let cw = min(ceil(checkoutCommand.textWidth) + 9, max(0, w - 16 - x))
                checkoutCommand.frame = NSRect(x: w - 16 - cw, y: y, width: cw, height: 20)
                checkoutCommand.padding = 4
            }
            y += 20 + 16
            // `base ← head`, the files and the counts on the right.
            let dw = diffStat.width
            diffStat.frame = NSRect(x: w - 16 - dw, y: y + 2, width: dw, height: 16)
            var fr = w - 16 - dw - (dw > 0 ? 8 : 0)
            let fw = ceil(files.textWidth) + 1
            let filesBlock = max(64, 14 + 6 + fw)
            files.frame = NSRect(x: fr - fw, y: y + 2, width: fw, height: 16)
            filesIcon.frame = NSRect(x: fr - fw - 6 - 14, y: y + 3, width: 14, height: 14)
            fr -= filesBlock + 8
            let branchesWidth = max(0, fr - 16)
            let baseWidth = min(ceil(base.textWidth) + 1, branchesWidth * 0.4)
            base.frame = NSRect(x: 16, y: y + 2, width: baseWidth, height: 16)
            arrow.frame = NSRect(x: 16 + baseWidth + 6, y: y + 3, width: 14, height: 14)
            let hx = arrow.frame.maxX + 6 + 4 // `PullRequestCopyableCode` is `px-1`
            head.frame = NSRect(x: hx, y: y + 2, width: min(ceil(head.textWidth) + 1, max(0, 16 + branchesWidth - hx)), height: 16)
            y += 20 + 16
        }
        // Tab bar (`border-t border-border/60 px-4 py-2`).
        tabRule.frame = CGRect(x: 0, y: y, width: w, height: 1)
        y += 1 + 8
        let tw = tabs.intrinsicContentSize.width
        tabs.frame = NSRect(x: 16, y: y, width: tw, height: 28)
        let trailingX = 16 + tw + 8
        if tab == .summary {
            let cw = min(ceil(checksLabel.textWidth) + 1, max(0, w - 16 - trailingX - 20))
            checksLabel.frame = NSRect(x: w - 16 - cw, y: y + 6, width: cw, height: 16)
            checksIcon.frame = NSRect(x: w - 16 - cw - 6 - 14, y: y + 7, width: 14, height: 14)
        } else if tab == .timeline {
            let ow = ceil(orderButton.intrinsicContentSize.width)
            orderButton.frame = NSRect(x: w - 16 - ow, y: y + 2, width: ow, height: 24)
            let mw2 = ceil(timelineMeta.textWidth) + 1
            timelineMeta.frame = NSRect(x: w - 16 - ow - 8 - mw2, y: y + 6, width: mw2, height: 16)
        }
        headerRule.frame = CGRect(x: 0, y: hh, width: w, height: 1)
        let content = NSRect(x: 0, y: hh + 1, width: w, height: max(0, bounds.height - hh - 1))
        summary.frame = content
        timeline.frame = content
        code.frame = content
        composerButton.frame = NSRect(x: w - 16 - 32, y: bounds.height - 12 - 32, width: 32, height: 32)
        let bw = max(14, ceil(pendingBadge.textWidth) + 8)
        pendingBadge.frame = NSRect(x: composerButton.frame.maxX + 4 - bw, y: composerButton.frame.minY - 4, width: bw, height: 14)
    }

    /// The condensed row (`px-4 pb-2 pt-1 text-xs`): avatar and time, a rule, `base ← head` in
    /// `font-mono text-2xs`, then the files and counts in `text-2xs`.
    private func layoutCondensedRow(y: CGFloat, width w: CGFloat) {
        condensedAvatar.frame = NSRect(x: 16, y: y, width: 16, height: 16)
        let tw = ceil(condensedTime.textWidth) + 1
        condensedTime.frame = NSRect(x: 16 + 16 + 6, y: y, width: tw, height: 16)
        var r = w - 16
        let sw = condensedStat.width
        condensedStat.frame = NSRect(x: r - sw, y: y + 1, width: sw, height: 14); r -= sw + (sw > 0 ? 8 : 0)
        let fw = ceil(condensedFiles.textWidth) + 1
        condensedFiles.frame = NSRect(x: r - fw, y: y + 1, width: fw, height: 14)
        condensedFilesIcon.frame = NSRect(x: r - fw - 4 - 12, y: y + 2, width: 12, height: 12)
        r -= fw + 4 + 12 + 8
        var x = condensedTime.frame.maxX + 8 + 1 + 8
        let room = max(0, r - x)
        let bw = min(ceil(condensedBase.textWidth) + 1, room * 0.4)
        condensedBase.frame = NSRect(x: x, y: y + 1, width: bw, height: 14); x += bw + 6
        condensedArrow.frame = NSRect(x: x, y: y + 2, width: 12, height: 12); x += 12 + 6
        condensedHead.frame = NSRect(x: x, y: y + 1, width: max(0, min(ceil(condensedHead.textWidth) + 1, r - x)), height: 14)
        condensedRule.frame = CGRect(x: condensedTime.frame.maxX + 8, y: y + 2, width: 1, height: 12)
        condensedRule.isHidden = false
    }

    private func restyle() {
        repo.color = Themed.color(\.mutedForeground)
        titleLabel.color = Themed.color(\.foreground)
        authorLogin.color = Themed.color(\.foreground)
        dot.color = Themed.color(\.mutedForeground, 0.5)
        for l in [updated, files, checksLabel, timelineMeta] { l.color = Themed.color(\.mutedForeground) }
        checkoutCommand.color = Themed.color(\.mutedForeground)
        base.color = Themed.color(\.mutedForeground, 0.7)
        head.color = Themed.color(\.mutedForeground, 0.7)
        arrow.strokeColor = Themed.color(\.mutedForeground, 0.42)
        filesIcon.strokeColor = Themed.color(\.mutedForeground)
        condensedTitle.color = Themed.color(\.foreground)
        condensedTime.color = Themed.color(\.mutedForeground)
        for l in [condensedBase, condensedHead] { l.color = Themed.color(\.mutedForeground, 0.65) }
        condensedArrow.strokeColor = Themed.color(\.mutedForeground, 0.6)
        condensedFiles.color = Themed.color(\.mutedForeground)
        condensedFilesIcon.strokeColor = Themed.color(\.mutedForeground)
    }

    public override func updateLayer() {
        layer?.backgroundColor = WindowGlass.ground.cgColor(in: self)
        condensedRule.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
        pendingBadge.layer?.backgroundColor = Themed.color(\.info).cgColor(in: self)
        pendingBadge.color = .white
        tabRule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        headerRule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        restyle()
    }

    final class HeaderBox: DSView {}
}

/// A text button that underlines on hover (`underline-offset-2 hover:underline`), with an optional
/// context menu.
final class LinkLabel: DSView {
    private let label = LabelView()
    private var tracking: NSTrackingArea?
    // A padded label is `PullRequestCopyableCode` (:35): `transition-colors hover:bg-accent/45`, so its fill fades.
    private var hovered = false {
        didSet { label.isUnderlined = hovered && underlines; redisplay(transitioning: padding > 0 ? .background : []) }
    }
    var underlines = true
    var padding: CGFloat = 0 { didSet { needsLayout = true } }
    var text: String { get { label.text } set { label.text = newValue; needsLayout = true } }
    var font: NSFont { get { label.font } set { label.font = newValue } }
    var color: NSColor { get { label.color } set { label.color = newValue } }
    var textWidth: CGFloat { label.textWidth }
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        addSubview(label)
        setAccessibilityRole(.button)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: padding, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 2 * padding), height: 16)
        layer?.cornerRadius = 4
    }

    override func updateLayer() { Motion.setBackground(layer, hovered && padding > 0 ? Themed.color(\.accent, 0.45).cgColor(in: self) : nil) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The merged or closed state in the merge slot (`Badge size="control" variant="outline"` with the
/// state's glyph and word in its tone).
final class StateBadge: DSView {
    private let badge: BadgeView
    private let icon: IconView
    private let label: LabelView

    init(tone: PullRequestStateTone) {
        badge = BadgeView("", variant: .outline, size: .control)
        icon = IconView(name: PullRequestStyle.icon(tone), size: 14, strokeColor: PullRequestStyle.color(tone))
        label = LabelView(tone.label, font: DSFont.ui(12, weight: .medium), color: PullRequestStyle.color(tone))
        super.init(frame: .zero)
        label.lineHeight = 16
        [badge, icon, label].forEach(addSubview)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 8 + 14 + 4 + ceil(label.textWidth) + 8, height: 24) }
    override func layout() {
        super.layout()
        badge.frame = bounds
        icon.frame = NSRect(x: 8, y: 5, width: 14, height: 14)
        label.frame = NSRect(x: 26, y: 4, width: ceil(label.textWidth) + 1, height: 16)
    }
}

/// `PullRequestDetailGhost`: the panel's shape while the first read is on its way.
final class PullRequestDetailGhostView: DSView {
    private let bars = (0..<9).map { _ in SkeletonView(shape: .pill) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bars.forEach(addSubview)
        setAccessibilityLabel("Loading pull request")
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        let specs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (16, 8, 140, 12), (16, 36, w * 0.6, 18), (16, 66, 180, 12), (16, 102, w * 0.45, 12),
            (16, 145, 200, 24), (16, 196, 120, 12), (16, 222, w - 32, 12), (16, 244, w * 0.7, 12), (16, 266, w * 0.5, 12),
        ]
        for (bar, s) in zip(bars, specs) { bar.frame = NSRect(x: s.0, y: s.1, width: max(0, s.2), height: s.3) }
    }
}
