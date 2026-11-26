import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The issue panel (4928 apps/web/src/components/issue/IssueDetailPanel.tsx:379-888): the title
/// block with the state control and thread links, Labels and Assignees, then Description, Linked
/// pull requests and Activity sections, and the floating comment composer. Built on the pull
/// request panel's pieces, as T3 builds it on `PullRequestSection`, `PullRequestMetaRow` and
/// `PullRequestCommentBody`.
public final class IssueDetailView: DSView {
    /// What the panel shows (IssueDetailPanel.tsx:416-427).
    public enum Phase: Equatable, Sendable {
        /// `IssueDetailGhost`, seeded by the list row when there is one.
        case loading(seed: IssueListEntry?)
        /// "Could not load this issue" with Retry.
        case failed(String)
        case loaded
    }

    /// Everything the loaded panel draws.
    public struct Model: Equatable, Sendable {
        public var detail: IssueDetail
        public var access: IssueListLogic.Access
        /// `prependIssueComments` over the detail's newest page.
        public var comments: [IssueComment]
        public var nextCursor: String?
        public var loadingOlder = false
        public var refreshing = false
        /// "Could not refresh this issue" (#38537); the loaded issue stays.
        public var refreshError: String?
        public var changingState = false
        public var saving = false
        /// `IssueThreadLinks`: linked here (nil when the panel stands beside no thread), the linked
        /// thread count (nil while unknown, shown "?" after a failed read), and the link button.
        public var linkedHere: Bool?
        public var linkedThreadCount: Int?
        public var linkedThreadsFailed = false
        public var canLink = true
        public var linkPending = false
        public var cwd: String?
        public var nowMs: Int64 = 0
        public init(detail: IssueDetail, access: IssueListLogic.Access) {
            self.detail = detail; self.access = access; comments = detail.comments; nextCursor = detail.commentsCursor
        }
    }

    public private(set) var phase: Phase = .loading(seed: nil)
    public private(set) var model: Model?

    public var onRetry: (() -> Void)?
    public var onRefresh: (() -> Void)?
    public var onOpenURL: ((String) -> Void)?
    public var onSetState: ((String) -> Void)?
    public var onSaveTitle: ((String) -> Void)?
    public var onSaveBody: ((String) -> Void)?
    public var onPickLabels: ((NSView) -> Void)?
    public var onPickAssignees: ((NSView) -> Void)?
    /// (comment id or nil for the issue, content, reacted, the bar to tell of a refusal).
    public var onReact: ((String?, String, Bool, PullRequestReactionBarView) -> Void)?
    public var onLoadOlder: (() -> Void)?
    public var onComment: ((String) -> Void)?
    public var onToggleLink: (() -> Void)?
    public var onShowLinkedThreads: (() -> Void)?
    public var onOpenPullRequest: ((IssueLinkedPullRequest) -> Void)?

