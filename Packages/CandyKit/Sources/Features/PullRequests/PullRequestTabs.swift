import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// A vertical stack in a scroll view: each child reports its height for a width.
@MainActor
protocol StackItem: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}

final class StackDocument: DSView {
    var items: [StackItem] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; items.forEach(addSubview); needsLayout = true }
    }
    var insets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    var spacing: CGFloat = 0
    var maxWidth: CGFloat = .greatestFiniteMagnitude
    var minimumHeight: CGFloat = 0

    func height(forWidth width: CGFloat) -> CGFloat {
        let w = min(maxWidth, width - insets.left - insets.right)
        let visible = items.filter { !$0.isHidden }
        return insets.top + insets.bottom + visible.map { $0.height(forWidth: w) }.reduce(0, +) + CGFloat(max(0, visible.count - 1)) * spacing
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - insets.left - insets.right
        let w = min(maxWidth, inner)
        let x = insets.left + (inner - w) / 2
        var y = insets.top
        for item in items where !item.isHidden {
            let h = item.height(forWidth: w)
            item.frame = NSRect(x: x, y: y, width: w, height: h)
            y += h + spacing
        }
    }
}

/// Reports a tab's scroll offset (the detail header condenses on it) and moves it by a refund.
@MainActor
final class PullRequestScrollWatcher {
    private weak var scroll: ScrollAreaView?
    private var observer: NSObjectProtocol?
    var onScroll: ((CGFloat) -> Void)?

    init(_ scroll: ScrollAreaView) {
        self.scroll = scroll
        let clip = scroll.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScroll?(clip.bounds.minY) }
        }
    }

    // The block holds the clip view, so the center would keep the whole tab alive.
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var top: CGFloat { scroll?.scrollView.contentView.bounds.minY ?? 0 }

    /// Moves the content by `delta` without the header's change pulling it out from under the reader.
    func adjust(by delta: CGFloat) {
        guard let sv = scroll?.scrollView else { return }
        let clip = sv.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, clip.bounds.minY + delta)))
        sv.reflectScrolledClipView(clip)
    }
}

/// A scroll view over a `StackDocument` that sizes the document on layout.
final class StackScrollView: DSView {
    let document = StackDocument()
    private let scroll: ScrollAreaView
    let watcher: PullRequestScrollWatcher
    override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: document, scrollbars: .native) // PullRequestTimelineTab.tsx:580, PullRequestSummaryTab.tsx:711
        watcher = PullRequestScrollWatcher(scroll)
        super.init(frame: frameRect)
        addSubview(scroll)
    }
    func reload() { needsLayout = true; document.needsLayout = true }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let w = scroll.bounds.width
        document.frame = NSRect(x: 0, y: document.frame.minY, width: w, height: max(bounds.height, document.height(forWidth: w)))
        document.layoutSubtreeIfNeeded()
    }
}

// MARK: - Summary

