import Foundation

// Pull request wire types (packages/contracts/src/pullRequest.ts) and the payloads the Pull
// Requests page, the detail panel and thread linking send (protocol.md 9.3). Enumerations stay
// strings so a value a newer server adds still decodes. Ids are the server's own (unscoped).

/// `PullRequestActor` (pullRequest.ts:123).
public struct PullRequestActor: Codable, Hashable, Sendable {
    public var isBot: Bool?
    public var login: String
    public var name: String?
    public var avatarUrl: String?
    public init(login: String, name: String? = nil, avatarUrl: String? = nil, isBot: Bool? = nil) {
        self.login = login; self.name = name; self.avatarUrl = avatarUrl; self.isBot = isBot
    }
}

/// `PullRequestLabel` (pullRequest.ts:133).
public struct PullRequestLabel: Codable, Hashable, Sendable {
    public var name: String
    public var color: String?
    /// Optional since 4928 (pullRequest.ts:98); older servers leave it out.
    public var description: String?
    public init(name: String, color: String? = nil, description: String? = nil) { self.name = name; self.color = color; self.description = description }
}

/// `PullRequestCheck` (pullRequest.ts:150). `status`: pending, action-required, success,
/// failure, skipped, neutral, cancelled.
public struct PullRequestCheck: Codable, Hashable, Sendable {
    public var name: String
    public var status: String
    public var description: String?
    public var url: String?
    public var required: Bool?
    public init(name: String, status: String, description: String? = nil, url: String? = nil, required: Bool? = nil) {
        self.name = name; self.status = status; self.description = description; self.url = url; self.required = required
    }
}

/// `PullRequestReaction` (pullRequest.ts:178).
public struct PullRequestReaction: Codable, Hashable, Sendable {
    public var content: String
    public var count: Int
    public var actors: [String]
    public var viewerHasReacted: Bool
    public init(content: String, count: Int, actors: [String], viewerHasReacted: Bool) {
        self.content = content; self.count = count; self.actors = actors; self.viewerHasReacted = viewerHasReacted
    }
}

/// `PullRequestComment` (pullRequest.ts:200). `kind`: issue-comment, review-comment, review.
public struct PullRequestComment: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var author: PullRequestActor?
    public var body: String
    public var createdAt: String
    public var editedAt: String?
    public var url: String?
    public var path: String?
    public var reviewState: String?
    public var reactions: [PullRequestReaction]?
    /// The host's answer to whether this reader may rewrite the remark (2994, pullRequest.ts:217).
    /// Absent from older servers and hosts that don't say, which leaves the guess from authorship.
    public var canEdit: Bool?
    public init(id: String, kind: String, author: PullRequestActor?, body: String, createdAt: String,
                url: String? = nil, path: String? = nil, reviewState: String? = nil, reactions: [PullRequestReaction]? = nil,
                canEdit: Bool? = nil) {
        self.id = id; self.kind = kind; self.author = author; self.body = body; self.createdAt = createdAt
        self.url = url; self.path = path; self.reviewState = reviewState; self.reactions = reactions; self.canEdit = canEdit
    }
}

/// `PullRequestThreadComment` (pullRequest.ts:227).
public struct PullRequestThreadComment: Codable, Hashable, Sendable {
    public var id: String
    public var author: PullRequestActor?
    public var body: String
    public var createdAt: String
    public var editedAt: String?
    public var url: String?
    public var reactions: [PullRequestReaction]?
    /// As on `PullRequestComment` (2994, pullRequest.ts:246).
    public var canEdit: Bool?
    /// The review that posted it, so a link to a review with no words finds its comments (4928 pullRequest.ts:184).
    public var reviewUrl: String?
}

/// `PullRequestReviewThread` (pullRequest.ts:243): a conversation pinned to a diff line.
public struct PullRequestReviewThread: Codable, Hashable, Sendable {
    public var id: String
    public var path: String
    public var line: Int?
    public var side: String
    public var isResolved: Bool
    public var isOutdated: Bool
    public var comments: [PullRequestThreadComment]
    public var commentCount: Int?
    public var nextCommentsCursor: String?
    /// The host's per-thread answer, which only narrows the viewer's `resolve` (2994, pullRequest.ts:277).
    public var canResolve: Bool?

    /// A thread on the change request as a whole (`PullRequestOverviewThread`, 4928 pullRequest.ts:206-210),
    /// such as a GitLab overview thread. The wire sends `path: null`, which decodes as "".
    public var isOverview: Bool { path.isEmpty }

    public init(id: String, path: String, line: Int?, side: String, isResolved: Bool, isOutdated: Bool,
                comments: [PullRequestThreadComment], commentCount: Int? = nil, nextCommentsCursor: String? = nil, canResolve: Bool? = nil) {
        self.id = id; self.path = path; self.line = line; self.side = side; self.isResolved = isResolved; self.isOutdated = isOutdated
        self.comments = comments; self.commentCount = commentCount; self.nextCommentsCursor = nextCommentsCursor; self.canResolve = canResolve
    }

    private enum CodingKeys: String, CodingKey { case id, path, line, side, isResolved, isOutdated, comments, commentCount, nextCommentsCursor, canResolve }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        side = try c.decodeIfPresent(String.self, forKey: .side) ?? "right"
        isResolved = try c.decode(Bool.self, forKey: .isResolved)
        isOutdated = try c.decode(Bool.self, forKey: .isOutdated)
        comments = try c.decode([PullRequestThreadComment].self, forKey: .comments)
        commentCount = try c.decodeIfPresent(Int.self, forKey: .commentCount)
        nextCommentsCursor = try c.decodeIfPresent(String.self, forKey: .nextCommentsCursor)
        canResolve = try c.decodeIfPresent(Bool.self, forKey: .canResolve)
    }
}

