import AppKit
import DesignSystem
import T3Protocol

/// `usePullRequestReviewStore` (pullRequestReviewStore.ts): the review being written, held until it
/// is sent. Line comments and the summary per pull request, never persisted (a half-written review
/// lives as long as the app does).
@MainActor
public final class PullRequestReviewStore {
    public static let shared = PullRequestReviewStore()
    public static let didChange = Notification.Name("PullRequestReviewStore.didChange")
    public private(set) var drafts: [String: [PullRequestReviewCommentDraft]] = [:]
    public private(set) var summaries: [String: String] = [:]
    private var sequence = 0

    public init() {}

    /// `pullRequestReviewKey` (line 28): project, host and repository lower cased, number.
    public static func key(_ ref: PullRequestRef) -> String {
        "\(ref.projectId)\u{1f}\(ref.host?.lowercased() ?? "")\u{1f}\(ref.repository.lowercased())\u{1f}\(ref.number)"
    }

    /// `nextPendingReviewCommentId` (line 22).
    public func nextId() -> String { sequence += 1; return "pending-review-comment-\(sequence)" }

    public func comments(_ key: String) -> [PullRequestReviewCommentDraft] { drafts[key] ?? [] }
    public func summary(_ key: String) -> String { summaries[key] ?? "" }

    public func add(_ key: String, _ comment: PullRequestReviewCommentDraft) { drafts[key, default: []].append(comment); changed() }
    public func remove(_ key: String, ids: Set<String>) {
        let rest = (drafts[key] ?? []).filter { !ids.contains($0.id) }
        drafts[key] = rest.isEmpty ? nil : rest
        changed()
    }
    public func clear(_ key: String) { drafts[key] = nil; changed() }
    public func setSummary(_ key: String, _ body: String) { summaries[key] = body; changed() }
    /// Only the exact summary the host accepted goes (line 78): a revision typed meanwhile is new work.
    public func clearSummary(_ key: String, submitted: String) {
        guard summaries[key] == submitted else { return }
        summaries[key] = nil
        changed()
    }

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}

/// `PullRequestComposer` (PullRequestComposer.tsx:102-186) with `PullRequestCommentForm` and
/// `PullRequestReviewForm`: the popover's mode toggle or title, discard and close buttons, then the
/// comment box (Close or Reopen with comment, Comment) or the review summary with the verdict select
/// and Submit review. Both drafts outlive the popover; the caller runs the requests and reports back
/// through `commentSubmitting` and `reviewPending`.
public final class PullRequestComposerView: DSView {
    static let width: CGFloat = 384 - 2 - 32

    public let reviewKey: String
    private let canComment: Bool
    private let verdicts: [String]
    private let followUp: String?
    private let summaryRequired: Bool
    private let store: PullRequestReviewStore
    private let modeToggle: ToggleGroupView?
    private let titleLabel = LabelView("", font: DSFont.ui(14, weight: .semibold))
    private let discard = ButtonView(nil, icon: .trash2, variant: .ghost, size: .iconXs)
    private let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    public let commentBox = TextareaView(placeholder: "Leave a comment")
    public let reviewBox = TextareaView()
    private let followUpButton: ButtonView?
    private let commentButton = ButtonView("Comment", icon: .send, variant: .outline, size: .xs)
    private let verdictSelect: SelectView?
    private let submit = ButtonView("Submit review", variant: .default, size: .xs)
    private var observer: NSObjectProtocol?
    public private(set) var mode: String

    /// "comment", "close" or "reopen" while that request runs; the box locks.
    public var commentSubmitting: String? { didSet { update() } }
    /// The detail's own action is running (`actionPending`).
    public var actionPending = false { didSet { update() } }
    public var reviewPending = false { didSet { update() } }

    public var onComment: ((String) -> Void)?
    public var onCommentAction: ((_ body: String, _ action: String) -> Void)?
    public var onReview: ((_ verdict: String, _ body: String, _ comments: [PullRequestReviewCommentDraft]) -> Void)?
    public var onClose: (() -> Void)?