/// The Summary tab (PullRequestSummaryTab.tsx): Reviewers and Labels rows, then the Description,
/// Checks (closed) and Comments sections with sticky, collapsible headings.
public final class PullRequestSummaryView: DSView {
    private let stack = StackScrollView()
    private let meta = MetaRowsItem()
    private let descriptionSection = SectionItem(title: "Description")
    private let checks = SectionItem(title: "Checks", open: false)
    private let comments = SectionItem(title: "Comments (0)")
    private let markdown = PullRequestDescriptionItem()
    private let checkRows = ChecksListItem()
    private let commentList = CommentsItem()
    private let orderButton = ButtonView("Newest first", icon: .arrowDownUp, variant: .ghostMuted, size: .xs)
    /// "Filter", or "N hidden" (2994 PullRequestSummaryTab.tsx:874-904).
    private let filterButton = ButtonView("Filter", icon: .listFilter, variant: .ghostMuted, size: .xs).menuTrigger()
    private let commentTools = HStackAccessory()
    private var commentFilter = PullRequestDetailLogic.CommentFilter.load()
    private var newestFirst = true
    private var detail: PullRequestDetail?
    var onOpenURL: ((String) -> Void)?
    var scrollTarget: PullRequestScrollWatcher { stack.watcher }
    /// The reviewer and label pickers' triggers were pressed.
    var onPickReviewers: ((NSView) -> Void)? { get { meta.onPickReviewers } set { meta.onPickReviewers = newValue } }
    var onPickLabels: ((NSView) -> Void)? { get { meta.onPickLabels } set { meta.onPickLabels = newValue } }
    /// The description editor's Save (`pullRequests.update` with `body`).
    var onSaveBody: ((String) -> Void)? { get { markdown.onSave } set { markdown.onSave = newValue } }
    /// A comment rewritten (`pullRequests.updateComment`).
    var onSaveComment: ((PullRequestComment, String) -> Void)? { get { commentList.onSave } set { commentList.onSave = newValue } }
    /// A reaction pressed on a comment: (comment id, content, reacted, the bar to tell of a refusal).
    var onReact: ((String, String, Bool, PullRequestReactionBarView) -> Void)? { get { commentList.onReact } set { commentList.onReact = newValue } }
    var bodySaving: Bool { get { markdown.saving } set { markdown.saving = newValue } }
    var commentSaving: Bool { get { commentList.saving } set { commentList.saving = newValue } }
    func finishBodyEdit() { markdown.stopEditing(); stack.reload() }
    func finishCommentEdit() { commentList.editingId = nil; stack.reload() }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(stack)
        markdown.onResize = { [weak self] in self?.stack.reload() }
        commentList.onResize = { [weak self] in self?.stack.reload() }
        descriptionSection.body = markdown
        checks.body = checkRows
        comments.body = commentList
        commentTools.views = [filterButton, orderButton]
        comments.accessory = commentTools
        filterButton.iconSize = 12
        filterButton.setAccessibilityLabel("Filter comments")
        filterButton.action = { [weak self] in self?.showFilterMenu() }
        orderButton.iconSize = 12
        orderButton.action = { [weak self] in
            guard let self else { return }
            self.newestFirst.toggle()
            self.orderButton.title = self.newestFirst ? "Newest first" : "Oldest first"
            self.commentTools.invalidateIntrinsicContentSize()
            self.commentList.newestFirst = self.newestFirst
            self.stack.reload()
        }
        for s in [descriptionSection, checks, comments] { s.onToggle = { [weak self] in self?.stack.reload() } }
        checkRows.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        commentList.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        stack.document.items = [meta, descriptionSection, checks, comments]
        stack.document.insets = NSEdgeInsets(top: 0, left: 0, bottom: 56, right: 0)
    }

    func set(_ d: PullRequestDetail, activityPending: Bool, activityError: String?, nowMs: Int64) {
        detail = d
        meta.set(d)
        markdown.set(d)
        checkRows.checks = d.checks
        comments.title = "Comments (\(d.commentCount))"
        commentList.set(d, pending: activityPending, error: activityError, nowMs: nowMs, filter: commentFilter)
        updateFilterButton()
        stack.reload()
    }

    private func updateFilterButton() {
        let hidden = detail.map { PullRequestDetailLogic.filterComments($0, commentFilter).hidden } ?? 0
        filterButton.title = hidden > 0 ? "\(hidden) hidden" : "Filter"
        commentTools.invalidateIntrinsicContentSize()
        comments.needsLayout = true
    }

    /// `Menu` with a "Show" group of two checkboxes that keep the menu open (`closeOnClick={false}`).
    private func showFilterMenu() {
        let apply: (PullRequestDetailLogic.CommentFilter) -> Void = { [weak self] f in
            guard let self else { return }
            self.commentFilter = f
            f.save()
            if let d = self.detail { self.commentList.refilter(d, filter: f) }
            self.updateFilterButton()
            self.stack.reload()
        }
        let bots = MenuItem.checkbox("Bot comments", checked: commentFilter.bots) { [weak self] on in
            guard var f = self?.commentFilter else { return }
            f.bots = on
            apply(f)
        }
        let resolved = MenuItem.checkbox("Resolved or dismissed", checked: commentFilter.resolved) { [weak self] on in
            guard var f = self?.commentFilter else { return }
            f.resolved = on
            apply(f)
        }
        MenuPopupView.show([.label("Show"), bots, resolved], from: filterButton,
                           placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    public override func layout() { super.layout(); stack.frame = bounds }
}

/// `MetaRow`s (`grid-cols-[6rem_minmax(0,1fr)] min-h-6 text-xs`, `px-4 pt-2.5 pb-1 space-y-2`).
final class MetaRowsItem: DSView, StackItem {
    private let reviewersIcon = IconView(name: .users, size: 14)
    private let reviewersLabel = LabelView("Reviewers", font: DSFont.ui(12))
    private let labelsIcon = IconView(name: .tag, size: 14)
    private let labelsLabel = LabelView("Labels", font: DSFont.ui(12))
    private let noneReviewers = LabelView("None", font: DSFont.ui(12))
    private let noneLabels = LabelView("None", font: DSFont.ui(12))
    private var avatars: [PullRequestAvatarView] = []
    private var chips: [BadgeView] = []
    private var showsLabels = false
    private let reviewerButton = ButtonView(nil, icon: .userPlus, variant: .ghost, size: .iconXs)
    private let labelButton = ButtonView(nil, icon: .tag, variant: .ghost, size: .iconXs)
    var onPickReviewers: ((NSView) -> Void)?
    var onPickLabels: ((NSView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [reviewersLabel, labelsLabel, noneReviewers, noneLabels] { l.lineHeight = 16; addSubview(l) }
        [reviewersIcon, labelsIcon, reviewerButton, labelButton].forEach(addSubview)
        reviewerButton.iconSize = 14
        labelButton.iconSize = 14
        reviewerButton.setAccessibilityLabel("Request a review")
        labelButton.setAccessibilityLabel("Change labels")
        reviewerButton.action = { [weak self] in guard let self else { return }; self.onPickReviewers?(self.reviewerButton) }
        labelButton.action = { [weak self] in guard let self else { return }; self.onPickLabels?(self.labelButton) }
    }

    func set(_ d: PullRequestDetail) {
        avatars.forEach { $0.removeFromSuperview() }
        // `reviewerEntries`: everyone asked or answering, a verdict as a ring on the face.
        let outcomes = PullRequestDetailLogic.latestReviewOutcomes(d.comments, commits: d.commits)
        var seen = Set<String>()
        var entries: [(PullRequestActor?, String?, Bool)] = []
        for o in outcomes { seen.insert(o.key.lowercased()); entries.append((o.actor, o.outcome, o.stale)) }
        for r in d.reviewers where !seen.contains(r.login.lowercased()) { entries.append((r, nil, false)) }
        avatars = entries.map { actor, outcome, stale in
            let a = PullRequestAvatarView()
            a.actor = actor
            if let outcome { a.ring = PullRequestStyle.outcomeRing(outcome, stale: stale) }
            a.toolTip = actor?.login ?? "ghost"
            addSubview(a)
            return a
        }
        noneReviewers.isHidden = !entries.isEmpty
        chips.forEach { $0.removeFromSuperview() }
        showsLabels = !d.labels.isEmpty || d.capabilities.labels == true
        chips = d.labels.map { PullRequestLabelChip.make($0, size: .default) }
        chips.forEach(addSubview)
        noneLabels.isHidden = !d.labels.isEmpty || !showsLabels
        [labelsIcon, labelsLabel].forEach { $0.isHidden = !showsLabels }
        // Shown wherever the host can take the change, disabled with the reason where this account may not
        // (PullRequestSummaryTab.tsx:781-821, PullRequestCandidatePicker.tsx:75-88).
        reviewerButton.isHidden = !(d.capabilities.reviewers.request && d.capabilities.reviewers.listCandidates)
        reviewerButton.isEnabled = d.viewerPermissions.requestReviewers
        reviewerButton.toolTip = d.viewerPermissions.requestReviewers ? "Request a review" : "Asking someone to review needs write access on this repository"
        labelButton.isHidden = d.capabilities.labels != true
        labelButton.isEnabled = d.viewerPermissions.labels != false
        labelButton.toolTip = d.viewerPermissions.labels != false ? "Change labels" : "Changing labels needs triage access on this repository"
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 10 + 24 + (showsLabels ? 8 + 24 : 0) + 4 }

    override func layout() {
        super.layout()
        var y: CGFloat = 10
        reviewersIcon.frame = NSRect(x: 16, y: y + 5, width: 14, height: 14)
        reviewersLabel.frame = NSRect(x: 36, y: y + 4, width: 70, height: 16)
        var x: CGFloat = 16 + 96 + 8
        for a in avatars { a.frame = NSRect(x: x, y: y + 4, width: 16, height: 16); x += 12 }
        noneReviewers.frame = NSRect(x: 16 + 104, y: y + 4, width: 40, height: 16)
        let rx = avatars.isEmpty ? 16 + 104 + ceil(noneReviewers.textWidth) + 6 : x + 4 + 6
        reviewerButton.frame = NSRect(x: rx, y: y, width: 24, height: 24)
        y += 24 + 8
        labelsIcon.frame = NSRect(x: 16, y: y + 5, width: 14, height: 14)
        labelsLabel.frame = NSRect(x: 36, y: y + 4, width: 70, height: 16)
        x = 16 + 104
        for c in chips {
            let cw = min(192, ceil(c.intrinsicContentSize.width))
            c.frame = NSRect(x: x, y: y + 3, width: cw, height: 18)
            x += cw + 4
        }
        noneLabels.frame = NSRect(x: 16 + 104, y: y + 4, width: 40, height: 16)
        labelButton.frame = NSRect(x: chips.isEmpty ? 16 + 104 + ceil(noneLabels.textWidth) + 4 : x, y: y, width: 24, height: 24)
    }

    override func updateLayer() {
        for l in [reviewersLabel, labelsLabel, noneReviewers, noneLabels] { l.color = Themed.color(\.mutedForeground) }
        reviewersIcon.strokeColor = Themed.color(\.mutedForeground)
        labelsIcon.strokeColor = Themed.color(\.mutedForeground)
    }
}

/// `Section`: a heading (`px-4 py-3 text-xs font-medium text-muted-foreground`, chevron turning on
/// open) over a `px-4 pb-4` body.
final class SectionItem: DSView, StackItem {
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let chevron = IconView(name: .chevronRight, size: 14)
    var title: String { get { label.text } set { label.text = newValue; needsLayout = true } }
    /// The chevron turns over 150ms, `rotate-90` when open (PullRequestSummaryTab.tsx:335-340).
    var isOpen: Bool { didSet { body?.isHidden = !isOpen; chevron.setRotation(isOpen ? 90 : 0); onToggle?() } }
    var body: StackItem? { didSet { oldValue?.removeFromSuperview(); if let body { addSubview(body); body.isHidden = !isOpen } } }
    var accessory: NSView? { didSet { oldValue?.removeFromSuperview(); accessory.map(addSubview) } }
    var onToggle: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(title: String, open: Bool = true) {
        isOpen = open
        super.init(frame: .zero)
        label.text = title
        label.lineHeight = 16
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    func height(forWidth width: CGFloat) -> CGFloat { 40 + (isOpen ? (body?.height(forWidth: width - 32) ?? 0) + 16 : 0) }

    override func layout() {
        super.layout()
        let lw = ceil(label.textWidth) + 1
        label.frame = NSRect(x: 16, y: 12, width: lw, height: 16)
        chevron.frame = NSRect(x: 16 + lw + 6, y: 13, width: 14, height: 14)
        chevron.setRotation(isOpen ? 90 : 0, motion: .none)
        if let accessory {
            let s = accessory.intrinsicContentSize
            accessory.frame = NSRect(x: bounds.width - 16 - s.width, y: (40 - s.height) / 2, width: s.width, height: s.height)
        }
        if let body, isOpen { body.frame = NSRect(x: 16, y: 40, width: bounds.width - 32, height: body.height(forWidth: bounds.width - 32)) }
    }

    override func updateLayer() {
        label.color = hovered ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        chevron.strokeColor = Themed.color(\.mutedForeground, 0.6)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 40), options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // `CollapsiblePanel` (PullRequestSummaryTab.tsx:345): the body slides open over 200 ms.
        if p.y < 40, accessory.map({ !$0.frame.contains(p) }) ?? true { CollapseMotion.run(in: self) { isOpen.toggle() } }
    }
}

/// The description's Markdown (`PullRequestMarkdown`, the chat renderer).
final class MarkdownItem: DSView, StackItem {
    let view = MarkdownView()
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); addSubview(view) }
    func height(forWidth width: CGFloat) -> CGFloat { view.height(forWidth: width) }
    override func layout() { super.layout(); view.frame = bounds }
}