/// `PullRequestReviewerCandidate` (pullRequest.ts:275).
public struct PullRequestReviewerCandidate: Codable, Hashable, Sendable {
    public var login: String
    public var name: String?
    public var avatarUrl: String?
    public var isBot: Bool?
    public var id: String
    public var kind: String
    public var isRequested: Bool
}

public struct PullRequestReviewerCandidateList: Codable, Hashable, Sendable {
    public var candidates: [PullRequestReviewerCandidate]
    public var truncated: Bool
}

/// `PullRequestLabelCandidate` (pullRequest.ts:302).
public struct PullRequestLabelCandidate: Codable, Hashable, Sendable {
    public var name: String
    public var color: String?
    public var description: String?
    public var isApplied: Bool
}

public struct PullRequestLabelCandidateList: Codable, Hashable, Sendable {
    public var candidates: [PullRequestLabelCandidate]
    public var truncated: Bool
}

/// `PullRequestFilterOptionsInput` (4928 pullRequest.ts:585): `pullRequests.filterOptions` asks for
/// `labels`, `authors` or `references`, scoped like the list. `sigil` goes with `references`.
public struct PullRequestFilterOptionsInput: Codable, Hashable, Sendable {
    public var kind: String
    public var projectId: String?
    public var query: String?
    public var sigil: String?
    public init(kind: String, projectId: String?, query: String? = nil, sigil: String? = nil) {
        self.kind = kind; self.projectId = projectId; self.query = query; self.sigil = sigil
    }
}

/// `PullRequestReferenceCandidate` (4928 pullRequest.ts:597): an issue or change request a composer
/// can reference, with the text the host links (`#12`, `!12`).
public struct PullRequestReferenceCandidate: Codable, Hashable, Sendable {
    public var reference: String
    /// `issue` or `change-request`.
    public var kind: String
    public var number: Int
    public var title: String
    /// `open`, `closed` or `merged`.
    public var state: String
    public init(reference: String, kind: String, number: Int, title: String, state: String) {
        self.reference = reference; self.kind = kind; self.number = number; self.title = title; self.state = state
    }
}