    private let stack = StackScrollView()
    private let header = IssueHeaderItem()
    private let descriptionSection = SectionItem(title: "Description")
    private let descriptionItem = IssueDescriptionItem()
    private let linkedSection = SectionItem(title: "Linked pull requests")
    private let linkedList = IssueLinkedPullRequestsItem()
    private let activitySection = SectionItem(title: "Activity")
    private let activity = IssueActivityItem()
    public let composer = IssueCommentComposerView()
    private var ghost: IssueDetailGhostView?
    private var failure: EmptyView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(stack)
        addSubview(composer)
        descriptionSection.body = descriptionItem
        linkedSection.body = linkedList
        activitySection.body = activity
        for s in [descriptionSection, linkedSection, activitySection] { s.onToggle = { [weak self] in self?.stack.reload() } }
        stack.document.items = [header, descriptionSection, linkedSection, activitySection]
        descriptionItem.onResize = { [weak self] in self?.stack.reload() }
        header.onResize = { [weak self] in self?.stack.reload() }
        activity.onResize = { [weak self] in self?.stack.reload() }
        header.onRefresh = { [weak self] in self?.onRefresh?() }
        header.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        header.onSetState = { [weak self] s in self?.onSetState?(s) }
        header.onSaveTitle = { [weak self] t in self?.onSaveTitle?(t) }
        header.onPickLabels = { [weak self] v in self?.onPickLabels?(v) }
        header.onPickAssignees = { [weak self] v in self?.onPickAssignees?(v) }
        header.onToggleLink = { [weak self] in self?.onToggleLink?() }
        header.onShowLinkedThreads = { [weak self] in self?.onShowLinkedThreads?() }
        descriptionItem.onSave = { [weak self] body in self?.onSaveBody?(body) }
        descriptionItem.reactionBar.onToggle = { [weak self] content, reacted in
            guard let self else { return }
            self.onReact?(nil, content, reacted, self.descriptionItem.reactionBar)
        }
        linkedList.onSelect = { [weak self] pr in self?.onOpenPullRequest?(pr) }
        activity.onLoadOlder = { [weak self] in self?.onLoadOlder?() }
        activity.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        activity.onReact = { [weak self] id, content, reacted, bar in self?.onReact?(id, content, reacted, bar) }
        composer.onSubmit = { [weak self] text in self?.onComment?(text) }
        showLoading(seed: nil)
    }

    public func showLoading(seed: IssueListEntry?) {
        phase = .loading(seed: seed)
        model = nil
        failure?.removeFromSuperview(); failure = nil
        if ghost == nil { let g = IssueDetailGhostView(); addSubview(g); ghost = g }
        ghost?.seed = seed
        stack.isHidden = true
        composer.isHidden = true
        needsLayout = true
    }

    public func showFailure(_ message: String) {
        phase = .failed(message)
        model = nil
        ghost?.removeFromSuperview(); ghost = nil
        failure?.removeFromSuperview()
        let empty = EmptyView(title: "Could not load this issue", message: message, icon: .circleDot)
        let retry = ButtonView("Retry", icon: .refreshCw, variant: .outline, size: .sm)
        retry.action = { [weak self] in self?.onRetry?() }
        empty.content = ButtonRow([retry])
        addSubview(empty)
        failure = empty
        stack.isHidden = true
        composer.isHidden = true
        needsLayout = true
    }

    public func show(_ m: Model) {
        let issueChanged = model?.detail.url != m.detail.url
        phase = .loaded
        model = m
        ghost?.removeFromSuperview(); ghost = nil
        failure?.removeFromSuperview(); failure = nil
        stack.isHidden = false
        header.set(m)
        descriptionItem.set(m)
        linkedSection.isHidden = m.detail.linkedPullRequests.isEmpty
        linkedList.set(m.detail.linkedPullRequests, scope: m.detail.scope)
        activitySection.title = m.detail.commentCount > 0 ? "Activity (\(m.detail.commentCount))" : "Activity"
        activity.set(m)
        composer.isHidden = !m.detail.capabilities.comment
        composer.blocked = m.access.comment ? nil : (m.access.blocked ?? "You cannot comment here.")
        if issueChanged { composer.clear() }
        // Room for the floating composer, so the last comment scrolls clear of it (`pb-32`).
        stack.document.insets = NSEdgeInsets(top: 0, left: 0, bottom: m.detail.capabilities.comment ? 128 : 16, right: 0)
        stack.reload()
        needsLayout = true
    }

    /// The comment posted: the box empties (IssueCommentComposer.tsx:57).
    public func commentPosted() { composer.clear() }
    public func commentFailed() { composer.submitting = false }
    public func finishTitleEdit() { header.stopEditing() }
    public func finishBodyEdit() { descriptionItem.stopEditing(); stack.reload() }

    public override func layout() {
        super.layout()
        stack.frame = bounds
        ghost?.frame = bounds
        failure?.frame = bounds
        // `absolute inset-x-0 bottom-0 px-3` over the chat composer's bottom inset, `sm:h-[calc(env(safe-area-inset-bottom)+1.25rem)]`,
        // so the two cards line up side by side (#39994, IssueCommentComposer.tsx at 5258).
        let ch = composer.height(forWidth: bounds.width - 24)
        composer.frame = NSRect(x: 12, y: bounds.height - 20 - ch, width: max(0, bounds.width - 24), height: ch)
    }
}

// MARK: - Header

