import Foundation

// The thread detail read model, `OrchestrationV2ThreadProjection` (orchestrationV2.ts:1785-1810),
// typed as far as the timeline needs. See docs/protocol.md 7.1 and 7.5. Optional fields accept a
// missing key and `null`; unknown fields are ignored unless noted.

/// `OrchestrationV2AppThread` (orchestrationV2.ts:364-439), the `projection.thread` and the
/// payload of every `thread.*` event. Typed fields cover the thread view; `raw` keeps the rest.
public struct AppThread: Codable, Hashable, Sendable, Identifiable {
    public let id: ThreadId
    public let projectId: ProjectId?
    public let title: String
    public let providerInstanceId: ProviderInstanceId?
    public let branch: String?
    public let worktreePath: String?
    public let lineage: ThreadLineage?
    public let createdBy: String?
    public let creationSource: String?
    public let activeProviderThreadId: String?
    public let historyOrigin: String?
    public let archivedAt: T3Timestamp?
    public let deletedAt: T3Timestamp?
    public let createdAt: T3Timestamp?
    public let updatedAt: T3Timestamp?
    /// The thread's guest link (orchestrationV2.ts:443). Absent from servers before 3669 and while nobody shares it.
    public let guestShare: ThreadGuestShare?
    public let raw: JSONValue

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, providerInstanceId, branch, worktreePath, lineage, createdBy
        case creationSource, activeProviderThreadId, historyOrigin, archivedAt, deletedAt, createdAt, updatedAt, guestShare
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ThreadId.self, forKey: .id)
        projectId = try c.decodeIfPresent(ProjectId.self, forKey: .projectId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        providerInstanceId = try c.decodeIfPresent(ProviderInstanceId.self, forKey: .providerInstanceId)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        lineage = try? c.decodeIfPresent(ThreadLineage.self, forKey: .lineage)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        creationSource = try c.decodeIfPresent(String.self, forKey: .creationSource)
        activeProviderThreadId = try c.decodeIfPresent(String.self, forKey: .activeProviderThreadId)
        historyOrigin = try c.decodeIfPresent(String.self, forKey: .historyOrigin)
        archivedAt = try c.decodeIfPresent(T3Timestamp.self, forKey: .archivedAt)
        deletedAt = try c.decodeIfPresent(T3Timestamp.self, forKey: .deletedAt)
        createdAt = try c.decodeIfPresent(T3Timestamp.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(T3Timestamp.self, forKey: .updatedAt)
        guestShare = (try? c.decodeIfPresent(ThreadGuestShare.self, forKey: .guestShare)) ?? nil
        raw = try JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.raw == rhs.raw }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// `isProviderNativeSubagentThread` (orchestrationV2.ts:442-451).
    public var isProviderNativeSubagent: Bool {
        lineage?.relationshipToParent == .subagent && creationSource == "provider"
    }
}

/// `OrchestrationV2Run` (orchestrationV2.ts:541-584).
public struct Run: Codable, Hashable, Sendable, Identifiable {
    public var id: RunId
    public var threadId: ThreadId
    public var ordinal: Int
    /// The run's provider and model (orchestrationV2.ts:547-548); handoff rows name them.
    public var providerInstanceId: ProviderInstanceId?
    public var modelSelection: ModelSelection?
    public var rootNodeId: NodeId?
    public var activeAttemptId: RunAttemptId?
    public var checkpointId: CheckpointId?
    public var userMessageId: MessageId?
    /// The provider thread the run executes on; picks the provider session (queue capabilities).
    public var providerThreadId: String?
    public var status: ThreadStatus
    public var queuePosition: Int?
    public var queueHeld: Bool?
    public var requestedAt: T3Timestamp
    public var startedAt: T3Timestamp?
    public var completedAt: T3Timestamp?
    public var workStartedAt: T3Timestamp?
    public var restartCancelledBackgroundWork: JSONValue?
    /// The launch's workspace strategy, kept so a failed preparation can be retried (orchestrationV2.ts:583).
    public var workspacePreparation: JSONValue?
}

