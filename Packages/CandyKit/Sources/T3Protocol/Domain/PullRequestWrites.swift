import Foundation

// The pull request writes WP7.5c added (pullRequest.ts:1112-1255, git.ts:169-322) and the small
// answers they come with. Each builder returns nil where the contract's schema would refuse the
// input, so a bad payload never reaches the socket.

/// `PullRequestReviewPosition` (pullRequest.ts:1137): one line of the diff.
public enum PullRequestReviewPosition: Hashable, Sendable {
    case added(newLine: Int)
    case deleted(oldLine: Int)
    /// `side` is "left" or "right": which copy of an unchanged line a split diff picked.
    case context(oldLine: Int, newLine: Int, side: String)

    public var json: JSONValue {
        switch self {
        case .added(let n): .object(["kind": .string("added"), "newLine": .number(Double(n))])
        case .deleted(let o): .object(["kind": .string("deleted"), "oldLine": .number(Double(o))])
        case .context(let o, let n, let side):
            .object(["kind": .string("context"), "oldLine": .number(Double(o)), "newLine": .number(Double(n)), "side": .string(side)])
        }
    }

    /// `getReviewPositionAnchor`: the side and line an annotation sits on.
    public var anchor: (side: String, line: Int) {
        switch self {
        case .added(let n): ("right", n)
        case .deleted(let o): ("left", o)
        case .context(let o, let n, let side): side == "left" ? ("left", o) : ("right", n)
        }
    }
}

/// `PullRequestReviewCommentDraft` (pullRequest.ts:1158) plus the store's local id
/// (`PendingReviewComment`, pullRequestReviewStore.ts:12).
public struct PullRequestReviewCommentDraft: Hashable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var oldPath: String?
    public var position: PullRequestReviewPosition
    public var body: String
    public init(id: String, path: String, oldPath: String? = nil, position: PullRequestReviewPosition, body: String) {
        self.id = id; self.path = path; self.oldPath = oldPath; self.position = position; self.body = body
    }

    /// The wire shape: `oldPath` only where it differs from `path`, no local id.
    public var json: JSONValue {
        var o: [String: JSONValue] = ["path": .string(path), "position": position.json, "body": .string(body)]
        if let oldPath, oldPath != path { o["oldPath"] = .string(oldPath) }
        return .object(o)
    }
}

/// `PullRequestThreadCommentsResult` (pullRequest.ts:1197).
public struct PullRequestThreadCommentsResult: Codable, Hashable, Sendable {
    public var comments: [PullRequestThreadComment]
    public var nextCursor: String?
}

/// `GitResolvedPullRequest` (git.ts:97).
public struct GitResolvedPullRequest: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    public var url: String
    public var baseBranch: String
    public var headBranch: String
    public var state: String
}

/// `GitResolvePullRequestResult` (git.ts:306).
public struct GitResolvePullRequestResult: Codable, Hashable, Sendable {
    public var pullRequest: GitResolvedPullRequest
}

/// `GitPreparePullRequestThreadResult` (git.ts:311). `isOnPullRequestHead` defaults to true.
public struct GitPreparePullRequestThreadResult: Codable, Hashable, Sendable {
    public var pullRequest: GitResolvedPullRequest
    public var branch: String
    public var worktreePath: String?
    public var isOnPullRequestHead: Bool

    private enum CodingKeys: String, CodingKey { case pullRequest, branch, worktreePath, isOnPullRequestHead }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pullRequest = try c.decode(GitResolvedPullRequest.self, forKey: .pullRequest)
        branch = try c.decode(String.self, forKey: .branch)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        isOnPullRequestHead = try c.decodeIfPresent(Bool.self, forKey: .isOnPullRequestHead) ?? true
    }
}

extension PullRequestPayloads {
    static let maxBody = 65_536

    private static func trimmedNonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// `CommentBody`: not trimmed (markdown), non-empty, at most 65536 characters; the service also
    /// refuses a body that is only whitespace.
    private static func commentBody(_ body: String) -> String? {
        guard trimmedNonEmpty(body) != nil, body.count <= maxBody else { return nil }
        return body
    }

