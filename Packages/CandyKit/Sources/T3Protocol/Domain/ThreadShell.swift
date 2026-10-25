import Foundation

/// `OrchestrationV2ThreadShell` (packages/contracts/src/orchestrationV2.ts:1836-1928): one sidebar
/// row. Optional fields accept a missing key and `null`. The three `Tristate` fields keep the
/// difference because the official client reads it.
public struct ThreadShell: Codable, Hashable, Sendable, Identifiable {
    public var createdBy: String
    public var creationSource: String
    public var id: ThreadId
    public var projectId: ProjectId
    public var title: String
    public var providerInstanceId: ProviderInstanceId
    public var modelSelection: ModelSelection
    public var runtimeMode: String
    public var interactionMode: InteractionMode
    public var branch: String?
    public var worktreePath: String?
    public var linkedPullRequest: ThreadLinkedPullRequest?
    public var pullRequests: [ThreadPullRequestLink]?
    public var branchPullRequest: ThreadLinkedPullRequest?
    public var lineage: ThreadLineage
    public var forkedFrom: ForkedFrom?
    public var activeProviderThreadId: String?
    public var historyOrigin: String?
    public var latestRunId: RunId?
    public var latestRunRequestedAt: T3Timestamp?
    public var latestRunStartedAt: T3Timestamp?
    /// Absent on servers that predate it; `presentThreadShell` then falls back to `updatedAt`.
    public var latestRunCompletedAt: Tristate<T3Timestamp>
    /// Stop reached the latest run (orchestrationV2.ts:1829). Absent on servers before 3473.
    public var latestRunStopRequested: Bool?
    /// The latest run was a compaction T3 Code started and none of it failed (orchestrationV2.ts:1917). Absent before 3669.
    public var latestRunSilent: Bool?
    public var activeRunId: RunId?
    /// Absent on older servers; `resolveThreadWorkingStartedAt` then uses the latest run.
    public var activityRunStartedAt: Tristate<T3Timestamp>
    public var activityRunStatus: ThreadStatus?
    /// The running turn waits on another thread (orchestrationV2.ts:1835), so it reads as Waiting.
    public var blockedOnThreadWait: Bool?
    public var status: ThreadStatus
    public var lastError: String?
    public var lastErrorClass: ProviderFailureClass?
    /// The provider's own code for the current failure (orchestrationV2.ts:1841), such as ChatGPT's usage limit codes. Absent before 3669.
    public var lastErrorCode: String?
    public var usageLimitResetAt: T3Timestamp?
    public var pendingRuntimeRequest: PendingRuntimeRequestSummary?
    /// Always `null` in this server build. Don't build previews on it.
    public var latestVisibleMessage: JSONValue?
    public var latestUserMessageAt: T3Timestamp?
    public var latestUserAuthoredMessageAt: T3Timestamp?
    public var hasActionableProposedPlan: Bool
    /// Decodes to nil when absent; read `backgroundTasks` for T3's default of `[]`.
    public var pendingBackgroundTasks: [PendingBackgroundTask]?
    public var providerInstanceHistory: [ProviderInstanceId]?
    public var goal: ProviderGoal?
    public var itemCount: Int
    public var visibleItemCount: Int
    public var createdAt: T3Timestamp
    public var updatedAt: T3Timestamp
    public var archivedAt: T3Timestamp?
    public var settledOverride: SettledOverride?
    public var settledAt: T3Timestamp?
    public var unsettledAt: T3Timestamp?
    public var snoozedUntil: T3Timestamp?
    public var snoozedAt: T3Timestamp?
    public var limitRecovery: LimitRecovery?
    public var pinnedAt: T3Timestamp?
    public var autoSettleDisabledAt: T3Timestamp?
    public var pinOrderKey: String?
    public var activeOrderKey: String?
    /// Absent on servers without visited tracking; the client then uses its own watermark.
    public var lastVisitedAt: Tristate<T3Timestamp>
    public var titleRegeneration: TitleRegeneration?
    public var deletedAt: T3Timestamp?
    /// Guest messages waiting for the owner to send or dismiss (orchestrationV2.ts:1930-1931). Absent before Nightly 3655.
    public var pendingGuestMessageCount: Int?
    /// Whether this shell's server marks the background work the agent waits on (`awaited`), as servers do
    /// from Nightly 3655 (91ea0e18eb). Those servers always send `pendingGuestMessageCount`, which arrived in
    /// the same build (fb76594d7b), so its presence tells them apart from 3473.
    // ponytail: a field standing in for a version check; use a capability if T3 adds one
    public var marksAwaitedWork: Bool { pendingGuestMessageCount != nil }