/// `OrchestrationV2RunAttempt` (orchestrationV2.ts:597-619).
public struct RunAttempt: Codable, Hashable, Sendable, Identifiable {
    public var id: RunAttemptId
    public var runId: RunId
    public var attemptOrdinal: Int
    public var rootNodeId: NodeId
    public var providerTurnId: String?
    /// `pending`, `running`, `completed`, `interrupted`, `failed`, `cancelled`, `superseded`.
    public var status: String
    public var reason: String?
    public var startedAt: T3Timestamp?
    public var completedAt: T3Timestamp?

    public init(id: RunAttemptId, runId: RunId, attemptOrdinal: Int, rootNodeId: NodeId, status: String) {
        self.id = id
        self.runId = runId
        self.attemptOrdinal = attemptOrdinal
        self.rootNodeId = rootNodeId
        self.status = status
    }
}

/// `OrchestrationV2ExecutionNode` (orchestrationV2.ts:622-660).
public struct ExecutionNode: Codable, Hashable, Sendable, Identifiable {
    public var id: NodeId
    public var threadId: ThreadId
    public var runId: RunId?
    public var parentNodeId: NodeId?
    public var rootNodeId: NodeId
    public var kind: String
    public var status: String
    public var startedAt: T3Timestamp?
    public var completedAt: T3Timestamp?

    public init(id: NodeId, threadId: ThreadId, runId: RunId?, parentNodeId: NodeId?, rootNodeId: NodeId, kind: String, status: String) {
        self.id = id
        self.threadId = threadId
        self.runId = runId
        self.parentNodeId = parentNodeId
        self.rootNodeId = rootNodeId
        self.kind = kind
        self.status = status
    }
}

/// `OrchestrationV2ConversationMessage` (orchestrationV2.ts:1113-1137).
public struct ConversationMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: MessageId
    public var threadId: ThreadId
    public var runId: RunId?
    public var nodeId: NodeId?
    /// `user`, `assistant` or `system`.
    public var role: String
    public var text: String
    public var streaming: Bool
    public var createdAt: T3Timestamp
    public var updatedAt: T3Timestamp
    /// Set on automatic deliveries, which the queue strip leaves out (`getUserQueuedThreadRuns`).
    public var delegatedCompletion: JSONValue?
    public var notification: JSONValue?
    /// The scheduled task that sent it, when it's a scheduled run's prompt (orchestrationV2.ts:1093).
    public var scheduledTaskId: String?
    /// The script a provider-native workflow runs, not prose (orchestrationV2.ts:1095-1099).
    public var workflowScript: Bool?
    /// `OrchestrationMessageContext`; a sent guest message carries `guest` here (composerContext.ts:257-272 at 3669).
    public var context: JSONValue?
}

extension ConversationMessage {
    public init(id: MessageId, threadId: ThreadId, runId: RunId?, role: String, text: String, streaming: Bool, createdAt: T3Timestamp,
                updatedAt: T3Timestamp, scheduledTaskId: String? = nil) {
        self.id = id; self.threadId = threadId; self.runId = runId; nodeId = nil; self.role = role; self.text = text
        self.streaming = streaming; self.createdAt = createdAt; self.updatedAt = updatedAt; self.scheduledTaskId = scheduledTaskId
    }
}

/// `OrchestrationV2PlanArtifact` (orchestrationV2.ts:1170-1191), flat over its `kind`.
public struct PlanArtifact: Codable, Hashable, Sendable, Identifiable {
    public var id: PlanId
    public var threadId: ThreadId
    public var runId: RunId?
    /// `proposed_plan` or `todo_list`.
    public var kind: String
    /// `draft`, `active`, `completed`, `superseded`.
    public var status: String
    public var markdown: String?
    public var steps: JSONValue?
    public var explanation: String?
}

/// `{path, kind, additions, deletions}` of a checkpoint or a turn diff summary.
public struct CheckpointFile: Codable, Hashable, Sendable {
    public var path: String
    public var kind: String?
    public var additions: Int?
    public var deletions: Int?

    public init(path: String, kind: String? = nil, additions: Int? = nil, deletions: Int? = nil) {
        self.path = path
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
    }
}

