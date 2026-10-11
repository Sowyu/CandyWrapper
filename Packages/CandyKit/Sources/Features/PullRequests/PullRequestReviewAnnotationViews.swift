import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What a review conversation card can ask of the host (PullRequestCodeTab.tsx:929-990). Each
/// completion says whether the host took it, so a failed reply or edit keeps its words.
@MainActor
public struct PullRequestReviewThreadActions {
    public var reply: (_ threadId: String, _ body: String, _ done: @escaping @MainActor (Bool) -> Void) -> Void
    public var setResolved: (_ threadId: String, _ resolved: Bool) -> Void
    public var loadMore: (_ threadId: String, _ cursor: String, _ done: @escaping @MainActor (PullRequestThreadCommentsResult?) -> Void) -> Void
    public var editComment: (_ commentId: String, _ body: String, _ done: @escaping @MainActor (Bool) -> Void) -> Void
    public var react: (_ subjectId: String, _ content: String, _ reacted: Bool, _ bar: PullRequestReactionBarView) -> Void
    public init(reply: @escaping (String, String, @escaping @MainActor (Bool) -> Void) -> Void, setResolved: @escaping (String, Bool) -> Void,
                loadMore: @escaping (String, String, @escaping @MainActor (PullRequestThreadCommentsResult?) -> Void) -> Void,
                editComment: @escaping (String, String, @escaping @MainActor (Bool) -> Void) -> Void,
                react: @escaping (String, String, Bool, PullRequestReactionBarView) -> Void) {
        self.reply = reply; self.setResolved = setResolved; self.loadMore = loadMore; self.editComment = editComment; self.react = react
    }
}

/// The card frame (`mx-3 my-2 rounded-xl border border-border/70 bg-background p-3 text-sm shadow-sm`).
public class PullRequestAnnotationCardView: DSView, DiffAnnotationContent {
    let card = DSView()
    var dashed = false
    /// Asks the diff to lay out again after the card's height changed.
    var onResize: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.shadowOpacity = 1
        card.layer?.shadowRadius = 1
        card.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(card)
    }

    func contentHeight(forWidth width: CGFloat) -> CGFloat { 0 }
    public func height(forWidth width: CGFloat) -> CGFloat { 8 + 12 + contentHeight(forWidth: width - 24 - 24 - 2) + 12 + 8 + 2 }

    public override func layout() {
        super.layout()
        card.frame = NSRect(x: 12, y: 8, width: max(0, bounds.width - 24), height: max(0, bounds.height - 16))
    }

    public override func updateLayer() {
        card.layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        card.layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
        card.layer?.shadowColor = NSColor.black.withAlphaComponent(0.05).cgColor
    }

    /// The content box inside `p-3`.
    var inner: NSRect { NSRect(x: 13, y: 13, width: max(0, card.bounds.width - 26), height: max(0, card.bounds.height - 26)) }
}

/// `PendingReviewCommentCard` (PullRequestReviewAnnotation.tsx:57-86): dashed, "Pending — sent when
/// you submit the review", the trash, the words.
public final class PullRequestPendingCommentCardView: PullRequestAnnotationCardView {
    private let icon = IconView(name: .messageSquare, size: 14)
    private let label = LabelView("Pending — sent when you submit the review", font: DSFont.ui(12))
    private let remove = ButtonView(nil, icon: .trash2, variant: .ghost, size: .iconXs)
    private let body = TextBlockView()
    var onRemove: (() -> Void)?

    init(_ comment: PullRequestReviewCommentDraft) {
        super.init(frame: .zero)
        label.lineHeight = 16
        remove.iconSize = 14
        remove.setAccessibilityLabel("Discard this comment")
        remove.action = { [weak self] in self?.onRemove?() }
        body.font = DSFont.ui(14)
        body.lineHeight = 23
        body.text = comment.body
        [icon, label, remove, body].forEach(card.addSubview)
        card.layer?.borderWidth = 0
        dashBorder.fillColor = nil
        dashBorder.lineDashPattern = [4, 3]
        card.layer?.addSublayer(dashBorder)
    }

    private let dashBorder = CAShapeLayer()

    override func contentHeight(forWidth width: CGFloat) -> CGFloat { 24 + 8 + body.height(forWidth: width) }