    /// `PullRequestCommentUpdateInput` (pullRequest.ts:1125). Write RPC: `pullRequests.updateComment`.
    /// `kind` is issue-comment or review-comment; a review's own summary is not rewritable.
    public static func updateComment(_ ref: PullRequestRef, commentId: String, kind: String, body: String) -> JSONValue? {
        guard let id = trimmedNonEmpty(commentId), kind == "issue-comment" || kind == "review-comment", let body = commentBody(body) else { return nil }
        var o = ref.json
        o["commentId"] = .string(id)
        o["kind"] = .string(kind)
        o["body"] = .string(body)
        return .object(o)
    }

    /// `PullRequestThreadCommentsInput` (pullRequest.ts:1190), a read: `pullRequests.threadComments`.
    public static func threadComments(_ ref: PullRequestRef, threadId: String, cursor: String) -> JSONValue {
        var o = ref.json
        o["threadId"] = .string(threadId)
        o["cursor"] = .string(cursor)
        return .object(o)
    }

    /// `PullRequestThreadReplyInput` (pullRequest.ts:1203). Write RPC: `pullRequests.replyToThread`.
    public static func replyToThread(_ ref: PullRequestRef, threadId: String, body: String) -> JSONValue? {
        guard let id = trimmedNonEmpty(threadId), let body = commentBody(body) else { return nil }
        var o = ref.json
        o["threadId"] = .string(id)
        o["body"] = .string(body)
        return .object(o)
    }

    /// `PullRequestThreadResolutionInput` (pullRequest.ts:1210). Write RPC: `pullRequests.setThreadResolution`.
    public static func setThreadResolution(_ ref: PullRequestRef, threadId: String, resolved: Bool) -> JSONValue {
        var o = ref.json
        o["threadId"] = .string(threadId)
        o["resolved"] = .bool(resolved)
        return .object(o)
    }

    /// `PullRequestReactionInput` (pullRequest.ts:1221). Write RPC: `pullRequests.setReaction`. No
    /// `subjectId` reacts to the change request itself.
    public static func setReaction(_ ref: PullRequestRef, subjectId: String?, content: String, reacted: Bool) -> JSONValue? {
        guard PullRequestReactions.order.contains(content) else { return nil }
        var o = ref.json
        if let subjectId { guard let id = trimmedNonEmpty(subjectId) else { return nil }; o["subjectId"] = .string(id) }
        o["content"] = .string(content)
        o["reacted"] = .bool(reacted)
        return .object(o)
    }

    /// `PullRequestReviewerRequestInput` (pullRequest.ts:1240), 1 to 25 reviewers. Write RPC:
    /// `pullRequests.requestReviewers`.
    public static func requestReviewers(_ ref: PullRequestRef, reviewers: [(id: String, kind: String)], requested: Bool) -> JSONValue? {
        guard (1...25).contains(reviewers.count),
              reviewers.allSatisfy({ trimmedNonEmpty($0.id) != nil && ($0.kind == "user" || $0.kind == "team") }) else { return nil }
        var o = ref.json
        o["reviewers"] = .array(reviewers.map { .object(["id": .string(trimmedNonEmpty($0.id)!), "kind": .string($0.kind)]) })
        o["requested"] = .bool(requested)
        return .object(o)
    }

    /// `PullRequestLabelChangeInput` (pullRequest.ts:1257), 1 to 25 names. Write RPC: `pullRequests.setLabels`.
    public static func setLabels(_ ref: PullRequestRef, labels: [String], applied: Bool) -> JSONValue? {
        let names = labels.compactMap(trimmedNonEmpty)
        guard names.count == labels.count, (1...25).contains(names.count) else { return nil }
        var o = ref.json
        o["labels"] = .array(names.map { .string($0) })
        o["applied"] = .bool(applied)
        return .object(o)
    }