    public var backgroundTasks: [PendingBackgroundTask] { pendingBackgroundTasks ?? [] }
}

// MARK: - Open enums

/// `OrchestrationV2ShellThreadStatus`: `idle` or any run status (orchestrationV2.ts:1813-1816).
public struct ThreadStatus: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let idle: Self = "idle"
    public static let preparing: Self = "preparing"
    public static let queued: Self = "queued"
    public static let starting: Self = "starting"
    public static let running: Self = "running"
    public static let waiting: Self = "waiting"
    public static let completed: Self = "completed"
    public static let interrupted: Self = "interrupted"
    public static let failed: Self = "failed"
    public static let cancelled: Self = "cancelled"
    public static let rolledBack: Self = "rolled_back"
}

/// `OrchestrationV2RuntimeRequest.fields.kind` (orchestrationV2.ts:1030-1033).
public struct RuntimeRequestKind: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let command: Self = "command"
    public static let fileRead: Self = "file-read"
    public static let fileChange: Self = "file-change"
    public static let mcpElicitation: Self = "mcp-elicitation"
    public static let permission: Self = "permission"
    public static let dynamicToolCall: Self = "dynamic_tool_call"
    public static let userInput: Self = "user_input"
    public static let authRefresh: Self = "auth_refresh"
}

/// `OrchestrationV2ProviderFailureClass` (orchestrationV2.ts:1261-1268).
public struct ProviderFailureClass: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let usageLimit: Self = "usage_limit"
    public static let providerError: Self = "provider_error"
    public static let transportError: Self = "transport_error"
    public static let permissionError: Self = "permission_error"
    public static let validationError: Self = "validation_error"
    public static let unknown: Self = "unknown"
}

/// `ProviderInteractionMode` (packages/contracts/src/providerPolicy.ts:34-36).
public struct InteractionMode: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let `default`: Self = "default"
    public static let plan: Self = "plan"
}

public struct SettledOverride: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let settled: Self = "settled"
    public static let active: Self = "active"
}

public struct LineageRelationship: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fork: Self = "fork"
    public static let subagent: Self = "subagent"
}

/// `OrchestrationV2PendingBackgroundTask` kinds (orchestrationV2.ts:810-828).
public struct BackgroundTaskKind: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let subagent: Self = "subagent"
    public static let command: Self = "command"
    public static let monitor: Self = "monitor"
    public static let backgroundTask: Self = "background_task"
}

public struct GoalStatus: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let active: Self = "active"
    public static let paused: Self = "paused"
    public static let blocked: Self = "blocked"
    public static let usageLimited: Self = "usage_limited"
    public static let budgetLimited: Self = "budget_limited"
    public static let complete: Self = "complete"
}

public struct PullRequestState: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let open: Self = "open"
    public static let closed: Self = "closed"
    public static let merged: Self = "merged"
}

/// `ThreadPullRequestLinkSource` (packages/contracts/src/threadPullRequest.ts). Clients hide
/// `stack-dismissed` links.
public struct PullRequestLinkSource: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let manual: Self = "manual"
    public static let created: Self = "created"
    public static let agent: Self = "agent"
    public static let stack: Self = "stack"
    public static let stackDismissed: Self = "stack-dismissed"
}

// MARK: - Nested shapes

/// `OrchestrationV2AppThreadLineage` (orchestrationV2.ts:108-112).
public struct ThreadLineage: Codable, Hashable, Sendable {
    public var parentThreadId: ThreadId?
    public var relationshipToParent: LineageRelationship?
    public var rootThreadId: ThreadId

    public init(parentThreadId: ThreadId?, relationshipToParent: LineageRelationship?, rootThreadId: ThreadId) {
        self.parentThreadId = parentThreadId
        self.relationshipToParent = relationshipToParent
        self.rootThreadId = rootThreadId
    }
}

/// `forkedFrom`: a union on `type` (`run`, `node`, `provider_thread`). Kept flat so a new type
/// still decodes.
public struct ForkedFrom: Codable, Hashable, Sendable {
    public var type: String
    public var threadId: ThreadId?
    public var runId: RunId?
    public var nodeId: String?
    public var providerThreadId: String?
    public var providerTurnId: String?

    public init(type: String, threadId: ThreadId? = nil, runId: RunId? = nil) {
        self.type = type
        self.threadId = threadId
        self.runId = runId
    }
}

/// `OrchestrationV2PendingRuntimeRequestSummary` (orchestrationV2.ts:1819-1825).
public struct PendingRuntimeRequestSummary: Codable, Hashable, Sendable {
    public var id: RuntimeRequestId
    public var kind: RuntimeRequestKind
    public var createdAt: T3Timestamp
    /// False for an async question the run keeps working past (orchestrationV2.ts:1792). Absent
    /// from servers before 3473, which counts as blocking.
    public var blocking: Bool?

