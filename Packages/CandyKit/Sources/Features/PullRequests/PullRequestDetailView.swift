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
    public private(set) var detail: PullRequestDetail?
    public var activityPending = true { didSet { if activityPending != oldValue { rebuildTabs() } } }
    public var activityError: String? { didSet { if activityError != oldValue { rebuildTabs() } } }
    public var tab: Tab = .summary { didSet { if tab != oldValue { tabs.selectedIndex = tab.rawValue; showTab() } } }
    public var refreshing = false { didSet { more.icon = refreshing ? .refreshCw : .ellipsis } }
    public var actionPending = false { didSet { rebuildActions() } }
    public var nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) { didSet { rebuild() } }
    /// The merge method the reader last picked (`pullRequestMergeMethod` in the UI state store).
    public var preferredMergeMethod = "merge" { didSet { rebuildActions() } }

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
    public var onReview: ((_ verdict: String, _ body: String) -> Void)?
    /// The Code tab asked for a scope: nil is all commits.
    public var onCommit: ((String?) -> Void)?
    public var onSetViewed: ((_ path: String, _ viewed: Bool) -> Void)?

    // Header.
    private let headerBox = HeaderBox()
    private let repo = LinkLabel()
    private let numberLink = LinkLabel()
    private let numberIcon = IconView(name: .externalLink, size: 10)
    private let checkout = ButtonView("Check out", icon: .gitBranch, variant: .outline, size: .xs)
    private var primary: NSView?
    let more = ButtonView(nil, icon: .ellipsis, variant: .ghostMuted, size: .iconXs)
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

    // Content.
    let summary = PullRequestSummaryView()
    let timeline = PullRequestTimelineView()
    let code = PullRequestCodeView()
    private var ghost: PullRequestDetailGhostView?
    private var failure: EmptyView?
    private let composerButton = ButtonView(nil, icon: .messageSquare, variant: .glass, size: .icon)

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
        for l in [tabRule, headerRule] { l.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]; headerBox.layer?.addSublayer(l) }
        [summary, timeline, code].forEach(addSubview)
        addSubview(composerButton)
        composerButton.setAccessibilityLabel("Comment on pull request")
        composerButton.action = { [weak self] in self?.showComposer() }
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

    public func showFailure(title: String, message: String) {
        phase = .failed(title: title, message: message)
        detail = nil
        rebuild()
    }

    public func show(_ detail: PullRequestDetail) {
        let sameIdentity = self.detail?.url == detail.url
        self.detail = detail
        phase = .loaded
        if !sameIdentity { code.reset() }
        rebuild()
    }

    /// The Code tab's patch, or its state.
    public func setPatch(_ patch: String?, loading: Bool, error: String?, commit: String?) {
        code.set(patch: patch, loading: loading, error: error, commit: commit, commits: detail?.commits ?? [])
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
            let retry = ButtonView("Retry", icon: .refreshCw, variant: .outline, size: .sm)
            retry.action = { [weak self] in self?.onRetry?() }
            e.content = ButtonRow([retry])
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
        primary?.removeFromSuperview()
        primary = nil
        guard let d = detail else { return }
        let allowed = PullRequestDetailLogic.allowedMergeMethods(d)
        let method = PullRequestDetailLogic.selectedMergeMethod(allowed, preferred: preferredMergeMethod)
        switch PullRequestDetailLogic.primaryControl(d) {
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
            let b = ButtonView(actionPending ? "Enabling..." : "Auto-merge (\(PullRequestDetailLogic.mergeMethodLabel(method).lowercased()))",
                               icon: .gitMerge, variant: .default, size: .xs)
            b.iconSize = 14
            b.isEnabled = !actionPending
            b.action = { [weak self] in self?.confirm("enable-auto-merge", method: method) }
            primary = b
        case "auto-merge-armed":
            let label = d.autoMergeMethod.map { "Auto-merge (\(PullRequestDetailLogic.mergeMethodLabel($0).lowercased()))" } ?? "Auto-merge"
            let badge = BadgeView(label, variant: .info, size: .control, icon: .gitMerge)
            badge.toolTip = "\(label): the host will merge this on its own once its requirements are met"
            primary = badge
        case "merge":
            let b = ButtonView(actionPending ? "Merging..." : PullRequestDetailLogic.mergeMethodLabel(method), icon: .gitMerge, variant: .default, size: .xs)
            b.iconSize = 14
            b.isEnabled = !actionPending
            b.action = { [weak self] in self?.confirm("merge", method: method) }
            primary = b
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

    /// The confirmation T3 asks before merging, auto-merging, reverting or closing.
    private func confirm(_ action: String, method: String? = nil) {
        guard let d = detail, let window else { return }
        let methodLabel = PullRequestDetailLogic.mergeMethodLabel(method ?? "merge")
        let (title, message, button): (String, String, String) = switch action {
        case "merge": ("Merge pull request?", "This merges #\(d.number) using \(method ?? "merge").", methodLabel)
        case "enable-auto-merge": ("Enable auto-merge?", "This merges #\(d.number) using \(method ?? "merge") as soon as the host considers it ready, which may be immediately.", "Enable auto-merge")
        case "revert": ("Revert these changes?", "This opens a new pull request that reverses the changes merged by #\(d.number).", "Create revert PR")
        default: ("Close pull request?", "This closes #\(d.number) without merging it.", "Close")
        }
        let dialog = DialogView(kind: .alertDialog, title: title, message: message)
        let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
        let go = ButtonView(button, variant: action == "close" ? .destructive : .default, size: .sm)
        dialog.footerButtons = [cancel, go]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { host.close() }
        go.action = { [weak self] in host.close(); self?.onAction?(action, method) }
    }

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
            let method = PullRequestDetailLogic.selectedMergeMethod(allowed, preferred: preferredMergeMethod)
            let showsMergeNow = (primaryControl == "enable-auto-merge" || primaryControl == "auto-merge-armed") && can("merge") && !d.isDraft && !conflicting && !allowed.isEmpty
            if showsMergeNow {
                var item = MenuItem("Merge now", icon: .gitMerge, disabled: actionPending)
                item.action = { [weak self] in self?.confirm("merge", method: method) }
                items.append(item)
            }
            let armed = d.autoMergeEnabled == true
            let showsAutoMerge = (armed && can("disable-auto-merge"))
                || (!armed && primaryControl != "enable-auto-merge" && !d.isDraft && !conflicting && can("enable-auto-merge") && !allowed.isEmpty)
            if armed && can("disable-auto-merge") {
                var item = MenuItem("Disable auto-merge", icon: .gitMerge, disabled: actionPending)
                item.action = { [weak self] in self?.onAction?("disable-auto-merge", nil) }
                items.append(item)
            } else if showsAutoMerge {
                var item = MenuItem("Enable auto-merge", icon: .gitMerge, disabled: actionPending)
                item.action = { [weak self] in self?.confirm("enable-auto-merge", method: method) }
                items.append(item)
            }
            let showsMethods = can("merge") && !d.isDraft && !conflicting && allowed.count > 1
            if showsMethods {
                if showsDraftToggle || showsMergeNow || showsAutoMerge { items.append(.separator) }
                for m in allowed {
                    var item = MenuItem.radio(PullRequestDetailLogic.mergeMethodLabel(m), checked: m == method) { [weak self] _ in
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
            var close = MenuItem("Close pull request", icon: .gitPullRequestClosed, destructive: true, disabled: actionPending)
            close.action = { [weak self] in self?.confirm("close") }
            items += [.separator, close]
        } else if d.state == "closed" && can("reopen") {
            var reopen = MenuItem("Reopen pull request", icon: .gitPullRequestArrow, disabled: actionPending)
            reopen.action = { [weak self] in self?.onAction?("reopen", nil) }
            items += [.separator, reopen]
        } else if d.state == "merged" && can("revert") {
            var revert = MenuItem("Revert changes", icon: .rotateCcw, disabled: actionPending)
            revert.action = { [weak self] in self?.confirm("revert") }
            items += [.separator, revert]
        }
        MenuPopupView.show(items, from: more, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    /// `PullRequestComposer`: Comment, or Review with a verdict, in a popover over the glass button.
    private func showComposer() {
        guard let d = detail else { return }
        let canComment = d.capabilities.comment && d.viewerPermissions.comment
        let verdicts = d.capabilities.review.verdicts.filter { d.viewerPermissions.verdicts.contains($0) }
        let form = PullRequestComposerForm(canComment: canComment, verdicts: verdicts, forgejo: d.provider == "forgejo")
        let popover = PopoverView(content: form, width: .lg)
        let open = popover.show(from: composerButton, placement: PopupPlacement(side: .top, align: .end, sideOffset: 8, fallbackAxisSide: .none))
        form.onComment = { [weak self] body in if let open { self?.composerButton.popupHost?.close(open) }; self?.onComment?(body) }
        form.onReview = { [weak self] verdict, body in if let open { self?.composerButton.popupHost?.close(open) }; self?.onReview?(verdict, body) }
        form.onClose = { [weak self] in if let open { self?.composerButton.popupHost?.close(open) } }
    }

    // MARK: Layout

    /// The header's height: the 28pt top row, the title block and the tab bar.
    public static let headerHeight: CGFloat = 28 + 4 + 24 + 8 + 20 + 16 + 20 + 16 + 1 + 44

    public override func layout() {
        super.layout()
        let w = bounds.width
        ghost?.frame = bounds
        failure?.frame = bounds
        guard phase == .loaded else { return }
        let hh = Self.headerHeight
        headerBox.frame = NSRect(x: 0, y: 0, width: w, height: hh + 1)
        // Top row (`h-7`, `pl-4`, actions `mr-4 gap-1`).
        var r = w - 16
        let mw: CGFloat = 24
        more.frame = NSRect(x: r - mw, y: 2, width: mw, height: 24); r -= mw + 4
        if let primary {
            let pw = ceil(primary.intrinsicContentSize.width)
            primary.frame = NSRect(x: r - pw, y: 2, width: pw, height: 24); r -= pw + 4
        }
        if !checkout.isHidden {
            let cw = ceil(checkout.intrinsicContentSize.width)
            checkout.frame = NSRect(x: r - cw, y: 2, width: cw, height: 24); r -= cw + 4
        }
        let nw = ceil(numberLink.textWidth) + 1
        let repoWidth = min(ceil(repo.textWidth) + 1, max(0, r - 8 - 16 - nw - 2 - 10 - 4))
        repo.frame = NSRect(x: 16, y: 6, width: repoWidth, height: 16)
        numberLink.frame = NSRect(x: 16 + repoWidth + 4, y: 6, width: nw, height: 16)
        numberIcon.frame = NSRect(x: numberLink.frame.maxX + 2, y: 9, width: 10, height: 10)
        // Body (`mt-1 px-4 pb-4`).
        var y: CGFloat = 28 + 4
        titleLabel.frame = NSRect(x: 16, y: y + 1, width: max(0, w - 32), height: 22)
        y += 24 + 8
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
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
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
    private var hovered = false { didSet { label.isUnderlined = hovered && underlines; needsDisplay = true } }
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

    override func updateLayer() { layer?.backgroundColor = hovered && padding > 0 ? Themed.color(\.accent, 0.45).cgColor(in: self) : nil }
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

/// The composer popover (PullRequestComposer.tsx, PullRequestCommentForm.tsx, PullRequestReviewForm.tsx).
final class PullRequestComposerForm: DSView {
    private let mode: ToggleGroupView?
    private let titleLabel: LabelView?
    private let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    private let comment = TextareaView(placeholder: "Leave a comment", size: .sm)
    private let review = TextareaView(placeholder: "Summarize your review (optional)", size: .sm)
    private let verdict: ToggleGroupView?
    private let submitComment = ButtonView("Comment", variant: .default, size: .sm)
    private let submitReview = ButtonView("Submit review", variant: .default, size: .sm)
    private let verdicts: [String]
    private let forgejo: Bool
    private var reviewing: Bool
    var onComment: ((String) -> Void)?
    var onReview: ((String, String) -> Void)?
    var onClose: (() -> Void)?

    init(canComment: Bool, verdicts: [String], forgejo: Bool) {
        self.verdicts = verdicts
        self.forgejo = forgejo
        reviewing = !canComment
        mode = canComment && !verdicts.isEmpty ? ToggleGroupView(variant: .segmented, items: [("Comment", nil), ("Review", nil)], selected: 0) : nil
        titleLabel = mode == nil ? LabelView(reviewing ? "Review pull request" : "Comment on pull request", font: DSFont.ui(14, weight: .semibold)) : nil
        let labels = verdicts.map { $0 == "approve" ? "Approve" : $0 == "request-changes" ? "Request changes" : "Comment" }
        verdict = verdicts.isEmpty ? nil : ToggleGroupView(variant: .segmented, items: labels.map { ($0, nil) }, selected: 0)
        super.init(frame: NSRect(x: 0, y: 0, width: 352, height: 200))
        [mode, titleLabel, close, comment, review, verdict, submitComment, submitReview].compactMap { $0 }.forEach(addSubview)
        titleLabel?.lineHeight = 20
        close.iconSize = 14
        close.setAccessibilityLabel("Close composer")
        close.action = { [weak self] in self?.onClose?() }
        mode?.onChange = { [weak self] i in self?.reviewing = i == 1; self?.update() }
        verdict?.onChange = { [weak self] _ in self?.update() }
        comment.onChange = { [weak self] _ in self?.update() }
        review.onChange = { [weak self] _ in self?.update() }
        submitComment.action = { [weak self] in
            guard let self else { return }
            let body = self.comment.text
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.onComment?(body) }
        }
        submitReview.action = { [weak self] in
            guard let self, let v = self.selectedVerdict else { return }
            self.onReview?(v, self.review.text)
        }
        update()
    }

    private var selectedVerdict: String? { verdict?.selectedIndex.flatMap { verdicts.indices.contains($0) ? verdicts[$0] : nil } }

    private func update() {
        comment.isHidden = reviewing
        submitComment.isHidden = reviewing
        review.isHidden = !reviewing
        verdict?.isHidden = !reviewing
        submitReview.isHidden = !reviewing
        submitComment.isEnabled = !comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsSummary = selectedVerdict == "request-changes" && forgejo
        review.placeholder = needsSummary ? "Summarize your review (required to request changes)" : "Summarize your review (optional)"
        submitReview.isEnabled = !(needsSummary && review.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 352, height: 24 + 12 + 96 + 8 + 28) }

    override func layout() {
        super.layout()
        let w = bounds.width
        if let mode { mode.frame = NSRect(x: 0, y: 0, width: mode.intrinsicContentSize.width, height: 24) }
        titleLabel?.frame = NSRect(x: 0, y: 2, width: w - 32, height: 20)
        close.frame = NSRect(x: w - 24, y: 0, width: 24, height: 24)
        let area = NSRect(x: 0, y: 36, width: w, height: 96)
        comment.frame = area
        review.frame = area
        let y = area.maxY + 8
        let sw = ceil(submitComment.intrinsicContentSize.width)
        submitComment.frame = NSRect(x: w - sw, y: y, width: sw, height: 28)
        let rw = ceil(submitReview.intrinsicContentSize.width)
        submitReview.frame = NSRect(x: w - rw, y: y, width: rw, height: 28)
        if let verdict { verdict.frame = NSRect(x: 0, y: y + 2, width: verdict.intrinsicContentSize.width, height: 24) }
    }

    override func updateLayer() { titleLabel?.color = Themed.color(\.popoverForeground) }
}
