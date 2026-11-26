import Foundation

// Issue wire types (4928 packages/contracts/src/issue.ts) and the payloads the Issues page, the
// issue panel and thread linking send (rpc.ts:1334-1424). Enumerations stay strings so a value a
// newer server adds still decodes. Actors, labels and reactions are the pull request types, as in
// T3 (issue.ts:32-37, 66-70).

/// `IssueState` (issue.ts:46-52). `category` is `open` or `closed`; `name` is the tracker's own.
public struct IssueState: Codable, Hashable, Sendable {
    public var category: String
    public var name: String
    public var closeReason: String?
    public init(category: String, name: String, closeReason: String? = nil) {
        self.category = category; self.name = name; self.closeReason = closeReason
    }
}

/// `IssueRef` (issue.ts:77-84). `host` is absent for the kind's public host.
public struct IssueRef: Codable, Hashable, Sendable {
    public var projectId: String
    public var tracker: String
    public var host: String?
    public var scope: String
    public var key: String
    public init(projectId: String, tracker: String, host: String?, scope: String, key: String) {
        self.projectId = projectId; self.tracker = tracker; self.host = host; self.scope = scope; self.key = key
    }

    public var json: [String: JSONValue] {
        var o: [String: JSONValue] = ["projectId": .string(projectId), "tracker": .string(tracker),
                                      "scope": .string(scope), "key": .string(key)]
        if let host { o["host"] = .string(host) }
        return o
    }

    public var scopeRef: IssueScopeRef { IssueScopeRef(projectId: projectId, tracker: tracker, host: host, scope: scope) }
}

/// `IssueScopeRef` (issue.ts:88-94).
public struct IssueScopeRef: Codable, Hashable, Sendable {
    public var projectId: String
    public var tracker: String
    public var host: String?
    public var scope: String
    public init(projectId: String, tracker: String, host: String?, scope: String) {
        self.projectId = projectId; self.tracker = tracker; self.host = host; self.scope = scope
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["projectId": .string(projectId), "tracker": .string(tracker), "scope": .string(scope)]
        if let host { o["host"] = .string(host) }
        return .object(o)
    }
}

/// `IssueListEntry` (issue.ts:97-122): `IssueSummary` with the project that read it.
public struct IssueListEntry: Codable, Hashable, Sendable {
    public var tracker: String
    public var host: String
    public var scope: String
    public var key: String
    /// `#123` on a git host, `ENG-123` on Linear.
    public var displayKey: String
    public var title: String
    public var url: String
    public var author: PullRequestActor?
    public var state: IssueState
    public var createdAt: String
    public var updatedAt: String
    public var closedAt: String?
    public var assignees: [PullRequestActor]
    public var labels: [PullRequestLabel]
    public var commentCount: Int
    public var projectId: String
    public var projectTitle: String

    public init(tracker: String, host: String, scope: String, key: String, displayKey: String, title: String, url: String,
                author: PullRequestActor?, state: IssueState, createdAt: String, updatedAt: String, closedAt: String? = nil,
                assignees: [PullRequestActor] = [], labels: [PullRequestLabel] = [], commentCount: Int = 0,
                projectId: String, projectTitle: String) {
        self.tracker = tracker; self.host = host; self.scope = scope; self.key = key; self.displayKey = displayKey
        self.title = title; self.url = url; self.author = author; self.state = state; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.closedAt = closedAt; self.assignees = assignees; self.labels = labels
        self.commentCount = commentCount; self.projectId = projectId; self.projectTitle = projectTitle
    }

    public var ref: IssueRef { IssueRef(projectId: projectId, tracker: tracker, host: host, scope: scope, key: key) }
}

/// `IssueComment` (issue.ts:124-133). `reactions` is absent on a tracker without them.
public struct IssueComment: Codable, Hashable, Sendable {
    public var id: String
    public var author: PullRequestActor?
    public var body: String
    public var createdAt: String
    public var url: String?
    public var reactions: [PullRequestReaction]?
    public init(id: String, author: PullRequestActor?, body: String, createdAt: String, url: String? = nil, reactions: [PullRequestReaction]? = nil) {
        self.id = id; self.author = author; self.body = body; self.createdAt = createdAt; self.url = url; self.reactions = reactions
    }
}

