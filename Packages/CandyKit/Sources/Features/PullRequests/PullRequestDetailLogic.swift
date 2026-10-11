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
    public static func actionSuccess(_ action: String) -> String {
        switch action {
        case "merge": "Pull request merged"
        case "ready": "Marked ready for review"
        case "draft": "Converted to draft"
        case "close": "Pull request closed"
        case "reopen": "Pull request reopened"
        case "update-branch": "Branch updated with the base branch"
        case "enable-auto-merge": "Auto-merge turned on — merges as soon as this is ready, sooner if it already is"
        case "disable-auto-merge": "Auto-merge turned off"
        case "revert": "Revert pull request opened"
        case "approve-workflows": "Workflows approved"
        default: "Done"
        }
    }

    /// `ACTION_FAILURE_LABELS` (PullRequestDetailPanel.tsx:221-232).
    public static func actionFailure(_ action: String) -> String {
        switch action {
        case "merge": "Could not merge this pull request"
        case "ready": "Could not mark this ready for review"
        case "draft": "Could not convert this to a draft"
        case "close": "Could not close this pull request"
        case "reopen": "Could not reopen this pull request"
        case "update-branch": "Could not update this branch"
        case "enable-auto-merge": "Could not turn on auto-merge"
        case "disable-auto-merge": "Could not turn off auto-merge"
        case "revert": "Could not open a revert pull request"
        case "approve-workflows": "Could not approve workflows"
        default: "Could not do that"
        }
    }

    /// `canPerformPullRequestAction`: the host can, and this account may.
    public static func can(_ detail: PullRequestDetail?, _ action: String) -> Bool {
        guard let detail else { return false }
        return detail.capabilities.actions.contains(action) && detail.viewerPermissions.actions.contains(action)
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
        var events = [TimelineEvent(id: "created", at: d.createdAt, kind: .opened, title: "opened this pull request", body: nil, markdown: false,
                                    url: nil, actor: d.author, additions: nil, deletions: nil, path: nil, reviewState: nil, reactions: [])]
        events += d.commits.map { c in
            TimelineEvent(id: c.oid, at: c.committedDate, kind: .commit, title: "Commit \(c.oid.prefix(7))",
                          body: c.messageHeadline.isEmpty ? nil : c.messageHeadline, markdown: false, url: nil,
                          actor: c.authors?.first, additions: c.additions, deletions: c.deletions, path: nil, reviewState: nil, reactions: [])
        }
        events += d.comments.map { c in
            TimelineEvent(id: c.id, at: c.createdAt, kind: c.kind == "review" ? .review : .comment, title: c.kind == "review" ? "reviewed" : "commented",
                          body: visibleBody(c.body), markdown: true, url: c.url, actor: c.author, additions: nil, deletions: nil,
                          path: c.path, reviewState: c.reviewState, reactions: c.reactions ?? [])
        }
        if let merged = d.mergedAt {
            events.append(TimelineEvent(id: "merged", at: merged, kind: .merged, title: "Pull request merged", body: nil, markdown: false,
                                        url: nil, actor: nil, additions: nil, deletions: nil, path: nil, reviewState: nil, reactions: []))
        } else if let closed = d.closedAt {
            events.append(TimelineEvent(id: "closed", at: closed, kind: .closed, title: "Pull request closed", body: nil, markdown: false,
                                        url: nil, actor: nil, additions: nil, deletions: nil, path: nil, reviewState: nil, reactions: []))
        }
        return events.stableSorted { $0.at > $1.at }
    }

    /// `groupPullRequestTimelineConversations`: consecutive remarks without a verdict fold into one
    /// conversation; commits, verdicts and lifecycle stay rows of their own.
    public static func groupConversations(_ events: [TimelineEvent]) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        for e in events {
            if (e.kind == .comment || e.kind == .review) && reviewOutcome(e.reviewState) == nil {
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
