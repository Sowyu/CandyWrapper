import Foundation

/// `OrchestrationV2SubscribeThreadInput` (orchestrationV2.ts:3238-3257). Nil fields are left out
/// of the JSON, matching `optionalKey`.
public struct SubscribeThreadInput: Codable, Hashable, Sendable {
    public var threadId: ThreadId
    public var afterSequence: Int?
    public var requestCompletionMarker: Bool?
    public var acceptBoundedSnapshot: Bool?
    public var acceptCompactTurnItems: Bool?
    public var acceptDedupedBodies: Bool?
    public var acceptCompactIds: Bool?

    public init(
        threadId: ThreadId, afterSequence: Int? = nil, requestCompletionMarker: Bool? = nil,
        acceptBoundedSnapshot: Bool? = nil, acceptCompactTurnItems: Bool? = nil,
        acceptDedupedBodies: Bool? = nil, acceptCompactIds: Bool? = nil
    ) {
        self.threadId = threadId
        self.afterSequence = afterSequence
        self.requestCompletionMarker = requestCompletionMarker
        self.acceptBoundedSnapshot = acceptBoundedSnapshot
        self.acceptCompactTurnItems = acceptCompactTurnItems
        self.acceptDedupedBodies = acceptDedupedBodies
        self.acceptCompactIds = acceptCompactIds
    }
}

/// A thread snapshot: the `snapshot` stream item without its `kind`, and the body of
/// `GET /api/orchestration/threads/:id/bounded` (`OrchestrationV2ThreadBoundedSnapshot`,
/// orchestrationV2.ts:3278-3302). The history keys are absent on a legacy full snapshot.
public struct ThreadDetailSnapshot: Codable, Hashable, Sendable {
    public var snapshotSequence: Int
    public var projection: ThreadProjection
    public var historyCursor: Tristate<String>
    public var hasMoreHistory: Bool?
    public var latestLocalTurnOrdinal: Tristate<Int>
    public var payloadBudgetExceeded: Bool?
    /// `projection.turnItems` omits the items of local visible rows; restore them with
    /// `restoringLocalVisibleTurnItems()` before use.
    public var turnItemsOmitLocalVisible: Bool?

    public init(
        snapshotSequence: Int, projection: ThreadProjection, historyCursor: Tristate<String> = .absent,
        hasMoreHistory: Bool? = nil, latestLocalTurnOrdinal: Tristate<Int> = .absent,
        payloadBudgetExceeded: Bool? = nil, turnItemsOmitLocalVisible: Bool? = nil
    ) {
        self.snapshotSequence = snapshotSequence
        self.projection = projection
        self.historyCursor = historyCursor
        self.hasMoreHistory = hasMoreHistory
        self.latestLocalTurnOrdinal = latestLocalTurnOrdinal
        self.payloadBudgetExceeded = payloadBudgetExceeded
        self.turnItemsOmitLocalVisible = turnItemsOmitLocalVisible
    }

    private enum CodingKeys: String, CodingKey {
        case snapshotSequence, projection, historyCursor, hasMoreHistory, latestLocalTurnOrdinal
        case payloadBudgetExceeded, turnItemsOmitLocalVisible
    }

    public init(from decoder: Decoder) throws {
        try self.init(restored: ThreadPayloadRestoration.snapshot(JSONValue(from: decoder)))
    }

    /// Shares the decoded representation with the stateful stream restorer, avoiding another
    /// walk over the snapshot's records after their ID and body markers have been consumed.
    init(restored raw: JSONValue) throws {
        let c = try TreeDecoder(raw, parent: nil, key: nil).container(keyedBy: CodingKeys.self)
        snapshotSequence = try c.decode(Int.self, forKey: .snapshotSequence)
        guard let value = raw["projection"] else { throw ThreadPayloadRestoration.invalid("Missing projection") }
        projection = try value.decode(as: ThreadProjection.self)
        historyCursor = try c.decode(Tristate<String>.self, forKey: .historyCursor)
        hasMoreHistory = try c.decodeIfPresent(Bool.self, forKey: .hasMoreHistory)
        latestLocalTurnOrdinal = try c.decode(Tristate<Int>.self, forKey: .latestLocalTurnOrdinal)
        payloadBudgetExceeded = try c.decodeIfPresent(Bool.self, forKey: .payloadBudgetExceeded)
        turnItemsOmitLocalVisible = try c.decodeIfPresent(Bool.self, forKey: .turnItemsOmitLocalVisible)
    }