/// `IssueEvent` (issue.ts:140-163). `kind`: closed, reopened, labeled, unlabeled, assigned,
/// unassigned, renamed, referenced, state-changed.
public struct IssueEvent: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var actor: PullRequestActor?
    public var createdAt: String
    public var detail: String?
    public init(id: String, kind: String, actor: PullRequestActor?, createdAt: String, detail: String?) {
        self.id = id; self.kind = kind; self.actor = actor; self.createdAt = createdAt; self.detail = detail
    }
}

/// `IssueLinkedPullRequest` (issue.ts:166-176).
public struct IssueLinkedPullRequest: Codable, Hashable, Sendable {
    public var repository: String
    public var number: Int
    public var title: String
    public var url: String
    public var state: String
    public var isDraft: Bool
    public var closesIssue: Bool
}

/// `IssueCapabilities` (issue.ts:182-201): what a tracker can do at all.
public struct IssueCapabilities: Codable, Hashable, Sendable {
    public var create: Bool
    public var edit: Bool
    public var comment: Bool
    public var labels: Bool
    public var assignees: Bool
    public var reactions: Bool
    public var templates: Bool
    public var linkedPullRequests: Bool
    public var events: Bool
    public var search: Bool
    public init(create: Bool = false, edit: Bool = false, comment: Bool = false, labels: Bool = false, assignees: Bool = false,
                reactions: Bool = false, templates: Bool = false, linkedPullRequests: Bool = false, events: Bool = false, search: Bool = false) {
        self.create = create; self.edit = edit; self.comment = comment; self.labels = labels; self.assignees = assignees
        self.reactions = reactions; self.templates = templates; self.linkedPullRequests = linkedPullRequests
        self.events = events; self.search = search
    }
}

/// `IssueViewerPermissions` (issue.ts:209-215).
public struct IssueViewerPermissions: Codable, Hashable, Sendable {
    public var setState: Bool
    public var comment: Bool
    public var edit: Bool
    public var labels: Bool
    public var assignees: Bool
    public init(setState: Bool = true, comment: Bool = true, edit: Bool = true, labels: Bool = true, assignees: Bool = true) {
        self.setState = setState; self.comment = comment; self.edit = edit; self.labels = labels; self.assignees = assignees
    }
}

/// `IssueDetail` (issue.ts:218-243).
public struct IssueDetail: Codable, Hashable, Sendable {
    public var tracker: String
    public var host: String
    public var scope: String
    public var key: String
    public var displayKey: String
    public var title: String
    public var url: String
    public var author: PullRequestActor?
    public var state: IssueState
    public var createdAt: String
    public var updatedAt: String
    public var closedAt: String?
    public var assignees: [PullRequestActor]
    public var labels: [PullRequestLabel]
    public var commentCount: Int
    public var projectId: String
    public var projectTitle: String
    /// False for an issue outside every project's scope, read-only here.
    public var writable: Bool
    public var capabilities: IssueCapabilities
    public var viewerPermissions: IssueViewerPermissions
    /// Every state the issue can be in, in the tracker's order, the current one included.
    public var states: [IssueState]
    public var viewer: String?
    public var body: String
    public var reactions: [PullRequestReaction]?
    public var comments: [IssueComment]
    public var commentsCursor: String?
    public var events: [IssueEvent]
    public var linkedPullRequests: [IssueLinkedPullRequest]

    public var summary: IssueListEntry {
        IssueListEntry(tracker: tracker, host: host, scope: scope, key: key, displayKey: displayKey, title: title, url: url,
                       author: author, state: state, createdAt: createdAt, updatedAt: updatedAt, closedAt: closedAt,
                       assignees: assignees, labels: labels, commentCount: commentCount, projectId: projectId, projectTitle: projectTitle)
    }
}