/// `PullRequestFilterOptions` (4928 pullRequest.ts:606). Servers from before reference completion
/// send no `references`.
public struct PullRequestFilterOptions: Codable, Hashable, Sendable {
    public var labels: [PullRequestLabel]
    public var authors: [PullRequestActor]
    public var references: [PullRequestReferenceCandidate]
    public var truncated: Bool
    public init(labels: [PullRequestLabel] = [], authors: [PullRequestActor] = [], references: [PullRequestReferenceCandidate] = [], truncated: Bool = false) {
        self.labels = labels; self.authors = authors; self.references = references; self.truncated = truncated
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = try c.decodeIfPresent([PullRequestLabel].self, forKey: .labels) ?? []
        authors = try c.decodeIfPresent([PullRequestActor].self, forKey: .authors) ?? []
        references = try c.decodeIfPresent([PullRequestReferenceCandidate].self, forKey: .references) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// `PullRequestCommit` (pullRequest.ts:316).
public struct PullRequestCommit: Codable, Hashable, Sendable {
    public var oid: String
    public var messageHeadline: String
    public var committedDate: String
    public var additions: Int?
    public var deletions: Int?
    public var authors: [PullRequestActor]?
    public init(oid: String, messageHeadline: String, committedDate: String, additions: Int? = nil, deletions: Int? = nil, authors: [PullRequestActor]? = nil) {
        self.oid = oid; self.messageHeadline = messageHeadline; self.committedDate = committedDate
        self.additions = additions; self.deletions = deletions; self.authors = authors
    }
}

/// `PullRequestCapabilities` (pullRequest.ts:394): what the host can do at all.
public struct PullRequestCapabilities: Codable, Hashable, Sendable {
    public struct Review: Codable, Hashable, Sendable {
        public var inlineComment: Bool
        public var reply: Bool
        public var resolve: Bool
        public var verdicts: [String]
    }
    public struct Reviewers: Codable, Hashable, Sendable {
        public var request: Bool
        public var listCandidates: Bool
        /// The host answers `reviewerCandidates` with a `query` (4928 pullRequest.ts:282).
        public var searchCandidates: Bool?
    }
    public struct Edit: Codable, Hashable, Sendable {
        public var changeRequest: Bool
        public var comment: Bool
        /// The host can turn maintainer edits on or off (4928, #25588).
        public var maintainerEdits: Bool?
    }
    public var diff: Bool
    public var comment: Bool
    public var actions: [String]
    public var mergeMethods: [String]
    public var updateMethods: [String]?
    public var search: Bool
    public var reactions: Bool?
    /// `host` or `environment`: who keeps the viewed marks.
    public var viewedFiles: String?
    public var review: Review
    public var reviewers: Reviewers
    public var edit: Edit?
    public var stacks: Bool?
    public var stackActions: Bool?
    /// Stack actions also arm and cancel auto-merge for a layer and the open layers below it
    /// (5258 pullRequest.ts:313, 69d8f4217f #41809).
    public var stackAutoMerge: Bool?
    public var deleteBranch: Bool?
    public var labels: Bool?
    /// The host searches the repository's users, so composers complete `@login` (4928 pullRequest.ts:314).
    public var mentions: Bool?
    /// The sigils composers complete references for, `#` and `!` (4928 pullRequest.ts:315).
    public var referenceSigils: [String]?
    /// Every head gets a check, so a long silence means none reported (4928 pullRequest.ts:320).
    public var checksAlwaysReport: Bool?
    /// The diff reads one withheld file by `path` (4928 pullRequest.ts:323).
    public var withheldFileDiff: Bool?
}

/// `PullRequestViewerPermissions` (pullRequest.ts:460): what this account may do.
public struct PullRequestViewerPermissions: Codable, Hashable, Sendable {
    public var stackRebase: Bool?
    public var actions: [String]
    public var comment: Bool
    public var resolve: Bool
    public var verdicts: [String]
    public var requestReviewers: Bool
    public var updateMethods: [String]?
    public var labels: Bool?
    /// Whether the title and description can be rewritten, where the host says (2994, pullRequest.ts:506).
    public var editChangeRequest: Bool?
    /// Whether the viewer can turn maintainer edits on or off (4928 pullRequest.ts:338, #25588).
    public var maintainerEdits: Bool?
}

public struct PullRequestMergeCapabilities: Codable, Hashable, Sendable {
    public var merge: Bool
    public var squash: Bool
    public var rebase: Bool
    /// 4928 (pullRequest.ts:347): absent on older servers, which means not allowed.
    public var fastForward: Bool?
    private enum CodingKeys: String, CodingKey { case merge, squash, rebase, fastForward = "fast-forward" }
    public init(merge: Bool, squash: Bool, rebase: Bool, fastForward: Bool? = nil) {
        self.merge = merge; self.squash = squash; self.rebase = rebase; self.fastForward = fastForward
    }
    public func allows(_ method: String) -> Bool {
        switch method { case "merge": merge; case "squash": squash; case "rebase": rebase; case "fast-forward": fastForward == true; default: false }
    }
}

/// `PullRequestStackMembership` (pullRequest.ts:494).
public struct PullRequestStackMembership: Codable, Hashable, Sendable {
    public var number: Int
    public var position: Int
    public var size: Int
    public var base: String
}

/// `PullRequestListEntry` (pullRequest.ts:502), plus the environment the client read it from.
public struct PullRequestListEntry: Codable, Hashable, Sendable {
    public var stack: PullRequestStackMembership?
    public var provider: String
    public var host: String
    public var projectId: String
    public var projectTitle: String
    public var repository: String
    public var number: Int
    public var title: String
    public var url: String
    public var author: PullRequestActor?
    public var headBranch: String
    public var baseBranch: String
    public var state: String
    public var isDraft: Bool
    public var mergeability: String
    /// 4928 (pullRequest.ts:375): the host merges only after a rebase onto the base.
    public var rebaseRequired: Bool?
    public var additions: Int
    public var deletions: Int
    public var createdAt: String
    public var updatedAt: String
    public var observedAt: Double?
    public var viewerReviewRequested: Bool
    public var labels: [PullRequestLabel]
    public var reviewDecision: String?
    public var checksState: String?
    /// Not on the wire: the environment the row was read from (`EnvironmentPullRequestEntry`).
    public var environmentId: String?

    public init(provider: String = "github", host: String = "github.com", projectId: String, projectTitle: String = "Project",
                repository: String, number: Int, title: String, url: String? = nil, author: PullRequestActor? = nil,
                headBranch: String = "feature", baseBranch: String = "main", state: String = "open", isDraft: Bool = false,
                mergeability: String = "mergeable", additions: Int = 0, deletions: Int = 0,
                createdAt: String = "2026-01-01T00:00:00.000Z", updatedAt: String = "2026-01-01T00:00:00.000Z",
                viewerReviewRequested: Bool = false, labels: [PullRequestLabel] = [], reviewDecision: String? = nil,
                checksState: String? = nil, stack: PullRequestStackMembership? = nil, environmentId: String? = nil) {
        self.provider = provider; self.host = host; self.projectId = projectId; self.projectTitle = projectTitle
        self.repository = repository; self.number = number; self.title = title
        self.url = url ?? "https://\(host)/\(repository)/pull/\(number)"; self.author = author
        self.headBranch = headBranch; self.baseBranch = baseBranch; self.state = state; self.isDraft = isDraft
        self.mergeability = mergeability; self.additions = additions; self.deletions = deletions
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.viewerReviewRequested = viewerReviewRequested
        self.labels = labels; self.reviewDecision = reviewDecision; self.checksState = checksState; self.stack = stack
        self.environmentId = environmentId
    }
}

/// `PullRequestProviderSummary` (pullRequest.ts:609).
public struct PullRequestProviderSummary: Codable, Hashable, Sendable {
    public var host: String
    public var kind: String
    public var searchesOnHost: Bool
    /// What this host can do, so a row offers only those actions (2994, pullRequest.ts:641). Absent from older servers.
    public var actions: [String]?
    public var projectCount: Int
    public var configured: Bool
    public var detail: String?
}

public struct PullRequestListProjectError: Codable, Hashable, Sendable {
    public var projectId: String
    public var projectTitle: String
    public var message: String
}

/// `PullRequestListResult` (pullRequest.ts:629).
public struct PullRequestListResult: Codable, Hashable, Sendable {
    public var viewers: [String: String]
    public var providers: [PullRequestProviderSummary]
    public var entries: [PullRequestListEntry]
    public var errors: [PullRequestListProjectError]
    public var truncated: Bool
    public var nextCursors: [String: String]
    public init(viewers: [String: String] = [:], providers: [PullRequestProviderSummary] = [], entries: [PullRequestListEntry] = [],
                errors: [PullRequestListProjectError] = [], truncated: Bool = false, nextCursors: [String: String] = [:]) {
        self.viewers = viewers; self.providers = providers; self.entries = entries; self.errors = errors
        self.truncated = truncated; self.nextCursors = nextCursors
    }
}

/// `PullRequestRef` (pullRequest.ts:664): what every per pull request read takes.
public struct PullRequestRef: Codable, Hashable, Sendable {
    public var projectId: String
    public var host: String?
    public var repository: String
    public var number: Int
    public init(projectId: String, host: String? = nil, repository: String, number: Int) {
        self.projectId = projectId; self.host = host; self.repository = repository; self.number = number
    }

    public var json: [String: JSONValue] {
        var o: [String: JSONValue] = ["projectId": .string(projectId), "repository": .string(repository), "number": .number(Double(number))]
        if let host { o["host"] = .string(host) }
        return o
    }
    public var payload: JSONValue { .object(json) }
}

/// `PullRequestLinkedThreadsResult` (pullRequest.ts:700).
public struct PullRequestLinkedThreadsResult: Codable, Hashable, Sendable {
    public struct Thread: Codable, Hashable, Sendable {
        public var id: String
        public var projectId: String
        public var title: String
        public var archivedAt: String?
    }
    public var threads: [Thread]
}

/// `PullRequestPreview` (pullRequest.ts:713): a Markdown link's hover card.
public struct PullRequestPreview: Codable, Hashable, Sendable {
    public var projectId: String
    public var repository: String
    public var number: Int
    public var title: String
    public var url: String
    public var author: PullRequestActor?
    public var state: String
    public var isDraft: Bool
    public var createdAt: String
}

/// `PullRequestStack` (pullRequest.ts:760): a host's native stack, bottom layer first.
public struct PullRequestStackDetail: Codable, Hashable, Sendable {
    public struct Layer: Codable, Hashable, Sendable {
        public var number: Int
        public var title: String?
        public var isDraft: Bool?
        public var headSha: String?
        public var headBranch: String
        public var state: String
        public init(number: Int, title: String? = nil, isDraft: Bool? = nil, headSha: String? = nil, headBranch: String, state: String) {
            self.number = number; self.title = title; self.isDraft = isDraft; self.headSha = headSha; self.headBranch = headBranch; self.state = state
        }
    }
    public var id: String
    public var number: Int
    public var url: String
    public var base: String
    public var layers: [Layer]
    public init(id: String, number: Int, url: String, base: String, layers: [Layer]) {
        self.id = id; self.number = number; self.url = url; self.base = base; self.layers = layers
    }
}

/// `PullRequestDetail` composed with `PullRequestActivity` (`PullRequestDetailView`,
/// pullRequest.ts:829, 904, 913). The activity half arrives from a second read, so its fields default to
/// empty until it lands.
public struct PullRequestDetail: Codable, Hashable, Sendable {
    public var provider: String
    public var capabilities: PullRequestCapabilities
    public var viewerPermissions: PullRequestViewerPermissions
    public var projectId: String
    public var projectTitle: String
    public var workspaceRoot: String
    public var repository: String
    public var number: Int
    public var title: String
    public var body: String
    public var url: String
    public var author: PullRequestActor?
    public var state: String
    public var isDraft: Bool
    public var mergeability: String
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var headBranch: String
    public var headRepositoryNameWithOwner: String?
    public var headSha: String?
    public var baseBranch: String
    public var createdAt: String
    public var updatedAt: String
    public var mergedAt: String?
    public var closedAt: String?
    public var reviewers: [PullRequestActor]
    public var labels: [PullRequestLabel]
    public var checks: [PullRequestCheck]
    public var mergeCapabilities: PullRequestMergeCapabilities
    public var viewer: String?
    public var baseComparison: String?
    public var behindBy: Int?
    public var autoMergeEnabled: Bool?
    public var autoMergeMethod: String?
    public var workflowApprovalsRequired: Int?
    /// 4928 (pullRequest.ts:658-686).
    public var rebaseRequired: Bool?
    public var mergedBy: PullRequestActor?
    public var mergeQueueRemoval: PullRequestMergeQueueRemoval?
    public var maintainerCanModify: Bool?
    // Activity (`PullRequestActivity`).
    public var comments: [PullRequestComment] = []
    public var commentCount: Int = 0
    public var commentsTruncated = false
    public var reviewThreads: [PullRequestReviewThread] = []
    public var commits: [PullRequestCommit] = []
    public var reactions: [PullRequestReaction]?

    private enum CodingKeys: String, CodingKey {
        case provider, capabilities, viewerPermissions, projectId, projectTitle, workspaceRoot, repository, number, title, body, url
        case author, state, isDraft, mergeability, additions, deletions, changedFiles, headBranch, headRepositoryNameWithOwner, headSha
        case baseBranch, createdAt, updatedAt, mergedAt, closedAt, reviewers, labels, checks, mergeCapabilities, viewer
        case baseComparison, behindBy, autoMergeEnabled, autoMergeMethod, workflowApprovalsRequired
        case rebaseRequired, mergedBy, mergeQueueRemoval, maintainerCanModify
        case comments, commentCount, commentsTruncated, reviewThreads, commits, reactions
    }

    private enum OverviewKey: String, CodingKey { case overviewThreads }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        capabilities = try c.decode(PullRequestCapabilities.self, forKey: .capabilities)
        viewerPermissions = try c.decode(PullRequestViewerPermissions.self, forKey: .viewerPermissions)
        projectId = try c.decode(String.self, forKey: .projectId)
        projectTitle = try c.decode(String.self, forKey: .projectTitle)
        workspaceRoot = try c.decode(String.self, forKey: .workspaceRoot)
        repository = try c.decode(String.self, forKey: .repository)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        url = try c.decode(String.self, forKey: .url)
        author = try c.decodeIfPresent(PullRequestActor.self, forKey: .author)
        state = try c.decode(String.self, forKey: .state)
        isDraft = try c.decode(Bool.self, forKey: .isDraft)
        mergeability = try c.decode(String.self, forKey: .mergeability)
        additions = try c.decode(Int.self, forKey: .additions)
        deletions = try c.decode(Int.self, forKey: .deletions)
        changedFiles = try c.decode(Int.self, forKey: .changedFiles)
        headBranch = try c.decode(String.self, forKey: .headBranch)
        headRepositoryNameWithOwner = try c.decodeIfPresent(String.self, forKey: .headRepositoryNameWithOwner)
        headSha = try c.decodeIfPresent(String.self, forKey: .headSha)
        baseBranch = try c.decode(String.self, forKey: .baseBranch)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        mergedAt = try c.decodeIfPresent(String.self, forKey: .mergedAt)
        closedAt = try c.decodeIfPresent(String.self, forKey: .closedAt)
        reviewers = try c.decodeIfPresent([PullRequestActor].self, forKey: .reviewers) ?? []
        labels = try c.decode([PullRequestLabel].self, forKey: .labels)
        checks = try c.decode([PullRequestCheck].self, forKey: .checks)
        mergeCapabilities = try c.decode(PullRequestMergeCapabilities.self, forKey: .mergeCapabilities)
        viewer = try c.decodeIfPresent(String.self, forKey: .viewer)
        baseComparison = try c.decodeIfPresent(String.self, forKey: .baseComparison)
        behindBy = try c.decodeIfPresent(Int.self, forKey: .behindBy)
        autoMergeEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoMergeEnabled)
        autoMergeMethod = try c.decodeIfPresent(String.self, forKey: .autoMergeMethod)
        workflowApprovalsRequired = try c.decodeIfPresent(Int.self, forKey: .workflowApprovalsRequired)
        rebaseRequired = try c.decodeIfPresent(Bool.self, forKey: .rebaseRequired)
        mergedBy = try c.decodeIfPresent(PullRequestActor.self, forKey: .mergedBy)
        mergeQueueRemoval = try c.decodeIfPresent(PullRequestMergeQueueRemoval.self, forKey: .mergeQueueRemoval)
        maintainerCanModify = try c.decodeIfPresent(Bool.self, forKey: .maintainerCanModify)
        comments = try c.decodeIfPresent([PullRequestComment].self, forKey: .comments) ?? []
        commentCount = try c.decodeIfPresent(Int.self, forKey: .commentCount) ?? comments.count
        commentsTruncated = try c.decodeIfPresent(Bool.self, forKey: .commentsTruncated) ?? false
        // `pullRequestConversationThreads` (4928 pullRequest.ts:712-717): overview threads follow the line ones.
        reviewThreads = (try c.decodeIfPresent([PullRequestReviewThread].self, forKey: .reviewThreads) ?? [])
            + (try decoder.container(keyedBy: OverviewKey.self).decodeIfPresent([PullRequestReviewThread].self, forKey: .overviewThreads) ?? [])
        commits = try c.decodeIfPresent([PullRequestCommit].self, forKey: .commits) ?? []
        reactions = try c.decodeIfPresent([PullRequestReaction].self, forKey: .reactions)
    }