/// The Checks section's rows (`px-2 py-2 text-xs leading-5`): status glyph, name, status word.
final class ChecksListItem: DSView, StackItem {
    var checks: [PullRequestCheck] = [] { didSet { rebuild() } }
    var onOpenURL: ((String) -> Void)?
    private var rows: [CheckRow] = []
    private let empty = LabelView("No checks reported.", font: DSFont.ui(12))

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); empty.lineHeight = 16; addSubview(empty) }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = checks.map { c in
            let r = CheckRow(c)
            r.onOpen = { [weak self] in if let url = c.url { self?.onOpenURL?(url) } }
            addSubview(r)
            return r
        }
        empty.isHidden = !checks.isEmpty
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { checks.isEmpty ? 16 : CGFloat(rows.count) * 36 }

    override func layout() {
        super.layout()
        empty.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
        for (i, r) in rows.enumerated() { r.frame = NSRect(x: 0, y: CGFloat(i) * 36, width: bounds.width, height: 36) }
    }

    override func updateLayer() { empty.color = Themed.color(\.mutedForeground) }

    final class CheckRow: DSView {
        private let glyph = CheckStatusGlyph()
        private let name = LabelView("", font: DSFont.ui(12))
        private let status = LabelView("", font: DSFont.ui(12))
        var onOpen: (() -> Void)?
        private var hovered = false { didSet { needsDisplay = true } }
        private var tracking: NSTrackingArea?
        init(_ c: PullRequestCheck) {
            super.init(frame: .zero)
            let p = PullRequestStyle.checkStatus(c.status)
            glyph.set(icon: p.icon, color: p.color, spinning: c.status == "pending")
            name.text = c.name
            status.text = PullRequestDetailLogic.checkStatusLabel(c)
            name.lineHeight = 20; status.lineHeight = 20
            [glyph, name, status].forEach(addSubview)
            layer?.cornerRadius = 8
            toolTip = c.description ?? c.name
        }
        override func layout() {
            super.layout()
            glyph.frame = NSRect(x: 8, y: 11, width: 14, height: 14)
            let sw = ceil(status.textWidth) + 1
            status.frame = NSRect(x: bounds.width - 12 - sw, y: 8, width: sw, height: 20)
            name.frame = NSRect(x: 30, y: 8, width: max(0, status.frame.minX - 8 - 30), height: 20)
        }
        override func updateLayer() {
            layer?.backgroundColor = hovered ? Themed.color(\.accent, 0.6).cgColor(in: self) : nil
            name.color = Themed.color(\.foreground)
            status.color = Themed.color(\.mutedForeground)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(tracking!)
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        override func mouseUp(with event: NSEvent) { onOpen?() }
    }
}

/// The Comments section: the truncation notice, "No comments yet.", or the conversations. A review
/// thread shows its finding with the replies under it (3473 PullRequestSummaryTab.tsx:623-659, 70a869d262).
// ponytail: every conversation renders at once; T3 pages them by 20. Add the paging when a long review is
// slow to open
final class CommentsItem: DSView, StackItem {
    private var rows: [StackItem] = []
    private var cards: [CommentCard] = []
    private var detail: PullRequestDetail?
    /// The conversations the filter lets through.
    private var items: [PullRequestDetailLogic.ConversationItem] = []
    /// Collapsed cards the reader opened.
    private var openIds: Set<String> = []
    private var nowMs: Int64 = 0
    var editingId: String? { didSet { if editingId != oldValue { rebuildCards() } } }
    var saving = false { didSet { cards.forEach { $0.editor?.saving = saving } } }
    var onSave: ((PullRequestComment, String) -> Void)?
    var onReact: ((String, String, Bool, PullRequestReactionBarView) -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onResize: (() -> Void)?
    private let note = TextBlockView()
    var newestFirst = true { didSet { needsLayout = true } }
    private var state: (pending: Bool, error: String?) = (true, nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        note.font = DSFont.ui(12)
        note.lineHeight = 16
        addSubview(note)
    }

    func set(_ d: PullRequestDetail, pending: Bool, error: String?, nowMs: Int64, filter: PullRequestDetailLogic.CommentFilter = .init()) {
        state = (pending, error)
        self.nowMs = nowMs
        refilter(d, filter: filter)
    }

    /// The filter changed, or the detail did: rebuild the cards from the conversations it lets through.
    func refilter(_ d: PullRequestDetail, filter: PullRequestDetailLogic.CommentFilter) {
        if detail?.url != d.url { openIds = [] }
        detail = d
        let (shown, hidden) = PullRequestDetailLogic.filterComments(d, filter)
        items = shown
        if editingId != nil, !shown.contains(where: { $0.comments.contains { $0.id == editingId } }) { editingId = nil }
        rebuildCards()
        note.text = state.pending ? "Loading comments…" : state.error ?? (d.comments.isEmpty && d.reviewThreads.isEmpty ? "No comments yet."
            : shown.isEmpty ? PullRequestDetailLogic.allCommentsHiddenNote(hidden) : "")
        needsLayout = true
    }

    private func card(_ c: PullRequestComment, _ d: PullRequestDetail, collapsed: PullRequestDetailLogic.Collapsed? = nil, reply: Bool = false,
                      replyCount: Int = 0, replies: PullRequestReplyList? = nil, more: PullRequestMoreRepliesLine? = nil) -> CommentCard {
        let card = CommentCard(c, nowMs: nowMs, cwd: d.workspaceRoot,
                               canEdit: PullRequestWriteLogic.canEditComment(d, author: c.author?.login, kind: c.kind, hostAnswer: c.canEdit),
                               canReact: d.capabilities.reactions == true, editing: editingId == c.id,
                               collapsed: collapsed, open: openIds.contains(c.id), reply: reply,
                               replyCount: replyCount, replies: replies, moreReplies: more)
        // A rebuilt list keeps the cards the reader opened (T3 keys them by detail and comment).
        card.onResize = { [weak self, weak card] in
            guard let self, let card else { return }
            if card.isOpen { self.openIds.insert(c.id) } else { self.openIds.remove(c.id) }
            self.onResize?()
        }
        card.onEdit = { [weak self] in self?.editingId = c.id; self?.onResize?() }
        card.onCancel = { [weak self] in self?.editingId = nil; self?.onResize?() }
        card.onSave = { [weak self] body in self?.onSave?(c, body) }
        card.reactionBar.onToggle = { [weak self, weak card] content, reacted in
            guard let self, let card else { return }
            self.onReact?(c.id, content, reacted, card.reactionBar)
        }
        card.editor?.saving = saving
        card.editor?.onResize = { [weak self] in self?.onResize?() }
        cards.append(card)
        return card
    }

    private func rebuildCards() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        cards = []
        guard let d = detail, !state.pending, state.error == nil else { return }
        rows = items.map { item -> StackItem in
            guard case .thread(let root, let replies, let thread, let more) = item else {
                return card(item.root, d, collapsed: PullRequestDetailLogic.collapsed(item.root, thread: nil))
            }
            // `ml-4 space-y-2 border-l-2 border-border/60 pl-3`.
            let list = replies.isEmpty ? nil : PullRequestReplyList(replies.map { card($0, d, reply: true) }, indent: 16, rule: 2, spacing: 8)
            let line = more.hasMoreReplies ? PullRequestMoreRepliesLine(more) : nil
            line?.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
            if let collapsed = PullRequestDetailLogic.collapsed(root, thread: thread) {
                return card(root, d, collapsed: collapsed, replyCount: replies.count + more.moreReplies, replies: list, more: line)
            }
            // `space-y-2`: the finding, its replies, then what the host holds back.
            return PullRequestConversationStack([card(root, d)] + [list, line].compactMap { $0 }, spacing: 8)
        }
        rows.forEach(addSubview)
        needsLayout = true
    }

    private var ordered: [StackItem] { newestFirst ? rows.reversed() : rows }

    func height(forWidth width: CGFloat) -> CGFloat {
        if rows.isEmpty { return 8 + note.height(forWidth: width) + 8 }
        return ordered.map { $0.height(forWidth: width) }.reduce(0, +) + CGFloat(rows.count - 1) * 12
    }

    override func layout() {
        super.layout()
        note.isHidden = !rows.isEmpty
        note.frame = NSRect(x: 0, y: 8, width: bounds.width, height: note.height(forWidth: bounds.width))
        var y: CGFloat = 0
        for c in ordered {
            let h = c.height(forWidth: bounds.width)
            c.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 12
        }
    }

    override func updateLayer() { note.color = Themed.color(\.mutedForeground) }
}

/// Views stacked top to bottom with a gap (`space-y-*`).
final class PullRequestConversationStack: DSView, StackItem {
    private let rows: [StackItem]
    private let spacing: CGFloat
    init(_ rows: [StackItem], spacing: CGFloat) {
        self.rows = rows
        self.spacing = spacing
        super.init(frame: .zero)
        rows.forEach(addSubview)
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        rows.map { $0.height(forWidth: width) }.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for r in rows {
            let h = r.height(forWidth: bounds.width)
            r.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + spacing
        }
    }
}