    public init(detail d: PullRequestDetail, reviewKey: String, store: PullRequestReviewStore = .shared) {
        self.reviewKey = reviewKey
        self.store = store
        let offer = PullRequestWriteLogic.composerOffer(d)
        canComment = offer.canComment
        verdicts = offer.verdicts
        followUp = PullRequestWriteLogic.commentFollowUp(d)
        summaryRequired = d.provider == "forgejo"
        modeToggle = canComment && !verdicts.isEmpty ? ToggleGroupView(variant: .segmented, items: [("Comment", nil), ("Review", nil)], selected: 0) : nil
        if let followUp {
            let b = ButtonView(followUp == "close" ? "Close with comment" : "Reopen with comment",
                               icon: followUp == "close" ? .gitPullRequestClosed : .gitPullRequestArrow,
                               variant: followUp == "close" ? .destructiveOutline : .outline, size: .xs)
            followUpButton = b
        } else {
            followUpButton = nil
        }
        let labels = verdicts.compactMap { v in PullRequestWriteLogic.verdicts.first { $0.value == v }?.label }
        verdictSelect = verdicts.isEmpty ? nil : SelectView(options: labels, selected: 0, size: .xs)
        let started = !store.comments(reviewKey).isEmpty || !store.summary(reviewKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        mode = PullRequestWriteLogic.composerMode(canComment: canComment, verdicts: verdicts, reviewStarted: started)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 160))
        titleLabel.lineHeight = 14
        [modeToggle, titleLabel, discard, close, commentBox, reviewBox, followUpButton, commentButton, verdictSelect, submit]
            .compactMap { $0 }.forEach(addSubview)
        for b in [discard, close] { b.iconSize = 14 }
        discard.setAccessibilityLabel("Discard pending line comments")
        discard.toolTip = "Discard pending line comments"
        close.setAccessibilityLabel("Close composer")
        commentBox.setAccessibilityLabel("Comment on this pull request")
        reviewBox.setAccessibilityLabel("Review summary")
        reviewBox.placeholder = summaryRequired && verdicts.contains("request-changes")
            ? "Summarize your review (required to request changes)" : "Summarize your review (optional)"
        reviewBox.text = store.summary(reviewKey)
        followUpButton?.iconSize = 14
        commentButton.iconSize = 14
        if let verdictSelect {
            verdictSelect.fitsContent = true
            verdictSelect.alignItemWithTrigger = false
            verdictSelect.popupSide = .top
            verdictSelect.optionGlyphs = verdicts.map { Self.verdictIcon($0).definition }
            verdictSelect.setAccessibilityLabel("Review verdict")
            verdictSelect.onChange = { [weak self] _ in self?.update() }
        }
        modeToggle?.onChange = { [weak self] i in
            guard let self else { return }
            guard let i else { self.update(); return }
            self.mode = i == 1 ? "review" : "comment"
            self.update()
            self.focusBox()
        }
        close.action = { [weak self] in self?.onClose?() }
        discard.action = { [weak self] in guard let self else { return }; self.store.clear(self.reviewKey) }
        commentBox.onChange = { [weak self] _ in self?.update() }
        reviewBox.onChange = { [weak self] text in guard let self else { return }; self.store.setSummary(self.reviewKey, text) }
        commentBox.onCommand = { [weak self] sel in self?.commandEnter(sel, submit: { self?.sendComment("comment") }) ?? false }
        commentButton.action = { [weak self] in self?.sendComment("comment") }
        followUpButton?.action = { [weak self] in if let f = self?.followUp { self?.sendComment(f) } }
        submit.action = { [weak self] in self?.sendReview() }
        observer = NotificationCenter.default.addObserver(forName: PullRequestReviewStore.didChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        setAccessibilityLabel("Pull request composer")
        update()
    }

    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    static func verdictIcon(_ v: String) -> IconName { v == "approve" ? .check : v == "request-changes" ? .circleX : .messageSquare }

    private var pending: [PullRequestReviewCommentDraft] { store.comments(reviewKey) }
    private var selectedVerdict: String? { verdictSelect?.selectedIndex.flatMap { verdicts.indices.contains($0) ? verdicts[$0] : nil } }

    /// Opening picks the mode with work waiting in it (Composer line 76).
    public func prepareToOpen() {
        let started = !pending.isEmpty || !store.summary(reviewKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        mode = PullRequestWriteLogic.composerMode(canComment: canComment, verdicts: verdicts, reviewStarted: started)
        update()
    }

    public func focusBox() { window?.makeFirstResponder(mode == "review" ? reviewBox : commentBox) }

    /// ⌘Enter sends (CommentForm lines 98-110).
    private func commandEnter(_ sel: Selector, submit: () -> Void) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
        submit()
        return true
    }

    private func sendComment(_ action: String) {
        let trimmed = commentBox.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, commentSubmitting == nil, !actionPending else { return }
        commentSubmitting = action
        if action == "comment" { onComment?(trimmed) } else { onCommentAction?(trimmed, action) }
    }

    /// The comment landed: the box empties (CommentForm lines 80-83).
    public func commentPosted() { commentBox.text = ""; commentSubmitting = nil }

