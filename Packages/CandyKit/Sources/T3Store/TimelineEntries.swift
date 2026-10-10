import Foundation
import T3Protocol

/// `ChatMessage` (apps/web/src/types.ts), built from a user or assistant turn item.
public struct ChatMessage: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable, Hashable { case user, assistant, system }
    public var id: MessageId
    public var role: Role
    public var text: String
    public var runId: RunId?
    public var streaming: Bool
    public var createdAt: T3Timestamp
    public var updatedAt: T3Timestamp
    public var inputIntent: InputIntent?
    public var createdBy: String?
    public var creationSource: String?
    public var senderThreadId: String?
    public var scheduledTaskId: String?
    public var context: JSONValue?
    public var attachments: [JSONValue]

    public init(
        id: MessageId, role: Role, text: String, runId: RunId? = nil, streaming: Bool = false,
        createdAt: T3Timestamp, updatedAt: T3Timestamp? = nil, inputIntent: InputIntent? = nil,
        createdBy: String? = nil, creationSource: String? = nil, senderThreadId: String? = nil,
        scheduledTaskId: String? = nil, context: JSONValue? = nil, attachments: [JSONValue] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.runId = runId
        self.streaming = streaming
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.inputIntent = inputIntent
        self.createdBy = createdBy
        self.creationSource = creationSource
        self.senderThreadId = senderThreadId
        self.scheduledTaskId = scheduledTaskId
        self.context = context
        self.attachments = attachments
    }
}

/// `ProposedPlan` (apps/web/src/types.ts).
public struct ProposedPlan: Sendable, Hashable {
    public var id: PlanId
    public var runId: RunId?
    public var planMarkdown: String
    /// `draft`, `active`, `completed` or `superseded`.
    public var status: String
    public var createdAt: T3Timestamp
    public var updatedAt: T3Timestamp
}

/// `TimelineAttempt` (session-logic.ts:118-121).
public struct TimelineAttempt: Sendable, Hashable {
    public var id: RunAttemptId
    public var runId: RunId
    public var attemptOrdinal: Int
    public var rootNodeId: NodeId
    public var status: String

    public init(id: RunAttemptId, runId: RunId, attemptOrdinal: Int = 1, rootNodeId: NodeId, status: String) {
        self.id = id
        self.runId = runId
        self.attemptOrdinal = attemptOrdinal
        self.rootNodeId = rootNodeId
        self.status = status
    }
}

/// `TimelineEntry` (session-logic.ts:123-169), the output of pass 1.
///
/// Skipped: the `html-render` and `mcp-app` kinds. They need a web view, so their completed
/// `dynamic_tool` calls stay ordinary work entries until that milestone.
public struct TimelineEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case message(ChatMessage, projectedItem: ProjectedTurnItem?)
        case proposedPlan(ProposedPlan)
        case work(WorkLogEntry)
        /// fork, handoff, run interrupt request and result, secret request, subagent.
        case event(ProjectedTurnItem)
    }

    public var id: String
    public var createdAt: T3Timestamp
    public var kind: Kind
    public var attempt: TimelineAttempt?

    public init(id: String, createdAt: T3Timestamp, kind: Kind, attempt: TimelineAttempt? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.attempt = attempt
    }

    public static func message(_ id: String, _ message: ChatMessage, attempt: TimelineAttempt? = nil) -> Self {
        Self(id: id, createdAt: message.createdAt, kind: .message(message, projectedItem: nil), attempt: attempt)
    }

    public static func work(_ id: String, _ entry: WorkLogEntry, attempt: TimelineAttempt? = nil) -> Self {
        Self(id: id, createdAt: entry.createdAt, kind: .work(entry), attempt: attempt)
    }

    public var message: ChatMessage? { if case .message(let m, _) = kind { return m }; return nil }
    public var work: WorkLogEntry? { if case .work(let e) = kind { return e }; return nil }
    public var eventItem: ProjectedTurnItem? { if case .event(let p) = kind { return p }; return nil }

    /// `timelineEntryIsPersistentResourceCard` (session-logic.ts:338-349): fork, created thread
    /// and secret request events never fold.
    public var isPersistentResourceCard: Bool {
        guard let item = eventItem?.item else { return false }
        return item.type == .fork || item.type == .threadCreated || item.type == .secretRequest
    }
}

public enum TimelineEntries {
    static let standaloneEventTypes: Set<TurnItemType> = [
        .fork, .handoff, .runInterruptRequest, .runInterruptResult, .secretRequest, .subagent,
    ]

    /// `turnItemIsWorkspacePreparation` (client-runtime/src/state/turnItemPresentation.ts:13-20).
    static func isWorkspacePreparation(_ item: TurnItem) -> Bool {
        (item.type == .commandExecution && item.string("input") == "Preparing workspace")
            || (item.type == .error && item.status == .cancelled
                && item["failure"]?["code"]?.stringValue == "workspace_preparation_failed")
    }