    /// Whether the snapshot carries progressive history metadata (threads.ts:590-593).
    public var hasProgressiveHistory: Bool {
        !historyCursor.isAbsent || hasMoreHistory != nil || !latestLocalTurnOrdinal.isAbsent
    }

    /// Port of `boundedSnapshotProjection` (packages/shared/src/orchestrationV2BoundedSnapshot.ts:51-58):
    /// prepends the items of local visible rows that a compact snapshot left out of `turnItems`.
    public func restoringLocalVisibleTurnItems() -> ThreadProjection {
        guard turnItemsOmitLocalVisible == true else { return projection }
        let threadId = projection.thread.id
        let local = projection.visibleTurnItems
            .filter { $0.isLocal || $0.sourceThreadId == threadId }
            .map(\.item)
        guard !local.isEmpty else { return projection }
        var restored = projection
        restored.turnItems = local + projection.turnItems
        return restored
    }
}

/// `OrchestrationV2ThreadHistoryPage` (orchestrationV2.ts:3305-3317): older rows, oldest first,
/// from `GET /api/orchestration/threads/:id/history`.
public struct ThreadHistoryPage: Codable, Hashable, Sendable {
    public var snapshotSequence: Int
    public var items: [ProjectedTurnItem]
    public var nextCursor: String?
    public var hasMoreHistory: Bool

    public init(snapshotSequence: Int, items: [ProjectedTurnItem], nextCursor: String?, hasMoreHistory: Bool) {
        self.snapshotSequence = snapshotSequence
        self.items = items
        self.nextCursor = nextCursor
        self.hasMoreHistory = hasMoreHistory
    }

    private enum CodingKeys: String, CodingKey { case snapshotSequence, items, nextCursor, hasMoreHistory }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshotSequence = try c.decode(Int.self, forKey: .snapshotSequence)
        let raw = try ThreadPayloadRestoration.expandIds(JSONValue(from: decoder), container: nil)
        guard let rows = raw["items"] else { throw ThreadPayloadRestoration.invalid("Missing history items") }
        items = try rows.decode(as: CompatibleTurnItems<ProjectedTurnItem>.self).values
        for row in items { try ThreadPayloadRestoration.rejectOmittedBodies(row.item.raw) }
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        hasMoreHistory = try c.decode(Bool.self, forKey: .hasMoreHistory)
    }
}

/// Query of the history endpoint (`RT/threadHistoryHttp.ts:11-46`).
public struct ThreadHistoryRequest: Hashable, Sendable {
    public enum View: String, Sendable { case conversation, activity }
    public var threadId: ThreadId
    public var cursor: String
    public var throughEntryId: String?
    public var view: View?

    public init(threadId: ThreadId, cursor: String, throughEntryId: String? = nil, view: View? = nil) {
        self.threadId = threadId
        self.cursor = cursor
        self.throughEntryId = throughEntryId
        self.view = view
    }

    /// `/api/orchestration/threads/<id>/history?cursor=...`, relative to the environment's base URL.
    public var path: String {
        var components = URLComponents()
        components.path = "/api/orchestration/threads/\(threadId.rawValue)/history"
        components.queryItems = [URLQueryItem(name: "cursor", value: cursor), URLQueryItem(name: "compactIds", value: "1")]
            + (throughEntryId.map { [URLQueryItem(name: "throughEntryId", value: $0)] } ?? [])
            + (view.map { [URLQueryItem(name: "view", value: $0.rawValue)] } ?? [])
        // URLComponents leaves `+` alone, and the server's query parser reads it as a space; the
        // cursor is opaque, so encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.string ?? components.path
    }

