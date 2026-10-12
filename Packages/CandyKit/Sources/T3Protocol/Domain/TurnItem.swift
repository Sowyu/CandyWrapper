import Foundation

public enum TurnItemIdTag {}
public enum NodeIdTag {}
public enum RunAttemptIdTag {}
public enum MessageIdTag {}
public enum PlanIdTag {}
public enum CheckpointIdTag {}
public enum CheckpointScopeIdTag {}

public typealias TurnItemId = TaggedID<TurnItemIdTag>
public typealias NodeId = TaggedID<NodeIdTag>
public typealias RunAttemptId = TaggedID<RunAttemptIdTag>
public typealias MessageId = TaggedID<MessageIdTag>
public typealias PlanId = TaggedID<PlanIdTag>
public typealias CheckpointId = TaggedID<CheckpointIdTag>
public typealias CheckpointScopeId = TaggedID<CheckpointScopeIdTag>

/// `OrchestrationV2TurnItem.type` (orchestrationV2.ts:1372-1577).
public struct TurnItemType: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let userMessage: Self = "user_message"
    public static let assistantMessage: Self = "assistant_message"
    public static let reasoning: Self = "reasoning"
    public static let proposedPlan: Self = "proposed_plan"
    public static let todoList: Self = "todo_list"
    public static let userInputRequest: Self = "user_input_request"
    public static let fileChange: Self = "file_change"
    public static let commandExecution: Self = "command_execution"
    public static let fileSearch: Self = "file_search"
    public static let webSearch: Self = "web_search"
    public static let approvalRequest: Self = "approval_request"
    public static let checkpoint: Self = "checkpoint"
    public static let runInterruptRequest: Self = "run_interrupt_request"
    public static let runInterruptResult: Self = "run_interrupt_result"
    public static let systemNotice: Self = "system_notice"
    public static let error: Self = "error"
    public static let compaction: Self = "compaction"
    public static let handoff: Self = "handoff"
    public static let fork: Self = "fork"
    public static let threadCreated: Self = "thread_created"
    public static let secretRequest: Self = "secret_request"
    public static let subagent: Self = "subagent"
    public static let dynamicTool: Self = "dynamic_tool"
    public static let notification: Self = "notification"

    static let known: Set<String> = [
        "user_message", "assistant_message", "reasoning", "proposed_plan", "todo_list",
        "user_input_request", "file_change", "command_execution", "file_search", "web_search",
        "approval_request", "checkpoint", "run_interrupt_request", "run_interrupt_result",
        "system_notice", "error", "compaction", "handoff", "fork", "thread_created",
        "secret_request", "subagent", "dynamic_tool", "notification",
    ]

    /// Unknown types are dropped from projections and turn `turn-item.updated` into an
    /// unknown event (docs/protocol.md 1.4).
    public var isKnown: Bool { Self.known.contains(rawValue) }
}

/// `OrchestrationV2TurnItemStatus` (orchestrationV2.ts:1238-1247).
public struct TurnItemStatus: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let idle: Self = "idle"
    public static let pending: Self = "pending"
    public static let running: Self = "running"
    public static let waiting: Self = "waiting"
    public static let completed: Self = "completed"
    public static let failed: Self = "failed"
    public static let cancelled: Self = "cancelled"
    public static let interrupted: Self = "interrupted"
}

/// `UserMessageInputIntent` (orchestrationV2.ts:1307-1312).
public struct InputIntent: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let turnStart: Self = "turn_start"
    public static let queuedTurn: Self = "queued_turn"
    public static let steer: Self = "steer"
    public static let promotedQueuedToSteer: Self = "promoted_queued_to_steer"
}

/// One `OrchestrationV2TurnItem`. The base fields (orchestrationV2.ts:1316-1335) are typed;
/// everything type-specific stays in `raw`, the whole wire object, and is read through the
/// accessors below. The work log reads tool inputs and outputs as untyped JSON anyway, and a
/// newer server's extra fields survive a round trip.
public struct TurnItem: Codable, Hashable, Sendable, Identifiable {
    public let id: TurnItemId
    public let threadId: ThreadId
    public let type: TurnItemType
    public let runId: RunId?
    public let nodeId: NodeId?
    public let providerTurnId: String?
    public let parentItemId: TurnItemId?
    public let ordinal: Int
    public let status: TurnItemStatus
    public let title: String?
    public let startedAt: T3Timestamp?
    public let completedAt: T3Timestamp?
    public let updatedAt: T3Timestamp
    public let raw: JSONValue