/// A review thread's replies behind a rule (`ml-* border-l border-border/60 pl-3 space-y-*`).
final class PullRequestReplyList: DSView, StackItem {
    private let cards: [CommentCard]
    private let indent: CGFloat
    private let ruleWidth: CGFloat
    private let spacing: CGFloat
    private let rule = CALayer()

    init(_ cards: [CommentCard], indent: CGFloat, rule ruleWidth: CGFloat, spacing: CGFloat) {
        self.cards = cards
        self.indent = indent
        self.ruleWidth = ruleWidth
        self.spacing = spacing
        super.init(frame: .zero)
        rule.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(rule)
        cards.forEach(addSubview)
    }

    private var inset: CGFloat { indent + ruleWidth + 12 }

    func height(forWidth width: CGFloat) -> CGFloat {
        cards.map { $0.height(forWidth: width - inset) }.reduce(0, +) + CGFloat(max(0, cards.count - 1)) * spacing
    }

    override func layout() {
        super.layout()
        rule.frame = CGRect(x: indent, y: 0, width: ruleWidth, height: bounds.height)
        var y: CGFloat = 0
        for c in cards {
            let h = c.height(forWidth: bounds.width - inset)
            c.frame = NSRect(x: inset, y: y, width: bounds.width - inset, height: h)
            y += h + spacing
        }
    }

    override func updateLayer() { rule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self) }
}

/// `PullRequestMoreReplies` (3473 PullRequestMoreReplies.tsx): "N more replies" where the host gave a
/// count, else "More replies", and "View on host" (`hover:text-foreground hover:underline`) where a
/// remark has a link; `py-1 text-xs text-muted-foreground gap-2`.
final class PullRequestMoreRepliesLine: DSView, StackItem {
    private let label = LabelView("", font: DSFont.ui(12))
    private let link = LinkLabel()
    private let url: String?
    var onOpenURL: ((String) -> Void)?

    init(_ more: PullRequestDetailLogic.ReplyAvailability) {
        url = more.url
        super.init(frame: .zero)
        label.text = PullRequestDetailLogic.moreRepliesLabel(more.moreReplies)
        label.lineHeight = 16
        addSubview(label)
        link.text = "View on host"
        link.font = DSFont.ui(12)
        link.isHidden = more.url == nil
        link.setAccessibilityLabel("View on host")
        link.onClick = { [weak self] in if let self, let url = self.url { self.onOpenURL?(url) } }
        addSubview(link)
    }

    func height(forWidth width: CGFloat) -> CGFloat { 24 }

    override func layout() {
        super.layout()
        let lw = ceil(label.textWidth) + 1
        label.frame = NSRect(x: 0, y: 4, width: min(lw, bounds.width), height: 16)
        link.frame = NSRect(x: lw + 8, y: 4, width: ceil(link.textWidth) + 1, height: 16)
    }

    override func updateLayer() {
        label.color = Themed.color(\.mutedForeground)
        link.color = Themed.color(\.mutedForeground)
        link.hoverColor = Themed.color(\.foreground)
    }
}

/// One comment card (`rounded-lg border border-border/60`): a `bg-muted/25` head with the author,
/// the time and the verdict, then the body.
final class CommentCard: DSView, StackItem, FocusWithinObserver {
    let reactionBar = PullRequestReactionBarView()
    /// The pencil fades in while the card (`article.group`) is hovered or holds keyboard focus
    /// (`PullRequestEditButton`, PullRequestEditButton.tsx:17, PullRequestSummaryTab.tsx:215).
    private var hover: HoverGroup?
    private var focusWithin = false
    func focusWithinChanged(_ focused: Bool) { focusWithin = focused; revealEdit() }
    private func revealEdit() { HoverReveal.fade([editButton], visible: hover?.hovered == true || focusWithin) }
    private let editButton = ButtonView(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs)
    private(set) var editor: PullRequestMarkdownEditorView?
    var onEdit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: ((String) -> Void)?
    private let headFill = CALayer()
    private let avatar = PullRequestAvatarView()
    private let login = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let time = LabelView("", font: DSFont.ui(12))
    private let state = LabelView("", font: DSFont.ui(12))
    private let body = MarkdownView()
    private let hasBody: Bool
    /// A resolved or dismissed remark (`CollapsedComment`): no head fill, a status toggle and a
    /// one-line preview while closed, the words below once opened.
    private let collapsed: PullRequestDetailLogic.Collapsed?
    private(set) var isOpen = false
    private var mayEdit = false
    private var toggle: ButtonView?
    private let chevron = IconView(name: .chevronDown, size: 14)
    private let location = LabelView("", font: DSFont.mono(12))
    private let outdated = LabelView("Outdated", font: DSFont.ui(12))
    private var summary: CollapsedSummaryLine?
    /// A finished thread's reply count beside the identity, its replies in the opened panel (`mt-3`)
    /// and what the host holds back below it (`px-3 pb-3`) (3473 PullRequestSummaryTab.tsx:236-281).
    private let replyCount = LabelView("", font: DSFont.ui(12))
    private let replies: PullRequestReplyList?
    private let moreReplies: PullRequestMoreRepliesLine?
    var onResize: (() -> Void)?

    /// `reply`: a review thread's answer, which names no file (the finding above it does).
    init(_ c: PullRequestComment, nowMs: Int64, cwd: String, canEdit: Bool = false, canReact: Bool = false, editing: Bool = false,
         collapsed: PullRequestDetailLogic.Collapsed? = nil, open: Bool = false, reply: Bool = false,
         replyCount count: Int = 0, replies: PullRequestReplyList? = nil, moreReplies: PullRequestMoreRepliesLine? = nil) {
        self.replies = replies
        self.moreReplies = moreReplies
        // An empty verdict hides the body, unless this reader may rewrite it (the pencil lives there).
        hasBody = PullRequestDetailLogic.visibleBody(c.body) != nil || canEdit
        self.collapsed = collapsed
        // An edit in progress keeps its card open.
        isOpen = open || editing
        super.init(frame: .zero)
        reactionBar.canReact = canReact
        reactionBar.reactions = c.reactions ?? []
        addSubview(reactionBar)
        editButton.iconSize = 12
        editButton.setAccessibilityLabel("Edit comment")
        editButton.isHidden = !canEdit || editing
        mayEdit = canEdit
        editButton.action = { [weak self] in self?.onEdit?() }
        editButton.alphaValue = 0
        addSubview(editButton)
        hover = HoverGroup(self) { [weak self] _ in self?.revealEdit() }
        if editing {
            let e = PullRequestMarkdownEditorView(value: c.body, label: "Edit comment", cwd: cwd)
            e.onCancel = { [weak self] in self?.onCancel?() }
            e.onSave = { [weak self] body in self?.onSave?(body) }
            editor = e
            addSubview(e)
            DispatchQueue.main.async { [weak e] in e?.focus() }
        }
        headFill.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(headFill)
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        avatar.actor = c.author
        login.text = c.author?.login ?? "ghost"
        time.text = TimestampFormat.formatRelativeTimeLabel(c.createdAt, nowMs: nowMs)
        if let outcome = PullRequestDetailLogic.reviewOutcome(c.reviewState) {
            state.text = outcome == "approved" ? "Approved" : outcome == "changes-requested" ? "Changes requested" : "Review dismissed"
        } else if c.kind == "review-comment", !reply, let path = c.path {
            state.text = path
        }
        for l in [login, time, state] { l.lineHeight = 16; addSubview(l) }
        addSubview(avatar)
        body.cwd = cwd
        if hasBody { body.setMarkdown(c.body) }
        addSubview(body)
        if let collapsed {
            headFill.isHidden = true
            state.isHidden = true
            // `rounded-md px-2 py-1 text-xs gap-1.5`, muted, `hover:bg-muted hover:text-foreground`.
            let t = ButtonView(collapsed.label, variant: .ghostMuted, size: .xs)
            t.accessory = chevron
            t.action = { [weak self] in self?.setOpen(!(self?.isOpen ?? false)) }
            t.setAccessibilityLabel(collapsed.label)
            addSubview(t)
            toggle = t
            chevron.setRotation(isOpen ? 180 : 0, motion: .none)
            location.text = collapsed.location ?? ""
            location.lineHeight = 16
            location.truncates = true
            location.toolTip = collapsed.location
            outdated.lineHeight = 16
            outdated.isHidden = !collapsed.outdated
            [location, outdated].forEach(addSubview)
            if count > 0 {
                replyCount.text = PullRequestDetailLogic.replyCountLabel(count)
                replyCount.lineHeight = 16
                addSubview(replyCount)
            }
            replies.map(addSubview)
            moreReplies.map(addSubview)
            if let visible = PullRequestDetailLogic.visibleBody(c.body) {
                let line = CollapsedSummaryLine(PullRequestDetailLogic.collapsedSummary(visible))
                line.onClick = { [weak self] in self?.setOpen(true) }
                addSubview(line)
                summary = line
            }
        }
    }