    public init(id: RuntimeRequestId, kind: RuntimeRequestKind, createdAt: T3Timestamp, blocking: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.blocking = blocking
    }
}

/// `OrchestrationV2PendingBackgroundTask`. A task without `kind` decodes as `background_task`,
/// like T3's `kindUnionWithFallback`.
public struct PendingBackgroundTask: Codable, Hashable, Sendable {
    public var taskId: String
    public var description: String?
    public var kind: BackgroundTaskKind
    public var childThreadId: ThreadId?
    /// The agent resumes when this work ends (orchestrationV2.ts:556-562). Servers before 3669
    /// don't send it.
    public var awaited: Bool

    public init(taskId: String, description: String? = nil, kind: BackgroundTaskKind, childThreadId: ThreadId? = nil, awaited: Bool = false) {
        self.taskId = taskId
        self.description = description
        self.kind = kind
        self.childThreadId = childThreadId
        self.awaited = awaited
    }

    private enum CodingKeys: String, CodingKey { case taskId, description, kind, childThreadId, awaited }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        kind = try c.decodeIfPresent(BackgroundTaskKind.self, forKey: .kind) ?? .backgroundTask
        childThreadId = try c.decodeIfPresent(ThreadId.self, forKey: .childThreadId)
        awaited = try c.decodeIfPresent(Bool.self, forKey: .awaited) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskId, forKey: .taskId)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(childThreadId, forKey: .childThreadId)
        if awaited { try c.encode(true, forKey: .awaited) }
    }
}

/// `OrchestrationV2ProviderGoal` (orchestrationV2.ts:858-868).
public struct ProviderGoal: Codable, Hashable, Sendable {
    public var objective: String
    public var status: GoalStatus
    public var tokensUsed: Int?
    public var tokenBudget: Int?
    public var timeUsedSeconds: Int?
    public var checks: Int?
    public var lastCheck: String?
}

/// `OrchestrationV2LimitRecovery` (orchestrationV2.ts:339-346).
public struct LimitRecovery: Codable, Hashable, Sendable {
    public var requestId: String?
    public var runId: RunId
    public var resetAt: T3Timestamp
    public var autoResume: Bool
    public var snooze: Bool?
}

public struct TitleRegeneration: Codable, Hashable, Sendable {
    public var requestId: String
    public var startedAt: T3Timestamp
}

/// `ThreadLinkedPullRequest` (packages/contracts/src/threadPullRequest.ts:24-30), the legacy
/// single link.
public struct ThreadLinkedPullRequest: Codable, Hashable, Sendable {
    public var projectId: ProjectId
    public var repository: String
    public var number: Int
    public var url: String
}

/// `ThreadPullRequestLink` (threadPullRequest.ts:127-136).
public struct ThreadPullRequestLink: Codable, Hashable, Sendable {
    public var host: String
    public var repository: String
    public var number: Int
    public var url: String
    public var source: PullRequestLinkSource
    public var linkedAt: T3Timestamp
    /// Host state from the sync reactor; nil until first sync. Unsynced links count as open.
    public var snapshot: PullRequestSnapshot?
    public var stack: PullRequestStack?
    public var watch: JSONValue?
}

/// `ThreadPullRequestSnapshot` (threadPullRequest.ts:50-69).
public struct PullRequestSnapshot: Codable, Hashable, Sendable {
    public var state: PullRequestState
    public var title: String
    public var headBranch: String
    public var baseBranch: String
    public var isDraft: Bool
    public var updatedAt: T3Timestamp?
    public var syncedAt: T3Timestamp
    public var closedAt: String?
    public var mergedAt: String?
    public var author: JSONValue?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    public var reviewDecision: String?
    public var checksState: String?
    public var mergeability: String?
}

/// `ThreadPullRequestStack` (threadPullRequest.ts:79-87). Layers run bottom to top.
public struct PullRequestStack: Codable, Hashable, Sendable {
    public struct Layer: Codable, Hashable, Sendable {
        public var number: Int
        public var headBranch: String
        public var state: PullRequestState
    }

    public var kind: String
    public var id: String
    public var number: Int
    public var url: String
    public var base: String
    public var layers: [Layer]
}

extension ThreadShell {
    /// `isProviderNativeSubagentThread` (orchestrationV2.ts:442-451).
    public var isProviderNativeSubagent: Bool { lineage.relationshipToParent == .subagent && creationSource == "provider" }
}