    private enum CodingKeys: String, CodingKey {
        case id, threadId, type, runId, nodeId, providerTurnId, parentItemId, ordinal, status
        case title, startedAt, completedAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(TurnItemId.self, forKey: .id)
        threadId = try c.decode(ThreadId.self, forKey: .threadId)
        type = try c.decode(TurnItemType.self, forKey: .type)
        runId = try c.decodeIfPresent(RunId.self, forKey: .runId)
        nodeId = try c.decodeIfPresent(NodeId.self, forKey: .nodeId)
        providerTurnId = try c.decodeIfPresent(String.self, forKey: .providerTurnId)
        parentItemId = try c.decodeIfPresent(TurnItemId.self, forKey: .parentItemId)
        ordinal = try c.decode(Int.self, forKey: .ordinal)
        status = try c.decode(TurnItemStatus.self, forKey: .status)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        startedAt = try c.decodeIfPresent(T3Timestamp.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(T3Timestamp.self, forKey: .completedAt)
        updatedAt = try c.decode(T3Timestamp.self, forKey: .updatedAt)
        raw = try JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    /// `raw` holds every other field, so it decides equality.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.raw == rhs.raw }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(updatedAt)
    }

    /// Builds an item from its wire object, for tests and synthesized rows.
    public init(json: JSONValue) throws {
        self = try json.decode(as: TurnItem.self)
    }

    // MARK: Type-specific fields (orchestrationV2.ts:1373-1576)

    public subscript(key: String) -> JSONValue? {
        guard let value = raw[key], value != .null else { return nil }
        return value
    }

    public func string(_ key: String) -> String? { self[key]?.stringValue }

    public var text: String { string("text") ?? "" }
    public var messageId: MessageId? { string("messageId").map { MessageId($0) } }
    public var inputIntent: InputIntent? { string("inputIntent").map { InputIntent(rawValue: $0) } }
    public var streaming: Bool { self["streaming"]?.boolValue ?? false }
    public var requestId: String? { string("requestId") }
    public var toolName: String? { string("toolName") }
    /// `command_execution.input` is a string, `dynamic_tool.input` any JSON.
    public var input: JSONValue? { self["input"] }
    public var output: JSONValue? { self["output"] }
    public var outputOmitted: Bool { self["outputOmitted"]?.boolValue ?? false }
    public var exitCode: Int? { self["exitCode"]?.intValue }
    public var questionAnswer: JSONValue? { self["questionAnswer"] }
    public var subagentId: String? { string("subagentId") }
}

/// `OrchestrationV2ProjectedTurnItem` (orchestrationV2.ts:1610-1616): a row of
/// `visibleTurnItems` or a history page.
public struct ProjectedTurnItem: Codable, Hashable, Sendable {
    public var position: Int
    /// `local`, `inherited` or `synthetic`.
    public var visibility: String
    public var sourceThreadId: ThreadId
    public var sourceItemId: TurnItemId
    public var item: TurnItem

    public init(position: Int, visibility: String, sourceThreadId: ThreadId, sourceItemId: TurnItemId, item: TurnItem) {
        self.position = position
        self.visibility = visibility
        self.sourceThreadId = sourceThreadId
        self.sourceItemId = sourceItemId
        self.item = item
    }

    /// A local row for an item of this thread.
    public init(local item: TurnItem, position: Int = 0) {
        self.init(position: position, visibility: "local", sourceThreadId: item.threadId, sourceItemId: item.id, item: item)
    }

    public var isLocal: Bool { visibility == "local" }
}

/// Decodes an array of turn items or projected rows, dropping rows whose item `type` this build
/// doesn't know (docs/protocol.md 1.4). A known type that doesn't decode still fails.
struct KnownTurnItems<Element: Decodable>: Decodable {
    var values: [Element] = []

    private struct Peek: Decodable {
        var type: TurnItemType?
        var item: Item?
        struct Item: Decodable { var type: TurnItemType }
    }

    /// Reads the type with the element's own decoder, then decodes the element or skips it.
    private struct Lossy: Decodable {
        var value: Element?
        init(from decoder: Decoder) throws {
            let peek = try Peek(from: decoder)
            if let type = peek.type ?? peek.item?.type, !type.isKnown { return }
            value = try Element(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        values = try [Lossy](from: decoder).compactMap(\.value)
    }
}

extension JSONValue {
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var intValue: Int? {
        guard case .number(let n) = self, n.rounded() == n, abs(n) < 9e15 else { return nil }
        return Int(n)
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }
}

/// `OrchestrationV2NotificationSource` (contracts/src/orchestrationV2.ts:1047-1098) as T3's clients decode it.
/// Servers send a subagent as `background_task` with `work: "subagent"` and a command as
/// `background_command`, the shape clients from before those kinds read. A kind T3 doesn't know, or
/// none, decodes as `background_task` (`kindUnionWithFallback`, :770-797).
public enum NotificationSource {
    /// `system` is T3 Code itself, such as a restart continuing a turn (a7223f396, orchestrationV2.ts:1186).
    static let known: Set<String> = ["delegated_task", "subagent", "command", "monitor", "background_task", "system"]

    /// The decoded kind: `delegated_task`, `subagent`, `command`, `monitor`, `background_task` or `system`.
    public static func kind(_ source: JSONValue?) -> String {
        let raw = source?["kind"]?.stringValue ?? ""
        if raw == "background_task", source?["work"]?.stringValue == "subagent" { return "subagent" }
        if raw == "background_command" { return "command" }
        return known.contains(raw) ? raw : "background_task"
    }
}