/// The `px-4 pb-1` block: scope, key, state control, thread links and refresh; the refresh alert;
/// the title or its editor; the meta line; Labels and Assignees (IssueDetailPanel.tsx:550-724).
final class IssueHeaderItem: DSView, StackItem, FocusWithinObserver {
    private let scope = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let keyButton = IssueKeyLinkView()
    private let stateButton = ButtonView("", icon: .circleDot, variant: .outline, size: .xs).menuTrigger()
    private let stateLabel = LabelView("", font: DSFont.ui(12, weight: .medium))
    private var stateIcon = IconView(name: .circleDot, size: 14)
    private let threadsButton = ButtonView("", icon: .messageSquare, variant: .ghost, size: .xs)
    private let linkButton = ButtonView(nil, icon: .link2, variant: .ghost, size: .iconXs)
    private let refreshButton = ButtonView(nil, icon: .refreshCw, variant: .ghost, size: .iconXs)
    private var alert: AlertView?
    private let title = TextBlockView()
    private let editButton = ButtonView(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs)
    private var hover: HoverGroup?
    private var focusWithin = false
    func focusWithinChanged(_ focused: Bool) { focusWithin = focused; revealEdit() }
    private func revealEdit() { HoverReveal.fade([editButton], visible: hover?.hovered == true || focusWithin) }
    private let titleInput = InputView(placeholder: "", size: .sm)
    private let saveButton = ButtonView("Save", variant: .default, size: .sm)
    private let cancelButton = ButtonView("Cancel", variant: .outline, size: .sm)
    private(set) var editing = false
    private let authorAvatar = PullRequestAvatarView()
    private let meta = LabelView("", font: DSFont.ui(12))
    private let labelsRow = IssueMetaRow(icon: .tag, label: "Labels")
    private let assigneesRow = IssueMetaRow(icon: .users, label: "Assignees")
    private var model: IssueDetailView.Model?
    var onRefresh: (() -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onSetState: ((String) -> Void)?
    var onSaveTitle: ((String) -> Void)?
    var onPickLabels: ((NSView) -> Void)?
    var onPickAssignees: ((NSView) -> Void)?
    var onToggleLink: (() -> Void)?
    var onShowLinkedThreads: (() -> Void)?
    var onResize: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scope.lineHeight = 16
        stateLabel.lineHeight = 16
        meta.lineHeight = 16
        title.font = DSFont.ui(16, weight: .semibold)
        title.lineHeight = 22 // `text-base leading-snug`
        [scope, keyButton, stateButton, stateLabel, stateIcon, threadsButton, linkButton, refreshButton, title, editButton,
         authorAvatar, meta, labelsRow, assigneesRow].forEach(addSubview)
        for b in [linkButton, refreshButton] { b.iconSize = 14 }
        threadsButton.iconSize = 14
        stateButton.iconSize = 14
        refreshButton.setAccessibilityLabel("Refresh issue")
        refreshButton.setTooltip("Refresh issue")
        refreshButton.action = { [weak self] in self?.onRefresh?() }
        keyButton.action = { [weak self] in if let url = self?.model?.detail.url { self?.onOpenURL?(url) } }
        stateButton.action = { [weak self] in self?.showStateMenu() }
        linkButton.action = { [weak self] in self?.onToggleLink?() }
        threadsButton.action = { [weak self] in self?.onShowLinkedThreads?() }
        editButton.iconSize = 12
        editButton.setAccessibilityLabel("Edit title")
        editButton.alphaValue = 0
        editButton.action = { [weak self] in self?.startEditing() }
        hover = HoverGroup(self) { [weak self] _ in self?.revealEdit() }
        titleInput.setAccessibilityLabel("Issue title")
        titleInput.onSubmit = { [weak self] in self?.submitTitle() }
        titleInput.onCommand = { [weak self] sel in
            guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
            self?.stopEditing()
            return true
        }
        saveButton.action = { [weak self] in self?.submitTitle() }
        cancelButton.action = { [weak self] in self?.stopEditing() }
        labelsRow.onPick = { [weak self] v in self?.onPickLabels?(v) }
        assigneesRow.onPick = { [weak self] v in self?.onPickAssignees?(v) }
        labelsRow.pickLabel = "Change labels"
        assigneesRow.pickLabel = "Change assignees"
    }

    func set(_ m: IssueDetailView.Model) {
        let changed = model?.detail.url != m.detail.url
        model = m
        let d = m.detail
        if changed && editing { stopEditing() }
        scope.text = d.scope
        keyButton.set(text: d.displayKey, color: IssueListLogic.color(d.state))
        keyButton.setAccessibilityLabel("Open \(d.displayKey) on \(IssueListLogic.providerName(d.tracker))")
        // The state control: a menu of the other states, or a plain label (IssueDetailPanel.tsx:500-546).
        let movable = !m.access.states.isEmpty
        stateButton.isHidden = !movable
        stateLabel.isHidden = movable
        stateIcon.isHidden = movable
        stateButton.title = d.state.name
        stateButton.icon = IssueListLogic.icon(d.state)
        stateButton.iconColor = IssueListLogic.color(d.state)
        stateButton.trailingIcon = .chevronDown
        stateButton.isEnabled = !m.changingState
        stateButton.setAccessibilityLabel("Issue state, \(d.state.name)")
        stateLabel.text = d.state.name
        stateIcon.removeFromSuperview()
        stateIcon = IconView(name: IssueListLogic.icon(d.state), size: 14, strokeColor: IssueListLogic.color(d.state))
        stateIcon.isHidden = movable
        addSubview(stateIcon)
        // `IssueThreadLinks` (IssueThreadLinks.tsx:118-176).
        let count = m.linkedThreadCount ?? 0
        threadsButton.isHidden = !(count > 0 || (m.linkedThreadCount == nil && m.linkedThreadsFailed))
        threadsButton.title = count > 0 ? "\(count)" : "?"
        let threadsLabel = count > 0 ? (count == 1 ? "Linked from 1 thread" : "Linked from \(count) threads") : "Linked threads"
        threadsButton.setAccessibilityLabel(threadsLabel)
        threadsButton.setTooltip("\(threadsLabel). Search in the command palette.")
        linkButton.isHidden = !m.canLink
        linkButton.isEnabled = !m.linkPending
        let linked = m.linkedHere == true
        linkButton.icon = linked ? .link2Off : .link2
        linkButton.setAccessibilityLabel(linked ? "Unlink from thread" : "Link to thread")
        linkButton.setTooltip(linked ? "Unlink from this thread" : m.linkedHere == nil ? "Link to thread" : "Link to this thread")
        refreshButton.isEnabled = !m.refreshing
        if let error = m.refreshError {
            if alert == nil { let a = AlertView("Could not refresh this issue", variant: .error); addSubview(a); alert = a }
            alert?.message = error
        } else { alert?.removeFromSuperview(); alert = nil }
        title.text = d.title
        editButton.isHidden = !m.access.edit
        authorAvatar.actor = d.author
        var parts = ["\(d.author?.login ?? "ghost")", "opened \(TimestampFormat.formatRelativeTimeLabel(d.createdAt, nowMs: m.nowMs))"]
        if let closed = d.closedAt { parts.append("closed \(TimestampFormat.formatRelativeTimeLabel(closed, nowMs: m.nowMs))") }
        if !d.writable { parts.append("Read-only") }
        meta.text = parts.joined(separator: "  ")
        labelsRow.set(labels: d.labels, picker: d.capabilities.labels, allowed: m.access.labels,
                      reason: m.access.blocked ?? "Changing labels needs triage access on this tracker.")
        assigneesRow.set(actors: d.assignees, picker: d.capabilities.assignees, allowed: m.access.assignees,
                         reason: m.access.blocked ?? "Changing assignees needs triage access on this tracker.")
        titleInput.isEnabled = !m.saving
        saveButton.isEnabled = !m.saving
        cancelButton.isEnabled = !m.saving
        needsLayout = true
    }