    /// Opens or closes the words, sliding the cards below (`CollapsiblePanel`, `{open ? … : null}`).
    func setOpen(_ open: Bool) {
        guard collapsed != nil, open != isOpen else { return }
        CollapseMotion.run(in: self, showsClosingContent: false) {
            isOpen = open
            chevron.setRotation(open ? 180 : 0)
            needsLayout = true
            onResize?()
        }
    }

    /// The `p-3` block's height: the status row, the location and, while closed, the preview.
    private var collapsedHead: CGFloat {
        guard let collapsed else { return 0 }
        return 12 + 24 + (collapsed.location != nil ? 24 : 0) + (!isOpen && summary != nil ? 24 : 0) + 12
    }

    /// The words shown in an opened card: none for a bare verdict nobody may rewrite.
    private var collapsedShowsBody: Bool { isOpen && (hasBody || editor != nil) }

    /// What the host holds back, below the panel.
    private var moreRepliesHeight: CGFloat { moreReplies == nil ? 0 : 24 + 12 }

    func height(forWidth w: CGFloat) -> CGFloat {
        if collapsed != nil {
            guard isOpen else { return collapsedHead + moreRepliesHeight + 2 }
            let ew: CGFloat = mayEdit && editor == nil ? 28 : 0
            let words = editor.map { $0.height(forWidth: w - 24) } ?? (collapsedShowsBody ? body.height(forWidth: w - 24 - ew) : 0)
            let replyBlock = replies.map { 12 + $0.height(forWidth: w - 26) } ?? 0
            return collapsedHead + (collapsedShowsBody ? 8 + words : 0) + replyBlock + 12 + moreRepliesHeight + 2
        }
        if let editor { return 36 + 24 + editor.height(forWidth: w - 24) + 2 }
        return 36 + (hasBody ? 24 + body.height(forWidth: w - 24 - (editButton.isHidden ? 0 : 28)) : 0) + 2
    }

    override func layout() {
        super.layout()
        if collapsed != nil { layoutCollapsed(); return }
        headFill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 37)
        avatar.frame = NSRect(x: 12, y: 11, width: 16, height: 16)
        var x: CGFloat = 34
        let lw = ceil(login.textWidth) + 1
        login.frame = NSRect(x: x, y: 11, width: lw, height: 16); x += lw + 8
        let tw = ceil(time.textWidth) + 1
        time.frame = NSRect(x: x, y: 11, width: tw, height: 16); x += tw + 8
        let rw = reactionBar.isHidden ? 0 : reactionBar.width
        reactionBar.frame = NSRect(x: bounds.width - 12 - rw, y: 7, width: rw, height: 24)
        state.frame = NSRect(x: x, y: 11, width: max(0, bounds.width - 12 - x - (rw > 0 ? rw + 8 : 0)), height: 16)
        body.isHidden = !hasBody || editor != nil
        let ew: CGFloat = editButton.isHidden ? 0 : 28
        if hasBody { body.frame = NSRect(x: 12, y: 37 + 12, width: bounds.width - 24 - ew, height: body.height(forWidth: bounds.width - 24 - ew)) }
        editButton.frame = NSRect(x: bounds.width - 12 - 24, y: 37 + 8, width: 24, height: 24)
        if let editor { editor.frame = NSRect(x: 12, y: 37 + 12, width: bounds.width - 24, height: editor.height(forWidth: bounds.width - 24)) }
    }

    /// `p-3`: identity, the status toggle and the reactions on one row (`items-start gap-2`), then
    /// `mt-2` location and preview; opened, the words below in `px-3 pb-3` with `mt-2`.
    private func layoutCollapsed() {
        let top: CGFloat = 1 + 12
        let rw = reactionBar.isHidden ? 0 : reactionBar.width
        reactionBar.frame = NSRect(x: bounds.width - 13 - rw, y: top, width: rw, height: 24)
        var x: CGFloat = 13
        avatar.frame = NSRect(x: x, y: top + 4, width: 16, height: 16); x += 16 + 6
        let lw = ceil(login.textWidth) + 1
        login.frame = NSRect(x: x, y: top + 4, width: lw, height: 16); x += lw + 8
        let tw = ceil(time.textWidth) + 1
        time.frame = NSRect(x: x, y: top + 4, width: tw, height: 16); x += tw + 8
        if !replyCount.text.isEmpty {
            let cw = ceil(replyCount.textWidth) + 1
            replyCount.frame = NSRect(x: x, y: top + 4, width: cw, height: 16); x += cw + 8
        }
        if let toggle {
            let w = ceil(toggle.intrinsicContentSize.width)
            toggle.frame = NSRect(x: x, y: top, width: w, height: 24)
        }
        var y = top + 24
        let hasLocation = !(collapsed?.location ?? "").isEmpty
        location.isHidden = !hasLocation
        outdated.isHidden = !hasLocation || collapsed?.outdated != true
        if hasLocation {
            let ow = outdated.isHidden ? 0 : ceil(outdated.textWidth) + 1 + 8
            location.frame = NSRect(x: 13, y: y + 8, width: min(ceil(location.textWidth) + 1, bounds.width - 26 - ow), height: 16)
            outdated.frame = NSRect(x: location.frame.maxX + 8, y: y + 8, width: ow - 8, height: 16)
            y += 24
        }
        summary?.isHidden = isOpen
        if let summary, !isOpen {
            summary.frame = NSRect(x: 13, y: y + 8, width: bounds.width - 26, height: 16)
        }
        let bodyTop = 1 + collapsedHead + 8
        let ew: CGFloat = mayEdit && editor == nil ? 28 : 0
        body.isHidden = !collapsedShowsBody || editor != nil
        editButton.isHidden = !mayEdit || editor != nil || !isOpen
        if collapsedShowsBody {
            body.frame = NSRect(x: 13, y: bodyTop, width: bounds.width - 26 - ew, height: body.height(forWidth: bounds.width - 26 - ew))
            editButton.frame = NSRect(x: bounds.width - 13 - 24, y: bodyTop - 4, width: 24, height: 24)
        }
        if let editor { editor.frame = NSRect(x: 13, y: bodyTop, width: bounds.width - 26, height: editor.height(forWidth: bounds.width - 26)) }
        replies?.isHidden = !isOpen
        if let replies, isOpen {
            let wordsBottom = editor.map { $0.frame.maxY } ?? (collapsedShowsBody ? body.frame.maxY : 1 + collapsedHead)
            replies.frame = NSRect(x: 13, y: wordsBottom + 12, width: bounds.width - 26, height: replies.height(forWidth: bounds.width - 26))
        }
        moreReplies?.frame = NSRect(x: 13, y: bounds.height - 1 - 12 - 24, width: bounds.width - 26, height: 24)
    }

    override func updateLayer() {
        layer?.borderColor = Themed.color(\.border, 0.6).cgColor(in: self)
        chevron.strokeColor = Themed.color(\.mutedForeground)
        location.color = Themed.color(\.mutedForeground)
        replyCount.color = Themed.color(\.mutedForeground)
        outdated.color = Themed.color(\.mutedForeground)
        layer?.backgroundColor = WindowGlass.paneFill.cgColor(in: self)
        headFill.backgroundColor = Themed.color(\.muted, 0.25).cgColor(in: self)
        login.color = Themed.color(\.foreground)
        time.color = Themed.color(\.mutedForeground)
        state.color = Themed.color(\.mutedForeground)
    }
}

/// A collapsed remark's preview (`mt-2 block w-full truncate text-left text-xs text-muted-foreground
/// hover:text-foreground`): one line, and a press opens the card.
final class CollapsedSummaryLine: DSView {
    private let label = LabelView("", font: DSFont.ui(12))
    private var hover: HoverGroup?
    var onClick: (() -> Void)?

    init(_ text: String) {
        super.init(frame: .zero)
        label.text = text
        label.lineHeight = 16
        label.truncates = true
        addSubview(label)
        hover = HoverGroup(self) { [weak self] _ in self?.needsDisplay = true; self?.updateLayer() }
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }

    override var wantsUpdateLayer: Bool { true }
    override func layout() { super.layout(); label.frame = bounds }
    override func updateLayer() { label.color = Themed.color(hover?.hovered == true ? \.foreground : \.mutedForeground) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Timeline

/// The Timeline tab (PullRequestTimelineTab.tsx): a rail at 15pt with one row per lifecycle event,
/// commit and verdict, and runs of remarks folded into one conversation row; newest first.
public final class PullRequestTimelineView: DSView {
    private let stack = StackScrollView()
    private let rail = CALayer()
    var newestFirst = true { didSet { rebuild() } }
    var onOpenCommit: ((String) -> Void)?
    var onOpenURL: ((String) -> Void)?
    private var detail: PullRequestDetail?
    private var pending = true
    private var error: String?
    private var nowMs: Int64 = 0
    private let note = NoteItem()
    var scrollTarget: PullRequestScrollWatcher { stack.watcher }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(stack)
        stack.document.insets = NSEdgeInsets(top: 20, left: 16, bottom: 56, right: 16)
        stack.document.maxWidth = 768
        rail.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        stack.document.layer?.addSublayer(rail)
    }

    func set(_ d: PullRequestDetail, pending: Bool, error: String?, nowMs: Int64) {
        detail = d; self.pending = pending; self.error = error; self.nowMs = nowMs
        rebuild()
    }

    private func rebuild() {
        guard let d = detail else { return }
        if pending || error != nil {
            note.text = pending ? "Loading activity…" : error ?? ""
            stack.document.items = [note]
            stack.reload()
            return
        }
        let events = PullRequestDetailLogic.timeline(d)
        let ordered = newestFirst ? events : events.reversed()
        let newestCommit = PullRequestDetailLogic.newestCommitAt(d.commits)
        let items: [StackItem] = PullRequestDetailLogic.groupConversations(ordered).map { row in
            switch row {
            case .comments(let events): return ConversationRow(events, nowMs: nowMs, cwd: d.workspaceRoot)
            case .event(let e):
                if let thread = e.thread {
                    let r = ReviewThreadRow(e, thread: thread, nowMs: nowMs, cwd: d.workspaceRoot)
                    r.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
                    return r
                }
                if e.kind == .commit {
                    let r = TimelineEventRow(commit: e, nowMs: nowMs)
                    r.onClick = { [weak self] in self?.onOpenCommit?(e.id) }
                    return r
                }
                if let outcome = PullRequestDetailLogic.reviewOutcome(e.reviewState) {
                    let stale = newestCommit.map { e.at < $0 } ?? false
                    return TimelineEventRow(verdict: e, outcome: outcome, stale: stale, nowMs: nowMs, cwd: d.workspaceRoot)
                }
                return TimelineEventRow(lifecycle: e, nowMs: nowMs)
            }
        }
        note.text = "No activity yet."
        stack.document.items = items.isEmpty ? [note] : items
        stack.reload()
    }

    public override func layout() {
        super.layout()
        stack.frame = bounds
        let doc = stack.document
        let inner = doc.bounds.width - 32
        let x = 16 + (inner - min(768, inner)) / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rail.frame = CGRect(x: x + 15, y: 24, width: 1, height: max(0, doc.bounds.height - 20 - 56 - 20 - 4))
        rail.isHidden = pending || error != nil
        CATransaction.commit()
    }

    public override func updateLayer() { rail.backgroundColor = Themed.color(\.border, 0.45).cgColor(in: self) }

    final class NoteItem: DSView, StackItem {
        private let label = LabelView("", font: DSFont.ui(12))
        var text: String { get { label.text } set { label.text = newValue } }
        override init(frame frameRect: NSRect) { super.init(frame: frameRect); label.alignment = .center; label.lineHeight = 16; addSubview(label) }
        func height(forWidth width: CGFloat) -> CGFloat { 96 }
        override func layout() { super.layout(); label.frame = NSRect(x: 0, y: 40, width: bounds.width, height: 16) }
        override func updateLayer() { label.color = Themed.color(\.mutedForeground) }
    }
}

/// The rail's marker (`size-8 bg-background`) with an avatar (`size-7`) or a 14pt glyph.
final class TimelineMarker: DSView {
    private var icon: IconView?
    private var avatar: PullRequestAvatarView?
    /// `opacity-45` on the avatar.
    var muted = false { didSet { avatar?.alphaValue = muted ? 0.45 : 1 } }
    init(actor: PullRequestActor?, fallback: IconName, muted: Bool = false) {
        self.muted = muted
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        if let actor {
            let a = PullRequestAvatarView()
            a.actor = actor
            a.alphaValue = muted ? 0.45 : 1
            addSubview(a); avatar = a
        } else {
            let i = IconView(name: fallback, size: 14)
            addSubview(i); icon = i
        }
    }
    override func layout() {
        super.layout()
        avatar?.frame = NSRect(x: 2, y: 2, width: 28, height: 28)
        icon?.frame = NSRect(x: 9, y: 9, width: 14, height: 14)
    }
    override func updateLayer() {
        layer?.backgroundColor = WindowGlass.paneFill.cgColor(in: self)
        icon?.strokeColor = Themed.color(\.mutedForeground)
    }
}

/// A lifecycle, commit or verdict row (`relative mb-5 pl-12`).
final class TimelineEventRow: DSView, StackItem {
    private let marker: TimelineMarker
    private let title = LabelView("", font: DSFont.ui(12, weight: .semibold))
    private let actorName = LabelView("", font: DSFont.ui(12, weight: .semibold))
    private let subtitle = LabelView("", font: DSFont.ui(11))
    private let stat = PullRequestDiffStatView()
    private var body: MarkdownView?
    private var verdictIcon: IconView?
    var onClick: (() -> Void)?
    private let pinTop: Bool
    /// Commit rows: `transition-colors group-hover:text-primary` on the title (PullRequestTimelineTab.tsx:389).
    private var hover: HoverGroup?

    init(lifecycle e: PullRequestDetailLogic.TimelineEvent, nowMs: Int64) {
        let (icon, label): (IconName, String) = e.kind == .opened ? (.gitPullRequestArrow, "Pull request opened")
            : e.kind == .merged ? (.gitMerge, "Pull request merged") : (.gitPullRequestClosed, "Pull request closed")
        marker = TimelineMarker(actor: nil, fallback: icon)
        pinTop = false
        super.init(frame: .zero)
        actorName.text = e.actor?.login ?? ""
        title.text = label
        subtitle.text = TimestampFormat.formatRelativeTimeLabel(e.at, nowMs: nowMs)
        setup()
    }

    init(commit e: PullRequestDetailLogic.TimelineEvent, nowMs: Int64) {
        marker = TimelineMarker(actor: e.actor, fallback: .gitCommitHorizontal)
        pinTop = false
        super.init(frame: .zero)
        title.text = e.body ?? "Untitled commit"
        subtitle.text = "\(e.id.prefix(7))   \(TimestampFormat.formatRelativeTimeLabel(e.at, nowMs: nowMs))"
        if let a = e.additions, let d = e.deletions { stat.additions = a; stat.deletions = d } else { stat.isHidden = true }
        stat.font = DSFont.mono(10)
        setup()
        setAccessibilityLabel("View commit \(e.id)")
        hover = HoverGroup(self) { [weak self] _ in self?.redisplay(transitioning: .color) }
    }

    init(verdict e: PullRequestDetailLogic.TimelineEvent, outcome: String, stale: Bool, nowMs: Int64, cwd: String) {
        marker = TimelineMarker(actor: e.actor, fallback: outcome == "approved" ? .circleCheck : outcome == "changes-requested" ? .circleX : .circleDashed)
        pinTop = true
        super.init(frame: .zero)
        actorName.text = e.actor?.login ?? "ghost"
        let label = outcome == "approved" ? "Approved" : outcome == "changes-requested" ? "Changes requested" : "Review dismissed"
        title.text = stale ? "\(label) earlier changes" : label
        subtitle.text = TimestampFormat.formatRelativeTimeLabel(e.at, nowMs: nowMs)
        let icon = IconView(name: outcome == "approved" ? .circleCheck : outcome == "changes-requested" ? .circleX : .circleDashed, size: 14,
                            strokeColor: outcome == "approved" ? PullRequestStyle.color(.open) : outcome == "changes-requested" ? Themed.color(\.destructive) : Themed.color(\.mutedForeground, 0.7))
        verdictIcon = icon
        addSubview(icon)
        if let text = e.body {
            let m = MarkdownView()
            m.cwd = cwd
            m.setMarkdown(text)
            body = m
            addSubview(m)
        }
        setup()
    }