    public override func layout() {
        super.layout()
        let r = inner
        icon.frame = NSRect(x: r.minX, y: r.minY + 5, width: 14, height: 14)
        label.frame = NSRect(x: r.minX + 22, y: r.minY + 4, width: max(0, r.width - 22 - 28), height: 16)
        remove.frame = NSRect(x: r.maxX - 24, y: r.minY, width: 24, height: 24)
        body.frame = NSRect(x: r.minX, y: r.minY + 32, width: r.width, height: body.height(forWidth: r.width))
        dashBorder.frame = card.bounds
        dashBorder.path = CGPath(roundedRect: card.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 11.5, cornerHeight: 11.5, transform: nil)
    }

    public override func updateLayer() {
        super.updateLayer()
        dashBorder.strokeColor = Themed.color(\.border, 0.7).cgColor(in: self)
        icon.strokeColor = Themed.color(\.mutedForeground)
        label.color = Themed.color(\.mutedForeground)
        body.color = Themed.color(\.foreground)
    }
}

/// `DiffCommentAnnotation kind="draft"` (DiffCommentAnnotation.tsx:117-170) with "Add to review": a
/// small textarea, the ⌘Enter hint, Cancel and the submit.
public final class PullRequestDraftCommentView: DSView, DiffAnnotationContent {
    public let textarea = TextareaView(size: .sm)
    private let hint = LabelView("⌘/Ctrl Enter to send", font: DSFont.ui(10))
    private let cancel = ButtonView("Cancel", variant: .ghostMuted, size: .xs)
    private let submit = ButtonView("Add to review", variant: .default, size: .xs)
    var onCancel: (() -> Void)?
    var onComment: ((String) -> Void)?
    var onResize: (() -> Void)?

    init(rangeLabel: String) {
        super.init(frame: .zero)
        textarea.placeholder = "Add a comment…"
        textarea.setAccessibilityLabel("Comment on lines \(rangeLabel)")
        hint.lineHeight = 14
        [textarea, hint, cancel, submit].forEach(addSubview)
        textarea.onChange = { [weak self] _ in self?.update(); self?.onResize?() }
        textarea.onCommand = { [weak self] sel in
            guard let self else { return false }
            if sel == #selector(NSResponder.cancelOperation(_:)) { self.onCancel?(); return true }
            if sel == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true { self.send(); return true }
            return false
        }
        cancel.action = { [weak self] in self?.onCancel?() }
        submit.action = { [weak self] in self?.send() }
        update()
    }

    private var trimmed: String { textarea.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func update() { submit.isEnabled = !trimmed.isEmpty }
    private func send() { if !trimmed.isEmpty { onComment?(trimmed) } }
    public func focus() { window?.makeFirstResponder(textarea) }

    public func height(forWidth width: CGFloat) -> CGFloat {
        textarea.frame.size.width = width - 24
        return 8 + textarea.intrinsicContentSize.height + 6 + 24 + 8
    }

    public override func layout() {
        super.layout()
        let w = bounds.width - 24
        textarea.frame.size.width = w
        let th = textarea.intrinsicContentSize.height
        textarea.frame = NSRect(x: 12, y: 8, width: w, height: th)
        let y = 8 + th + 6
        let sw = ceil(submit.intrinsicContentSize.width), cw = ceil(cancel.intrinsicContentSize.width)
        submit.frame = NSRect(x: 12 + w - sw, y: y, width: sw, height: 24)
        cancel.frame = NSRect(x: submit.frame.minX - 4 - cw, y: y, width: cw, height: 24)
        hint.frame = NSRect(x: 12, y: y + 5, width: max(0, cancel.frame.minX - 16), height: 14)
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        hint.color = Themed.color(\.mutedForeground, 0.7)
    }
}

/// `ReviewThreadCard` (PullRequestReviewAnnotation.tsx:89-358): the state glyph and "Open · n
/// comments" (a resolved one starts folded), "outdated", Resolve or Unresolve; then each comment
/// with its author, time, reactions and the pencil on the reader's own; "Load more comments"; Reply.
public final class PullRequestReviewThreadCardView: PullRequestAnnotationCardView {
    private var thread: PullRequestReviewThread
    private let canReply: Bool
    private let canResolve: Bool
    private let canReact: Bool
    private let canEdit: (PullRequestThreadComment) -> Bool
    private let actions: PullRequestReviewThreadActions
    private let cwd: String
    private let nowMs: Int64
    private var expanded: Bool
    private var replying = false
    private var editingId: String?
    private var loaded: (comments: [PullRequestThreadComment], cursor: String?)?
    private var busy = false

