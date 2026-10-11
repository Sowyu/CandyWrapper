import Foundation
import T3Protocol

/// The decisions behind WP7.5c's pull request controls: who may edit, what a stack action would
/// touch, what the pickers and composer allow, how the header condenses, and where a Markdown
/// link previews. Each function cites the T3 source it ports.
public enum PullRequestWriteLogic {
    // MARK: Editing (pullRequestEditing.logic.ts)

    static func sameLogin(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// `canEditPullRequestChangeRequest` (line 21): the host can, and the reader wrote it or may merge it.
    public static func canEditChangeRequest(_ d: PullRequestDetail) -> Bool {
        guard d.capabilities.edit?.changeRequest == true else { return false }
        return sameLogin(d.viewer, d.author?.login) || d.viewerPermissions.actions.contains("merge")
    }

    /// `canEditPullRequestComment` (line 34): the reader's own issue or review comment.
    public static func canEditComment(_ d: PullRequestDetail, author: String?, kind: String) -> Bool {
        guard d.capabilities.edit?.comment == true, kind == "issue-comment" || kind == "review-comment" else { return false }
        return sameLogin(d.viewer, author)
    }

    /// `saveTitle` (PullRequestDetailPanel.tsx:1033-1058): nil closes the editor without a request
    /// (blank or unchanged), otherwise the trimmed title to send.
    public static func titleToSave(_ draft: String, current: String) -> String? {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == current ? nil : t
    }

    // MARK: Stacks (PullRequestStackMenu.tsx)

    public struct StackPlan: Equatable, Sendable {
        /// 1 based position of the open pull request, 0 when it is not a layer.
        public var position: Int
        /// The layers "Merge stack" merges: this one and the unmerged ones under it.
        public var mergeLayers: [PullRequestStackDetail.Layer]
        /// Every unmerged layer, which "Rebase stack" rebases.
        public var unmerged: [PullRequestStackDetail.Layer]
        public var mergeDisabled: Bool
        public var rebaseDisabled: Bool
        /// "Every layer being merged must be open and ready for review."
        public var showsReadyNote: Bool
        /// The merge button beside the menu shows only on an open layer.
        public var selectedIsOpen: Bool
    }

    /// Lines 57-75.
    public static func stackPlan(_ stack: PullRequestStackDetail, current: Int, pending: Bool) -> StackPlan {
        let unmerged = stack.layers.filter { $0.state != "merged" }
        let hasClosed = unmerged.contains { $0.state != "open" }
        let position = (stack.layers.firstIndex { $0.number == current } ?? -1) + 1
        let mergeLayers = Array(stack.layers.prefix(position)).filter { $0.state != "merged" }
        let selected = position > 0 ? stack.layers[position - 1] : nil
        let mergeHasClosed = mergeLayers.contains { $0.state != "open" }
        let heads = unmerged.compactMap(\.headSha)
        let mergeDisabled = pending || selected?.state != "open" || mergeLayers.contains { $0.headSha == nil } || mergeHasClosed
            || mergeLayers.isEmpty || mergeLayers.contains { $0.isDraft == true }
        let rebaseDisabled = pending || heads.count != unmerged.count || hasClosed || unmerged.isEmpty
        return StackPlan(position: position, mergeLayers: mergeLayers, unmerged: unmerged, mergeDisabled: mergeDisabled,
                         rebaseDisabled: rebaseDisabled, showsReadyNote: mergeHasClosed || mergeLayers.contains { $0.isDraft == true },
                         selectedIsOpen: selected?.state == "open")
    }

    /// The `runAction` input of "Merge stack" or "Rebase stack" (lines 84-104): merge targets the open
    /// layer with the merge layers' heads, rebase targets the top with every unmerged head.
    public static func stackActionPayload(_ stack: PullRequestStackDetail, ref: PullRequestRef, action: String, mergeMethod: String) -> JSONValue? {
        let plan = stackPlan(stack, current: ref.number, pending: false)
        let target = action == "merge" ? (plan.position > 0 ? stack.layers[plan.position - 1] : nil) : stack.layers.last
        guard let target, target.headSha != nil else { return nil }
        let heads = (action == "merge" ? plan.mergeLayers : plan.unmerged).compactMap { l in l.headSha.map { (number: l.number, headSha: $0) } }
        var r = ref
        r.number = target.number
        return PullRequestPayloads.action(r, action: action, mergeMethod: action == "merge" ? mergeMethod : nil,
                                          updateMethod: action == "merge" ? nil : "rebase", stackNumber: stack.number, expectedStackHeads: heads)
    }

    /// The confirmation's title and description (lines 228-236).
    public static func stackConfirmation(_ stack: PullRequestStackDetail, current: Int, action: String, mergeMethod: String) -> (title: String, message: String, button: String) {
        let plan = stackPlan(stack, current: current, pending: false)
        if action == "merge" {
            return ("Merge \(plan.mergeLayers.count) pull requests?",
                    "Merge #\(current) and its unmerged layers below into \(stack.base) using \(mergeMethod). GitHub checks their rules before merging or queueing them and rebases the remaining stack after merging.",
                    "Merge stack")
        }
        return ("Rebase \(plan.unmerged.count) pull requests?",
                "Rebase the remote branches from bottom to top onto \(stack.base). This rewrites branch history and may restart checks. If a layer fails, earlier updates remain.",
                "Rebase stack")
    }

    /// `allowsSinglePullRequestMerge` (pullRequestDetail.logic.ts:47): with stack actions, a single
    /// merge waits until the stack read says there is none.
    public static func allowsSingleMerge(supportsStackActions: Bool, hasStack: Bool, stackPending: Bool, stackError: Bool) -> Bool {
        !supportsStackActions || (!hasStack && !stackPending && !stackError)
    }

    /// `pullRequestStackView` notice (pullRequestStackSnapshot.ts:51-72).
    public static func stackNotice(hasData: Bool, isSuccess: Bool, isPending: Bool, error: Bool) -> String? {
        guard hasData else { return nil }
        if error { return "Stack data may be stale. We couldn’t refresh it." }
        if !isSuccess || isPending { return "Refreshing stack… Showing saved data." }
        return nil
    }

    /// `PullRequestStackLayerContent` (lines 12-24): title (or branch), then `#n · branch · State`.
    public static func stackLayerLines(_ l: PullRequestStackDetail.Layer, compact: Bool) -> (title: String, detail: String) {
        let state = PullRequestStateTone(state: l.state, isDraft: l.isDraft ?? false).label
        let title = (l.title?.isEmpty == false ? l.title! : l.headBranch)
        return (title, "#\(l.number) · " + (compact ? "" : "\(l.headBranch) · ") + state)
    }

    // MARK: Pickers (PullRequestLabelPicker.tsx, PullRequestReviewerPicker.tsx)

    /// `matches` (LabelPicker line 23): name or description contains the query.
    public static func filterLabels(_ c: [PullRequestLabelCandidate], query: String) -> [PullRequestLabelCandidate] {
        let q = query.lowercased()
        return q.isEmpty ? c : c.filter { $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    /// `matches` (ReviewerPicker line 28): login or name contains the query.
    public static func filterReviewers(_ c: [PullRequestReviewerCandidate], query: String) -> [PullRequestReviewerCandidate] {
        let q = query.lowercased()
        return q.isEmpty ? c : c.filter { $0.login.lowercased().contains(q) || ($0.name ?? "").lowercased().contains(q) }
    }

    // MARK: Composer (PullRequestComposer.tsx, PullRequestCommentForm.tsx, PullRequestReviewForm.tsx)

    /// `VERDICTS` (ReviewForm line 24): value, label, the toast once sent.
    public static let verdicts: [(value: String, label: String, sent: String)] = [
        ("comment", "Comment", "Review submitted"), ("approve", "Approve", "Pull request approved"),
        ("request-changes", "Request changes", "Changes requested"),
    ]

    /// What the reader may send (Composer lines 64-68): `canComment`, and the verdicts both the host and
    /// the account allow, in T3's order.
    public static func composerOffer(_ d: PullRequestDetail) -> (canComment: Bool, verdicts: [String]) {
        let canComment = d.capabilities.comment && d.viewerPermissions.comment
        let allowed = d.capabilities.review.verdicts.filter { d.viewerPermissions.verdicts.contains($0) }
        return (canComment, verdicts.map(\.value).filter { allowed.contains($0) })
    }

    /// The mode opening lands on (Composer line 76): review when one is started.
    public static func composerMode(canComment: Bool, verdicts: [String], reviewStarted: Bool) -> String {
        canComment ? (verdicts.isEmpty ? "comment" : (reviewStarted ? "review" : "comment")) : "review"
    }

    /// `canSubmit` (ReviewForm line 119): Forgejo needs a summary to request changes; approve may be
    /// empty; the others need words or line comments.
    public static func canSubmitReview(verdict: String, body: String, pendingComments: Int, summaryRequired: Bool) -> Bool {
        let hasBody = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if verdict == "request-changes" && summaryRequired { return hasBody }
        return verdict == "approve" || hasBody || pendingComments > 0
    }

    /// `followUpAction` (CommentForm line 44): close an open one, reopen a closed one.
    public static func commentFollowUp(_ d: PullRequestDetail) -> String? {
        let both = { (a: String) in d.capabilities.actions.contains(a) && d.viewerPermissions.actions.contains(a) }
        if d.state == "open" && both("close") { return "close" }
        if d.state == "closed" && both("reopen") { return "reopen" }
        return nil
    }

    /// The trigger's accessible name (Composer lines 84-90).
    public static func composerLabel(pending: Int, reviewStarted: Bool, canComment: Bool) -> String {
        if pending > 0 { return "Review pull request, \(pending) \(pending == 1 ? "comment" : "comments") pending" }
        return reviewStarted || !canComment ? "Review pull request" : "Comment on pull request"
    }

    // MARK: Review threads (pullRequestDetail.logic.ts:170-189, PullRequestReviewAnnotation.tsx)

    /// `mergePullRequestThreadComments`: the base, then loaded ones not already there.
    public static func mergeThreadComments(_ base: [PullRequestThreadComment], _ loaded: [PullRequestThreadComment]) -> [PullRequestThreadComment] {
        var seen = Set(base.map(\.id))
        return base + loaded.filter { seen.insert($0.id).inserted }
    }

    /// `editPullRequestThreadComment`.
    public static func editThreadComment(_ comments: [PullRequestThreadComment], id: String, body: String) -> [PullRequestThreadComment] {
        comments.map { var c = $0; if c.id == id { c.body = body }; return c }
    }

    /// The thread card's head: "Open · 2 comments", "Resolved · 1 comment".
    public static func threadHead(_ t: PullRequestReviewThread, loaded: Int) -> String {
        let n = t.commentCount ?? loaded
        return "\(t.isResolved ? "Resolved" : "Open") · \(n) \(n == 1 ? "comment" : "comments")"
    }

    // MARK: Condensed header (PullRequestDetailPanel.tsx:2676-2696)

    /// The chrome folds once the scroll passes the fold's height plus 32, and opens again only at the
    /// hard top (under 4). Returns the next state and the scroll refund to apply when it folds.
    public static func condensed(previous: Bool, scrollTop: CGFloat, foldHeight: CGFloat, condensedRowHeight: CGFloat) -> (condensed: Bool, refund: CGFloat?) {
        if previous {
            return (!(scrollTop < 4 && foldHeight > 0), nil)
        }
        if foldHeight > 0 && scrollTop > foldHeight + 32 { return (true, -(foldHeight - condensedRowHeight)) }
        return (false, nil)
    }

    // MARK: Links in Markdown (lib/openPullRequestLink.ts, chat/externalLinkContextMenu.ts)

    /// `resolvePullRequestPreviewTarget` (openPullRequestLink.ts:98): a change request URL in a
    /// repository one of the environment's projects reads. `projects` are (id, identity) pairs.
    public static func previewTarget(url: String, pullRequestsEnabled: Bool, projects: [(id: String, identity: RepositoryIdentity?)]) -> PullRequestRef? {
        guard pullRequestsEnabled, let parsed = ChangeRequestURL.parse(url) else { return nil }
        guard let project = projects.first(where: { $0.identity?.owns(parsed) == true }) else { return nil }
        return PullRequestRef(projectId: project.id, host: parsed.authority ?? parsed.host,
                              repository: project.identity?.pullRequestRepository ?? parsed.repository, number: parsed.number)
    }

    /// `externalLinkContextMenuItems` (line 38): the link action first when there is one.
    public static func linkMenuItems(canOpenInPreview: Bool, threadLinkAction: String?) -> [(id: String, label: String)] {
        var items: [(String, String)] = []
        if let threadLinkAction { items.append((threadLinkAction, threadLinkAction == "link-to-thread" ? "Link to thread" : "Unlink from thread")) }
        if canOpenInPreview { items.append(("open-in-preview", "Open in integrated browser")) }
        items += [("open-external", "Open in system browser"), ("copy-link", "Copy Link")]
        return items.map { (id: $0.0, label: $0.1) }
    }

    /// The preview card's author line (PullRequestLinkPreview.tsx:94-99).
    public static func previewAuthor(_ a: PullRequestActor?) -> String {
        guard let a else { return "ghost" }
        if let n = a.name, !n.isEmpty, n != a.login { return "\(n) (@\(a.login))" }
        return a.login
    }

    // MARK: Checkout dialog (PullRequestThreadDialog.tsx:198-214)

    /// The input's complaint once the reader has typed.
    public static func checkoutValidation(_ text: String, dirty: Bool, singular: String = "pull request") -> String? {
        guard dirty else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Paste a \(singular) URL, checkout command, or enter 123 / #123." }
        if ChangeRequestURL.reference(text) == nil { return "Use a \(singular) URL, checkout command, 123, or #123." }
        return nil
    }

    // MARK: List paging (routes/_chat.pull-requests.tsx:1175-1197)

    /// "Load more": continue with the answer's cursors where it gave some (raising the page only for
    /// environments that are truncated without one), else grow the page by 99 up to 500.
    public static func loadMore(pageSize: Int, nextCursors: [String: [String: String]], truncatedEnvironments: [String])
        -> (pageSize: Int, cursors: [String: [String: String]]?, regrown: [String]) {
        let regrown = truncatedEnvironments.filter { nextCursors[$0] == nil }
        if !nextCursors.isEmpty {
            return (regrown.isEmpty ? pageSize : min(pageSize + PullRequestListLogic.pageSize, PullRequestListLogic.maxPageSize), nextCursors, regrown)
        }
        return (min(pageSize + PullRequestListLogic.pageSize, PullRequestListLogic.maxPageSize), nil, [])
    }

    /// Which environments a continuation reads (lines 720-726): those with cursors, and the regrown.
    public static func continues(_ env: String, cursors: [String: [String: String]]?, regrown: [String]) -> Bool {
        cursors == nil || cursors?[env] != nil || regrown.contains(env)
    }
}