    /// `GitPullRequestRefInput` (git.ts:163), a read: `git.resolvePullRequest`.
    public static func resolvePullRequest(cwd: String, reference: String) -> JSONValue {
        .object(["cwd": .string(cwd), "reference": .string(reference)])
    }

    /// `GitPreparePullRequestThreadInput` (git.ts:169). Write RPC: `git.preparePullRequestThread`.
    /// The thread id travels only with `worktree` (PullRequestThreadDialog.tsx:160-164).
    public static func preparePullRequestThread(cwd: String, reference: String, mode: String, threadId: String?) -> JSONValue? {
        guard let cwd = trimmedNonEmpty(cwd), let reference = trimmedNonEmpty(reference), mode == "local" || mode == "worktree" else { return nil }
        var o: [String: JSONValue] = ["cwd": .string(cwd), "reference": .string(reference), "mode": .string(mode)]
        if mode == "worktree", let threadId { o["threadId"] = .string(threadId) }
        return .object(o)
    }
}

/// Reactions (pullRequestReactions.logic.ts).
public enum PullRequestReactions {
    /// `PULL_REQUEST_REACTION_ORDER` (line 4): GitHub's picker order.
    public static let order = ["thumbs-up", "thumbs-down", "laugh", "hooray", "confused", "heart", "rocket", "eyes"]

    public static func emoji(_ content: String) -> String {
        switch content {
        case "thumbs-up": "👍"; case "thumbs-down": "👎"; case "laugh": "😄"; case "hooray": "🎉"
        case "confused": "😕"; case "heart": "❤️"; case "rocket": "🚀"; case "eyes": "👀"
        default: "?"
        }
    }

    public static func name(_ content: String) -> String {
        switch content { case "thumbs-up": "thumbs up"; case "thumbs-down": "thumbs down"; default: content }
    }

    /// `pullRequestReactionTooltip` (line 73): "You, a, and 2 others reacted with heart emoji".
    public static func tooltip(_ r: PullRequestReaction) -> String {
        let viewerHasRoom = r.actors.count < r.count
        let names = r.viewerHasReacted && viewerHasRoom ? ["You"] + r.actors : r.actors
        let shown = Array(names.prefix(min(3, r.count)))
        let others = max(0, r.count - shown.count)
        var parts = shown
        if others > 0 {
            parts.append(shown.isEmpty ? "\(others) \(others == 1 ? "person" : "people")" : "\(others) \(others == 1 ? "other" : "others")")
        }
        let joined: String = switch parts.count {
        case 0: ""
        case 1: parts[0]
        case 2: "\(parts[0]) and \(parts[1])"
        default: parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
        return "\(joined) reacted with \(name(r.content)) emoji"
    }

    /// `applyPendingPullRequestReactions` (line 88): presses in flight drawn over the host's counts.
    public static func applyPending(_ reactions: [PullRequestReaction], _ pending: [String: Bool]) -> [PullRequestReaction] {
        if pending.isEmpty { return reactions }
        var by = Dictionary(reactions.map { ($0.content, $0) }, uniquingKeysWith: { a, _ in a })
        for (content, reacted) in pending {
            guard let current = by[content] else {
                if reacted { by[content] = PullRequestReaction(content: content, count: 1, actors: [], viewerHasReacted: true) }
                continue
            }
            if current.viewerHasReacted == reacted { continue }
            let count = current.count + (reacted ? 1 : -1)
            if count <= 0 { by[content] = nil } else { var n = current; n.count = count; n.viewerHasReacted = reacted; by[content] = n }
        }
        return order.compactMap { by[$0] }
    }

    /// `reactionsSignature` (PullRequestReactions.tsx:31): pending presses are forgotten once it moves.
    public static func signature(_ reactions: [PullRequestReaction]) -> String {
        reactions.map { "\($0.content):\($0.count):\($0.viewerHasReacted ? 1 : 0)" }.joined(separator: " ")
    }
}