    private func showStateMenu() {
        guard let m = model else { return }
        let items = m.access.states.map { s -> MenuItem in
            var item = MenuItem(s.name, icon: IssueListLogic.icon(s))
            item.iconColor = IssueListLogic.color(s)
            item.action = { [weak self] in self?.onSetState?(s.name) }
            return item
        }
        MenuPopupView.show(items, from: stateButton, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    private func startEditing() {
        guard let m = model else { return }
        editing = true
        titleInput.text = m.detail.title
        [titleInput, saveButton, cancelButton].forEach(addSubview)
        title.isHidden = true
        editButton.isHidden = true
        onResize?()
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self?.titleInput) }
    }

    func stopEditing() {
        guard editing else { return }
        editing = false
        [titleInput, saveButton, cancelButton].forEach { $0.removeFromSuperview() }
        title.isHidden = false
        editButton.isHidden = !(model?.access.edit ?? false)
        onResize?()
    }

    /// A blank or unchanged title just closes the editor (IssueDetailPanel.tsx:603-607).
    private func submitTitle() {
        let next = titleInput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !next.isEmpty, next != model?.detail.title { onSaveTitle?(next) } else { stopEditing() }
    }

    private var alertHeight: CGFloat { alert.map { 8 + $0.height(forWidth: bounds.width - 32) } ?? 0 }

    private func titleHeight(_ width: CGFloat) -> CGFloat {
        editing ? 32 : max(22, title.height(forWidth: width - 32 - (editButton.isHidden ? 0 : 28)))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let alertH = alert.map { 8 + $0.height(forWidth: width - 32) } ?? 0
        // Row 28, alert, `mt-1` title, `mt-2 min-h-5` meta, `mt-4` rows of 24 with `space-y-2`, `pb-1`.
        return 28 + alertH + 4 + titleHeight(width) + 8 + 20 + 16 + 24 + 8 + 24 + 4
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        var r = w - 16
        refreshButton.frame = NSRect(x: r - 24, y: 2, width: 24, height: 24); r -= 24 + 4
        if !linkButton.isHidden { linkButton.frame = NSRect(x: r - 24, y: 2, width: 24, height: 24); r -= 24 + 4 }
        if !threadsButton.isHidden {
            let tw = ceil(threadsButton.intrinsicContentSize.width)
            threadsButton.frame = NSRect(x: r - tw, y: 2, width: tw, height: 24); r -= tw + 4
        }
        if !stateButton.isHidden {
            let sw = ceil(stateButton.intrinsicContentSize.width)
            stateButton.frame = NSRect(x: r - sw, y: 2, width: sw, height: 24); r -= sw + 4
        } else {
            let lw = ceil(stateLabel.textWidth) + 1
            stateLabel.frame = NSRect(x: r - lw, y: 6, width: lw, height: 16)
            stateIcon.frame = NSRect(x: r - lw - 4 - 14, y: 7, width: 14, height: 14)
            r -= lw + 18 + 4
        }
        let kw = keyButton.preferredWidth
        let sw = min(ceil(scope.textWidth) + 1, max(0, r - 16 - kw - 4))
        scope.frame = NSRect(x: 16, y: 6, width: sw, height: 16)
        keyButton.frame = NSRect(x: 16 + sw + 4, y: 6, width: kw, height: 16)
        var y: CGFloat = 28
        if let alert {
            let ah = alert.height(forWidth: w - 32)
            alert.frame = NSRect(x: 16, y: y + 8, width: w - 32, height: ah)
            y += 8 + ah
        }
        y += 4
        let th = titleHeight(w)
        if editing {
            let bw = ceil(saveButton.intrinsicContentSize.width), cw = ceil(cancelButton.intrinsicContentSize.width)
            cancelButton.frame = NSRect(x: w - 16 - cw, y: y, width: cw, height: 32)
            saveButton.frame = NSRect(x: w - 16 - cw - 8 - bw, y: y, width: bw, height: 32)
            titleInput.frame = NSRect(x: 16, y: y, width: max(0, w - 32 - cw - bw - 16), height: 32)
        } else {
            let tw = w - 32 - (editButton.isHidden ? 0 : 28)
            title.frame = NSRect(x: 16, y: y, width: tw, height: th)
            editButton.frame = NSRect(x: w - 16 - 24, y: y - 1, width: 24, height: 24)
        }
        y += th + 8
        authorAvatar.frame = NSRect(x: 16, y: y + 2, width: 16, height: 16)
        meta.frame = NSRect(x: 16 + 16 + 6, y: y + 2, width: max(0, w - 32 - 22), height: 16)
        y += 20 + 16
        labelsRow.frame = NSRect(x: 16, y: y, width: w - 32, height: 24)
        y += 24 + 8
        assigneesRow.frame = NSRect(x: 16, y: y, width: w - 32, height: 24)
    }