    private func setup() {
        for l in [title, actorName] { l.lineHeight = 16 }
        subtitle.lineHeight = 16
        stat.lineHeight = 16
        [marker, actorName, title, subtitle, stat].forEach(addSubview)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let base: CGFloat = 6 + 16 + 4 + 16 + 6
        return base + (body.map { 8 + $0.height(forWidth: width - 48) } ?? 0) + 20
    }

    override func layout() {
        super.layout()
        let contentH = bounds.height - 20
        marker.frame = NSRect(x: 0, y: pinTop ? 24 - 16 : (contentH - 32) / 2, width: 32, height: 32)
        var x: CGFloat = 48
        if !actorName.text.isEmpty {
            let aw = ceil(actorName.textWidth) + 1
            actorName.frame = NSRect(x: x, y: 6, width: aw, height: 16); x += aw + 6
        }
        if let verdictIcon { verdictIcon.frame = NSRect(x: x, y: 7, width: 14, height: 14); x += 14 + 6 }
        let sw = stat.isHidden ? 0 : stat.width
        title.frame = NSRect(x: x, y: 6, width: max(0, bounds.width - x - (sw > 0 ? sw + 10 : 0)), height: 16)
        subtitle.frame = NSRect(x: 48, y: 26, width: max(0, bounds.width - 48), height: 16)
        if sw > 0 { stat.frame = NSRect(x: bounds.width - sw, y: (contentH - 16) / 2, width: sw, height: 16) }
        if let body { body.frame = NSRect(x: 48, y: 50, width: bounds.width - 48, height: body.height(forWidth: bounds.width - 48)) }
    }

    override func updateLayer() {
        title.color = hover?.hovered == true ? Themed.color(\.primary) : Themed.color(\.foreground)
        actorName.color = Themed.color(\.foreground)
        subtitle.color = Themed.color(\.mutedForeground)
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// A run of remarks folded into one row (`ConversationGroup`): "N comments" and "M authors · time",
/// opening to the cards.
final class ConversationRow: DSView, StackItem {
    private let marker: TimelineMarker
    private let title = LabelView("", font: DSFont.ui(12, weight: .semibold))
    private let subtitle = LabelView("", font: DSFont.ui(10))
    private let chevron = IconView(name: .chevronDown, size: 14)
    private var cards: [CommentCard] = []
    private var open = false { didSet { (superview as? StackDocument)?.needsLayout = true; superview?.superview?.superview?.superview?.needsLayout = true; needsLayout = true; cards.forEach { $0.isHidden = !open }
        // `transition-transform`, `rotate-180` when open (PullRequestTimelineTab.tsx:336-341).
        chevron.setRotation(open ? 180 : 0) } }

    init(_ events: [PullRequestDetailLogic.TimelineEvent], nowMs: Int64, cwd: String) {
        var actors: [String: PullRequestActor] = [:]
        var order: [String] = []
        for e in events { if let a = e.actor, actors[a.login] == nil { actors[a.login] = a; order.append(a.login) } }
        marker = TimelineMarker(actor: order.first.flatMap { actors[$0] }, fallback: .messageSquare, muted: true)
        super.init(frame: .zero)
        title.text = "\(events.count) \(events.count == 1 ? "comment" : "comments")"
        subtitle.text = "\(order.count) \(order.count == 1 ? "author" : "authors") · \(TimestampFormat.formatRelativeTimeLabel(events.first?.at ?? "", nowMs: nowMs))"
        title.lineHeight = 16
        subtitle.lineHeight = 14
        [marker, title, subtitle, chevron].forEach(addSubview)
        cards = events.map { e in
            let c = CommentCard(PullRequestComment(id: e.id, kind: e.kind == .review ? "review" : "issue-comment", author: e.actor, body: e.body ?? "",
                                                   createdAt: e.at, url: e.url, path: e.path, reviewState: e.reviewState), nowMs: nowMs, cwd: cwd)
            c.isHidden = true
            addSubview(c)
            return c
        }
        alphaValue = 1
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let head: CGFloat = 8 + 16 + 2 + 14 + 8
        guard open else { return head + 20 }
        return head + 4 + cards.map { $0.height(forWidth: width - 48) }.reduce(0, +) + CGFloat(max(0, cards.count - 1)) * 4 + 20
    }

    override func layout() {
        super.layout()
        marker.frame = NSRect(x: 0, y: 24 - 16, width: 32, height: 32)
        title.frame = NSRect(x: 48, y: 8, width: max(0, bounds.width - 48 - 30), height: 16)
        subtitle.frame = NSRect(x: 48, y: 26, width: max(0, bounds.width - 48 - 30), height: 14)
        chevron.frame = NSRect(x: bounds.width - 14, y: 17, width: 14, height: 14)
        var y: CGFloat = 52
        for c in cards where open {
            let h = c.height(forWidth: bounds.width - 48)
            c.frame = NSRect(x: 48, y: y, width: bounds.width - 48, height: h)
            y += h + 4
        }
    }

    override func updateLayer() {
        let c = open ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        title.color = c
        title.alphaValue = open ? 1 : 0.55
        subtitle.color = Themed.color(\.mutedForeground)
        subtitle.alphaValue = open ? 1 : 0.55
        chevron.strokeColor = Themed.color(\.mutedForeground)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // `CollapsiblePanel` (PullRequestTimelineTab.tsx:344) around `{open ? … : null}`: the cards slide open
        // over 200 ms and go at once on close while the gap closes.
        if p.y < 48 {
            CollapseMotion.run(in: self, showsClosingContent: false) { open.toggle(); needsDisplay = true; enclosingStack?.reload() }
        }
    }

    private var enclosingStack: StackScrollView? {
        var v = superview
        while let s = v { if let stack = s as? StackScrollView { return stack }; v = s.superview }
        return nil
    }
}

/// A review thread's finding on the timeline (`ReviewThreadEvent`, 3473 PullRequestTimelineTab.tsx:373-468,
/// 70a869d262): a `px-2 py-2 text-2xs` toggle with the file and line, Resolved, Review dismissed and
/// Outdated, and while closed the author and reply count; open, the finding and its replies behind a
/// rule (`ml-2 border-l pl-3 space-y-1`). A finished thread starts closed with a muted marker.
final class ReviewThreadRow: DSView, StackItem {
    private let marker: TimelineMarker
    private let head = Head()
    private let root: CommentCard
    private let replies: PullRequestReplyList?
    private let more: PullRequestMoreRepliesLine?
    private var expanded: Bool
    var onOpenURL: ((String) -> Void)? { didSet { more?.onOpenURL = onOpenURL } }

    init(_ e: PullRequestDetailLogic.TimelineEvent, thread t: PullRequestDetailLogic.TimelineThread, nowMs: Int64, cwd: String) {
        let isDismissed = PullRequestDetailLogic.reviewOutcome(e.reviewState) == "dismissed"
        expanded = !t.isResolved && !isDismissed
        marker = TimelineMarker(actor: e.actor, fallback: .messageSquare, muted: !expanded)
        let card = { (e: PullRequestDetailLogic.TimelineEvent) in
            CommentCard(PullRequestComment(id: e.id, kind: e.kind == .review ? "review" : "review-comment", author: e.actor, body: e.body ?? "",
                                           createdAt: e.at, url: e.url, path: e.path, reviewState: e.reviewState), nowMs: nowMs, cwd: cwd, reply: true)
        }
        root = card(e)
        replies = t.replies.isEmpty ? nil : PullRequestReplyList(t.replies.map(card), indent: 8, rule: 1, spacing: 4)
        more = t.more.hasMoreReplies ? PullRequestMoreRepliesLine(t.more) : nil
        super.init(frame: .zero)
        let replyCount = t.replies.count + t.more.moreReplies
        head.set(location: t.line.map { "\(t.path):\($0)" } ?? t.path, resolved: t.isResolved, dismissed: isDismissed, outdated: t.isOutdated,
                 closedSummary: "· \(e.actor?.login ?? "ghost")" + (replyCount > 0 ? " · \(PullRequestDetailLogic.replyCountLabel(replyCount))" : ""))
        head.onToggle = { [weak self] in self?.toggle() }
        [marker, head, root].forEach(addSubview)
        replies.map(addSubview)
        more.map(addSubview)
        sync(motion: .none)
    }

    private func sync(motion: IconView.RotationMotion = .ease(0.15)) {
        root.isHidden = !expanded
        replies?.isHidden = !expanded
        marker.muted = !expanded
        head.setExpanded(expanded, motion: motion)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let w = width - 48
        let open = expanded ? root.height(forWidth: w) + (replies.map { $0.height(forWidth: w) } ?? 0) : 0
        return 32 + open + (more == nil ? 0 : 24) + 20
    }

    override func layout() {
        super.layout()
        marker.frame = NSRect(x: 0, y: 24 - 16, width: 32, height: 32)
        head.frame = NSRect(x: 48, y: 0, width: bounds.width - 48, height: 32)
        var y: CGFloat = 32
        if expanded {
            let w = bounds.width - 48
            let h = root.height(forWidth: w)
            root.frame = NSRect(x: 48, y: y, width: w, height: h); y += h
            if let replies {
                let rh = replies.height(forWidth: w)
                replies.frame = NSRect(x: 48, y: y, width: w, height: rh); y += rh
            }
        }
        // `px-2`.
        more?.frame = NSRect(x: 48 + 8, y: y, width: bounds.width - 48 - 16, height: 24)
    }

    private func toggle() {
        // `{expanded ? … : null}`: the finding comes and goes at once, as T3 renders it.
        expanded.toggle()
        sync()
        needsLayout = true
        var v = superview
        while let s = v { if let stack = s as? StackScrollView { stack.reload(); break }; v = s.superview }
    }

    /// The toggle: `flex items-center gap-2 px-2 py-2 text-2xs text-muted-foreground hover:text-foreground`.
    final class Head: DSView {
        private let fileIcon = IconView(name: .fileCode2, size: 12)
        private let location = LabelView("", font: DSFont.mono(11))
        private let resolvedIcon = IconView(name: .circleCheck, size: 12)
        private let resolved = LabelView("Resolved", font: DSFont.ui(11, weight: .medium))
        private let dismissed = LabelView("Review dismissed", font: DSFont.ui(11, weight: .medium))
        private let outdated = LabelView("Outdated", font: DSFont.ui(11, weight: .medium))
        private let closedSummary = LabelView("", font: DSFont.ui(11))
        private let chevron = IconView(name: .chevronDown, size: 14)
        private var hover: HoverGroup?
        private var expanded = false
        var onToggle: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            location.truncates = true
            for l in [location, resolved, dismissed, outdated, closedSummary] { l.lineHeight = 16 }
            [fileIcon, location, resolvedIcon, resolved, dismissed, outdated, closedSummary, chevron].forEach(addSubview)
            hover = HoverGroup(self) { [weak self] _ in self?.redisplay(transitioning: .color) }
            setAccessibilityRole(.button)
        }

        func set(location text: String, resolved isResolved: Bool, dismissed isDismissed: Bool, outdated isOutdated: Bool, closedSummary summary: String) {
            location.text = text
            resolved.isHidden = !isResolved
            resolvedIcon.isHidden = !isResolved
            dismissed.isHidden = !isDismissed
            outdated.isHidden = !isOutdated
            closedSummary.text = summary
            setAccessibilityLabel(text)
        }

        func setExpanded(_ open: Bool, motion: IconView.RotationMotion) {
            expanded = open
            closedSummary.isHidden = open
            chevron.setRotation(open ? 180 : 0, motion: motion)
            setAccessibilityExpanded(open)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let right = bounds.width - 8
            chevron.frame = NSRect(x: right - 14, y: 9, width: 14, height: 14)
            // `gap-2` between parts, `gap-1` inside Resolved.
            var tail: [(NSView, CGFloat, CGFloat)] = []
            if !resolved.isHidden { tail += [(resolvedIcon, 12, 8), (resolved, ceil(resolved.textWidth) + 1, 4)] }
            for l in [dismissed, outdated, closedSummary] where !l.isHidden { tail.append((l, ceil(l.textWidth) + 1, 8)) }
            let tailWidth = tail.reduce(CGFloat(0)) { $0 + $1.1 + $1.2 }
            var x: CGFloat = 8
            fileIcon.frame = NSRect(x: x, y: 10, width: 12, height: 12); x += 12 + 8
            let lw = min(ceil(location.textWidth) + 1, max(0, right - 14 - 8 - x - tailWidth))
            location.frame = NSRect(x: x, y: 8, width: lw, height: 16); x += lw
            for (v, w, gap) in tail {
                x += gap
                v.frame = v === resolvedIcon ? NSRect(x: x, y: 10, width: 12, height: 12) : NSRect(x: x, y: 8, width: w, height: 16)
                x += w
            }
        }

        override func updateLayer() {
            let c = Themed.color(hover?.hovered == true ? \.foreground : \.mutedForeground)
            fileIcon.strokeColor = c
            chevron.strokeColor = c
            [location, dismissed, outdated, closedSummary].forEach { $0.color = c }
            resolved.color = Themed.color(\.successForeground)
            resolvedIcon.strokeColor = Themed.color(\.successForeground)
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() } }
        override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
    }
}

/// The Description section (PullRequestSummaryTab.tsx:826-865): the Markdown with the pencil beside it
/// where the reader may rewrite it, or the editor (`allowEmpty`: saving nothing clears it).
final class PullRequestDescriptionItem: DSView, StackItem, FocusWithinObserver {
    let view = MarkdownView()
    /// The pencil fades in while the section body (`div.group`, PullRequestSummaryTab.tsx:827) is hovered.
    private var hover: HoverGroup?
    private var focusWithin = false
    func focusWithinChanged(_ focused: Bool) { focusWithin = focused; revealEdit() }
    private func revealEdit() { HoverReveal.fade([editButton], visible: hover?.hovered == true || focusWithin) }
    private let editButton = ButtonView(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs)
    private var editor: PullRequestMarkdownEditorView?
    private var detail: PullRequestDetail?
    private var editingURL: String?
    var saving = false { didSet { editor?.saving = saving } }
    var onSave: ((String) -> Void)?
    var onResize: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(view)
        editButton.iconSize = 12
        editButton.setAccessibilityLabel("Edit description")
        editButton.action = { [weak self] in self?.startEditing() }
        editButton.alphaValue = 0
        addSubview(editButton)
        hover = HoverGroup(self) { [weak self] _ in self?.revealEdit() }
    }