    /// The activity read layered over this detail (`PullRequestDetailView`): the activity's author
    /// and reviewers win only where it carries them.
    public mutating func apply(_ activity: PullRequestActivity) {
        if let a = activity.author { author = a }
        if let r = activity.reviewers { reviewers = r }
        comments = activity.comments
        // Never fewer than the remarks in hand: a host's count can leave out review thread replies
        // (3473 usePullRequestDetail.ts:156-165).
        commentCount = max(activity.commentCount, Set(activity.comments.map(\.id) + activity.conversationThreads.flatMap { $0.comments.map(\.id) }).count)
        commentsTruncated = activity.commentsTruncated
        reviewThreads = activity.conversationThreads
        commits = activity.commits
        reactions = activity.reactions
    }

    /// `PullRequestChecks` from `pullRequests.checks` replaces the state and the checks.
    public mutating func apply(_ checks: PullRequestChecks) {
        state = checks.state
        self.checks = checks.checks
    }
}

/// `PullRequestActivity` (pullRequest.ts:904).
public struct PullRequestActivity: Codable, Hashable, Sendable {
    public var author: PullRequestActor?
    public var reviewers: [PullRequestActor]?
    public var comments: [PullRequestComment]
    public var commentCount: Int
    public var commentsTruncated: Bool
    public var reviewThreadsTruncated: Bool?
    public var reviewThreads: [PullRequestReviewThread]
    /// 4928 (pullRequest.ts:706): threads on the change request as a whole, apart so older clients still decode.
    public var overviewThreads: [PullRequestReviewThread]?
    public var commits: [PullRequestCommit]
    public var reactions: [PullRequestReaction]?