    override func updateLayer() {
        scope.color = Themed.color(\.mutedForeground)
        meta.color = Themed.color(\.mutedForeground)
        title.color = Themed.color(\.foreground)
        if let m = model { stateLabel.color = Themed.color(\.foreground); stateIcon.strokeColor = IssueListLogic.color(m.detail.state) }
    }
}

/// The issue key as an external link tinted by its state, with `ExternalLinkIcon size-2.5`.
final class IssueKeyLinkView: ControlView {
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let icon = IconView(name: .externalLink, size: 10)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        addSubview(label)
        addSubview(icon)
        setAccessibilityRole(.link)
    }
    func set(text: String, color: NSColor) {
        label.text = text
        label.color = color
        icon.strokeColor = color
        needsLayout = true
    }
    var preferredWidth: CGFloat { ceil(label.textWidth) + 1 + 2 + 10 }
    override func layout() {
        super.layout()
        let lw = ceil(label.textWidth) + 1
        label.frame = NSRect(x: 0, y: 0, width: lw, height: 16)
        icon.frame = NSRect(x: lw + 2, y: 3, width: 10, height: 10)
    }
}

/// `PullRequestMetaRow` (PullRequestSummaryTab.tsx:375-381): `grid-cols-[6rem_minmax(0,1fr)]`,
/// the icon and name in muted text, then chips or people, "None", and the picker trigger.
final class IssueMetaRow: DSView {
    private let icon: IconView
    private let name: LabelView
    private let none = LabelView("None", font: DSFont.ui(12))
    private var items: [NSView] = []
    private let pick: ButtonView
    var onPick: ((NSView) -> Void)?
    var pickLabel = "" { didSet { pick.setAccessibilityLabel(pickLabel) } }

    init(icon: IconName, label: String) {
        self.icon = IconView(name: icon, size: 14)
        name = LabelView(label, font: DSFont.ui(12))
        pick = ButtonView(nil, icon: icon == .tag ? .tag : .userPlus, variant: .ghost, size: .iconXs)
        super.init(frame: .zero)
        name.lineHeight = 16
        none.lineHeight = 16
        pick.iconSize = 14
        pick.action = { [weak self] in guard let self else { return }; self.onPick?(self.pick) }
        [self.icon, name, none, pick].forEach(addSubview)
    }

    func set(labels: [PullRequestLabel], picker: Bool, allowed: Bool, reason: String) {
        items.forEach { $0.removeFromSuperview() }
        items = labels.map { PullRequestLabelChip.make($0, size: .default) }
        finish(empty: labels.isEmpty, picker: picker, allowed: allowed, reason: reason)
    }

    func set(actors: [PullRequestActor], picker: Bool, allowed: Bool, reason: String) {
        items.forEach { $0.removeFromSuperview() }
        items = actors.map { actor in
            let v = IssueActorLabel()
            v.actor = actor
            return v
        }
        finish(empty: actors.isEmpty, picker: picker, allowed: allowed, reason: reason)
    }

    private func finish(empty: Bool, picker: Bool, allowed: Bool, reason: String) {
        items.forEach(addSubview)
        none.isHidden = !empty
        pick.isHidden = !picker
        pick.isEnabled = allowed
        pick.setTooltip(allowed ? pickLabel : reason)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: 5, width: 14, height: 14)
        name.frame = NSRect(x: 20, y: 4, width: 76, height: 16)
        var x: CGFloat = 96 + 8
        if !none.isHidden { none.frame = NSRect(x: x, y: 4, width: ceil(none.textWidth) + 1, height: 16); x += ceil(none.textWidth) + 1 + 4 }
        for v in items {
            let iw: CGFloat
            if let chip = v as? BadgeView { iw = min(192, ceil(chip.intrinsicContentSize.width)); v.frame = NSRect(x: x, y: 3, width: iw, height: 18) }
            else if let a = v as? IssueActorLabel { iw = a.preferredWidth; v.frame = NSRect(x: x, y: 4, width: iw, height: 16) }
            else { iw = 0 }
            x += iw + 6
        }
        pick.frame = NSRect(x: x, y: 0, width: 24, height: 24)
    }

    override func updateLayer() {
        icon.strokeColor = Themed.color(\.mutedForeground)
        name.color = Themed.color(\.mutedForeground)
        none.color = Themed.color(\.mutedForeground)
    }
}

