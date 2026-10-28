import Foundation
import T3Protocol

/// The detail panel's logic (pullRequestDetail.logic.ts, pullRequestPresentation.tsx,
/// pullRequestFilesViewed.logic.ts, PullRequestDetailPanel.tsx constants).
public enum PullRequestDetailLogic {
    /// `PULL_REQUEST_MERGE_METHOD_LABELS`.
    public static func mergeMethodLabel(_ method: String) -> String {
        switch method {
        case "squash": "Squash and merge"
        case "rebase": "Rebase and merge"
        default: "Merge"
        }
    }

    /// `ACTION_SUCCESS_LABELS` (PullRequestDetailPanel.tsx:203-218).
    public static func actionSuccess(_ action: String, provider: String? = nil) -> String {
        let term = ChangeRequestTerminology.of(kind: provider)
        return switch action {
        case "merge": "Merge requested"
        case "ready": "Marked ready for review"
        case "draft": "Converted to draft"
        case "close": "\(term.title) closed"
        case "delete-branch": "Branch deleted"
        case "reopen": "\(term.title) reopened"
        case "update-branch": "Branch updated with the base branch"
        case "enable-auto-merge": "Auto-merge enabled"
        case "disable-auto-merge": "Auto-merge disabled"
        case "revert": "Revert \(term.singular) opened"
        case "approve-workflows": "Workflows approved"
        default: "Done"
        }
    }

    /// `ACTION_FAILURE_LABELS` (PullRequestDetailPanel.tsx:221-232).
    public static func actionFailure(_ action: String, provider: String? = nil, inPanel: Bool = false) -> String {
        let term = ChangeRequestTerminology.of(kind: provider)
        return switch action {
        case "merge": "Could not merge this \(term.singular)"
        case "ready": "Could not mark this ready for review"
        case "draft": "Could not convert this to a draft"
        case "close": "Could not close this \(term.singular)"
        case "delete-branch": "Could not delete this branch"
        case "reopen": "Could not reopen this \(term.singular)"
        case "update-branch": "Could not update this branch"
        case "enable-auto-merge": inPanel ? "Could not turn on auto-merge" : "Could not enable auto-merge"
        case "disable-auto-merge": inPanel ? "Could not turn off auto-merge" : "Could not disable auto-merge"
        case "revert": "Could not open a revert \(term.singular)"
        case "approve-workflows": "Could not approve workflows"
        default: "Could not do that"
        }
    }

    /// `canPerformPullRequestAction`: the host can, and this account may.
    public static func can(_ detail: PullRequestDetail?, _ action: String) -> Bool {
        guard let detail else { return false }
        return detail.capabilities.actions.contains(action) && detail.viewerPermissions.actions.contains(action)
    }

    /// `canDeletePullRequestBranch`, pullRequestDetail.logic.ts:1141-1154 (3234).
    public static func canDeleteBranch(_ detail: PullRequestDetail) -> Bool {
        detail.state != "open" && detail.capabilities.deleteBranch == true && can(detail, "delete-branch")
    }

    /// `allowedPullRequestMergeMethods`: the host's methods the repository allows.
    public static func allowedMergeMethods(_ detail: PullRequestDetail?) -> [String] {
        guard let detail else { return [] }
        return detail.capabilities.mergeMethods.filter { detail.mergeCapabilities.allows($0) }
    }

    /// `resolvePullRequestMergeMethod` (pullRequestDetail.logic.ts:59-69): this pull request's pick, then the
    /// project's default merge method setting, then the method last picked on this device.
    public static func selectedMergeMethod(_ allowed: [String], current: String? = nil, projectDefault: String? = nil, preferred: String) -> String {
        for m in [current, projectDefault, preferred] { if let m, allowed.contains(m) { return m } }
        return allowed.first ?? "merge"
    }

    /// `resolvePullRequestPrimaryControl`: merged, closed, resolve, ready, auto-merge-armed,
    /// enable-auto-merge, merge or nil.
    public static func primaryControl(state: String, isDraft: Bool, mergeability: String, checksState: String?,
                                      autoMergeEnabled: Bool?, hasMergeMethod: Bool, canMerge: Bool, canMarkReady: Bool,
                                      canEnableAutoMerge: Bool) -> String? {
        if state == "merged" { return "merged" }
        if state == "closed" { return "closed" }
        if mergeability == "conflicting" { return "resolve" }
        if isDraft { return canMarkReady ? "ready" : nil }
        if autoMergeEnabled == true { return "auto-merge-armed" }
        if !hasMergeMethod { return nil }
        if autoMergeEnabled == false, let checksState, checksState != "passing", canEnableAutoMerge { return "enable-auto-merge" }
        return canMerge ? "merge" : nil
    }