/// `IssueCommentsPage` (issue.ts:252-256).
public struct IssueCommentsPage: Codable, Hashable, Sendable {
    public var comments: [IssueComment]
    public var nextCursor: String?
}

/// `IssueListInput` (issue.ts:265-296).
public struct IssueListInput: Hashable, Sendable {
    public var state = "open"
    public var involvement: String?
    public var projectId: String?
    /// Projects left out of the listing, as the issues page hides them, at most 1,000 (5258 issue.ts:259-268,
    /// 9fde959ac0 #38799). Older servers ignore it, so the page also drops their rows.
    public var excludeProjectIds: [String]?
    public var host: String?
    public var limit: Int?
    public var cursors: [String: String]?
    public var refresh = false
    public var query: String?
    public var labels: [String]?
    public var assignee: String?
    public var sort: String?
    /// `ISSUE_LIST_MAX_EXCLUDED_PROJECTS` (5258 issue.ts:259).
    public static let maxExcludedProjects = 1_000
    public init() {}

    public var json: JSONValue {
        var o: [String: JSONValue] = ["state": .string(state)]
        if let involvement { o["involvement"] = .string(involvement) }
        if let projectId { o["projectId"] = .string(projectId) }
        if let excludeProjectIds, !excludeProjectIds.isEmpty {
            o["excludeProjectIds"] = .array(excludeProjectIds.prefix(IssueListInput.maxExcludedProjects).map { .string($0) })
        }
        if let host { o["host"] = .string(host) }
        if let limit { o["limit"] = .number(Double(limit)) }
        if let cursors { o["cursors"] = .object(cursors.mapValues { .string($0) }) }
        if refresh { o["refresh"] = .bool(true) }
        if let query, !query.isEmpty { o["query"] = .string(String(query.prefix(200))) }
        if let labels, !labels.isEmpty { o["labels"] = .array(labels.prefix(20).map { .string($0) }) }
        if let assignee { o["assignee"] = .string(assignee) }
        if let sort { o["sort"] = .string(sort) }
        return .object(o)
    }
}

/// `IssueTrackerSummary` (issue.ts:300-309).
public struct IssueTrackerSummary: Codable, Hashable, Sendable {
    public var tracker: String
    public var host: String
    public var projectCount: Int
    public var capabilities: IssueCapabilities?
    public var configured: Bool
    public var detail: String?
    public init(tracker: String, host: String, projectCount: Int, capabilities: IssueCapabilities?, configured: Bool, detail: String? = nil) {
        self.tracker = tracker; self.host = host; self.projectCount = projectCount; self.capabilities = capabilities
        self.configured = configured; self.detail = detail
    }
}

/// `IssueListProjectError` (issue.ts:311-316).
public struct IssueListProjectError: Codable, Hashable, Sendable {
    public var projectId: String
    public var projectTitle: String
    public var message: String
    public init(projectId: String, projectTitle: String, message: String) {
        self.projectId = projectId; self.projectTitle = projectTitle; self.message = message
    }
}

/// `IssueListResult` (issue.ts:318-333).
public struct IssueListResult: Codable, Hashable, Sendable {
    public var viewers: [String: String]
    public var trackers: [IssueTrackerSummary]
    public var entries: [IssueListEntry]
    public var errors: [IssueListProjectError]
    /// Keyed `"<host> <scope>"`, sent straight back as `cursors`.
    public var nextCursors: [String: String]
    /// Absent from servers that predate it.
    public var scopes: [IssueScopeRef]?
    public init(viewers: [String: String] = [:], trackers: [IssueTrackerSummary] = [], entries: [IssueListEntry] = [],
                errors: [IssueListProjectError] = [], nextCursors: [String: String] = [:], scopes: [IssueScopeRef]? = nil) {
        self.viewers = viewers; self.trackers = trackers; self.entries = entries; self.errors = errors
        self.nextCursors = nextCursors; self.scopes = scopes
    }
}