/// `PullRequestActorLabel`: a 16px face and the login.
final class IssueActorLabel: DSView {
    private let avatar = PullRequestAvatarView()
    private let login = LabelView("", font: DSFont.ui(12))
    var actor: PullRequestActor? {
        didSet { avatar.actor = actor; login.text = actor?.login ?? "ghost"; setTooltip(actor?.name.map { "\($0) (@\(login.text))" }); needsLayout = true }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        login.lineHeight = 16
        addSubview(avatar)
        addSubview(login)
    }
    var preferredWidth: CGFloat { 16 + 4 + ceil(login.textWidth) + 1 }
    override func layout() {
        super.layout()
        avatar.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        login.frame = NSRect(x: 20, y: 0, width: max(0, bounds.width - 20), height: 16)
    }
    override func updateLayer() { login.color = Themed.color(\.foreground) }
}

// MARK: - Description

/// The Description section's body: the Markdown, its pencil, the editor, and the reaction bar
/// (IssueDetailPanel.tsx:727-773).
final class IssueDescriptionItem: DSView, StackItem, FocusWithinObserver {
    let view = MarkdownView()
    let reactionBar = PullRequestReactionBarView()
    private var hover: HoverGroup?
    private var focusWithin = false
    func focusWithinChanged(_ focused: Bool) { focusWithin = focused; revealEdit() }
    private func revealEdit() { HoverReveal.fade([editButton], visible: hover?.hovered == true || focusWithin) }
    private let editButton = ButtonView(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs)
    private var editor: PullRequestMarkdownEditorView?
    private var model: IssueDetailView.Model?
    var onSave: ((String) -> Void)?
    var onResize: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(view)
        addSubview(reactionBar)
        editButton.iconSize = 12
        editButton.setAccessibilityLabel("Edit description")
        editButton.action = { [weak self] in self?.startEditing() }
        editButton.alphaValue = 0
        addSubview(editButton)
        hover = HoverGroup(self) { [weak self] _ in self?.revealEdit() }
    }

    func set(_ m: IssueDetailView.Model) {
        if model?.detail.url != m.detail.url, editor != nil { stopEditing() }
        model = m
        view.cwd = m.cwd
        view.setMarkdown(m.detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_No description provided._" : m.detail.body)
        editButton.isHidden = editor != nil || !m.access.edit
        reactionBar.isHidden = m.detail.reactions == nil
        reactionBar.canReact = m.access.react
        reactionBar.reactions = m.detail.reactions ?? []
        if m.detail.reactions == nil { reactionBar.isHidden = true }
        editor?.saving = m.saving
        needsLayout = true
    }

    private func startEditing() {
        guard let m = model else { return }
        let e = PullRequestMarkdownEditorView(value: m.detail.body, label: "Description", allowEmpty: true, cwd: m.cwd)
        e.onCancel = { [weak self] in self?.stopEditing(); self?.onResize?() }
        e.onSave = { [weak self] body in self?.onSave?(body) }
        e.onResize = { [weak self] in self?.onResize?() }
        editor = e
        addSubview(e)
        editButton.isHidden = true
        view.isHidden = true
        onResize?()
        DispatchQueue.main.async { [weak e] in e?.focus() }
    }

    func stopEditing() {
        editor?.removeFromSuperview()
        editor = nil
        view.isHidden = false
        editButton.isHidden = !(model?.access.edit ?? false)
    }

    private var barHeight: CGFloat { reactionBar.isHidden ? 0 : 8 + 24 }

    func height(forWidth width: CGFloat) -> CGFloat {
        if let editor { return editor.height(forWidth: width) + barHeight }
        return view.height(forWidth: width - (editButton.isHidden ? 0 : 28)) + barHeight
    }

    override func layout() {
        super.layout()
        let ew: CGFloat = editButton.isHidden ? 0 : 28
        let bh = barHeight
        let mh = bounds.height - bh
        view.frame = NSRect(x: 0, y: 0, width: bounds.width - ew, height: mh)
        editor?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: mh)
        editButton.frame = NSRect(x: bounds.width - 24, y: -34, width: 24, height: 24)
        if !reactionBar.isHidden { reactionBar.frame = NSRect(x: 0, y: mh + 8, width: bounds.width, height: 24) }
    }
}

// MARK: - Linked pull requests

/// `LinkedPullRequestRow` (IssueDetailPanel.tsx:339-377): state glyph, title, then "Closes this
/// issue" and `repo#n` (the repository left off when it is the issue's own), `px-2 py-1.5`.
final class IssueLinkedPullRequestsItem: DSView, StackItem {
    private var rows: [IssueLinkedPullRequestRow] = []
    var onSelect: ((IssueLinkedPullRequest) -> Void)?