    /// `pullRequestConversationThreads` (4928 pullRequest.ts:712-717).
    public var conversationThreads: [PullRequestReviewThread] { reviewThreads + (overviewThreads ?? []) }
}

/// `PullRequestMergeQueueRemoval` (4928 pullRequest.ts:635): the merge queue let go without merging.
public struct PullRequestMergeQueueRemoval: Codable, Hashable, Sendable {
    public var id: String
    public var removedAt: String
    public var reason: String?
}

/// `PullRequestChecks` (pullRequest.ts:892).
public struct PullRequestChecks: Codable, Hashable, Sendable {
    public var state: String
    public var checks: [PullRequestCheck]
}

/// `PullRequestListStatsResult` (pullRequest.ts:811): line counts for rows a listing sent without.
public struct PullRequestListStatsResult: Codable, Hashable, Sendable {
    public struct Stat: Codable, Hashable, Sendable {
        public var projectId: String
        public var repository: String
        public var number: Int
        public var additions: Int
        public var deletions: Int
    }
    public var stats: [Stat]
}

/// `PullRequestDiffResult` (pullRequest.ts:973), the answer of `POST /api/pull-requests/diff`.
public struct PullRequestDiffResult: Codable, Hashable, Sendable {
    public struct OmittedFileStat: Codable, Hashable, Sendable {
        public var path: String
        public var additions: Double
        public var deletions: Double
    }
    public var patch: String
    public var truncated: Bool
    public var nextCursor: String?
    public var omittedFileStats: [OmittedFileStat]?
    /// On the first page: withheld files read one at a time with `path` (4928 pullRequest.ts:751).
    public var withheldFilesReadable: Bool?
}