    private func sendReview() {
        guard !reviewPending, let v = selectedVerdict else { return }
        let body = store.summary(reviewKey)
        guard PullRequestWriteLogic.canSubmitReview(verdict: v, body: body, pendingComments: pending.count, summaryRequired: summaryRequired) else { return }
        reviewPending = true
        onReview?(v, body, pending)
    }

    /// The review landed: drop what was sent (ReviewForm lines 107-113).
    public func reviewSubmitted(body: String, comments: [PullRequestReviewCommentDraft]) {
        store.remove(reviewKey, ids: Set(comments.map(\.id)))
        store.clearSummary(reviewKey, submitted: body)
        reviewBox.text = store.summary(reviewKey)
        reviewPending = false
    }

    private func update() {
        let review = mode == "review"
        let count = pending.count
        modeToggle?.selectedIndex = review ? 1 : 0
        if let t = modeToggle?.items.last { t.title = count > 0 ? "Review (\(count))" : "Review" }
        titleLabel.isHidden = modeToggle != nil
        titleLabel.text = review ? "Review pull request" : "Comment on pull request"
        discard.isHidden = !(review && count > 0)
        discard.isEnabled = !reviewPending
        commentBox.isHidden = review
        commentButton.isHidden = review
        followUpButton?.isHidden = review
        reviewBox.isHidden = !review
        verdictSelect?.isHidden = !review
        submit.isHidden = !review
        let locked = commentSubmitting != nil || actionPending
        commentBox.isEnabled = !locked
        let hasComment = !commentBox.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        commentButton.isEnabled = hasComment && !locked
        commentButton.title = commentSubmitting == "comment" ? "Posting..." : "Comment"
        followUpButton?.isEnabled = hasComment && !locked
        if let f = followUp {
            followUpButton?.title = commentSubmitting == f ? (f == "close" ? "Closing..." : "Reopening...") : (f == "close" ? "Close with comment" : "Reopen with comment")
        }
        verdictSelect?.isEnabled = !reviewPending
        if let v = selectedVerdict, let select = verdictSelect {
            let icon = IconView(name: Self.verdictIcon(v), size: 12)
            select.leading = icon
        }
        submit.title = reviewPending ? "Submitting..." : "Submit review"
        submit.isEnabled = !reviewPending && selectedVerdict.map {
            PullRequestWriteLogic.canSubmitReview(verdict: $0, body: store.summary(reviewKey), pendingComments: count, summaryRequired: summaryRequired)
        } == true
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var boxHeight: CGFloat {
        let box = mode == "review" ? reviewBox : commentBox
        box.frame.size.width = Self.width
        return box.intrinsicContentSize.height
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: headerHeight + 12 + boxHeight + 8 + 24)
    }

    /// The `mb-3` row: the mode toggle group (28) or the title beside the 24pt buttons.
    private var headerHeight: CGFloat { modeToggle.map { max(24, $0.intrinsicContentSize.height) } ?? 24 }

    public override func layout() {
        super.layout()
        let w = bounds.width
        let hh = headerHeight
        if let modeToggle { modeToggle.frame = NSRect(x: 0, y: 0, width: modeToggle.intrinsicContentSize.width, height: modeToggle.intrinsicContentSize.height) }
        titleLabel.frame = NSRect(x: 0, y: (hh - 14) / 2, width: max(0, w - 56), height: 14)
        close.frame = NSRect(x: w - 24, y: (hh - 24) / 2, width: 24, height: 24)
        discard.frame = NSRect(x: w - 24 - 4 - 24, y: (hh - 24) / 2, width: 24, height: 24)
        let bh = boxHeight
        commentBox.frame = NSRect(x: 0, y: hh + 12, width: w, height: bh)
        reviewBox.frame = NSRect(x: 0, y: hh + 12, width: w, height: bh)
        let y = hh + 12 + bh + 8
        var r = w
        let cw = ceil(commentButton.intrinsicContentSize.width)
        commentButton.frame = NSRect(x: r - cw, y: y, width: cw, height: 24); r -= cw + 8
        if let f = followUpButton {
            let fw = ceil(f.intrinsicContentSize.width)
            f.frame = NSRect(x: r - fw, y: y, width: fw, height: 24)
        }
        let sw = ceil(submit.intrinsicContentSize.width)
        submit.frame = NSRect(x: w - sw, y: y, width: sw, height: 24)
        if let verdictSelect {
            let vw = ceil(verdictSelect.intrinsicContentSize.width)
            verdictSelect.frame = NSRect(x: 0, y: y, width: vw, height: 24)
        }
    }

    public override func updateLayer() { titleLabel.color = Themed.color(\.popoverForeground) }
}