    func set(_ links: [IssueLinkedPullRequest], scope: String) {
        rows.forEach { $0.removeFromSuperview() }
        rows = links.map { link in
            let r = IssueLinkedPullRequestRow(link, scope: scope)
            r.action = { [weak self] in self?.onSelect?(link) }
            addSubview(r)
            return r
        }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { CGFloat(rows.count) * 32 + CGFloat(max(0, rows.count - 1)) * 4 }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for r in rows { r.frame = NSRect(x: 0, y: y, width: bounds.width, height: 32); y += 36 }
    }
}

final class IssueLinkedPullRequestRow: ControlView {
    private let glyph = PullRequestStateGlyphView()
    private let title = LabelView("", font: DSFont.ui(14))
    private let meta = LabelView("", font: DSFont.ui(12))

    init(_ link: IssueLinkedPullRequest, scope: String) {
        super.init(frame: .zero)
        glyph.set(state: link.state, isDraft: link.isDraft, mergeability: nil)
        title.text = link.title
        title.lineHeight = 20
        meta.lineHeight = 16
        let repo = link.repository.lowercased() == scope.lowercased() ? "" : link.repository
        meta.text = (link.closesIssue ? "Closes this issue  " : "") + "\(repo)#\(link.number)"
        [glyph, title, meta].forEach(addSubview)
        layer?.cornerRadius = 6
        setAccessibilityLabel("\(link.title) \(repo)#\(link.number)")
    }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 8, y: 8, width: 16, height: 16)
        let mw = ceil(meta.textWidth) + 1
        meta.frame = NSRect(x: bounds.width - 8 - mw, y: 8, width: mw, height: 16)
        title.frame = NSRect(x: 32, y: 6, width: max(0, bounds.width - 32 - mw - 16), height: 20)
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = state.hovered ? Themed.color(\.accent).cgColor(in: self) : nil
        title.color = Themed.color(\.foreground)
        meta.color = Themed.color(\.mutedForeground)
    }
}

// MARK: - Activity

/// Comments and events by time, "Load older comments" above them (IssueDetailPanel.tsx:800-877).
final class IssueActivityItem: DSView, StackItem {
    private let olderButton = ButtonView("Load older comments", variant: .outline, size: .sm)
    private let emptyLabel = LabelView("Nothing has happened here yet.", font: DSFont.ui(14))
    private var rows: [StackItem] = []
    var onLoadOlder: (() -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onReact: ((String?, String, Bool, PullRequestReactionBarView) -> Void)?
    var onResize: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        emptyLabel.lineHeight = 20
        olderButton.action = { [weak self] in self?.onLoadOlder?() }
        addSubview(olderButton)
        addSubview(emptyLabel)
    }

    func set(_ m: IssueDetailView.Model) {
        olderButton.isHidden = m.nextCursor == nil
        olderButton.title = m.loadingOlder ? "Loading…" : "Load older comments"
        olderButton.isEnabled = !m.loadingOlder && !m.refreshing
        let items = IssueListLogic.timeline(comments: m.comments, events: m.detail.events)
        emptyLabel.isHidden = !items.isEmpty
        rows.forEach { $0.removeFromSuperview() }
        rows = items.map { item -> StackItem in
            switch item {
            case .comment(let c):
                let pr = PullRequestComment(id: c.id, kind: "issue-comment", author: c.author, body: c.body, createdAt: c.createdAt,
                                            url: c.url, reactions: c.reactions)
                let card = CommentCard(pr, nowMs: m.nowMs, cwd: m.cwd ?? "", canReact: m.access.react, headingLevel: 3)
                card.reactionBar.isHidden = c.reactions == nil
                card.reactionBar.onToggle = { [weak self, weak card] content, reacted in
                    guard let card else { return }
                    self?.onReact?(c.id, content, reacted, card.reactionBar)
                }
                card.onResize = { [weak self] in self?.onResize?() }
                return card
            case .event(let e):
                return IssueEventLine(e, nowMs: m.nowMs)
            }
        }
        rows.forEach(addSubview)
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var parts: [CGFloat] = []
        if !olderButton.isHidden { parts.append(28) }
        if !emptyLabel.isHidden { parts.append(20) }
        parts += rows.map { $0.height(forWidth: width) }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * 12 // `gap-3`
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if !olderButton.isHidden {
            olderButton.frame = NSRect(x: 0, y: 0, width: ceil(olderButton.intrinsicContentSize.width), height: 28)
            y += 28 + 12
        }
        if !emptyLabel.isHidden { emptyLabel.frame = NSRect(x: 0, y: y, width: bounds.width, height: 20); y += 20 + 12 }
        for r in rows {
            let h = r.height(forWidth: bounds.width)
            r.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 12
        }
    }

    override func updateLayer() { emptyLabel.color = Themed.color(\.mutedForeground) }
}

/// An event line (`PullRequestMetaLine px-1 text-xs text-muted-foreground`): who, what, when.
final class IssueEventLine: DSView, StackItem {
    private let actor = IssueActorLabel()
    private let sentence = LabelView("", font: DSFont.ui(12))