    private let stateIcon = IconView(name: .circle, size: 14)
    private let resolvedIcon = IconView(name: .circleCheck, size: 14)
    private let headButton = LinkLabel()
    private let outdated = LabelView("outdated", font: DSFont.ui(12))
    private let resolve = ButtonView("Resolve", variant: .ghost, size: .xs)
    private var commentViews: [PullRequestThreadCommentView] = []
    private let loadMore = ButtonView("Load more comments", variant: .ghost, size: .xs)
    private let replyButton = ButtonView("Reply", variant: .ghost, size: .xs)
    private let replyBox = TextareaView(size: .sm)
    private let replyCancel = ButtonView("Cancel", variant: .ghost, size: .xs)
    private let replySend = ButtonView("Reply", variant: .default, size: .xs)

    public init(thread: PullRequestReviewThread, canReply: Bool, canResolve: Bool, canReact: Bool,
                canEdit: @escaping (PullRequestThreadComment) -> Bool, actions: PullRequestReviewThreadActions, cwd: String, nowMs: Int64) {
        self.thread = thread
        self.canReply = canReply; self.canResolve = canResolve; self.canReact = canReact
        self.canEdit = canEdit; self.actions = actions; self.cwd = cwd; self.nowMs = nowMs
        expanded = !thread.isResolved
        super.init(frame: .zero)
        headButton.font = DSFont.ui(12)
        headButton.underlines = false
        headButton.onClick = { [weak self] in self?.toggleExpanded() }
        outdated.lineHeight = 16
        replyBox.placeholder = "Reply"
        replyBox.setAccessibilityLabel("Reply to this conversation")
        [stateIcon, resolvedIcon, headButton, outdated, resolve, loadMore, replyButton, replyBox, replyCancel, replySend].forEach(card.addSubview)
        resolve.action = { [weak self] in guard let self else { return }; self.actions.setResolved(self.thread.id, !self.thread.isResolved) }
        loadMore.action = { [weak self] in self?.loadMoreComments() }
        replyButton.action = { [weak self] in self?.replying = true; self?.rebuild(); DispatchQueue.main.async { self?.window?.makeFirstResponder(self?.replyBox) } }
        replyCancel.action = { [weak self] in self?.replying = false; self?.rebuild() }
        replySend.action = { [weak self] in self?.sendReply() }
        replyBox.onChange = { [weak self] _ in self?.updateButtons(); self?.onResize?() }
        replyBox.onCommand = { [weak self] sel in
            guard let self else { return false }
            if sel == #selector(NSResponder.cancelOperation(_:)) { self.replying = false; self.rebuild(); return true }
            if sel == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true { self.sendReply(); return true }
            return false
        }
        rebuild()
    }

    /// The host answered again: keep what this card loaded (`currentPage`), redraw the rest.
    public func update(_ thread: PullRequestReviewThread) {
        self.thread = thread
        rebuild()
    }

    private var comments: [PullRequestThreadComment] {
        PullRequestWriteLogic.mergeThreadComments(thread.comments, loaded?.comments ?? [])
    }
    private var nextCursor: String? { loaded == nil ? thread.nextCommentsCursor : loaded?.cursor }

    private func toggleExpanded() { expanded.toggle(); rebuild() }

    private func loadMoreComments() {
        guard let cursor = nextCursor, !busy else { return }
        busy = true
        updateButtons()
        actions.loadMore(thread.id, cursor) { [weak self] page in
            guard let self else { return }
            self.busy = false
            if let page { self.loaded = (PullRequestWriteLogic.mergeThreadComments(self.loaded?.comments ?? [], page.comments), page.nextCursor) }
            self.rebuild()
        }
    }