/// `PullRequestFilesViewedResult` (pullRequest.ts:1037). `state`: unviewed, viewed, dismissed.
public struct PullRequestFilesViewedResult: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        public var path: String
        public var state: String
        public init(path: String, state: String) { self.path = path; self.state = state }
    }
    public var files: [File]
    public var truncated: Bool
    public init(files: [File], truncated: Bool = false) { self.files = files; self.truncated = truncated }
}

// MARK: - Payloads

/// The inputs the client builds. Each mirrors the contract's struct field order.
public enum PullRequestPayloads {
    /// `PullRequestListInput` (pullRequest.ts:558). `limit` defaults to T3's page of 99.
    public static func list(state: String, involvement: String, limit: Int = 99, projectId: String? = nil, host: String? = nil,
                            filters: PullRequestListFilters = .init(), query: String? = nil,
                            cursors: [String: String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["state": .string(state), "involvement": .string(involvement), "limit": .number(Double(limit))]
        if let projectId { o["projectId"] = .string(projectId) }
        if let host { o["host"] = .string(host) }
        if !filters.isEmpty { o["filters"] = filters.json }
        if let query, !query.isEmpty { o["query"] = .string(query) }
        if let cursors, !cursors.isEmpty { o["cursors"] = .object(cursors.mapValues { .string($0) }) }
        return .object(o)
    }

    /// `PullRequestDiffInput` (pullRequest.ts:950), the body of `POST /api/pull-requests/diff`.
    public static func diff(_ ref: PullRequestRef, cursor: String? = nil, commit: String? = nil, path: String? = nil) -> JSONValue {
        var o = ref.json
        if let cursor { o["cursor"] = .string(cursor) }
        if let commit { o["commit"] = .string(commit) }
        if let path { o["path"] = .string(path) }
        return .object(o)
    }

    /// `PullRequestActionInput` (pullRequest.ts:1073). Write RPC: `pullRequests.runAction`. The stack
    /// fields go only to environments advertising `pullRequestStackActions` (PullRequestStackMenu.tsx:95-104).
    public static func action(_ ref: PullRequestRef, action: String, mergeMethod: String? = nil, updateMethod: String? = nil,
                              stackNumber: Int? = nil, expectedStackHeads: [(number: Int, headSha: String)]? = nil,
                              expectedHeadSha: String? = nil, replyWithSummary: Bool = false) -> JSONValue {
        var o = ref.json
        o["action"] = .string(action)
        // 4928 pullRequest.ts:840-846. The summary is opt-in, so a 3824 server never sees the flag.
        if let expectedHeadSha, !expectedHeadSha.isEmpty { o["expectedHeadSha"] = .string(expectedHeadSha) }
        if replyWithSummary { o["replyWithSummary"] = .bool(true) }
        if let mergeMethod { o["mergeMethod"] = .string(mergeMethod) }
        if let updateMethod { o["updateMethod"] = .string(updateMethod) }
        if let stackNumber { o["stackNumber"] = .number(Double(stackNumber)) }
        if let expectedStackHeads {
            o["expectedStackHeads"] = .array(expectedStackHeads.map { .object(["number": .number(Double($0.number)), "headSha": .string($0.headSha)]) })
        }
        return .object(o)
    }

    /// `PullRequestCommentInput` (pullRequest.ts:1096). Write RPC: `pullRequests.comment`.
    public static func comment(_ ref: PullRequestRef, body: String) -> JSONValue? {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 65_536 else { return nil }
        var o = ref.json
        o["body"] = .string(body)
        return .object(o)
    }

    /// `PullRequestUpdateInput` (pullRequest.ts:1112). Write RPC: `pullRequests.update`.
    public static func update(_ ref: PullRequestRef, title: String? = nil, body: String? = nil, maintainerCanModify: Bool? = nil) -> JSONValue? {
        var o = ref.json
        if let maintainerCanModify { o["maintainerCanModify"] = .bool(maintainerCanModify) }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 1024 else { return nil }
            o["title"] = .string(trimmed)
        }
        if let body { o["body"] = .string(body) }
        return .object(o)
    }

    /// `PullRequestSubmitReviewInput` (pullRequest.ts:1175) with the pending line comments.
    /// `expectedHeadSha` pins the review to the head on screen (5258 pullRequest.ts:923, #41761).
    public static func submitReview(_ ref: PullRequestRef, verdict: String, body: String, comments: [PullRequestReviewCommentDraft] = [],
                                    expectedHeadSha: String? = nil) -> JSONValue {
        var o = ref.json
        if let expectedHeadSha, !expectedHeadSha.isEmpty { o["expectedHeadSha"] = .string(expectedHeadSha) }
        o["verdict"] = .string(verdict)
        o["body"] = .string(body)
        o["comments"] = .array(comments.map(\.json))
        return .object(o)
    }

    /// `PullRequestSetFilesViewedInput` (pullRequest.ts:1056), at most 500 presses.
    public static func setFilesViewed(_ ref: PullRequestRef, files: [(path: String, viewed: Bool)]) -> JSONValue {
        setFilesViewed(ref, files: files.map { ($0.path, $0.viewed, nil) })
    }

    /// With each file's `revision`, the version the reader was shown (4928 pullRequest.ts:813-822).
    public static func setFilesViewed(_ ref: PullRequestRef, files: [(path: String, viewed: Bool, revision: String?)]) -> JSONValue {
        var o = ref.json
        o["files"] = .array(files.prefix(500).map { f in
            var e: [String: JSONValue] = ["path": .string(f.path), "viewed": .bool(f.viewed)]
            if let r = f.revision, !r.isEmpty { e["revision"] = .string(String(r.prefix(256))) }
            return .object(e)
        })
        return .object(o)
    }