    init(_ e: IssueEvent, nowMs: Int64) {
        super.init(frame: .zero)
        actor.actor = e.actor
        sentence.text = "\(IssueListLogic.eventSentence(e))  \(TimestampFormat.formatRelativeTimeLabel(e.createdAt, nowMs: nowMs))"
        sentence.lineHeight = 16
        addSubview(actor)
        addSubview(sentence)
    }

    func height(forWidth width: CGFloat) -> CGFloat { 20 }

    override func layout() {
        super.layout()
        let aw = actor.preferredWidth
        actor.frame = NSRect(x: 4, y: 2, width: aw, height: 16)
        sentence.frame = NSRect(x: 4 + aw + 6, y: 2, width: max(0, bounds.width - 4 - aw - 6 - 4), height: 16)
    }

    override func updateLayer() { sentence.color = Themed.color(\.mutedForeground) }
}

// MARK: - Composer

/// The floating comment card (IssueCommentComposer.tsx): a two-line textarea that grows to 16rem,
/// and the round send button. Mod+Enter sends; the reason the viewer cannot comment is the
/// placeholder and the box locks.
public final class IssueCommentComposerView: DSView {
    private let box = TextareaView(placeholder: "Leave a comment")
    private let send = ComposerPrimaryButton()
    private let card = CALayer()
    var onSubmit: ((String) -> Void)?
    public var blocked: String? { didSet { update() } }
    public var submitting = false { didSet { update() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull()]
        layer?.addSublayer(card)
        box.bare = true
        box.bareMinHeight = 40
        box.setAccessibilityLabel("Add a comment")
        box.onChange = { [weak self] _ in self?.update(); self?.superview?.needsLayout = true }
        box.onCommand = { [weak self] sel in
            guard sel == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
            self?.submit()
            return true
        }
        send.stageArt = false
        send.face = .send
        send.action = { [weak self] in self?.submit() }
        addSubview(box)
        addSubview(send)
        update()
    }

    func clear() { box.text = ""; submitting = false; update() }

    private func submit() {
        let text = box.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, blocked == nil, !submitting else { return }
        submitting = true
        onSubmit?(text)
    }

    private func update() {
        box.placeholder = blocked ?? "Leave a comment"
        box.isEnabled = blocked == nil && !submitting
        send.isEnabled = blocked == nil && !submitting && !box.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.tooltip = submitting ? "Posting comment" : "Comment"
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        // `pt-3 pb-1` box, capped at 16rem, then the `pb-2.5` row with the 32px button.
        min(256, max(40, box.height(forWidth: width - 28))) + 12 + 4 + 32 + 10 + 2
    }

    public override func layout() {
        super.layout()
        card.frame = bounds
        let bh = bounds.height - 12 - 4 - 32 - 10 - 2
        box.frame = NSRect(x: 14, y: 13, width: max(0, bounds.width - 28), height: max(0, bh))
        send.frame = NSRect(x: bounds.width - 11 - 32, y: bounds.height - 11 - 32, width: 32, height: 32)
    }

    public override func updateLayer() {
        card.cornerRadius = DesignGeometry.radius(ComposerView.radius, in: self)
        card.backgroundColor = Themed.color(\.card).cgColor(in: self)
        card.borderWidth = 1
        card.borderColor = Themed.color(\.border).cgColor(in: self)
        card.shadowOpacity = 1
        card.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
        card.shadowRadius = 8
        card.shadowOffset = CGSize(width: 0, height: -2)
    }
}

// MARK: - Ghost

/// `IssueDetailGhost` (IssueDetailGhost.tsx): the list row's key and title while the detail
/// loads, and skeleton bars for the rest.
final class IssueDetailGhostView: DSView {
    private let bars = (0..<8).map { _ in SkeletonView(shape: .pill) }
    private let key = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let title = TextBlockView()
    var seed: IssueListEntry? {
        didSet {
            key.text = seed.map { "\($0.scope) \($0.displayKey)" } ?? ""
            title.text = seed?.title ?? ""
            bars[0].isHidden = seed != nil
            bars[1].isHidden = seed != nil
            needsLayout = true
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bars.forEach(addSubview)
        key.lineHeight = 16
        title.font = DSFont.ui(16, weight: .semibold)
        title.lineHeight = 22
        addSubview(key)
        addSubview(title)
        setAccessibilityLabel("Loading issue")
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        key.frame = NSRect(x: 16, y: 6, width: w - 32, height: 16)
        let th = seed == nil ? 22 : title.height(forWidth: w - 32)
        title.frame = NSRect(x: 16, y: 32, width: w - 32, height: th)
        let specs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (16, 8, 140, 12), (16, 36, w * 0.6, 18), (16, 66, 180, 12), (16, 102, w * 0.45, 12),
            (16, 134, w * 0.4, 12), (16, 182, 120, 12), (16, 208, w - 32, 12), (16, 230, w * 0.7, 12),
        ]
        for (bar, s) in zip(bars, specs) { bar.frame = NSRect(x: s.0, y: s.1 + (seed == nil ? 0 : max(0, th - 22)), width: max(0, s.2), height: s.3) }
    }
    override func updateLayer() { key.color = Themed.color(\.mutedForeground); title.color = Themed.color(\.foreground) }
}
