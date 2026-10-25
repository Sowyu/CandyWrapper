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
    /// `"beforeCacheExpires"` or `"onReturn"` on a `/compact` T3 Code sent on its own (3669).
    public var idleCompaction: String?
    /// The thread opens with this workflow script, so it shows as the workflow's opening block.
    public var workflowOpening = false

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
public struct TimelineEntry: Sendable, Hashable, Identifiable {
    /// `indirect`, as `TimelineRow.Kind`: a shared box per payload keeps entry arrays small to copy.
    public indirect enum Kind: Sendable, Hashable {
        case message(ChatMessage, projectedItem: ProjectedTurnItem?)
        case proposedPlan(ProposedPlan)
        case work(WorkLogEntry)
        /// fork, handoff, run interrupt request and result, secret request, subagent.
        case event(ProjectedTurnItem)
        /// A completed `html_render` call: the page shows in the thread (session-logic.ts:717-731).
        case htmlRender(HtmlRenderReference, runId: RunId?)
        /// A completed tool call that carries an MCP App (session-logic.ts:733-749).
        case mcpApp(McpAppEntry, runId: RunId?)
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
    /// A published page or app: it stays visible when its turn or attempt folds.
    public var isWebContent: Bool {
        switch kind {
        case .htmlRender, .mcpApp: true
        default: false
        }
    }

    /// `timelineEntryIsPersistentResourceCard` (session-logic.ts:338-349): fork, created thread
    /// and secret request events never fold.
    public var isPersistentResourceCard: Bool {
        guard let item = eventItem?.item else { return false }
        return item.type == .fork || item.type == .threadCreated || item.type == .secretRequest
    }
}

/// The workflow script a coordinator's thread opens with (client-runtime state/subagentRuntime.ts:294-376).
public enum WorkflowOpening {
    /// `WORKFLOW_SCRIPT_START` (:295): the `meta` export, after any leading comments.
    nonisolated(unsafe) private static let scriptStart = try! NSRegularExpression(
        pattern: #"^\s*(?:(?://[^\n]*|/\*[\s\S]*?\*/)\s*)*export\s+const\s+meta\b"#)

    /// `isWorkflowScriptMessage` (:301-311): servers mark the script; older threads fall back to the text.
    public static func isScript(role: String, text: String, workflowScript: Bool?) -> Bool {
        guard role == "user" else { return false }
        if let workflowScript { return workflowScript }
        return scriptStart.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first user message when it is the workflow script of a provider-native subagent thread
    /// (`workflowOpeningParentThreadId` and `resolveWorkflowOpening`, :331-376).
    public static func messageId(_ projection: ThreadProjection) -> MessageId? {
        guard projection.thread.isProviderNativeSubagent, projection.thread.lineage?.parentThreadId != nil,
              let first = projection.messages.first(where: { $0.role == "user" }),
              isScript(role: first.role, text: first.text, workflowScript: first.workflowScript) else { return nil }
        return first.id
    }

    /// `workflowOpeningParentThreadId` (:367-378): the parent whose subagent rows describe this thread's workflow,
    /// nil unless the thread opens with a workflow script, so ordinary subagent threads never load their parent.
    public static func parentThreadId(_ projection: ThreadProjection) -> ThreadId? {
        messageId(projection) == nil ? nil : projection.thread.lineage?.parentThreadId
    }

    /// The parts of a workflow opening that live on the parent's coordinator row (`WorkflowOpening`, :315-324).
    public struct Plan: Equatable, Sendable {
        public var name: String?
        public var description: String?
        public var driver: String?
        public var providerInstanceId: String?
        /// Nil until the parent's coordinator row is loaded, and for a coordinator without a workflow.
        public var group: SubagentWorkflowGroup?
        public init(name: String? = nil, description: String? = nil, driver: String? = nil, providerInstanceId: String? = nil,
                    group: SubagentWorkflowGroup? = nil) {
            self.name = name; self.description = description; self.driver = driver; self.providerInstanceId = providerInstanceId; self.group = group
        }

        /// `resolveWorkflowOpening` (:331-361): the parent subagent whose child is this thread.
        public init(coordinator: JSONValue?) {
            guard let c = coordinator else { self.init(); return }
            let group = SubagentWorkflowGroup(coordinator: c)
            self.init(name: group?.name, description: c["title"]?.stringValue, driver: c["driver"]?.stringValue,
                      providerInstanceId: c["providerInstanceId"]?.stringValue, group: group)
        }

        /// The coordinator row among the parent projection's subagents.
        public static func coordinator(of threadId: ThreadId, in parentSubagents: [JSONValue]) -> JSONValue? {
            parentSubagents.first { $0["childThreadId"]?.stringValue == threadId.rawValue }
        }

        /// `workflowOpeningHeadline` (:380-420): the workflow, what it does, and "N agents · 2 working · 1 done".
        public var headline: (title: String, description: String?, agents: String?) {
            let title = name ?? description ?? "Workflow"
            let members = (group?.phases.flatMap(\.members) ?? []) + (group?.unphased ?? [])
            var counts: [String: Int] = [:]
            for m in members {
                let key = switch m.status {
                case "completed": "done"
                case "failed": "failed"
                case "cancelled", "interrupted": "stopped"
                default: "working"
                }
                counts[key, default: 0] += 1
            }
            let agents = members.isEmpty ? nil : "\(members.count) \(members.count == 1 ? "agent" : "agents") · "
                + ["working", "done", "failed", "stopped"].compactMap { k in counts[k].map { "\($0) \(k)" } }.joined(separator: " · ")
            return (title, description != nil && description != title ? description : nil, agents)
        }
    }
}

public enum TimelineEntries {
    static let standaloneEventTypes: Set<TurnItemType> = [
        .fork, .handoff, .runInterruptRequest, .runInterruptResult, .secretRequest, .subagent,
    ]

    /// `serverAcknowledgedUserMessageIds` (ChatView.tsx:1751-1766, `deriveCommittedServerUserMessageIds`
    /// in ChatView.logic.ts:1213-1221): user messages the server holds, as a timeline row or in
    /// `messages`. Either one makes the optimistic copy redundant: a bounded snapshot or an older
    /// page can carry the row without its message, and a queued prompt has a message but no row yet.
    public static func acknowledgedUserMessageIds(_ projection: ThreadProjection?) -> Set<MessageId> {
        guard let projection else { return [] }
        var ids = Set<MessageId>()
        for row in projection.visibleTurnItems where row.item.type == .userMessage {
            if let id = row.item.messageId { ids.insert(id) }
        }
        for message in projection.messages where message.role == "user" { ids.insert(message.id) }
        return ids
    }

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
        // Nothing to fill in: hand back the same array, so later comparisons stay cheap.
        guard requests.contains(where: { $0.status == "resolved" && $0.answers != nil }) else { return rows }
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

    /// Walks up the execution nodes to the attempt rooted there (session-logic.ts:603-617).
    struct AttemptLookup: Sendable {
        var byRootNodeId: [NodeId: RunAttempt]
        var nodeById: [NodeId: ExecutionNode]

        init(attempts: [RunAttempt], nodes: [ExecutionNode]) {
            byRootNodeId = Dictionary(attempts.map { ($0.rootNodeId, $0) }, uniquingKeysWith: { _, last in last })
            nodeById = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }

        func attempt(_ item: TurnItem) -> TimelineAttempt? {
            guard var nodeId = item.nodeId, let runId = item.runId else { return nil }
            var visited = Set<NodeId>()
            while visited.insert(nodeId).inserted {
                if let direct = byRootNodeId[nodeId], direct.runId == runId { return Self.timelineAttempt(direct) }
                guard let node = nodeById[nodeId] else { return nil }
                if let root = byRootNodeId[node.rootNodeId], root.runId == runId { return Self.timelineAttempt(root) }
                guard let parent = node.parentNodeId else { return nil }
                nodeId = parent
            }
            return nil
        }

        static func timelineAttempt(_ a: RunAttempt) -> TimelineAttempt {
            TimelineAttempt(id: a.id, runId: a.runId, attemptOrdinal: a.attemptOrdinal, rootNodeId: a.rootNodeId, status: a.status)
        }
    }

    /// Answers folded into their question card hide the user message that carried them.
    static func foldedAnswerMessageIds(_ rows: [ProjectedTurnItem]) -> Set<String> {
        Set(rows.compactMap { row -> String? in
            guard row.item.type == .userInputRequest, let answer = row.item.questionAnswer,
                let requestId = answer["requestId"]?.stringValue
            else { return nil }
            return "async-answer:\(requestId)"
        })
    }

    /// The entry of one row, or nil for a row the timeline leaves out.
    static func entry(_ row: ProjectedTurnItem, attempt: TimelineAttempt?, planById: [PlanId: PlanArtifact], folded: Set<String>) -> TimelineEntry? {
        // `position` is the row's index in `visibleTurnItems`, which every older history page
        // renumbers (threadHistoryMerge.ts:59). Nothing in the timeline reads it, so entries carry 0
        // and a page leaves the entries and rows after it equal.
        var row = row
        row.position = 0
        let item = row.item
        if isWorkspacePreparation(item) { return nil }
        // Task progress belongs in the composer; checkpoints become diff summaries.
        if item.type == .todoList || item.type == .checkpoint { return nil }
        if item.type == .userMessage, let messageId = item.messageId, folded.contains(messageId.rawValue) { return nil }
        let createdAt = item.startedAt ?? item.updatedAt
        switch item.type {
        case .notification:
            let entry = WorkLogEntry(
                id: item.id.rawValue, createdAt: createdAt, runId: item.runId, label: item.string("summary") ?? "",
                tone: .info, itemType: item.type, structuredPayload: item, projectedItem: row)
            return TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .work(entry), attempt: attempt)
        case .userMessage, .assistantMessage:
            let isUser = item.type == .userMessage
            var message = ChatMessage(
                id: item.messageId ?? MessageId(item.id.rawValue), role: isUser ? .user : .assistant, text: item.text,
                runId: item.runId, streaming: !isUser && item.streaming, createdAt: createdAt, updatedAt: item.updatedAt,
                inputIntent: isUser ? item.inputIntent : nil,
                createdBy: isUser ? item.string("createdBy") : nil,
                creationSource: isUser ? item.string("creationSource") : nil,
                senderThreadId: isUser ? item.string("senderThreadId") : nil,
                scheduledTaskId: isUser ? item.string("scheduledTaskId") : nil,
                context: isUser ? item["context"] : nil,
                attachments: item["attachments"]?.arrayValue ?? [])
            if isUser { message.idleCompaction = item.string("idleCompaction") }
            return TimelineEntry(id: message.id.rawValue, createdAt: createdAt, kind: .message(message, projectedItem: row), attempt: attempt)
        case .proposedPlan:
            let planId = PlanId(item.string("planId") ?? item.id.rawValue)
            let plan = planById[planId]
            let proposed = ProposedPlan(
                id: planId, runId: item.runId, planMarkdown: item.string("markdown") ?? "",
                status: plan?.kind == "proposed_plan" ? plan!.status : "active", createdAt: createdAt, updatedAt: item.updatedAt)
            return TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .proposedPlan(proposed), attempt: attempt)
        case .dynamicTool where ThreadWebContent.htmlRender(item) != nil:
            return TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .htmlRender(ThreadWebContent.htmlRender(item)!, runId: item.runId), attempt: attempt)
        case .dynamicTool where ThreadWebContent.mcpApp(item) != nil:
            let app = McpAppEntry(app: ThreadWebContent.mcpApp(item)!, sourceThreadId: row.sourceThreadId, itemId: row.sourceItemId,
                                  revision: TurnItemDetail.revision(item))
            return TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .mcpApp(app, runId: item.runId), attempt: attempt)
        case _ where standaloneEventTypes.contains(item.type):
            return TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .event(row), attempt: attempt)
        default:
            return TimelineEntry(id: item.id.rawValue, createdAt: createdAt, kind: .work(WorkLog.entry(for: row)), attempt: attempt)
        }
    }

    /// Port of `deriveTimelineEntriesFromVisibleTurnItems` (session-logic.ts:592-809), without
    /// optimistic and anchored messages (composer state). Order follows `visibleTurnItems`.
    public static func derive(
        visibleTurnItems: [ProjectedTurnItem], attempts: [RunAttempt] = [], nodes: [ExecutionNode] = [],
        plans: [PlanArtifact] = []
    ) -> [TimelineEntry] {
        var memo = Memo()
        return derive(visibleTurnItems: visibleTurnItems, attempts: attempts, nodes: nodes, plans: plans, memo: &memo).entries
    }

    /// `derive` remembered per row, so an update rebuilds only the rows that changed. T3 reuses
    /// entries across streaming updates the same way (`deriveTimelineEntriesFromVisibleTurnItemsWithState`,
    /// session-logic.ts:930-1030); this also covers tool and status updates, which T3 rebuilds whole.
    public struct Memo: Sendable {
        var rows: [ProjectedTurnItem] = []
        var attempts: [TimelineAttempt?] = []
        /// Per row, its index in `entries`, or -1 for a row left out.
        var entryIndex: [Int] = []
        var entries: [TimelineEntry] = []
        var folded: Set<String> = []
        var attemptsSource: [RunAttempt] = []
        var nodesSource: [ExecutionNode] = []
        var plansSource: [PlanArtifact] = []
        var lookup: AttemptLookup?
        /// After the last derive: the entries are the previous ones with this many new entries in
        /// front (an older history page), every previous entry reused as it was. Nil otherwise.
        public internal(set) var prepended: Int?

        public init() {}
    }

    /// Rows equal but for `position`, which a history page renumbers.
    static func samePayload(_ a: ProjectedTurnItem, _ b: ProjectedTurnItem) -> Bool {
        a.sourceItemId == b.sourceItemId && a.sourceThreadId == b.sourceThreadId && a.visibility == b.visibility && a.item == b.item
    }

    /// `derive` against the previous result in `memo`. Returns the entries and, when entries only
    /// changed in place (same count, same ids), the indices that changed; nil means the list
    /// changed shape.
    public static func derive(
        visibleTurnItems rows: [ProjectedTurnItem], attempts: [RunAttempt], nodes: [ExecutionNode], plans: [PlanArtifact],
        memo: inout Memo
    ) -> (entries: [TimelineEntry], changed: [Int]?) {
        let folded = foldedAnswerMessageIds(rows)
        let old = memo
        memo = Memo()
        // Plans and folded answers reach across rows; a change there rebuilds every row.
        let fresh = old.lookup == nil || folded != old.folded || plans != old.plansSource
        let lookupChanged = fresh || attempts != old.attemptsSource || nodes != old.nodesSource
        let lookup = lookupChanged ? AttemptLookup(attempts: attempts, nodes: nodes) : old.lookup!
        let planById = plans.isEmpty ? [:] : Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var next = Memo()
        next.rows = rows
        next.folded = folded
        next.attemptsSource = attempts
        next.nodesSource = nodes
        next.plansSource = plans
        next.lookup = lookup
        next.attempts.reserveCapacity(rows.count)
        next.entryIndex.reserveCapacity(rows.count)
        next.entries.reserveCapacity(old.entries.count + 1)
        // Rows line up by index while the window only grows at its end; a shifted row (a history
        // page, an insert) is found by its id.
        var oldIndexById: [TurnItemId: Int]?
        var sameShape = !fresh && rows.count == old.rows.count
        var changed: [Int] = []
        // An older page: the old rows follow the new ones in order, so they line up by offset.
        let front = !fresh && rows.count > old.rows.count
            && zip(rows[(rows.count - old.rows.count)...], old.rows).allSatisfy({ $0.sourceItemId == $1.sourceItemId })
            ? rows.count - old.rows.count : 0
        var frontEntries: Int?
        var reusedAll = front > 0
        for (i, row) in rows.enumerated() {
            var previous: Int?
            if i == front, front > 0 { frontEntries = next.entries.count }
            if front > 0 {
                previous = i < front ? nil : i - front
            } else if !fresh {
                if i < old.rows.count, old.rows[i].sourceItemId == row.sourceItemId {
                    previous = i
                } else {
                    sameShape = false
                    if oldIndexById == nil {
                        oldIndexById = Dictionary(old.rows.enumerated().map { ($1.sourceItemId, $0) }, uniquingKeysWith: { a, _ in a })
                    }
                    previous = oldIndexById![row.sourceItemId]
                }
            }
            let unchangedRow = previous.map { samePayload(old.rows[$0], row) } ?? false
            let attempt = unchangedRow && !lookupChanged ? old.attempts[previous!] : lookup.attempt(row.item)
            next.attempts.append(attempt)
            let entry: TimelineEntry?
            if let p = previous, unchangedRow, attempt == old.attempts[p] {
                let index = old.entryIndex[p]
                entry = index < 0 ? nil : old.entries[index]
            } else {
                if i >= front { reusedAll = false }
                entry = Self.entry(row, attempt: attempt, planById: planById, folded: folded)
                if sameShape, let p = previous {
                    let index = old.entryIndex[p]
                    if (index < 0) != (entry == nil) { sameShape = false } else if index >= 0 { changed.append(index) }
                }
            }
            if let entry {
                next.entryIndex.append(next.entries.count)
                next.entries.append(entry)
            } else {
                next.entryIndex.append(-1)
            }
        }
        next.prepended = reusedAll ? frontEntries : nil
        memo = next
        return (next.entries, sameShape ? changed : nil)
    }
}