    func set(_ d: PullRequestDetail) {
        detail = d
        view.cwd = d.workspaceRoot
        view.setMarkdown(d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_No description provided._" : d.body)
        // Keyed by the pull request, so an editor left open never shows over the next one.
        if editingURL != nil && editingURL != d.url { stopEditing() }
        editButton.isHidden = editor != nil || !PullRequestWriteLogic.canEditChangeRequest(d)
        needsLayout = true
    }

    private func startEditing() {
        guard let d = detail else { return }
        let e = PullRequestMarkdownEditorView(value: d.body, label: "Pull request description", placeholder: "Describe this pull request",
                                              allowEmpty: true, cwd: d.workspaceRoot)
        e.onCancel = { [weak self] in self?.stopEditing(); self?.onResize?() }
        e.onSave = { [weak self] body in self?.onSave?(body) }
        e.onResize = { [weak self] in self?.onResize?() }
        editor = e
        editingURL = d.url
        addSubview(e)
        editButton.isHidden = true
        view.isHidden = true
        onResize?()
        DispatchQueue.main.async { [weak e] in e?.focus() }
    }

    func stopEditing() {
        editor?.removeFromSuperview()
        editor = nil
        editingURL = nil
        view.isHidden = false
        editButton.isHidden = detail.map { !PullRequestWriteLogic.canEditChangeRequest($0) } ?? true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if let editor { return editor.height(forWidth: width) }
        return view.height(forWidth: width - (editButton.isHidden ? 0 : 28))
    }

    override func layout() {
        super.layout()
        let ew: CGFloat = editButton.isHidden ? 0 : 28
        view.frame = NSRect(x: 0, y: 0, width: bounds.width - ew, height: bounds.height)
        editButton.frame = NSRect(x: bounds.width - 24, y: 0, width: 24, height: 24)
        editor?.frame = bounds
    }
}

/// Controls side by side with `gap-1`, sized to fit, for a section header's accessory slot.
final class HStackAccessory: DSView {
    var views: [NSView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; views.forEach(addSubview); invalidateIntrinsicContentSize() } }
    override var intrinsicContentSize: NSSize {
        let sizes = views.map(\.intrinsicContentSize)
        return NSSize(width: sizes.map { ceil($0.width) }.reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * 4,
                      height: sizes.map(\.height).max() ?? 0)
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for v in views {
            let s = v.intrinsicContentSize
            v.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: ceil(s.width), height: s.height)
            x += ceil(s.width) + 4
        }
    }
}
