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

/// A scroll view over a `StackDocument` that sizes the document on layout.
final class StackScrollView: DSView {
    let document = StackDocument()
    private let scroll: ScrollAreaView
    override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: document)
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
    private let markdown = MarkdownItem()
    private let checkRows = ChecksListItem()
    private let commentList = CommentsItem()
    private let orderButton = ButtonView("Newest first", icon: .arrowDownUp, variant: .ghostMuted, size: .xs)
    private var newestFirst = true
    private var detail: PullRequestDetail?
    var onOpenURL: ((String) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(stack)
        descriptionSection.body = markdown
        checks.body = checkRows
        comments.body = commentList
        comments.accessory = orderButton
        orderButton.iconSize = 12
        orderButton.action = { [weak self] in
            guard let self else { return }
            self.newestFirst.toggle()
            self.orderButton.title = self.newestFirst ? "Newest first" : "Oldest first"
            self.commentList.newestFirst = self.newestFirst
            self.stack.reload()
        }
        for s in [descriptionSection, checks, comments] { s.onToggle = { [weak self] in self?.stack.reload() } }
        checkRows.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        stack.document.items = [meta, descriptionSection, checks, comments]
        stack.document.insets = NSEdgeInsets(top: 0, left: 0, bottom: 56, right: 0)
    }

    func set(_ d: PullRequestDetail, activityPending: Bool, activityError: String?, nowMs: Int64) {
        detail = d
        meta.set(d)
        markdown.view.cwd = d.workspaceRoot
        markdown.view.setMarkdown(d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_No description provided._" : d.body)
        checkRows.checks = d.checks
        comments.title = "Comments (\(d.commentCount))"
        commentList.set(d, pending: activityPending, error: activityError, nowMs: nowMs)
        stack.reload()
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [reviewersLabel, labelsLabel, noneReviewers, noneLabels] { l.lineHeight = 16; addSubview(l) }
        [reviewersIcon, labelsIcon].forEach(addSubview)
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
    var isOpen: Bool { didSet { body?.isHidden = !isOpen; chevron.frameCenterRotation = isOpen ? -90 : 0; onToggle?() } }
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
        chevron.frameCenterRotation = isOpen ? -90 : 0
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
        if p.y < 40, accessory.map({ !$0.frame.contains(p) }) ?? true { isOpen.toggle() }
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

/// The Comments section: the truncation notice, "No comments yet.", or the cards.
// ponytail: every comment renders at once; T3 pages them by 20 and folds bot and resolved ones into
// groups. Add the paging when a long review thread is slow to open
final class CommentsItem: DSView, StackItem {
    private var cards: [CommentCard] = []
    private let note = TextBlockView()
    var newestFirst = true { didSet { needsLayout = true } }
    private var state: (pending: Bool, error: String?) = (true, nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        note.font = DSFont.ui(12)
        note.lineHeight = 16
        addSubview(note)
    }

    func set(_ d: PullRequestDetail, pending: Bool, error: String?, nowMs: Int64) {
        state = (pending, error)
        cards.forEach { $0.removeFromSuperview() }
        cards = pending || error != nil ? [] : d.comments.map { c in
            let card = CommentCard(c, nowMs: nowMs, cwd: d.workspaceRoot)
            addSubview(card)
            return card
        }
        note.text = pending ? "Loading comments…" : error ?? (d.comments.isEmpty ? "No comments yet." : "")
        needsLayout = true
    }

    private var ordered: [CommentCard] { newestFirst ? cards.reversed() : cards }

    func height(forWidth width: CGFloat) -> CGFloat {
        if cards.isEmpty { return 8 + note.height(forWidth: width) + 8 }
        return ordered.map { $0.height(forWidth: width) }.reduce(0, +) + CGFloat(cards.count - 1) * 12
    }

    override func layout() {
        super.layout()
        note.isHidden = !cards.isEmpty
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

/// One comment card (`rounded-lg border border-border/60`): a `bg-muted/25` head with the author,
/// the time and the verdict, then the body.
final class CommentCard: DSView {
    private let headFill = CALayer()
    private let avatar = PullRequestAvatarView()
    private let login = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let time = LabelView("", font: DSFont.ui(12))
    private let state = LabelView("", font: DSFont.ui(12))
    private let body = MarkdownView()
    private let hasBody: Bool

    init(_ c: PullRequestComment, nowMs: Int64, cwd: String) {
        hasBody = PullRequestDetailLogic.visibleBody(c.body) != nil
        super.init(frame: .zero)
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
        } else if c.kind == "review-comment", let path = c.path {
            state.text = path
        }
        for l in [login, time, state] { l.lineHeight = 16; addSubview(l) }
        addSubview(avatar)
        body.cwd = cwd
        if hasBody { body.setMarkdown(c.body) }
        addSubview(body)
    }

    func height(forWidth w: CGFloat) -> CGFloat { 36 + (hasBody ? 24 + body.height(forWidth: w - 24) : 0) + 2 }

    override func layout() {
        super.layout()
        headFill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 37)
        avatar.frame = NSRect(x: 12, y: 11, width: 16, height: 16)
        var x: CGFloat = 34
        let lw = ceil(login.textWidth) + 1
        login.frame = NSRect(x: x, y: 11, width: lw, height: 16); x += lw + 8
        let tw = ceil(time.textWidth) + 1
        time.frame = NSRect(x: x, y: 11, width: tw, height: 16); x += tw + 8
        state.frame = NSRect(x: x, y: 11, width: max(0, bounds.width - 12 - x), height: 16)
        body.isHidden = !hasBody
        if hasBody { body.frame = NSRect(x: 12, y: 37 + 12, width: bounds.width - 24, height: body.height(forWidth: bounds.width - 24)) }
    }

    override func updateLayer() {
        layer?.borderColor = Themed.color(\.border, 0.6).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        headFill.backgroundColor = Themed.color(\.muted, 0.25).cgColor(in: self)
        login.color = Themed.color(\.foreground)
        time.color = Themed.color(\.mutedForeground)
        state.color = Themed.color(\.mutedForeground)
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
    private var detail: PullRequestDetail?
    private var pending = true
    private var error: String?
    private var nowMs: Int64 = 0
    private let note = NoteItem()

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
    init(actor: PullRequestActor?, fallback: IconName, muted: Bool = false) {
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
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
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
        title.color = Themed.color(\.foreground)
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
    private var open = false { didSet { (superview as? StackDocument)?.needsLayout = true; superview?.superview?.superview?.superview?.needsLayout = true; needsLayout = true; cards.forEach { $0.isHidden = !open } } }

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
        chevron.frameCenterRotation = open ? 180 : 0
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
        if p.y < 48 { open.toggle(); needsDisplay = true; enclosingStack?.reload() }
    }

    private var enclosingStack: StackScrollView? {
        var v = superview
        while let s = v { if let stack = s as? StackScrollView { return stack }; v = s.superview }
        return nil
    }
}

// MARK: - Code

/// The Code tab (PullRequestCodeTab.tsx): a `h-10` toolbar with the commit scope and the counts,
/// over the shared diff list with a "Viewed" tick on each file header.
public final class PullRequestCodeView: DSView {
    private let toolbarFill = CALayer()
    private let rule = CALayer()
    private let scope = ButtonView("All commits", variant: .secondary, size: .xs)
    private let counts = LabelView("", font: DSFont.ui(12))
    private let list = DiffListView()
    private let scroll: ScrollAreaView
    private let status = LabelView("", font: DSFont.ui(12))
    private var commits: [PullRequestCommit] = []
    private var commit: String?
    private var paths: [String] = []
    private var states: [String: String]?
    private var overlay: [String: Bool] = [:]
    private var store: String?
    var onCommit: ((String?) -> Void)?
    var onSetViewed: ((String, Bool) -> Void)?

    public override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: list)
        super.init(frame: frameRect)
        for l in [toolbarFill, rule] { l.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]; layer?.addSublayer(l) }
        scope.trailingIcon = .chevronDown
        scope.iconSize = 14
        counts.lineHeight = 16
        status.lineHeight = 16
        status.alignment = .center
        [scope, counts, scroll, status].forEach(addSubview)
        scope.action = { [weak self] in self?.showScopeMenu() }
        list.onSetViewed = { [weak self] path, viewed in self?.onSetViewed?(path, viewed) }
    }

    func reset() { commit = nil; paths = []; list.setDiff(UnifiedDiff("")) }

    func set(patch: String?, loading: Bool, error: String?, commit: String?, commits: [PullRequestCommit]) {
        self.commits = commits.sorted { (T3Timestamp($0.committedDate).epochMs ?? 0) > (T3Timestamp($1.committedDate).epochMs ?? 0) }
        self.commit = commit
        scope.title = commit.flatMap { oid in commits.first { $0.oid == oid }?.messageHeadline } ?? "All commits"
        scope.isHidden = commits.isEmpty
        if let patch {
            let diff = UnifiedDiff(patch)
            paths = diff.files.map(\.path)
            list.setDiff(diff, collapsedByDefault: false)
            // Viewed files start folded.
            for (i, p) in paths.enumerated() where PullRequestDetailLogic.isFileViewed(p, states: states, overlay: overlay) { list.setCollapsed(i, true) }
        }
        status.text = loading ? "Loading pull request diff..." : error ?? (patch?.isEmpty == true ? "No patch available for this selection." : "")
        status.isHidden = status.text.isEmpty
        updateCounts()
        needsLayout = true
    }

    func setViewed(states: [String: String]?, overlay: [String: Bool], store: String?) {
        self.states = states; self.overlay = overlay; self.store = store
        if store == nil {
            list.viewedState = nil
        } else {
            list.viewedState = { [weak self] (path: String) -> (viewed: Bool, stale: Bool)? in
                guard let self else { return nil }
                let viewed = PullRequestDetailLogic.isFileViewed(path, states: self.states, overlay: self.overlay)
                let stale = PullRequestDetailLogic.isStale(path, states: self.states)
                return (viewed: viewed, stale: stale)
            }
        }
        updateCounts()
    }

    private func updateCounts() {
        var text = "\(paths.count) \(paths.count == 1 ? "file" : "files")"
        if store != nil && !paths.isEmpty {
            text += "  ·  \(PullRequestDetailLogic.countViewed(paths, states: states, overlay: overlay)) / \(paths.count) "
            text += store == "environment" ? "viewed in T3 Code" : "viewed"
        }
        counts.text = text
        needsLayout = true
    }

    private func showScopeMenu() {
        var items = [MenuItem.radio("All commits", checked: commit == nil) { [weak self] _ in self?.onCommit?(nil) }]
        items[0].closesOnClick = true
        for c in commits.prefix(50) {
            var item = MenuItem.radio(c.messageHeadline, checked: commit == c.oid) { [weak self] _ in self?.onCommit?(c.oid) }
            item.shortcut = String(c.oid.prefix(7))
            item.closesOnClick = true
            items.append(item)
        }
        MenuPopupView.show(items, from: scope, placement: .dropdown)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        toolbarFill.frame = CGRect(x: 0, y: 0, width: w, height: 40)
        rule.frame = CGRect(x: 0, y: 40, width: w, height: 1)
        CATransaction.commit()
        var x: CGFloat = 16
        if !scope.isHidden {
            let sw = min(256, ceil(scope.intrinsicContentSize.width))
            scope.frame = NSRect(x: x, y: 8, width: sw, height: 24); x += sw + 12
        }
        counts.frame = NSRect(x: x, y: 12, width: max(0, w - 16 - x), height: 16)
        scroll.frame = NSRect(x: 0, y: 41, width: w, height: max(0, bounds.height - 41))
        status.frame = NSRect(x: 16, y: 41 + 24, width: max(0, w - 32), height: 16)
    }

    public override func updateLayer() {
        toolbarFill.backgroundColor = Themed.color(\.background).cgColor(in: self)
        rule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        counts.color = Themed.color(\.mutedForeground)
        status.color = Themed.color(\.mutedForeground)
    }
}