    private func sendReply() {
        let body = replyBox.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !busy else { return }
        busy = true
        updateButtons()
        actions.reply(thread.id, body) { [weak self] ok in
            guard let self else { return }
            self.busy = false
            if ok {
                // The mutation returns no comment: reopen the cursor so the reply stays reachable.
                if let l = self.loaded { self.loaded = (l.comments, l.cursor ?? self.thread.nextCommentsCursor) }
                self.replyBox.text = ""
                self.replying = false
            }
            self.rebuild()
        }
    }

    private func rebuild() {
        stateIcon.isHidden = thread.isResolved
        resolvedIcon.isHidden = !thread.isResolved
        headButton.text = PullRequestWriteLogic.threadHead(thread, loaded: comments.count)
        headButton.setAccessibilityExpanded(expanded)
        outdated.isHidden = !thread.isOutdated
        resolve.isHidden = !canResolve
        resolve.title = thread.isResolved ? "Unresolve" : "Resolve"
        commentViews.forEach { $0.removeFromSuperview() }
        commentViews = expanded ? comments.map { c in
            let v = PullRequestThreadCommentView(c, cwd: cwd, nowMs: nowMs, canReact: canReact, canEdit: canEdit(c), editing: editingId == c.id)
            v.onEdit = { [weak self] in self?.editingId = c.id; self?.rebuild() }
            v.onCancel = { [weak self] in self?.editingId = nil; self?.rebuild() }
            v.onSave = { [weak self] body in
                guard let self else { return }
                v.editor?.saving = true
                self.actions.editComment(c.id, body) { [weak self] ok in
                    guard let self else { return }
                    v.editor?.saving = false
                    if ok {
                        if let l = self.loaded { self.loaded = (PullRequestWriteLogic.editThreadComment(l.comments, id: c.id, body: body), l.cursor) }
                        self.editingId = nil
                        self.rebuild()
                    }
                }
            }
            v.reactions.onToggle = { [weak self, weak v] content, reacted in
                guard let self, let v else { return }
                self.actions.react(c.id, content, reacted, v.reactions)
            }
            v.onResize = { [weak self] in self?.onResize?() }
            card.addSubview(v)
            return v
        } : []
        loadMore.isHidden = !expanded || nextCursor == nil
        replyButton.isHidden = !expanded || !canReply || replying
        [replyBox, replyCancel, replySend].forEach { $0.isHidden = !expanded || !canReply || !replying }
        updateButtons()
        needsLayout = true
        onResize?()
    }

    private func updateButtons() {
        resolve.isEnabled = !busy
        loadMore.isEnabled = !busy
        loadMore.title = busy && nextCursor != nil && !replying ? "Loading..." : "Load more comments"
        replySend.isEnabled = !busy && !replyBox.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 24
        guard expanded else { return h }
        if !commentViews.isEmpty { h += 8 + commentViews.map { $0.height(forWidth: width) }.reduce(0, +) + CGFloat(commentViews.count - 1) * 12 }
        if !loadMore.isHidden { h += 8 + 24 }
        if !replyButton.isHidden { h += 8 + 24 }
        if replying && canReply {
            replyBox.frame.size.width = width
            h += 8 + replyBox.intrinsicContentSize.height + 8 + 24
        }
        return h
    }

    public override func layout() {
        super.layout()
        let r = inner
        stateIcon.frame = NSRect(x: r.minX, y: r.minY + 5, width: 14, height: 14)
        resolvedIcon.frame = stateIcon.frame
        let hw = ceil(headButton.textWidth) + 1
        headButton.frame = NSRect(x: r.minX + 22, y: r.minY + 4, width: hw, height: 16)
        outdated.frame = NSRect(x: headButton.frame.maxX + 8, y: r.minY + 4, width: ceil(outdated.textWidth) + 1, height: 16)
        let rw = ceil(resolve.intrinsicContentSize.width)
        resolve.frame = NSRect(x: r.maxX - rw, y: r.minY, width: rw, height: 24)
        var y = r.minY + 24
        if !commentViews.isEmpty {
            y += 8
            for v in commentViews {
                let h = v.height(forWidth: r.width)
                v.frame = NSRect(x: r.minX, y: y, width: r.width, height: h)
                y += h + 12
            }
            y -= 12
        }
        if !loadMore.isHidden {
            loadMore.frame = NSRect(x: r.minX, y: y + 8, width: ceil(loadMore.intrinsicContentSize.width), height: 24); y += 32
        }
        if !replyButton.isHidden {
            replyButton.frame = NSRect(x: r.minX, y: y + 8, width: ceil(replyButton.intrinsicContentSize.width), height: 24); y += 32
        }
        if !replyBox.isHidden {
            replyBox.frame.size.width = r.width
            let th = replyBox.intrinsicContentSize.height
            replyBox.frame = NSRect(x: r.minX, y: y + 8, width: r.width, height: th)
            let by = y + 8 + th + 8
            let sw = ceil(replySend.intrinsicContentSize.width), cw = ceil(replyCancel.intrinsicContentSize.width)
            replySend.frame = NSRect(x: r.maxX - sw, y: by, width: sw, height: 24)
            replyCancel.frame = NSRect(x: r.maxX - sw - 8 - cw, y: by, width: cw, height: 24)
        }
    }