/// `IssueLabelCandidate` and `IssueAssigneeCandidate` (issue.ts:419-432) in `IssueCandidates`.
public struct IssueCandidates: Codable, Hashable, Sendable {
    public struct Label: Codable, Hashable, Sendable {
        public var name: String
        public var color: String?
        public var description: String?
    }
    public struct Assignee: Codable, Hashable, Sendable {
        public var login: String
        public var name: String?
        public var avatarUrl: String?
        public var isBot: Bool?
        /// How the tracker addresses this person on a write.
        public var id: String
        public var actor: PullRequestActor { PullRequestActor(login: login, name: name, avatarUrl: avatarUrl, isBot: isBot) }
    }
    public var labels: [Label]
    public var assignees: [Assignee]
    public var truncated: Bool
}

/// `IssueLinkedThreadsResult` (issue.ts:536-547).
public struct IssueLinkedThreadsResult: Codable, Hashable, Sendable {
    public struct Thread: Codable, Hashable, Sendable {
        public var id: String
        public var projectId: String
        public var title: String
        public var archivedAt: String?
        public var settled: Bool
    }
    public var threads: [Thread]
}

/// `IssueTrackerConnection` (issue.ts:584-597) in `IssueTrackerConnectionList` (:599-604).
public struct IssueTrackerConnectionList: Codable, Hashable, Sendable {
    public struct Connection: Codable, Hashable, Sendable {
        public struct Credential: Codable, Hashable, Sendable {
            public var label: String
            public var helpUrl: String?
        }
        public struct Scope: Codable, Hashable, Sendable {
            public var key: String
            public var name: String
        }
        public var tracker: String
        public var displayName: String
        public var host: String
        public var scopeNoun: String
        public var credential: Credential
        public var connected: Bool
        public var account: String?
        public var detail: String?
        public var workspace: String?
        public var scopes: [Scope]
    }
    public struct Binding: Codable, Hashable, Sendable {
        public var tracker: String
        public var scope: String
        public init(tracker: String, scope: String) { self.tracker = tracker; self.scope = scope }
    }
    public var trackers: [Connection]
    public var bindings: [String: Binding]
}

/// Payloads for the issue writes (issue.ts:347-410) and thread links (orchestrationV2.ts:3301-3318).
public enum IssueWrites {
    /// `IssueCommentsPageInput` (issue.ts:246-250).
    public static func comments(_ ref: IssueRef, cursor: String) -> JSONValue {
        var o = ref.json; o["cursor"] = .string(String(cursor.prefix(4096))); return .object(o)
    }

    /// `IssueCommentInput` (issue.ts:363-367).
    public static func comment(_ ref: IssueRef, body: String) -> JSONValue {
        var o = ref.json; o["body"] = .string(String(body.prefix(65_536))); return .object(o)
    }

    /// `IssueUpdateInput` (issue.ts:374-381). `labels` and `assignees` are the whole set.
    public static func update(_ ref: IssueRef, title: String? = nil, body: String? = nil, labels: [String]? = nil, assignees: [String]? = nil) -> JSONValue {
        var o = ref.json
        if let title { o["title"] = .string(String(title.prefix(1024))) }
        if let body { o["body"] = .string(String(body.prefix(65_536))) }
        if let labels { o["labels"] = .array(labels.prefix(50).map { .string($0) }) }
        if let assignees { o["assignees"] = .array(assignees.prefix(25).map { .string($0) }) }
        return .object(o)
    }

    /// `IssueSetStateInput` (issue.ts:384-389): a name from `IssueDetail.states`.
    public static func setState(_ ref: IssueRef, state: String) -> JSONValue {
        var o = ref.json; o["state"] = .string(state); return .object(o)
    }

    /// `IssueReactionInput` (issue.ts:391-398). No `subjectId` reacts to the issue itself.
    public static func react(_ ref: IssueRef, subjectId: String?, content: String, reacted: Bool) -> JSONValue {
        var o = ref.json
        if let subjectId { o["subjectId"] = .string(subjectId) }
        o["content"] = .string(content)
        o["reacted"] = .bool(reacted)
        return .object(o)
    }