    /// Port of `createQuestionHistoryProjector` (client-runtime/src/state/threadRequests.ts:118-173):
    /// older answers were saved on the runtime request without updating the timeline item, so a
    /// resolved request with answers fills in the item's `questionAnswer`.
    public static func projectingQuestionHistory(_ rows: [ProjectedTurnItem], requests: [RuntimeRequest]) -> [ProjectedTurnItem] {
        let byId = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return rows.map { row in
            let item = row.item
            guard item.type == .userInputRequest, item.questionAnswer == nil, let requestId = item.requestId,
                let request = byId[requestId], request.status == "resolved", let answers = request.answers,
                case .object(var fields) = item.raw
            else { return row }
            var questionText: [String: JSONValue] = [:]
            for question in item["questions"]?.arrayValue ?? [] {
                if let id = question["id"]?.stringValue { questionText[id] = question["question"] ?? .string("") }
            }
            fields["questionAnswer"] = .object([
                "requestId": .string(request.id), "answers": answers,
                "attachmentsByQuestionId": .object([:]), "questionTextById": .object(questionText),
            ])
            guard let answered = try? TurnItem(json: .object(fields)) else { return row }
            var next = row
            next.item = answered
            return next
        }
    }

    /// Port of `deriveTimelineEntriesFromVisibleTurnItems` (session-logic.ts:592-809), without
    /// optimistic and anchored messages (composer state). Order follows `visibleTurnItems`.
    public static func derive(
        visibleTurnItems: [ProjectedTurnItem], attempts: [RunAttempt] = [], nodes: [ExecutionNode] = [],
        plans: [PlanArtifact] = []
    ) -> [TimelineEntry] {
        let attemptByRootNodeId = Dictionary(attempts.map { ($0.rootNodeId, $0) }, uniquingKeysWith: { _, last in last })
        let nodeById = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let planById = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        func timelineAttempt(_ a: RunAttempt) -> TimelineAttempt {
            TimelineAttempt(id: a.id, runId: a.runId, attemptOrdinal: a.attemptOrdinal, rootNodeId: a.rootNodeId, status: a.status)
        }
        // Walk up the execution nodes to the attempt rooted there (session-logic.ts:603-617).
        func resolveAttempt(_ item: TurnItem) -> TimelineAttempt? {
            guard var nodeId = item.nodeId, let runId = item.runId else { return nil }
            var visited = Set<NodeId>()
            while visited.insert(nodeId).inserted {
                if let direct = attemptByRootNodeId[nodeId], direct.runId == runId { return timelineAttempt(direct) }
                guard let node = nodeById[nodeId] else { return nil }
                if let root = attemptByRootNodeId[node.rootNodeId], root.runId == runId { return timelineAttempt(root) }
                guard let parent = node.parentNodeId else { return nil }
                nodeId = parent
            }
            return nil
        }

        let foldedAnswerMessageIds = Set(visibleTurnItems.compactMap { row -> String? in
            guard row.item.type == .userInputRequest, let answer = row.item.questionAnswer,
                let requestId = answer["requestId"]?.stringValue
            else { return nil }
            return "async-answer:\(requestId)"
        })

        var entries: [TimelineEntry] = []
        for row in visibleTurnItems {
            let item = row.item
            if isWorkspacePreparation(item) { continue }
            // Task progress belongs in the composer; checkpoints become diff summaries.
            if item.type == .todoList || item.type == .checkpoint { continue }
            if item.type == .userMessage, let messageId = item.messageId, foldedAnswerMessageIds.contains(messageId.rawValue) { continue }
            let createdAt = item.startedAt ?? item.updatedAt
            let attempt = resolveAttempt(item)
            switch item.type {
            case .notification:
                let entry = WorkLogEntry(
                    id: item.id.rawValue, createdAt: createdAt, runId: item.runId, label: item.string("summary") ?? "",
                    tone: .info, itemType: item.type, structuredPayload: item, projectedItem: row)
                entries.append(TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .work(entry), attempt: attempt))
            case .userMessage, .assistantMessage:
                let isUser = item.type == .userMessage
                let message = ChatMessage(
                    id: item.messageId ?? MessageId(item.id.rawValue), role: isUser ? .user : .assistant, text: item.text,
                    runId: item.runId, streaming: !isUser && item.streaming, createdAt: createdAt, updatedAt: item.updatedAt,
                    inputIntent: isUser ? item.inputIntent : nil,
                    createdBy: isUser ? item.string("createdBy") : nil,
                    creationSource: isUser ? item.string("creationSource") : nil,
                    senderThreadId: isUser ? item.string("senderThreadId") : nil,
                    scheduledTaskId: isUser ? item.string("scheduledTaskId") : nil,
                    context: isUser ? item["context"] : nil,
                    attachments: item["attachments"]?.arrayValue ?? [])
                entries.append(TimelineEntry(id: message.id.rawValue, createdAt: createdAt, kind: .message(message, projectedItem: row), attempt: attempt))
            case .proposedPlan:
                let planId = PlanId(item.string("planId") ?? item.id.rawValue)
                let plan = planById[planId]
                let proposed = ProposedPlan(
                    id: planId, runId: item.runId, planMarkdown: item.string("markdown") ?? "",
                    status: plan?.kind == "proposed_plan" ? plan!.status : "active", createdAt: createdAt, updatedAt: item.updatedAt)
                entries.append(TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .proposedPlan(proposed), attempt: attempt))
            case _ where standaloneEventTypes.contains(item.type):
                entries.append(TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .event(row), attempt: attempt))
            default:
                entries.append(TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .work(WorkLog.entry(for: row)), attempt: attempt))
            }
        }
        return entries
    }
}