    public override func updateLayer() {
        super.updateLayer()
        stateIcon.strokeColor = Themed.color(\.mutedForeground)
        resolvedIcon.strokeColor = Themed.color(\.successForeground)
        headButton.color = Themed.color(\.mutedForeground)
        outdated.color = Themed.color(\.mutedForeground)
    }
}

/// One comment of a conversation: author and time, the reactions on the right, then the body (the
/// pencil beside it on the reader's own) or the editor.
final class PullRequestThreadCommentView: DSView {
    private let avatar = PullRequestAvatarView()
    private let login = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let time = LabelView("", font: DSFont.ui(12))
    let reactions = PullRequestReactionBarView()
    private let body = MarkdownView()
    private let edit = ButtonView(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs)
    private(set) var editor: PullRequestMarkdownEditorView?
    var onEdit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: ((String) -> Void)?
    var onResize: (() -> Void)?

    init(_ c: PullRequestThreadComment, cwd: String, nowMs: Int64, canReact: Bool, canEdit: Bool, editing: Bool) {
        super.init(frame: .zero)
        avatar.actor = c.author
        login.text = c.author?.login ?? "ghost"
        time.text = TimestampFormat.formatRelativeTimeLabel(c.createdAt, nowMs: nowMs)
        for l in [login, time] { l.lineHeight = 16 }
        reactions.canReact = canReact
        reactions.reactions = c.reactions ?? []
        body.cwd = cwd
        body.setMarkdown(c.body)
        edit.iconSize = 12
        edit.setAccessibilityLabel("Edit comment")
        edit.isHidden = !canEdit || editing
        edit.action = { [weak self] in self?.onEdit?() }
        [avatar, login, time, reactions, body, edit].forEach(addSubview)
        if editing {
            let e = PullRequestMarkdownEditorView(value: c.body, label: "Edit comment", cwd: cwd)
            e.onCancel = { [weak self] in self?.onCancel?() }
            e.onSave = { [weak self] text in self?.onSave?(text) }
            e.onResize = { [weak self] in self?.onResize?() }
            editor = e
            body.isHidden = true
            addSubview(e)
            DispatchQueue.main.async { [weak e] in e?.focus() }
        }
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        if let editor { return 24 + 4 + editor.height(forWidth: w) }
        return 24 + 4 + body.height(forWidth: w - (edit.isHidden ? 0 : 28))
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        avatar.frame = NSRect(x: 0, y: 4, width: 16, height: 16)
        let lw = ceil(login.textWidth) + 1
        login.frame = NSRect(x: 22, y: 4, width: lw, height: 16)
        time.frame = NSRect(x: 22 + lw + 8, y: 4, width: ceil(time.textWidth) + 1, height: 16)
        let rw = reactions.isHidden ? 0 : reactions.width
        reactions.frame = NSRect(x: w - rw, y: 0, width: rw, height: 24)
        let ew: CGFloat = edit.isHidden ? 0 : 28
        body.frame = NSRect(x: 0, y: 28, width: w - ew, height: body.height(forWidth: w - ew))
        edit.frame = NSRect(x: w - 24, y: 28, width: 24, height: 24)
        editor?.frame = NSRect(x: 0, y: 28, width: w, height: editor?.height(forWidth: w) ?? 0)
    }

    override func updateLayer() {
        login.color = Themed.color(\.foreground)
        time.color = Themed.color(\.mutedForeground)
    }
}