    /// The header's primary control for a detail (PullRequestDetailPanel.tsx:1480-1492, single pull
    /// request merges assumed allowed).
    public static func primaryControl(_ d: PullRequestDetail) -> String? {
        let checks = effectiveChecksState(d)
        return primaryControl(state: d.state, isDraft: d.isDraft, mergeability: d.mergeability, checksState: checks,
                              autoMergeEnabled: d.autoMergeEnabled, hasMergeMethod: !allowedMergeMethods(d).isEmpty,
                              canMerge: can(d, "merge"), canMarkReady: can(d, "ready"), canEnableAutoMerge: can(d, "enable-auto-merge"))
    }

    /// `pullRequestCheckoutCommand` for the hosts with a one-line checkout.
    public static func checkoutCommand(provider: String, number: Int) -> String? {
        switch provider {
        case "github": "gh pr checkout \(number)"
        case "gitlab": "glab mr checkout \(number)"
        case "azure-devops": "az repos pr checkout --id \(number)"
        default: nil
        }
    }

    /// `describePullRequestDiffError` (pullRequestDiffError.ts:1-14): failures arrive wrapped in transport
    /// text, so the rate limit is recognized inside them.
    public static func describeDiffError(_ error: String, providerName: String, provider: String? = nil) -> (title: String, description: String) {
        if error.range(of: #"\brate limit\b|\brate[-_]limited\b|\btoo many requests\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return ("\(providerName) rate limit reached",
                    "\(providerName) is temporarily limiting requests, so this diff couldn't be loaded. Try again after the limit resets, or view the changes on \(providerName).")
        }
        return ("Couldn't load the changes",
                "The environment couldn't load this \(ChangeRequestTerminology.of(kind: provider).singular)'s diff. Try again, or view the changes on \(providerName).")
    }

    /// `openOnHostLabel` (pullRequestLinkContextMenu.ts).
    public static func openOnHostLabel(_ provider: String) -> String {
        "Open on \(PullRequestListLogic.providerName(provider))"
    }

    // MARK: Checks

    /// `pullRequestChecksState`: the rollup worked out from the checks, nil without any.
    public static func checksState(_ checks: [PullRequestCheck]) -> String? {
        guard !checks.isEmpty else { return nil }
        let s = Set(checks.map(\.status))
        if s.contains("failure") || s.contains("cancelled") { return "failing" }
        if s.contains("pending") || s.contains("action-required") { return "pending" }
        return s.contains("success") ? "passing" : nil
    }

    /// The header's rollup: workflows awaiting approval keep it pending (PullRequestDetailPanel.tsx:1468-1474).
    public static func effectiveChecksState(_ d: PullRequestDetail) -> String? {
        let state = checksState(d.checks)
        return state != "failing" && d.checks.contains(where: { $0.status == "action-required" }) ? "pending" : state
    }

    static func isWorkflowApproval(_ c: PullRequestCheck) -> Bool {
        c.status == "action-required" && (c.url?.range(of: #"/actions/runs/\d+(?:/|$)"#, options: .regularExpression) != nil)
    }

    /// `CHECK_STATUS_PRESENTATION` labels.
    public static func checkStatusLabel(_ c: PullRequestCheck) -> String {
        if isWorkflowApproval(c) { return "Awaiting approval" }
        switch c.status {
        case "pending": return "Running"
        case "action-required": return "Awaiting action"
        case "success": return "Passed"
        case "failure": return "Failed"
        case "cancelled": return "Cancelled"
        case "skipped": return "Skipped"
        default: return "Neutral"
        }
    }

    /// `CHECKS_STATE_PRESENTATION` labels, GitHub's wording.
    public static func checksStateLabel(_ state: String) -> String {
        switch state {
        case "passing": "All checks have passed"
        case "failing": "Some checks were not successful"
        default: "Some checks haven't completed yet"
        }
    }

    /// `summarizePullRequestChecks`: one facet, the most urgent.
    public static func summarizeChecks(_ checks: [PullRequestCheck]) -> String {
        guard !checks.isEmpty else { return "No checks reported" }
        let actionRequired = checks.filter { $0.status == "action-required" }
        let workflows = actionRequired.filter(isWorkflowApproval).count
        let others = actionRequired.count - workflows
        let failed = checks.filter { $0.status == "failure" || $0.status == "cancelled" }.count
        let pending = checks.filter { $0.status == "pending" }.count
        let passed = checks.filter { $0.status == "success" }.count
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        if failed > 0 { return "\(failed) of \(checks.count) failing" }
        if workflows > 0 && others > 0 { return "\(plural(workflows, "workflow", "workflows")) and \(plural(others, "check", "checks")) awaiting action" }
        if workflows > 0 { return "\(plural(workflows, "workflow", "workflows")) awaiting approval" }
        if others > 0 { return "\(plural(others, "check", "checks")) awaiting action" }
        if pending > 0 { return "\(pending) of \(checks.count) running" }
        return passed == checks.count ? "All checks passed" : "\(passed) of \(checks.count) passing"
    }

    /// `describePullRequestChecks`: every live facet.
    public static func describeChecks(_ checks: [PullRequestCheck]) -> String {
        guard !checks.isEmpty else { return "No checks reported" }
        let failed = checks.filter { $0.status == "failure" || $0.status == "cancelled" }.count
        let pending = checks.filter { $0.status == "pending" }.count
        let action = checks.filter { $0.status == "action-required" }.count
        let passed = checks.filter { $0.status == "success" }.count
        var parts: [String] = []
        if pending > 0 { parts.append("\(pending) of \(checks.count) running") }
        if action > 0 { parts.append("\(action) of \(checks.count) awaiting action") }
        if failed > 0 { parts.append(parts.isEmpty ? "\(failed) of \(checks.count) failing" : "\(failed) failed") }
        if parts.isEmpty { return passed == checks.count ? "All checks passed" : "\(passed) of \(checks.count) passing" }
        return parts.joined(separator: " · ")
    }

    /// `groupPullRequestChecks`: attention, running, completed (the checks popover's sections).
    /// The count trigger's words (3473 PullRequestChecksPopover.tsx:154-196, 618c46478a): the finished
    /// checks out of all while any is running or awaits action, else how many failed, else nothing.
    public static func checksCountLabel(_ checks: [PullRequestCheck]) -> String {
        let incomplete = checks.filter { $0.status == "pending" || $0.status == "action-required" }.count
        let failed = checks.filter { $0.status == "failure" || $0.status == "cancelled" }.count
        return incomplete > 0 ? "\(checks.count - incomplete)/\(checks.count)" : failed > 0 ? "\(failed) failed" : ""
    }

    public static func groupChecks(_ checks: [PullRequestCheck]) -> (attention: [PullRequestCheck], running: [PullRequestCheck], completed: [PullRequestCheck]) {
        (checks.filter { ["failure", "cancelled", "action-required"].contains($0.status) },
         checks.filter { $0.status == "pending" },
         checks.filter { ["success", "skipped", "neutral"].contains($0.status) })
    }

    /// `resolveThreadPanelPullRequestAction`: the details card row's one action.
    public static func threadPanelAction(_ d: PullRequestDetail?) -> String? {
        guard let d, d.state == "open" else { return nil }
        if d.mergeability == "conflicting" { return "resolve" }
        if d.isDraft { return can(d, "ready") ? "ready" : nil }
        let classified = d.checks.isEmpty ? "none" : (checksState(d.checks) ?? "passing")
        if classified == "failing" { return "fix" }
        if classified == "pending" { return nil }
        return can(d, "merge") && !allowedMergeMethods(d).isEmpty ? "merge" : nil
    }

    /// `resolveBaseFreshness`: an open, mergeable branch behind its base, and how it may update.
    public static func baseFreshness(_ d: PullRequestDetail) -> (behindBy: Int?, methods: [String])? {
        guard d.state == "open", d.baseComparison == "behind", d.mergeability == "mergeable" else { return nil }
        let allowed = d.viewerPermissions.updateMethods ?? []
        return (d.behindBy, (d.capabilities.updateMethods ?? []).filter { allowed.contains($0) })
    }

    // MARK: Comment filter (2994 PullRequestSummaryTab.tsx:369-439, 874-940)

    /// Which kinds of comment the conversation shows. Kept for the app, not per pull request: wanting
    /// bot reports and finished threads in view is a habit (`t3code:pull-request-comment-filter:v1`).
    public struct CommentFilter: Equatable, Sendable {
        public var bots = false
        public var resolved = false
        public init(bots: Bool = false, resolved: Bool = false) { self.bots = bots; self.resolved = resolved }

        static let key = "pullRequests.commentFilter.v1"
        public static func load(_ defaults: UserDefaults = .standard) -> CommentFilter {
            let d = defaults.dictionary(forKey: key)
            return CommentFilter(bots: d?["bots"] as? Bool ?? false, resolved: d?["resolved"] as? Bool ?? false)
        }
        public func save(_ defaults: UserDefaults = .standard) { defaults.set(["bots": bots, "resolved": resolved], forKey: Self.key) }
    }

    // MARK: Conversations (3473 pullRequestDetail.logic.ts:542-670, 70a869d262)

    /// What a review thread's reply list leaves on the host: the count it says it holds beyond the
    /// replies read, whether there are more at all, and the first remark's link (`PullRequestReplyAvailability`).
    public struct ReplyAvailability: Equatable, Sendable {
        public var moreReplies: Int
        public var hasMoreReplies: Bool
        public var url: String?
    }

    /// A loose remark, or a review thread's finding with its replies under it (`PullRequestConversationItem`).
    public enum ConversationItem: Equatable, Sendable {
        case comment(PullRequestComment)
        case thread(root: PullRequestComment, replies: [PullRequestComment], thread: PullRequestReviewThread, more: ReplyAvailability)

        public var id: String {
            switch self { case .comment(let c): c.id; case .thread(_, _, let t, _): t.id }
        }
        public var root: PullRequestComment {
            switch self { case .comment(let c): c; case .thread(let r, _, _, _): r }
        }
        public var thread: PullRequestReviewThread? {
            if case .thread(_, _, let t, _) = self { return t }
            return nil
        }
        /// `pullRequestConversationItemComments`.
        public var comments: [PullRequestComment] {
            switch self { case .comment(let c): [c]; case .thread(let r, let replies, _, _): [r] + replies }
        }
    }

    /// `pullRequestConversationItems`: each review thread's remarks gathered under its first one, and
    /// the thread placed at that remark's time among the loose remarks, which keep their order.
    public static func conversationItems(_ comments: [PullRequestComment], _ reviewThreads: [PullRequestReviewThread]) -> [ConversationItem] {
        let byId = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var claimed = Set<String>()
        var threads: [(at: Double, item: ConversationItem)] = []
        for t in reviewThreads {
            // The conversation's copy where it has one; some hosts list a remark only in its thread.
            let ordered = t.comments.map { c in
                byId[c.id] ?? PullRequestComment(id: c.id, kind: "review-comment", author: c.author, body: c.body, createdAt: c.createdAt,
                                                 url: c.url, path: t.path, reviewState: nil, reactions: c.reactions, canEdit: c.canEdit)
            }.stableSorted { (instant($0.createdAt) ?? 0) < (instant($1.createdAt) ?? 0) }
            guard let root = ordered.first else { continue }
            ordered.forEach { claimed.insert($0.id) }
            let more = max(0, (t.commentCount ?? ordered.count) - ordered.count)
            threads.append((instant(root.createdAt) ?? 0, .thread(root: root, replies: Array(ordered.dropFirst()), thread: t,
                                                                  more: ReplyAvailability(moreReplies: more, hasMoreReplies: more > 0 || t.nextCommentsCursor != nil,
                                                                                          url: ordered.first { $0.url != nil }?.url))))
        }
        threads = threads.stableSorted { $0.at < $1.at }
        var items: [ConversationItem] = []
        var next = 0
        for c in comments where !claimed.contains(c.id) {
            let at = instant(c.createdAt) ?? 0
            while next < threads.count, threads[next].at < at { items.append(threads[next].item); next += 1 }
            items.append(.comment(c))
        }
        items += threads[next...].map(\.item)
        return items
    }

    /// `isPullRequestCommentFinished`: in a resolved thread, or a dismissed verdict.
    public static func isFinished(_ c: PullRequestComment, thread: PullRequestReviewThread?) -> Bool {
        thread?.isResolved == true || reviewOutcome(c.reviewState) == "dismissed"
    }

    /// The conversations the filter lets through, in their order, and how many remarks it holds back.
    /// A conversation stays when any of its remarks passes, so a person's reply keeps a bot's finding
    /// in view (`filterPullRequestConversationItems`, PullRequestSummaryTab.tsx:415-427).
    public static func filterComments(_ d: PullRequestDetail, _ filter: CommentFilter) -> (shown: [ConversationItem], hidden: Int) {
        let items = conversationItems(d.comments, d.reviewThreads)
        let shown = items.filter { item in
            item.comments.contains { c in
                let bot = c.author?.isBot == true || c.author?.login.hasSuffix("[bot]") == true
                // A bot's approval or change request is a verdict, not chatter (pullRequestDetail.logic.ts:624-641 at 3814).
                let verdict = ["approved", "changes-requested"].contains(reviewOutcome(c.reviewState) ?? "")
                return (filter.bots || !bot || verdict) && (filter.resolved || !isFinished(c, thread: item.thread))
            }
        }
        let count: ([ConversationItem]) -> Int = { $0.reduce(0) { $0 + $1.comments.count } }
        return (shown, count(items) - count(shown))
    }

    /// `PullRequestMoreReplies`: "N more replies" where the host gave a count, else "More replies".
    public static func moreRepliesLabel(_ more: Int) -> String {
        more > 0 ? "\(more.formatted()) more \(more == 1 ? "reply" : "replies")" : "More replies"
    }

    /// "1 reply", "3 replies".
    public static func replyCountLabel(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "reply" : "replies")" }

    /// The one-line preview of a collapsed remark: comments, callout markers, link targets, list and
    /// heading marks, emphasis and runs of space stripped (2994 PullRequestSummaryTab.tsx:248-255).
    public static func collapsedSummary(_ body: String) -> String {
        var s = body
        let steps: [(String, String)] = [
            (#"<!--[\s\S]*?-->"#, ""),
            (#"(?m)^\s*>?\s*\[!\w+\]\s*$"#, ""),
            (#"!?(\[([^\]]+)\])\([^)]*\)"#, "$2"),
            (#"(?m)^[\s>#*-]+"#, ""),
            (#"[*`]"#, ""),
            (#"\s+"#, " "),
        ]
        for (pattern, template) in steps {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A finished remark's collapsed card (`CollapsedComment`, 2994 PullRequestSummaryTab.tsx:204-273, 568-591):
    /// its label, `path:line` (`CommentLocation`, :119-138) and whether the thread is outdated.
    public struct Collapsed: Equatable, Sendable {
        public var label: String
        public var location: String?
        public var outdated: Bool
    }

    /// The collapsed card for a resolved or dismissed comment, nil for one still open.
    public static func collapsed(_ c: PullRequestComment, thread: PullRequestReviewThread?) -> Collapsed? {
        let resolved = thread?.isResolved == true
        guard resolved || reviewOutcome(c.reviewState) == "dismissed" else { return nil }
        let location = (thread?.path ?? c.path).map { path in path + (thread?.line.map { ":\($0)" } ?? "") }
        return Collapsed(label: resolved ? "Resolved" : "Review dismissed", location: location, outdated: thread?.isOutdated == true)
    }

    /// The note where the filter hides every comment.
    public static func allCommentsHiddenNote(_ hidden: Int) -> String {
        hidden == 1 ? "The only comment is hidden by the filter." : "All \(hidden) comments are hidden by the filter."
    }

    // MARK: Reviews

    /// `pullRequestReviewOutcome`: approved, changes-requested, dismissed or nil.
    public static func reviewOutcome(_ reviewState: String?) -> String? {
        switch reviewState?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-") {
        case "approved": "approved"
        case "changes-requested": "changes-requested"
        case "dismissed": "dismissed"
        default: nil
        }
    }

    public struct ReviewOutcomeEntry: Equatable, Sendable {
        public var key: String
        public var actor: PullRequestActor?
        public var outcome: String
        public var at: String
        public var stale: Bool
    }

    static func instant(_ iso: String) -> Double? { T3Timestamp(iso).epochMs.map(Double.init) }

    /// `newestPullRequestCommitAt`.
    public static func newestCommitAt(_ commits: [PullRequestCommit]) -> String? {
        var newest: (String, Double)?
        for c in commits { if let at = instant(c.committedDate), at > (newest?.1 ?? -.infinity) { newest = (c.committedDate, at) } }
        return newest?.0
    }

    /// `latestPullRequestReviewOutcomes`: each reviewer's last verdict; dismissals leave nothing.
    public static func latestReviewOutcomes(_ comments: [PullRequestComment], commits: [PullRequestCommit] = []) -> [ReviewOutcomeEntry] {
        let newestCommit = newestCommitAt(commits).flatMap(instant)
        var order: [String] = []
        var latest: [String: ReviewOutcomeEntry] = [:]
        for c in comments {
            guard let outcome = reviewOutcome(c.reviewState) else { continue }
            let login = c.author?.login ?? "ghost:\(c.id)"
            if let current = latest[login], (instant(current.at) ?? 0) > (instant(c.createdAt) ?? 0) { continue }
            let at = instant(c.createdAt)
            let stale = newestCommit != nil && at != nil && at! < newestCommit!
            if latest[login] == nil { order.append(login) }
            latest[login] = ReviewOutcomeEntry(key: login, actor: c.author, outcome: outcome, at: c.createdAt, stale: stale)
        }
        return order.compactMap { latest[$0] }.filter { $0.outcome != "dismissed" }
    }

    /// The header's approval count: standing approvals only, and none from a truncated conversation.
    public static func approvalCount(_ d: PullRequestDetail) -> Int {
        d.commentsTruncated ? 0 : latestReviewOutcomes(d.comments, commits: d.commits).filter { $0.outcome == "approved" && !$0.stale }.count
    }

    // MARK: Timeline

    /// `PullRequestTimelineEvent`.
    public struct TimelineEvent: Equatable, Sendable {
        public enum Kind: String, Sendable { case opened, commit, comment, review, merged, closed }
        public var id: String
        public var at: String
        public var kind: Kind
        public var title: String
        public var body: String?
        public var markdown: Bool
        public var url: String?
        public var actor: PullRequestActor?
        public var additions: Int?
        public var deletions: Int?
        public var path: String?
        public var reviewState: String?
        public var reactions: [PullRequestReaction]
        /// A review thread's finding: its replies and where it sits (`PullRequestTimelineThread`).
        public var thread: TimelineThread?
    }

    public struct TimelineThread: Equatable, Sendable {
        public var path: String
        public var line: Int?
        public var isResolved: Bool
        public var isOutdated: Bool
        public var replies: [TimelineEvent]
        public var more: ReplyAvailability
    }

    static func commentEvent(_ c: PullRequestComment) -> TimelineEvent {
        TimelineEvent(id: c.id, at: c.createdAt, kind: c.kind == "review" ? .review : .comment, title: c.kind == "review" ? "reviewed" : "commented",
                      body: visibleBody(c.body), markdown: true, url: c.url, actor: c.author, additions: nil, deletions: nil,
                      path: c.path, reviewState: c.reviewState, reactions: c.reactions ?? [])
    }

    public enum TimelineRow: Equatable, Sendable {
        case event(TimelineEvent)
        case comments([TimelineEvent])
    }

    /// `visibleBody`: a body that is only HTML comments is no body.
    public static func visibleBody(_ body: String) -> String? {
        let stripped = body.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `buildPullRequestTimeline`: opened, commits, comments and reviews, merged or closed; newest first.
    public static func timeline(_ d: PullRequestDetail) -> [TimelineEvent] {
        var events = [TimelineEvent(id: "created", at: d.createdAt, kind: .opened, title: "opened this \(ChangeRequestTerminology.of(kind: d.provider).singular)", body: nil, markdown: false,
                                    url: nil, actor: d.author, additions: nil, deletions: nil, path: nil, reviewState: nil, reactions: [])]
        events += d.commits.map { c in
            TimelineEvent(id: c.oid, at: c.committedDate, kind: .commit, title: "Commit \(c.oid.prefix(7))",
                          body: c.messageHeadline.isEmpty ? nil : c.messageHeadline, markdown: false, url: nil,
                          actor: c.authors?.first, additions: c.additions, deletions: c.deletions, path: nil, reviewState: nil, reactions: [])
        }
        events += conversationItems(d.comments, d.reviewThreads).map { item in
            var e = commentEvent(item.root)
            if case .thread(_, let replies, let t, let more) = item {
                e.thread = TimelineThread(path: t.path, line: t.line, isResolved: t.isResolved, isOutdated: t.isOutdated,
                                          replies: replies.map(commentEvent), more: more)
            }
            return e
        }
        if let merged = d.mergedAt {
            events.append(TimelineEvent(id: "merged", at: merged, kind: .merged, title: "\(ChangeRequestTerminology.of(kind: d.provider).title) merged", body: nil, markdown: false,
                                        url: nil, actor: nil, additions: nil, deletions: nil, path: nil, reviewState: nil, reactions: []))
        } else if let closed = d.closedAt {
            events.append(TimelineEvent(id: "closed", at: closed, kind: .closed, title: "\(ChangeRequestTerminology.of(kind: d.provider).title) closed", body: nil, markdown: false,
                                        url: nil, actor: nil, additions: nil, deletions: nil, path: nil, reviewState: nil, reactions: []))
        }
        return events.stableSorted { $0.at > $1.at }
    }

    /// `groupPullRequestTimelineConversations`: consecutive remarks without a verdict fold into one
    /// conversation; commits, verdicts and lifecycle stay rows of their own.
    public static func groupConversations(_ events: [TimelineEvent]) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        for e in events {
            if (e.kind == .comment || e.kind == .review) && e.thread == nil && reviewOutcome(e.reviewState) == nil {
                if case .comments(let prior)? = rows.last { rows[rows.count - 1] = .comments(prior + [e]) } else { rows.append(.comments([e])) }
            } else {
                rows.append(.event(e))
            }
        }
        return rows
    }

    // MARK: Viewed files

    /// `isFileViewed`: the unconfirmed press, else the host's word (`dismissed` reads as unseen).
    public static func isFileViewed(_ path: String, states: [String: String]?, overlay: [String: Bool]) -> Bool {
        overlay[path] ?? (states?[path] == "viewed")
    }

    /// `isStaleViewedState`: cleared, then pushed to since.
    public static func isStale(_ path: String, states: [String: String]?) -> Bool { states?[path] == "dismissed" }

    public static func countViewed(_ paths: [String], states: [String: String]?, overlay: [String: Bool]) -> Int {
        paths.filter { isFileViewed($0, states: states, overlay: overlay) }.count
    }

    /// `settleFileViewedOverlay`: presses the host has caught up on leave the overlay.
    public static func settleOverlay(_ overlay: [String: Bool], states: [String: String]?, pending: Set<String>, answered: Set<String>) -> [String: Bool] {
        guard let states, !overlay.isEmpty else { return overlay }
        return overlay.filter { path, pressed in
            pending.contains(path) || !(answered.contains(path) || (states[path] == "viewed") == pressed)
        }
    }

    /// `revertFileViewedOverlay`: a failed request takes back only its own presses.
    public static func revertOverlay(_ overlay: [String: Bool], batch: [(path: String, viewed: Bool)], owned: Set<String>) -> [String: Bool] {
        var next = overlay
        for b in batch where owned.contains(b.path) && next[b.path] == b.viewed { next[b.path] = nil }
        return next
    }

    // MARK: Stacks

    /// One row of the stack menu (PullRequestStackLayers.tsx): top layer first, the base under it.
    public struct StackRow: Equatable, Sendable {
        public var number: Int
        public var title: String?
        public var state: String
        public var isDraft: Bool
        public var isCurrent: Bool
        /// 1 based, from the bottom.
        public var position: Int
    }

    public static func stackRows(_ stack: PullRequestStackDetail, current: Int) -> [StackRow] {
        stack.layers.enumerated().reversed().map { i, l in
            StackRow(number: l.number, title: l.title, state: l.state, isDraft: l.isDraft ?? false, isCurrent: l.number == current, position: i + 1)
        }
    }
}

/// How a pull request's state reads everywhere (`resolvePullRequestState`,
/// PULL_REQUEST_STATE_PRESENTATION in pullRequestIcons.tsx).
public enum PullRequestStateTone: String, Sendable {
    case open, draft, closed, merged

    public init(state: String, isDraft: Bool) {
        self = state == "open" && isDraft ? .draft : PullRequestStateTone(rawValue: state) ?? .open
    }

    public var label: String {
        switch self { case .open: "Open"; case .draft: "Draft"; case .closed: "Closed"; case .merged: "Merged" }
    }
}