    /// `PullRequestReviewerCandidatesInput` (4928 pullRequest.ts:455-459): `query` asks the host past the first page.
    public static func reviewerCandidates(_ ref: PullRequestRef, query: String? = nil) -> JSONValue {
        var o = ref.json
        if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty { o["query"] = .string(String(q.prefix(100))) }
        return .object(o)
    }

    /// `thread.pull-request.link` (orchestrationV2.ts:2755-2762), `source: manual`.
    public static func link(threadId: String, key: ThreadPullRequestKey, url: String, commandId: String = UUID().uuidString.lowercased()) -> JSONValue {
        .object(["type": .string("thread.pull-request.link"), "commandId": .string(commandId), "threadId": .string(threadId),
                 "host": .string(key.host), "repository": .string(key.repository), "number": .number(Double(key.number)),
                 "url": .string(url), "source": .string("manual")])
    }

    /// `thread.pull-request.unlink` (orchestrationV2.ts:2763-2768).
    public static func unlink(threadId: String, key: ThreadPullRequestKey, commandId: String = UUID().uuidString.lowercased()) -> JSONValue {
        .object(["type": .string("thread.pull-request.unlink"), "commandId": .string(commandId), "threadId": .string(threadId),
                 "host": .string(key.host), "repository": .string(key.repository), "number": .number(Double(key.number))])
    }

    /// `thread.meta.update` with `linkedPullRequest` for a server that has one link per thread
    /// (`planThreadPullRequestMutation`, threadPullRequestCompatibility.ts:46-60).
    public static func legacyLink(threadId: String, projectId: String?, repository: String, number: Int, url: String,
                                  commandId: String = UUID().uuidString.lowercased()) -> JSONValue {
        let linked: JSONValue = projectId.map {
            .object(["projectId": .string($0), "repository": .string(repository), "number": .number(Double(number)), "url": .string(url)])
        } ?? .null
        return .object(["type": .string("thread.meta.update"), "commandId": .string(commandId), "threadId": .string(threadId),
                        "linkedPullRequest": linked])
    }
}

/// `PullRequestListFilters` (pullRequest.ts:51). An absent field filters nothing.
public struct PullRequestListFilters: Hashable, Sendable {
    public var draft: String?
    public var review: String?
    public var checks: String?
    /// Each group is one `label:` qualifier; a row must hold one name of every group.
    public var labels: [[String]]?
    public var excludedLabels: [String]?
    public var author: String?

    public init(draft: String? = nil, review: String? = nil, checks: String? = nil, labels: [[String]]? = nil,
                excludedLabels: [String]? = nil, author: String? = nil) {
        self.draft = draft; self.review = review; self.checks = checks; self.labels = labels
        self.excludedLabels = excludedLabels; self.author = author
    }

    public var isEmpty: Bool { self == PullRequestListFilters() }
    public var count: Int {
        [draft, review, checks, author].compactMap { $0 }.count + (labels?.count ?? 0) + (excludedLabels?.count ?? 0)
    }

    /// The narrowing typed later wins over the menu's for the same field (`{...menu, ...typed}`).
    public func merging(_ other: PullRequestListFilters) -> PullRequestListFilters {
        PullRequestListFilters(draft: other.draft ?? draft, review: other.review ?? review, checks: other.checks ?? checks,
                               labels: other.labels ?? labels, excludedLabels: other.excludedLabels ?? excludedLabels,
                               author: other.author ?? author)
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let draft { o["draft"] = .string(draft) }
        if let review { o["review"] = .string(review) }
        if let checks { o["checks"] = .string(checks) }
        if let labels { o["labels"] = .array(labels.map { .array($0.map { .string($0) }) }) }
        if let excludedLabels { o["excludedLabels"] = .array(excludedLabels.map { .string($0) }) }
        if let author { o["author"] = .string(author) }
        return .object(o)
    }
}

// MARK: - Errors

/// What a failed pull request read says (`PullRequestUnavailableError.message`,
/// `PullRequestOperationError.message`, pullRequest.ts:1270-1427).
public enum PullRequestErrors {
    /// `PROVIDER_REQUIREMENT` (3473's pullRequest.ts:1270), for servers older than 3669, which send the
    /// host's own `requirement` instead (pullRequest.ts:887-901, 233f6eac69).
    static let requirements: [String: (missing: String, unauthenticated: String)] = [
        "github": ("No GitHub credential on the server. Set GH_TOKEN, or install the GitHub CLI (https://cli.github.com/) and run `gh auth login`.",
                   "GitHub has no working credential for this host. Run `gh auth login`, or check the account and hosts in Settings → Source Control."),
        "forgejo": ("Install Forgejo CLI (`fj` 0.6 or later) from https://codeberg.org/forgejo-contrib/forgejo-cli or Gitea CLI (`tea` 0.16 or later) from https://gitea.com/gitea/tea to browse Forgejo pull requests.",
                    "Authenticate your Forgejo or Gitea server with `fj --host <server-url> auth add-token` on the T3 Code server. If fj is missing or unconfigured for that server, use `tea login add`. A configured fj account must be repaired with fj."),
        "gitlab": ("GitLab CLI (`glab`) is required to browse change requests on this host. Install it from https://gitlab.com/gitlab-org/cli and reload.",
                   "GitLab CLI is not authenticated. Run `glab auth login` and retry."),
        "azure-devops": ("Azure CLI (`az`) with the Azure DevOps extension is required. Install `az`, then run `az extension add --name azure-devops`.",
                         "Azure CLI is not signed in. Run `az login` and retry."),
        "bitbucket": ("Bitbucket needs API credentials on the server. Add them in Settings → Source Control.",
                      "Bitbucket rejected the configured credentials. Check them in Settings → Source Control."),
    ]