    /// `/api/orchestration/threads/<id>/bounded?compactTurnItems=1`.
    public static func boundedSnapshotPath(_ threadId: ThreadId) -> String {
        var components = URLComponents()
        components.path = "/api/orchestration/threads/\(threadId.rawValue)/bounded"
        components.queryItems = [
            URLQueryItem(name: "compactTurnItems", value: "1"),
            URLQueryItem(name: "dedupeBodies", value: "1"),
            URLQueryItem(name: "compactIds", value: "1"),
        ]
        return components.string ?? components.path
    }
}

/// `type` of an `OrchestrationV2DomainEvent` (orchestrationV2.ts:1646-1781).
public struct ThreadEventType: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let threadDeleted: Self = "thread.deleted"
    public static let threadVisited: Self = "thread.visited"
    public static let threadMarkedUnread: Self = "thread.marked-unread"
    public static let runCreated: Self = "run.created"
    public static let runUpdated: Self = "run.updated"
    public static let runBackgroundWorkCancelled: Self = "run.background-work-cancelled"
    public static let runAttemptCreated: Self = "run-attempt.created"
    public static let runAttemptUpdated: Self = "run-attempt.updated"
    public static let nodeUpdated: Self = "node.updated"
    public static let subagentUpdated: Self = "subagent.updated"
    public static let providerSessionAttached: Self = "provider-session.attached"
    public static let providerSessionUpdated: Self = "provider-session.updated"
    public static let providerSessionDetached: Self = "provider-session.detached"
    public static let providerThreadUpdated: Self = "provider-thread.updated"
    public static let providerTurnUpdated: Self = "provider-turn.updated"
    public static let runtimeRequestUpdated: Self = "runtime-request.updated"
    public static let messageUpdated: Self = "message.updated"
    public static let turnItemUpdated: Self = "turn-item.updated"
    public static let planUpdated: Self = "plan.updated"
    public static let checkpointScopeCreated: Self = "checkpoint-scope.created"
    public static let checkpointCaptured: Self = "checkpoint.captured"
    public static let checkpointRollbackRequested: Self = "checkpoint.rollback-requested"
    public static let contextHandoffUpdated: Self = "context-handoff.updated"
    public static let contextTransferCreated: Self = "context-transfer.created"
    public static let contextTransferUpdated: Self = "context-transfer.updated"

    /// Every `thread.*` event carries the whole `AppThread`.
    static let threadPayloadTypes: Set<String> = [
        "thread.created", "thread.archived", "thread.unarchived", "thread.deleted", "thread.settled",
        "thread.unsettled", "thread.snoozed", "thread.unsnoozed", "thread.auto-settle-set", "thread.pinned",
        "thread.unpinned", "thread.pin-reordered", "thread.active-reordered", "thread.visited",
        "thread.marked-unread", "thread.metadata-updated", "thread.pull-request-synced",
        "thread.runtime-mode-updated", "thread.interaction-mode-updated", "thread.model-selection-updated",
        "thread.provider-switched",
    ]

    static let known: Set<String> = threadPayloadTypes.union([
        "run.created", "run.updated", "run.background-work-cancelled", "run-attempt.created",
        "run-attempt.updated", "node.updated", "subagent.updated", "provider-session.attached",
        "provider-session.updated", "provider-session.detached", "provider-thread.updated",
        "provider-turn.updated", "runtime-request.updated", "message.updated", "turn-item.updated",
        "plan.updated", "checkpoint-scope.created", "checkpoint.captured", "checkpoint.rollback-requested",
        "context-handoff.updated", "context-transfer.created", "context-transfer.updated",
    ])

    public var isKnown: Bool { Self.known.contains(rawValue) }
    public var carriesThread: Bool { Self.threadPayloadTypes.contains(rawValue) }
}