    /// `ThreadIssueKey` (issue.ts:487-494), as `issues.linkedThreads` takes it.
    public static func key(_ key: ThreadIssueKey) -> JSONValue {
        .object(["tracker": .string(key.tracker), "host": .string(key.host), "scope": .string(key.scope), "key": .string(key.key)])
    }

    /// `thread.issue.link` (orchestrationV2.ts:3301-3311), `source: manual`.
    public static func link(threadId: String, key: ThreadIssueKey, projectId: String, url: String, displayKey: String, title: String,
                            commandId: String = UUID().uuidString.lowercased()) -> JSONValue {
        .object(["type": .string("thread.issue.link"), "commandId": .string(commandId), "threadId": .string(threadId),
                 "tracker": .string(key.tracker), "host": .string(key.host), "scope": .string(key.scope), "key": .string(key.key),
                 "projectId": .string(projectId), "url": .string(url), "displayKey": .string(displayKey), "title": .string(title),
                 "source": .string("manual")])
    }

    /// `thread.issue.unlink` (orchestrationV2.ts:3312-3318).
    public static func unlink(threadId: String, key: ThreadIssueKey, commandId: String = UUID().uuidString.lowercased()) -> JSONValue {
        .object(["type": .string("thread.issue.unlink"), "commandId": .string(commandId), "threadId": .string(threadId),
                 "tracker": .string(key.tracker), "host": .string(key.host), "scope": .string(key.scope), "key": .string(key.key)])
    }
}

/// `ThreadIssueKey` (issue.ts:487-494): tracker-level identity, so the same issue linked through two
/// projects compares equal (`threadIssueKeyOf`, issue.ts:526-528).
public struct ThreadIssueKey: Hashable, Sendable {
    public var tracker: String
    public var host: String
    public var scope: String
    public var key: String
    public init(tracker: String, host: String, scope: String, key: String) {
        self.tracker = tracker; self.host = host; self.scope = scope; self.key = key
    }

    /// `threadIssueKeyOf`.
    public var normalized: String {
        "\(tracker)\u{0}\(host.trimmingCharacters(in: .whitespaces).lowercased())\u{0}\(scope.trimmingCharacters(in: .whitespaces).lowercased())\u{0}\(key.trimmingCharacters(in: .whitespaces))"
    }
}

extension ThreadIssueLink {
    public var issueKey: ThreadIssueKey { ThreadIssueKey(tracker: tracker, host: host, scope: scope, key: key) }
    public var ref: IssueRef { IssueRef(projectId: projectId.rawValue, tracker: tracker, host: host, scope: scope, key: key) }
}

/// The `_tag`ged errors issue RPCs fail with (issue.ts:441-480), read from the RPC failure's cause.
public enum IssueFailure {
    /// `IssueUnavailableError.message`.
    public static func unavailableMessage(_ reason: String) -> String {
        switch reason {
        case "tool-missing": return "The tool this tracker is read through is not installed or set up."
        case "unauthenticated": return "This tracker has no working credentials."
        default: return "Issues cannot be browsed for this project yet."
        }
    }

    /// The message a tagged issue error reads as (`IssueUnavailableError.message`,
    /// `IssueOperationError.message`, `IssueTrackerConnectionError.message`), or nil for another tag.
    public static func message(tag: String, fields: [String: JSONValue]) -> String? {
        switch tag {
        case "IssueUnavailableError":
            return unavailableMessage(fields["reason"]?.stringValue ?? "")
        case "IssueOperationError":
            let detail = fields["detail"]?.stringValue ?? "unknown error"
            return "Issue operation \(fields["operation"]?.stringValue ?? "request") failed: \(detail)"
        case "IssueTrackerConnectionError":
            return "\(fields["tracker"]?.stringValue ?? "tracker") connection failed: \(fields["detail"]?.stringValue ?? "unknown error")"
        default:
            return nil
        }
    }
}