/// `OrchestrationV2Checkpoint` (orchestrationV2.ts:1202-1215).
public struct Checkpoint: Codable, Hashable, Sendable, Identifiable {
    public var id: CheckpointId
    public var threadId: ThreadId
    public var scopeId: CheckpointScopeId
    public var runId: RunId?
    public var appRunOrdinal: Int?
    public var ordinalWithinScope: Int?
    public var ref: String
    /// `ready`, `missing`, `error`, `stale`.
    public var status: String
    public var files: [CheckpointFile]
    public var capturedAt: T3Timestamp
}

/// `OrchestrationV2RuntimeRequest` (orchestrationV2.ts:1025-1044).
public struct RuntimeRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var nodeId: NodeId?
    public var kind: RuntimeRequestKind
    /// `pending`, `resolved`, `expired`, `cancelled`.
    public var status: String
    public var createdAt: T3Timestamp?
    public var resolvedAt: T3Timestamp?
    public var decision: String?
    public var answers: JSONValue?
    public var responseCapability: ResponseCapability?
}

/// `OrchestrationV2RuntimeRequest.responseCapability` (orchestrationV2.ts:1035-1039): `live`
/// answers go to the provider session, `message` answers become a user message, and
/// `not_resumable` (with a reason) can't be answered.
public struct ResponseCapability: Codable, Hashable, Sendable {
    public var type: String
    public var reason: String?
    public init(type: String, reason: String? = nil) {
        self.type = type
        self.reason = reason
    }
}

/// `OrchestrationV2ThreadProjection`. Arrays the timeline doesn't read stay `[JSONValue]`
/// (objects with an `id`), so events can still upsert them.
public struct ThreadProjection: Codable, Hashable, Sendable {
    public var thread: AppThread
    public var runs: [Run]
    public var attempts: [RunAttempt]
    public var nodes: [ExecutionNode]
    public var subagents: [JSONValue]
    public var providerSessions: [JSONValue]
    public var providerThreads: [JSONValue]
    public var providerTurns: [JSONValue]
    public var runtimeRequests: [RuntimeRequest]
    public var messages: [ConversationMessage]
    public var plans: [PlanArtifact]
    /// Unknown item types are dropped while decoding.
    public var turnItems: [TurnItem]
    public var checkpointScopes: [JSONValue]
    public var checkpoints: [Checkpoint]
    public var contextHandoffs: [JSONValue]
    public var contextTransfers: [JSONValue]
    /// The ordered rows the timeline renders. Unknown item types are dropped while decoding.
    public var visibleTurnItems: [ProjectedTurnItem]
    public var updatedAt: T3Timestamp

    private enum CodingKeys: String, CodingKey {
        case thread, runs, attempts, nodes, subagents, providerSessions, providerThreads, providerTurns
        case runtimeRequests, messages, plans, turnItems, checkpointScopes, checkpoints, contextHandoffs
        case contextTransfers, visibleTurnItems, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list<T: Decodable>(_ key: CodingKeys) throws -> [T] {
            try c.decodeIfPresent([T].self, forKey: key) ?? []
        }
        thread = try c.decode(AppThread.self, forKey: .thread)
        runs = try list(.runs)
        attempts = try list(.attempts)
        nodes = try list(.nodes)
        subagents = try list(.subagents)
        providerSessions = try list(.providerSessions)
        providerThreads = try list(.providerThreads)
        providerTurns = try list(.providerTurns)
        runtimeRequests = try list(.runtimeRequests)
        messages = try list(.messages)
        plans = try list(.plans)
        turnItems = try c.decodeIfPresent(CompatibleTurnItems<TurnItem>.self, forKey: .turnItems)?.values ?? []
        checkpointScopes = try list(.checkpointScopes)
        checkpoints = try list(.checkpoints)
        contextHandoffs = try list(.contextHandoffs)
        contextTransfers = try list(.contextTransfers)
        visibleTurnItems = try c.decodeIfPresent(CompatibleTurnItems<ProjectedTurnItem>.self, forKey: .visibleTurnItems)?.values ?? []
        updatedAt = try c.decode(T3Timestamp.self, forKey: .updatedAt)
    }
}