    /// The message for a typed failure, or nil when it is not one of the pull request errors.
    public static func message(tag: String, fields: [String: JSONValue]) -> String? {
        switch tag {
        case "PullRequestUnavailableError":
            let provider = fields["provider"]?.stringValue
            let sent = fields["requirement"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let requirement = provider.flatMap { requirements[$0] }
            switch fields["reason"]?.stringValue {
            case "cli-missing": return sent ?? requirement?.missing ?? "The tool this host is read through is not installed or set up."
            case "cli-unauthenticated": return sent ?? requirement?.unauthenticated ?? "This host has no working credentials."
            case "repository-without-project":
                // 4928 pullRequest.ts:1036-1040.
                if let host = fields["host"]?.stringValue {
                    return "No project is on \(host). Add any \(host) project to read its change requests."
                }
                return "\(fields["repository"]?.stringValue ?? "This repository") is not a project. Add it as a project to read its change requests."
            default: return "Change requests cannot be browsed for this project's host yet."
            }
        case "PullRequestOperationError":
            let operation = fields["operation"]?.stringValue ?? ""
            let detail = fields["detail"]?.stringValue ?? ""
            return "Pull request operation \(operation) failed: \(detail)"
        default:
            return nil
        }
    }

    /// `isPullRequestNotFound` (pullRequestDetail.logic.ts:1196-1202).
    public static func isNotFound(tag: String, fields: [String: JSONValue]) -> Bool {
        tag == "PullRequestOperationError" && fields["reason"]?.stringValue == "not-found"
    }
}

/// `PullRequestChangeBreakdown` (pullRequest.ts:696-707), the reply of `pullRequests.changeBreakdown`
/// (rpc.ts:543): the change's lines split by what the files are, judged from their paths. The reply
/// is null when the host gives no per-file counts or has more files than one read covers.
public struct PullRequestChangeBreakdown: Codable, Hashable, Sendable {
    public struct LineCount: Codable, Hashable, Sendable {
        public var additions: Int
        public var deletions: Int
        public init(additions: Int, deletions: Int) { self.additions = additions; self.deletions = deletions }
    }
    public var code: LineCount
    public var tests: LineCount
    public var mocks: LineCount
    public var generated: LineCount
    /// Servers from before the docs split send no key; their docs lines sit in `code`.
    public var docs: LineCount

    public init(code: LineCount, tests: LineCount, mocks: LineCount, generated: LineCount, docs: LineCount = .init(additions: 0, deletions: 0)) {
        self.code = code; self.tests = tests; self.mocks = mocks; self.generated = generated; self.docs = docs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(LineCount.self, forKey: .code)
        tests = try c.decode(LineCount.self, forKey: .tests)
        mocks = try c.decode(LineCount.self, forKey: .mocks)
        generated = try c.decode(LineCount.self, forKey: .generated)
        docs = try c.decodeIfPresent(LineCount.self, forKey: .docs) ?? .init(additions: 0, deletions: 0)
    }

    /// The rows in T3's order (`KIND_LABELS`), leaving out kinds with no lines.
    public var rows: [(label: String, count: LineCount)] {
        [("Code", code), ("Tests", tests), ("Mocks", mocks), ("Generated", generated), ("Docs", docs)]
            .filter { $0.1.additions != 0 || $0.1.deletions != 0 }
    }
}

/// `PullRequestSummary` (4928 pullRequest.ts:512-541): what `pullRequests.runAction` answers when
/// asked with `replyWithSummary` (rpc.ts:1224-1229). Optional fields the host did not report stay nil.
public struct PullRequestSummary: Codable, Hashable, Sendable {
    public var provider: String
    public var projectId: String
    public var repository: String
    public var number: Int
    public var title: String
    public var url: String
    public var state: String
    public var isDraft: Bool?
    public var headBranch: String
    public var baseBranch: String
    public var closedAt: String?
    public var mergedAt: String?
    public var updatedAt: String
    public var author: PullRequestActor?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    public var mergeability: String?
    public var rebaseRequired: Bool?
    public var headSha: String?
    public var autoMergeEnabled: Bool?
    public var autoMergeMethod: String?
}

extension PullRequestDetail {
    /// `isStalePullRequestReply` (4928 client-runtime pullRequestReply.ts:10-20) without `observedAt`,
    /// which the detail CandyWrapper keeps does not carry.
    public func isStale(_ reply: PullRequestSummary) -> Bool {
        if state == "merged" && reply.state != "merged" { return true }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parse(_ s: String) -> Date? { f.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
        if let shown = parse(updatedAt), let replied = parse(reply.updatedAt), shown != replied { return replied < shown }
        return false
    }

    /// The detail reader's `rereads` (4928 client-runtime state/pullRequests.ts:901-905): reopening or a
    /// new head changes branch data and permissions the reply lacks.
    public func needsReread(after reply: PullRequestSummary) -> Bool {
        !isStale(reply) && ((state == "closed" && reply.state == "open") || (reply.headSha != nil && reply.headSha != headSha))
    }

    /// The detail reader's `patch` (state/pullRequests.ts:906-931): the reply's reported fields over the
    /// shown detail, and a disarmed auto-merge drops its method.
    public mutating func apply(_ reply: PullRequestSummary) {
        guard !isStale(reply) else { return }
        title = reply.title; url = reply.url; state = reply.state
        if let a = reply.author { author = a }
        if let v = reply.isDraft { isDraft = v }
        if let v = reply.mergeability { mergeability = v }
        if let v = reply.additions { additions = v }
        if let v = reply.deletions { deletions = v }
        if let v = reply.changedFiles { changedFiles = v }
        headBranch = reply.headBranch; baseBranch = reply.baseBranch; updatedAt = reply.updatedAt
        if let v = reply.mergedAt { mergedAt = v }
        if let v = reply.closedAt { closedAt = v }
        if let v = reply.autoMergeEnabled { autoMergeEnabled = v }
        if let v = reply.autoMergeMethod { autoMergeMethod = v }
        if reply.autoMergeEnabled == false { autoMergeMethod = nil }
    }
}