/// A decoded `OrchestrationV2DomainEvent` payload. Entities the timeline reads are typed; the
/// rest stay JSON objects that the reducer upserts by `id`.
public enum ThreadEventPayload: Hashable, Sendable {
    case thread(AppThread)
    case run(Run)
    case attempt(RunAttempt)
    case node(ExecutionNode)
    case runtimeRequest(RuntimeRequest)
    case message(ConversationMessage)
    case turnItem(TurnItem)
    case plan(PlanArtifact)
    case checkpoint(Checkpoint)
    /// Any other entity (subagent, provider session/thread/turn, checkpoint scope, context
    /// handoff/transfer) and the small payloads of detach, background-work-cancelled and
    /// rollback-requested.
    case json(JSONValue)
}

/// `OrchestrationV2DomainEvent`: the base fields (orchestrationV2.ts:1634-1643) and a payload.
public struct ThreadEvent: Hashable, Sendable {
    public var id: String
    public var type: ThreadEventType
    public var threadId: ThreadId
    public var runId: RunId?
    public var occurredAt: T3Timestamp
    public var payload: ThreadEventPayload

    public init(id: String, type: ThreadEventType, threadId: ThreadId, runId: RunId?, occurredAt: T3Timestamp, payload: ThreadEventPayload) {
        self.id = id
        self.type = type
        self.threadId = threadId
        self.runId = runId
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

/// `OrchestrationV2ThreadStreamItem` (orchestrationV2.ts:3366-3392). An event of a type this
/// build does not know decodes to `.unknownEvent` and still advances the resume cursor.
/// Unfamiliar turn items keep valid common fields for the generic timeline fallback.
public enum ThreadStreamItem: Decodable, Hashable, Sendable {
    case synchronized
    case snapshot(ThreadDetailSnapshot)
    case event(sequence: Int, event: ThreadEvent)
    case unknownEvent(sequence: Int, eventType: String)
    /// A `kind` this build doesn't know. Carries `sequence` when it has one.
    case unknown(kind: String, sequence: Int?)

    public var sequence: Int? {
        switch self {
        case .event(let s, _), .unknownEvent(let s, _): s
        case .unknown(_, let s): s
        case .synchronized, .snapshot: nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sequence, event, snapshotSequence, projection, historyCursor, hasMoreHistory
        case latestLocalTurnOrdinal, payloadBudgetExceeded, turnItemsOmitLocalVisible
    }

    private enum EventKeys: String, CodingKey {
        case id, type, threadId, runId, occurredAt, payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "synchronized":
            self = .synchronized
        case "snapshot":
            self = .snapshot(try ThreadDetailSnapshot(from: decoder))
        case "event":
            let sequence = try c.decode(Int.self, forKey: .sequence)
            let e = try c.nestedContainer(keyedBy: EventKeys.self, forKey: .event)
            let type = try e.decode(ThreadEventType.self, forKey: .type)
            guard type.isKnown else {
                self = .unknownEvent(sequence: sequence, eventType: type.rawValue)
                return
            }
            if type == .turnItemUpdated {
                struct Peek: Decodable { var type: TurnItemType }
                let itemType = try e.decode(Peek.self, forKey: .payload).type
                if !itemType.isKnown, (try? e.decode(TurnItem.self, forKey: .payload)) == nil {
                    self = .unknownEvent(sequence: sequence, eventType: type.rawValue)
                    return
                }
            }
            // Raw callers must use ThreadStore.applyWire for omitted event bodies.
            if type == .turnItemUpdated || type == .subagentUpdated {
                try ThreadPayloadRestoration.rejectOmittedBodies(e.decode(JSONValue.self, forKey: .payload))
            }
            let payload: ThreadEventPayload
            switch type {
            case _ where type.carriesThread: payload = .thread(try e.decode(AppThread.self, forKey: .payload))
            case .runCreated, .runUpdated: payload = .run(try e.decode(Run.self, forKey: .payload))
            case .runAttemptCreated, .runAttemptUpdated: payload = .attempt(try e.decode(RunAttempt.self, forKey: .payload))
            case .nodeUpdated: payload = .node(try e.decode(ExecutionNode.self, forKey: .payload))
            case .runtimeRequestUpdated: payload = .runtimeRequest(try e.decode(RuntimeRequest.self, forKey: .payload))
            case .messageUpdated: payload = .message(try e.decode(ConversationMessage.self, forKey: .payload))
            case .turnItemUpdated: payload = .turnItem(try e.decode(TurnItem.self, forKey: .payload))
            case .planUpdated: payload = .plan(try e.decode(PlanArtifact.self, forKey: .payload))
            case .checkpointCaptured: payload = .checkpoint(try e.decode(Checkpoint.self, forKey: .payload))
            default: payload = .json(try e.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null)
            }
            self = .event(sequence: sequence, event: ThreadEvent(
                id: try e.decodeIfPresent(String.self, forKey: .id) ?? "",
                type: type,
                threadId: try e.decode(ThreadId.self, forKey: .threadId),
                runId: try e.decodeIfPresent(RunId.self, forKey: .runId),
                occurredAt: try e.decode(T3Timestamp.self, forKey: .occurredAt),
                payload: payload))
        default:
            self = .unknown(kind: kind, sequence: try? c.decodeIfPresent(Int.self, forKey: .sequence))
        }
    }
}

// MARK: - Diffs

/// `OrchestrationGetTurnDiffInput` (packages/contracts/src/checkpointDiff.ts:33-39). Requires
/// `fromTurnCount <= toTurnCount`.
public struct GetTurnDiffInput: Codable, Hashable, Sendable {
    public var threadId: ThreadId
    public var fromTurnCount: Int
    public var toTurnCount: Int
    public var ignoreWhitespace: Bool?

    public init(threadId: ThreadId, fromTurnCount: Int, toTurnCount: Int, ignoreWhitespace: Bool? = nil) {
        self.threadId = threadId
        self.fromTurnCount = fromTurnCount
        self.toTurnCount = toTurnCount
        self.ignoreWhitespace = ignoreWhitespace
    }
}

/// `OrchestrationGetFullThreadDiffInput` (checkpointDiff.ts:44-49).
public struct GetFullThreadDiffInput: Codable, Hashable, Sendable {
    public var threadId: ThreadId
    public var toTurnCount: Int
    public var ignoreWhitespace: Bool?

    public init(threadId: ThreadId, toTurnCount: Int, ignoreWhitespace: Bool? = nil) {
        self.threadId = threadId
        self.toTurnCount = toTurnCount
        self.ignoreWhitespace = ignoreWhitespace
    }
}

/// `ThreadTurnDiff`, the result of both `orchestration.getTurnDiff` and
/// `orchestration.getFullThreadDiff` (checkpointDiff.ts:21-27). `diff` is a unified git patch;
/// an empty string means no net changes.
public struct ThreadTurnDiff: Codable, Hashable, Sendable {
    public var threadId: ThreadId
    public var fromTurnCount: Int
    public var toTurnCount: Int
    public var diff: String
}

// MARK: - Turn item detail

/// `OrchestrationV2GetTurnItemInput` (orchestrationV2.ts:3458-3463). `revision` is the item's
/// `updatedAt` as the client saw it (or `"live"` while it runs); it only keys the client cache.
public struct GetTurnItemInput: Codable, Hashable, Sendable {
    public var threadId: ThreadId
    public var itemId: TurnItemId
    public var revision: String?

    public init(threadId: ThreadId, itemId: TurnItemId, revision: String? = nil) {
        self.threadId = threadId
        self.itemId = itemId
        self.revision = revision
    }
}

/// `OrchestrationV2GetTurnItemResult` (orchestrationV2.ts:3467-3469). The server bounds inputs and
/// outputs to 256 KiB and ends a cut string with "\n… output truncated for transport"
/// (`WireProjection.ts:16-35`, `:171-197`). `item` is null when the item is gone.
public struct GetTurnItemResult: Codable, Hashable, Sendable {
    public var item: TurnItem?

    public init(item: TurnItem?) { self.item = item }

    private enum CodingKeys: String, CodingKey { case item }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decodeIfPresent(TurnItem.self, forKey: .item)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(item, forKey: .item)
    }
}
