import Foundation
import T3Protocol

/// `TimelineLatestRun` (MessagesTimeline.logic.ts:507-510).
public struct TimelineLatestRun: Sendable, Hashable {
    public var runId: RunId
    public var status: ThreadStatus
    public var requestedAt: T3Timestamp?
    public var startedAt: T3Timestamp?
    public var completedAt: T3Timestamp?
    /// The run is still open but its provider turn already ended, so nothing generates while the server settles it
    /// (models.ts:44-48, T3 07d38b8d17).
    public var turnEnded: Bool

    public init(runId: RunId, status: ThreadStatus, requestedAt: T3Timestamp? = nil, startedAt: T3Timestamp? = nil,
                completedAt: T3Timestamp? = nil, turnEnded: Bool = false) {
        self.runId = runId
        self.status = status
        self.requestedAt = requestedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.turnEnded = turnEnded
    }
}

/// One timeline row (`MessagesTimelineRow`, MessagesTimeline.logic.ts:514-648). Ids are stable
/// across derivations, so the view can diff by `id`.
///
/// Skipped: `html-render`, `mcp-app` (web content, later milestone) and `worktree-setup`
/// (composer state). `durationStart` and `revertTurnCount` are left out: the renderer never reads
/// the first, and rollback is out of scope for a read-only view.
public struct TimelineRow: Sendable, Hashable, Identifiable {
    /// `indirect` keeps each payload in its own shared box: the largest case (`workLive`, two work entries)
    /// made every row 2 KB inline, and a 2,000-message thread copies its row arrays on every history page.
    public indirect enum Kind: Sendable, Hashable {
        /// One user or assistant message. The assistant flags decide the footer and copy button.
        case message(
            ChatMessage, projectedItem: ProjectedTurnItem?, showAssistantMeta: Bool, showAssistantCopyButton: Bool,
            assistantCopyStreaming: Bool, turnDiffSummary: TurnDiffSummary?)
        /// The footer under an answer that trailing tool rows pushed down.
        case assistantMeta(ChatMessage, projectedItem: ProjectedTurnItem?, showAssistantCopyButton: Bool, assistantCopyStreaming: Bool)
        /// A lone tool call (`displayLabel` set) or the expanded body of a group (`isExpandedToolGroup`).
        case work(groupedEntries: [WorkLogEntry], isExpandedToolGroup: Bool, displayLabel: String?)
        /// The live activity line of a running turn.
        case workLive(entry: WorkLogEntry, groupedEntries: [WorkLogEntry], groupId: String, expanded: Bool, active: Bool, thought: WorkLogEntry?)
        /// "Working for 12s" header; `createdAt` is the turn start. `compacting` replaces it: "Compacting…"
        /// while a `/compact` waits for its compaction row, or why a compaction T3 Code started holds the
        /// user's message back (TimelineWorkGroupRows.tsx:286-300, MessagesTimeline.logic.ts:1611-1631).
        case working(compacting: String?)
        /// Placeholder while running with no visible activity. `compacting` blanks it (:3793-3795).
        case thinking(groupId: String?, expanded: Bool?, compacting: Bool)
        /// Header of a settled group of tool calls.
        case workToggle(WorkToggle)
        /// "Worked for 22s" header of a settled turn.
        case turnFold(runId: RunId, label: String, expanded: Bool)
        case attemptFold(runId: RunId, attemptId: RunAttemptId, label: String, expanded: Bool)
        /// `failed` draws red with `failure`, the item's summary, after the label (MessagesTimeline.tsx:1327-1377).
        case contextCompaction(label: String, active: Bool, failed: Bool = false, failure: String? = nil)
        /// fork, handoff, interrupt result, secret request, subagent (grouped), created-thread summary.
        case event(ProjectedTurnItem, subagents: [ProjectedTurnItem]?, resourceSummary: Bool)
        case proposedPlan(ProposedPlan)
        /// An agent's HTML page (`html-render`).
        case htmlRender(HtmlRenderReference)
        /// An MCP App (`mcp-app`).
        case mcpApp(McpAppEntry)
    }

    public struct WorkToggle: Sendable, Hashable {
        public var runId: RunId?
        public var groupId: String
        public var hiddenCount: Int
        public var expanded: Bool
        public var summary: String
        public var summaryKind: ToolGroupSummaryKind
        public var toolSurface: String?
        public var toolIcon: JSONValue?
        /// `browser`, `device`, `t3-code` or `pull-request` for a lone T3 tool.
        public var summaryToolIcon: String?
        public var hasFailure: Bool
    }

    public var id: String
    /// Nil only for `working` and `thinking` rows without a known turn start.
    public var createdAt: T3Timestamp?
    public var kind: Kind
    /// The next row is also a work log row, so no gap between them.
    public var continuesWorkLog = false

    public init(id: String, createdAt: T3Timestamp?, kind: Kind) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
    }

    public var message: ChatMessage? {
        switch kind {
        case .message(let m, _, _, _, _, _), .assistantMeta(let m, _, _, _): m
        default: nil
        }
    }

    var isWorkLog: Bool {
        switch kind {
        case .work, .workToggle, .workLive, .thinking: true
        default: false
        }
    }
}

/// Inputs of `deriveMessagesTimelineRows` (MessagesTimeline.logic.ts:1326-1346). The expansion
/// sets are UI state and default to empty, so everything starts collapsed.
public struct TimelineRowsInput: Sendable {
    public var entries: [TimelineEntry]
    public var latestRun: TimelineLatestRun?
    public var runningRunId: RunId?
    public var expandedRunIds: Set<RunId> = []
    public var expandedAttemptIds: Set<RunAttemptId> = []
    public var expandedWorkGroupIds: Set<String> = []
    public var isWorking = false
    /// Runless work is live (a provider-native subagent thread).
    public var runlessWorkActive = false
    public var activeTurnStartedAt: T3Timestamp?
    public var turnDiffSummaries: [TurnDiffSummary] = []
    /// A `/compact` runs and its compaction has not completed (`isCompacting`, ChatView.tsx:3597-3619).
    public var isCompacting = false

    public init(
        entries: [TimelineEntry], latestRun: TimelineLatestRun? = nil, runningRunId: RunId? = nil,
        expandedRunIds: Set<RunId> = [], expandedAttemptIds: Set<RunAttemptId> = [],
        expandedWorkGroupIds: Set<String> = [], isWorking: Bool = false, runlessWorkActive: Bool = false,
        activeTurnStartedAt: T3Timestamp? = nil, turnDiffSummaries: [TurnDiffSummary] = []
    ) {
        self.entries = entries
        self.latestRun = latestRun
        self.runningRunId = runningRunId
        self.expandedRunIds = expandedRunIds
        self.expandedAttemptIds = expandedAttemptIds
        self.expandedWorkGroupIds = expandedWorkGroupIds
        self.isWorking = isWorking
        self.runlessWorkActive = runlessWorkActive
        self.activeTurnStartedAt = activeTurnStartedAt
        self.turnDiffSummaries = turnDiffSummaries
    }

    /// Everything a thread view needs, derived from the projection like `ChatView` does
    /// (G-timeline-data.md 1.4).
    ///
    /// // ponytail: no usage-limit stand-in run, background-work hold or local dispatch timing
    /// (RT/threadExecution.ts); add them with the composer.
    public init(projection: ThreadProjection) {
        var memo = Memo()
        self = Self.derive(projection: projection, memo: &memo).input
    }

    /// What `derive(projection:memo:)` keeps between updates of one thread.
    public struct Memo: Sendable {
        var entries = TimelineEntries.Memo()
        var checkpoints: [Checkpoint] = []
        var messages: [ConversationMessage] = []
        var summaries: [TurnDiffSummary] = []

        public init() {}

        /// After the last derive: how many entries an older history page put in front of the
        /// previous ones, which all stayed as they were. Nil for any other change.
        public var prepended: Int? { entries.prepended }
    }

    /// `init(projection:)` against the previous update: only changed rows are rebuilt. `changed`
    /// lists the entries replaced in place; nil when the entry list changed shape.
    public static func derive(projection: ThreadProjection, memo: inout Memo) -> (input: TimelineRowsInput, changed: [Int]?) {
        let rows = TimelineEntries.projectingQuestionHistory(projection.visibleTurnItems, requests: projection.runtimeRequests)
        var (entries, changed) = TimelineEntries.derive(
            visibleTurnItems: rows, attempts: projection.attempts, nodes: projection.nodes, plans: projection.plans, memo: &memo.entries)
        if let opening = WorkflowOpening.messageId(projection),
           let i = entries.firstIndex(where: { $0.message?.id == opening && $0.message?.role == .user }),
           case .message(var m, let projected) = entries[i].kind {
            m.workflowOpening = true
            entries[i].kind = .message(m, projectedItem: projected)
        }
        let state = TimelineRunState(projection: projection)
        // Equal summaries keep the old array, so the row pass sees the same value cheaply.
        if projection.checkpoints != memo.checkpoints || projection.messages != memo.messages {
            let summaries = TurnDiffs.summaries(projection)
            if summaries != memo.summaries { memo.summaries = summaries }
            memo.checkpoints = projection.checkpoints
            memo.messages = projection.messages
        }
        var input = TimelineRowsInput(
            entries: entries, latestRun: state.latestRun, runningRunId: state.runningRunId, isWorking: state.isWorking,
            runlessWorkActive: state.runlessWorkStartedAt != nil,
            activeTurnStartedAt: state.activeTurnStartedAt, turnDiffSummaries: memo.summaries)
        input.isCompacting = state.isWorking && TimelineRunState.compactRequestActive(projection, latestRun: state.latestRun)
        return (input, changed)
    }

    /// Everything but the entries matches `other`: the row pass would fold and group the same way.
    func sameContext(_ other: TimelineRowsInput) -> Bool {
        latestRun == other.latestRun && runningRunId == other.runningRunId && isWorking == other.isWorking
            && isCompacting == other.isCompacting
            && runlessWorkActive == other.runlessWorkActive && activeTurnStartedAt == other.activeTurnStartedAt
            && expandedRunIds == other.expandedRunIds && expandedAttemptIds == other.expandedAttemptIds
            && expandedWorkGroupIds == other.expandedWorkGroupIds && turnDiffSummaries == other.turnDiffSummaries
    }
}

/// Run state the row pass reads (RT/threadExecution.ts:35-290, session-logic.ts:1069-1079).
public struct TimelineRunState: Sendable, Hashable {
    /// `deriveThreadActivityRun`: the newest run doing work, else the newest unheld run.
    public var latestRun: TimelineLatestRun?
    /// `deriveThreadRuntime.activeRunId`: the newest preparing, starting or running run.
    public var runningRunId: RunId?
    /// Phase `connecting` or `running`.
    public var isWorking: Bool
    public var runlessWorkStartedAt: T3Timestamp?
    public var activeTurnStartedAt: T3Timestamp?

    public init(projection: ThreadProjection) {
        func newest(_ statuses: Set<ThreadStatus>) -> Run? {
            projection.runs.filter { statuses.contains($0.status) }.max { $0.ordinal < $1.ordinal }
        }
        let unheld = projection.runs.filter { !($0.status == .queued && $0.queueHeld == true) }.max { $0.ordinal < $1.ordinal }
        let activity = newest([.preparing, .starting, .running, .waiting]) ?? unheld
        latestRun = activity.map {
            TimelineLatestRun(runId: $0.id, status: $0.status, requestedAt: $0.requestedAt, startedAt: $0.startedAt, completedAt: $0.completedAt,
                              turnEnded: Self.turnEnded($0, projection.providerTurns))
        }
        runningRunId = newest([.preparing, .starting, .running])?.id
        isWorking = activity.map { [.preparing, .starting, .queued, .running, .waiting].contains($0.status) } ?? false
        // A provider-native subagent thread has a runless root turn whose status follows the child.
        if projection.thread.isProviderNativeSubagent,
            let root = projection.nodes.last(where: { $0.kind == "root_turn" && $0.runId == nil }),
            ["pending", "running", "waiting"].contains(root.status)
        {
            runlessWorkStartedAt = root.startedAt
        }
        if let run = activity, isWorking {
            activeTurnStartedAt = run.startedAt ?? run.requestedAt
        } else {
            activeTurnStartedAt = runlessWorkStartedAt
        }
        isWorking = isWorking || runlessWorkStartedAt != nil
    }

    /// `turnEnded` in `summarizeThreadRun` (threadExecution.ts:52-71): an active run whose attempt's latest provider
    /// turn is neither pending nor running.
    static func turnEnded(_ run: Run, _ providerTurns: [JSONValue]) -> Bool {
        guard [.preparing, .starting, .running, .waiting].contains(run.status), let attempt = run.activeAttemptId?.rawValue else { return false }
        func ordinal(_ turn: JSONValue) -> Double { if case .number(let n)? = turn["ordinal"] { return n }; return 0 }
        let latest = providerTurns.filter { $0["runAttemptId"]?.stringValue == attempt }.max { ordinal($0) < ordinal($1) }
        guard let status = latest?["status"]?.stringValue else { return false }
        return status != "pending" && status != "running"
    }

    /// The server half of `isCompacting` (ChatView.tsx:3598-3615): the latest user message is a bare
    /// `/compact` in the unsettled activity run, and no completed compaction of that run has arrived.
    public static func compactRequestActive(_ projection: ThreadProjection, latestRun: TimelineLatestRun?) -> Bool {
        guard let run = latestRun, [.preparing, .queued, .starting, .running, .waiting].contains(run.status) else { return false }
        let items = projection.visibleTurnItems
        guard let index = items.lastIndex(where: { $0.item.type == .userMessage }) else { return false }
        let user = items[index].item
        guard user.runId == run.runId, (user["attachments"]?.arrayValue?.isEmpty ?? true),
              user.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/compact" else { return false }
        return !items[index...].contains { $0.item.type == .compaction && $0.item.runId == run.runId && $0.item.status == .completed }
    }
}

/// Port of the row pass in apps/web/src/components/chat/MessagesTimeline.logic.ts.
public enum TimelineRows {
    static let liveActivityRowId = "live-activity-row"
    static let workingRowId = "working-indicator-row"

    static func workGroupId(_ entryId: String) -> String { "work-group:\(entryId)" }

    // MARK: Run helpers (L:74-84, 712-958)

    /// `timelineEntryRunId`.
    static func runId(_ entry: TimelineEntry) -> RunId? {
        switch entry.kind {
        case .message(let m, _): m.role == .assistant ? m.runId : nil
        case .proposedPlan(let p): p.runId
        case .work(let w): w.runId
        case .event: nil
        case .htmlRender(_, let run), .mcpApp(_, let run): run
        }
    }

    /// `deriveTerminalAssistantMessageIds`: the last assistant message per run (or per prompt for
    /// runless replies) gets the footer and never folds.
    static func terminalAssistantMessageIds(_ entries: [TimelineEntry]) -> Set<MessageId> {
        var lastByKey: [String: MessageId] = [:]
        var unkeyedIndex = 0
        for entry in entries {
            guard let message = entry.message else { continue }
            if message.role == .user { unkeyedIndex += 1; continue }
            guard message.role == .assistant else { continue }
            lastByKey[message.runId.map { "turn:\($0.rawValue)" } ?? "unkeyed:\(unkeyedIndex)"] = message.id
        }
        return Set(lastByKey.values)
    }

    /// `deriveUnsettledRunId`: the running run, or the latest run until it records completion.
    static func unsettledRunId(_ latestRun: TimelineLatestRun?, runningRunId: RunId?) -> RunId? {
        if let runningRunId { return runningRunId }
        guard let latestRun else { return nil }
        let settled = latestRun.completedAt != nil && ![.running, .starting, .waiting].contains(latestRun.status)
        return settled ? nil : latestRun.runId
    }

    /// `liveSubagentCardEntryIds` (L:832-860): adjacent subagent cards of one run and provider
    /// turn stay visible while any member's child still works.
    static func liveSubagentCardEntryIds(_ entries: [TimelineEntry]) -> Set<String> {
        var visible = Set<String>()
        var batch: [TimelineEntry] = []
        func flush() {
            if batch.contains(where: { isWorkActive($0.eventItem!.item.status) }) { visible.formUnion(batch.map(\.id)) }
            batch = []
        }
        for entry in entries {
            guard let item = entry.eventItem?.item, item.type == .subagent else { flush(); continue }
            if let previous = batch.last?.eventItem?.item, previous.runId != item.runId || previous.providerTurnId != item.providerTurnId {
                flush()
            }
            batch.append(entry)
        }
        flush()
        return visible
    }

    /// `isOrchestrationV2WorkActive` (orchestrationV2.ts:705-709).
    static func isWorkActive(_ status: TurnItemStatus) -> Bool { status == .pending || status == .running || status == .waiting }

    /// `timelineEntryFoldRunId` (L:862-878): the run whose fold an entry joins.
    static func foldRunId(_ entry: TimelineEntry, runlessKey: RunId?) -> RunId? {
        switch entry.kind {
        case .work(let w): return w.itemType == .systemNotice ? nil : (w.runId ?? runlessKey)
        case .message(let m, _): return m.role == .assistant ? (m.runId ?? runlessKey) : nil
        case .event(let row):
            return entry.isPersistentResourceCard || row.item.type == .subagent ? (row.item.runId ?? runlessKey) : nil
        case .proposedPlan, .htmlRender, .mcpApp: return nil
        }
    }

    /// `timelineEntryStartsResponse`: a real prompt or an automatic wake. A steer continues its turn.
    static func startsResponse(_ entry: TimelineEntry) -> Bool {
        if let m = entry.message {
            return m.role == .user && m.inputIntent != .steer && m.inputIntent != .promotedQueuedToSteer
        }
        return entry.work?.itemType == .notification
    }

    static func lastResponseBoundaryIndex(_ entries: [TimelineEntry]) -> Int {
        entries.lastIndex(where: startsResponse) ?? -1
    }

    /// `deriveActiveVisualResponseRunIds` (L:900-927).
    static func activeVisualResponseRunIds(_ entries: [TimelineEntry], unsettledRunId: RunId?, isWorking: Bool) -> Set<RunId> {
        guard let unsettledRunId else { return [] }
        var ids: Set<RunId> = [unsettledRunId]
        guard isWorking else { return ids }
        for entry in entries.dropFirst(lastResponseBoundaryIndex(entries) + 1) {
            if let id = runId(entry) { ids.insert(id) }
        }
        return ids
    }

    /// `timelineEntryFailedItem`: a top-level failed `error` item.
    static func failedItem(_ entry: TimelineEntry) -> TurnItem? {
        let item: TurnItem? = switch entry.kind {
        case .event(let row): row.item
        case .work(let w): w.projectedItem?.item
        default: nil
        }
        guard let item, item.type == .error, item.status == .failed, item.parentItemId == nil else { return nil }
        return item
    }

    /// `failedTimelineRunIds` (L:941-956).
    static func failedRunIds(_ entries: [TimelineEntry], latestRun: TimelineLatestRun?) -> Set<RunId> {
        var failed = Set<RunId>()
        if let latestRun, latestRun.status == .failed { failed.insert(latestRun.runId) }
        for entry in entries { if let id = failedItem(entry)?.runId { failed.insert(id) } }
        return failed
    }

    // MARK: Folds (L:739-806, 961-1138)

    struct TurnFold {
        var runId: RunId
        var anchorEntryId: String
        var createdAt: T3Timestamp
        var hiddenEntryIds: Set<String>
        /// Every entry in the segment, including the cards a fold never hides.
        var entryIds: Set<String>
        var label: String
    }

    struct AttemptFold {
        var runId: RunId
        var attemptId: RunAttemptId
        var createdAt: T3Timestamp
        var hiddenEntryIds: Set<String>
    }

    /// `deriveSupersededAttemptFolds`: hides provider output of a superseded attempt. User
    /// messages, resource cards, live subagents and notices stay; failed runs are exempt.
    static func supersededAttemptFolds(_ entries: [TimelineEntry], unfoldedRunIds: Set<RunId>, liveSubagentEntryIds: Set<String>) -> [String: AttemptFold] {
        var order: [RunAttemptId] = []
        var byAttempt: [RunAttemptId: [TimelineEntry]] = [:]
        for entry in entries {
            guard let attempt = entry.attempt, attempt.status == "superseded", !unfoldedRunIds.contains(attempt.runId),
                entry.message?.role != .user, !entry.isPersistentResourceCard, !entry.isWebContent, !liveSubagentEntryIds.contains(entry.id),
                entry.work?.itemType != .systemNotice
            else { continue }
            if byAttempt[attempt.id] == nil { order.append(attempt.id) }
            byAttempt[attempt.id, default: []].append(entry)
        }
        var folds: [String: AttemptFold] = [:]
        for id in order {
            guard let group = byAttempt[id], let first = group.first, let attempt = first.attempt else { continue }
            folds[first.id] = AttemptFold(runId: attempt.runId, attemptId: attempt.id, createdAt: first.createdAt, hiddenEntryIds: Set(group.map(\.id)))
        }
        return folds
    }

    /// `computeElapsedMs` (L:482-488).
    static func elapsedMs(_ start: T3Timestamp?, _ end: T3Timestamp?) -> Double? {
        guard let s = start?.epochMs, let e = end?.epochMs else { return nil }
        return Double(max(0, e - s))
    }

    /// `maxIsoTimestamp` (L:489-497).
    static func maxTimestamp(_ a: T3Timestamp?, _ b: T3Timestamp?) -> T3Timestamp? {
        guard let a else { return b }
        guard let b else { return a }
        guard let am = a.epochMs else { return b }
        guard let bm = b.epochMs else { return a }
        return bm > am ? b : a
    }

    /// `deriveTurnFolds` (L:961-1138): a settled turn hides its activity before the terminal
    /// answer behind "Worked for ...". Failures, work in progress and resource cards stay.
    static func turnFolds(
        _ entries: [TimelineEntry], terminalIds: Set<MessageId>, latestRun: TimelineLatestRun?, unfoldedRunIds: Set<RunId>,
        runlessWorkActive: Bool, liveSubagentEntryIds: Set<String>
    ) -> [String: TurnFold] {
        var interruptedRunIds = Set<RunId>()
        // Where each run's prompt sits (T3 3105 9a01524f3, MessagesTimeline.logic.ts:1034-1040).
        var promptIndexByRunId: [RunId: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if startsResponse(entry), let runId = entry.message?.runId ?? entry.work?.runId, promptIndexByRunId[runId] == nil {
                promptIndexByRunId[runId] = index
            }
            if let item = entry.eventItem?.item, let runId = item.runId,
                item.type == .runInterruptRequest || item.type == .runInterruptResult
            {
                interruptedRunIds.insert(runId)
            }
        }
        struct Group {
            var entries: [TimelineEntry] = []
            var terminal: TimelineEntry?
            var hasStreamingMessage = false
            var startBoundary: T3Timestamp?
            var anchorEntryId: String
            /// Each steer after the turn has produced output starts a new segment at this index into `entries`,
            /// so the steer sits between the work it split (a8bb769d65, L:1038-1042).
            var steerSegments: [(startIndex: Int, steer: TimelineEntry)] = []
        }
        var order: [RunId] = []
        var groups: [RunId: Group] = [:]
        var runlessFailedKeys = Set<RunId>()
        var runlessKey: RunId?
        var responseKey: RunId?
        var pendingBoundary: (createdAt: T3Timestamp, anchorEntryId: String)?
        for (index, entry) in entries.enumerated() {
            if startsResponse(entry) {
                pendingBoundary = index + 1 < entries.count ? (entry.createdAt, entries[index + 1].id) : nil
                let boundaryRunId = entry.message?.runId ?? entry.work?.runId
                runlessKey = boundaryRunId == nil ? RunId("runless:\(entry.id)") : nil
                responseKey = boundaryRunId ?? runlessKey
                continue
            }
            if let m = entry.message, m.role == .user, m.inputIntent == .steer || m.inputIntent == .promotedQueuedToSteer {
                // L:1064-1075. Back-to-back steers split once, after the last of them.
                if let steerRunId = m.runId ?? responseKey, let count = groups[steerRunId]?.entries.count, count > 0 {
                    if groups[steerRunId]!.steerSegments.last?.startIndex == count { groups[steerRunId]!.steerSegments.removeLast() }
                    groups[steerRunId]!.steerSegments.append((count, entry))
                }
                continue
            }
            guard let ownRunId = foldRunId(entry, runlessKey: runlessKey) else { continue }
            // Resuming a subagent moves its item to the resuming run, but the item keeps its place in the turn that
            // started it. It folds with that turn, so the later run's fold still opens under its own prompt.
            let runId = responseKey.map { (promptIndexByRunId[ownRunId] ?? -1) > index ? $0 : ownRunId } ?? ownRunId
            if runId == runlessKey, failedItem(entry) != nil { runlessFailedKeys.insert(runId) }
            if groups[runId] == nil {
                order.append(runId)
                // Each prompt starts at most one turn; a second turn after it uses its own first entry.
                groups[runId] = Group(startBoundary: pendingBoundary?.createdAt, anchorEntryId: pendingBoundary?.anchorEntryId ?? entry.id)
                pendingBoundary = nil
            }
            groups[runId]!.entries.append(entry)
            if let message = entry.message {
                if terminalIds.contains(message.id) { groups[runId]!.terminal = entry }
                if message.streaming { groups[runId]!.hasStreamingMessage = true }
            }
        }

        var folds: [String: TurnFold] = [:]
        for runId in order {
            guard let group = groups[runId] else { continue }
            if unfoldedRunIds.contains(runId) || interruptedRunIds.contains(runId) || runlessFailedKeys.contains(runId)
                || (runlessWorkActive && runId == runlessKey) || group.hasStreamingMessage
            {
                continue
            }
            var hidden = Set<String>()
            let terminalIndex = group.terminal.flatMap { t in group.entries.firstIndex { $0.id == t.id } } ?? group.entries.count
            for (index, entry) in group.entries.enumerated() {
                if entry.id == group.terminal?.id { continue }
                let isCompaction = entry.work?.sourceActivityKind == "context-compaction"
                let isFoldableTrailing = entry.work.map { $0.toolLifecycleStatus != .inProgress && !WorkLog.displayIndicatesFailure($0) } ?? false
                if !isCompaction, index > terminalIndex, !isFoldableTrailing { continue }
                // Linked resources and still-working children outlive their run.
                if entry.isPersistentResourceCard || liveSubagentEntryIds.contains(entry.id) { continue }
                if entry.work?.itemType == .notification { continue }
                // User input stays visible after the surrounding work settles (80df91b52b, MessagesTimeline.logic.ts:1151-1152).
                if entry.work?.questionAnswer != nil { continue }
                hidden.insert(entry.id)
            }
            // A lone compaction stays visible; it folds only with other work.
            func hidesNonCompaction(_ entries: ArraySlice<TimelineEntry>) -> Bool {
                entries.contains { hidden.contains($0.id) && $0.work?.sourceActivityKind != "context-compaction" }
            }
            guard !hidden.isEmpty, hidesNonCompaction(group.entries[...]), let first = group.entries.first, let last = group.entries.last else { continue }

            let isLatest = latestRun?.runId == runId
            let lastEntryEnd = last.message?.updatedAt ?? last.createdAt
            let elapsed: Double? = if isLatest, let started = latestRun?.startedAt, let completed = latestRun?.completedAt {
                elapsedMs(started, completed)
            } else {
                elapsedMs(group.startBoundary ?? first.createdAt, maxTimestamp(group.terminal?.message?.updatedAt, lastEntryEnd) ?? lastEntryEnd)
            }
            let duration = elapsed.map(formatDuration)
            let label = isLatest && latestRun?.status == .interrupted
                ? (duration.map { "You stopped after \($0)" } ?? "You stopped this response")
                : (duration.map { "Worked for \($0)" } ?? "Worked")
            // The top row keeps the whole turn's time, steers included. Work after a steer folds under its own row
            // below that steer, keyed apart from the run so each segment opens on its own (L:1197-1221).
            func segment(_ entries: ArraySlice<TimelineEntry>) -> (hidden: Set<String>, ids: Set<String>) {
                let ids = Set(entries.map(\.id))
                return (hidden.intersection(ids), ids)
            }
            let firstSegment = segment(group.entries[..<(group.steerSegments.first?.startIndex ?? group.entries.count)])
            folds[group.anchorEntryId] = TurnFold(
                runId: runId, anchorEntryId: group.anchorEntryId, createdAt: group.startBoundary ?? first.createdAt,
                hiddenEntryIds: firstSegment.hidden, entryIds: firstSegment.ids, label: label)
            for (index, split) in group.steerSegments.enumerated() {
                let end = index + 1 < group.steerSegments.count ? group.steerSegments[index + 1].startIndex : group.entries.count
                let entries = group.entries[split.startIndex..<end]
                guard let anchor = entries.first, hidesNonCompaction(entries) else { continue }
                let segmentEnd = entries.map { $0.message?.updatedAt ?? $0.createdAt }.reduce(nil, maxTimestamp) ?? split.steer.createdAt
                let ms = elapsedMs(split.steer.createdAt, segmentEnd)
                let members = segment(entries)
                folds[anchor.id] = TurnFold(
                    runId: RunId("\(runId.rawValue):steer:\(split.steer.id)"), anchorEntryId: anchor.id, createdAt: split.steer.createdAt,
                    hiddenEntryIds: members.hidden, entryIds: members.ids, label: ms.map { "Continued for \(formatDuration($0))" } ?? "Continued")
            }
        }
        return folds
    }

    // MARK: Pre-passes (L:1246-1299)

    /// `settleSupersededReasoning`: a later entry ends thinking even without a completion.
    ///
    /// Skipped: `withoutSubagentDelegationRows`, which hides `delegate_task` tool rows whose child
    /// card exists. It needs `compactDynamicToolOutput`; add it when delegate threads matter.
    static func rowEntries(_ entries: [TimelineEntry], settleLast: Bool = false) -> [TimelineEntry] {
        entries.enumerated().map { index, entry in
            guard index < entries.count - 1 || settleLast, var work = entry.work, work.itemType == .reasoning, work.toolLifecycleStatus == .inProgress
            else { return entry }
            work.toolLifecycleStatus = .completed
            var settled = entry
            settled.kind = .work(work)
            return settled
        }
    }

    // MARK: Main pass (L:1326-1937)

    /// Port of `deriveMessagesTimelineRows`.
    public static func derive(_ input: TimelineRowsInput) -> [TimelineRow] {
        derive(input.entries, input, head: false)
    }

    /// The row pass over `entries`. `head` derives the front part of a thread whose later entries
    /// start with a prompt and share no run or attempt with this part (see `prepend`): the live
    /// tail (working header, live activity, thinking row) and the latest response belong to the
    /// later part, and no entry here is the thread's last.
    static func derive(_ entries: [TimelineEntry], _ input: TimelineRowsInput, head: Bool) -> [TimelineRow] {
        let entries = rowEntries(entries, settleLast: head)
        var summaryByMessageId: [MessageId: TurnDiffSummary] = [:]
        for summary in input.turnDiffSummaries { if let id = summary.assistantMessageId { summaryByMessageId[id] = summary } }
        let terminalIds = terminalAssistantMessageIds(entries)
        let unsettled = unsettledRunId(input.latestRun, runningRunId: input.runningRunId)
        let failed = failedRunIds(entries, latestRun: input.latestRun)
        let liveSubagents = liveSubagentCardEntryIds(entries)
        let attemptFolds = supersededAttemptFolds(entries, unfoldedRunIds: failed, liveSubagentEntryIds: liveSubagents)
        // The runs after the last prompt are in the later part, so only the unsettled run can be here.
        let activeResponseRunIds = head ? Set(unsettled.map { [$0] } ?? [])
            : activeVisualResponseRunIds(entries, unsettledRunId: unsettled, isWorking: input.isWorking)
        let runlessWorkActive = input.isWorking && input.runlessWorkActive
        // Live runless work keeps only the last prompt's runless turn open, and that prompt is later.
        let folds = turnFolds(
            entries, terminalIds: terminalIds, latestRun: input.latestRun, unfoldedRunIds: activeResponseRunIds.union(failed),
            runlessWorkActive: runlessWorkActive && !head, liveSubagentEntryIds: liveSubagents)
        var collapsed = Set<String>()
        for fold in folds.values where !input.expandedRunIds.contains(fold.runId) { collapsed.formUnion(fold.hiddenEntryIds) }
        var collapsedSuperseded = Set<String>()
        for fold in attemptFolds.values where !input.expandedAttemptIds.contains(fold.attemptId) {
            collapsedSuperseded.formUnion(fold.hiddenEntryIds)
        }
        func runIsActiveResponse(_ runId: RunId?) -> Bool {
            runId.map { activeResponseRunIds.contains($0) } ?? runlessWorkActive
        }
        func isInActiveRun(_ entry: WorkLogEntry) -> Bool {
            input.isWorking && entry.toolLifecycleStatus == .inProgress
                && (entry.runId.map { $0 == unsettled } ?? runlessWorkActive)
        }

        // A steer continues the current turn: the elapsed header stays under the initiating prompt.
        let activeTurnHeaderIndex = input.isWorking && !head ? lastResponseBoundaryIndex(entries) + 1 : entries.count

        // Contiguous trailing work of the active run collapses into one live row that survives
        // between actions (#8984).
        var activeToolEntries: [TimelineEntry] = []
        if input.isWorking, !head, unsettled != nil || runlessWorkActive {
            var tailAttemptId: RunAttemptId??
            var index = entries.count - 1
            while index >= activeTurnHeaderIndex {
                let entry = entries[index]
                guard let w = entry.work, w.tone != .error, w.sourceActivityKind != "runtime.error",
                    w.itemType != .systemNotice, w.itemType != .notification, w.questionAnswer == nil, runIsActiveResponse(w.runId),
                    w.sourceActivityKind != "context-compaction", !collapsed.contains(entry.id),
                    !collapsedSuperseded.contains(entry.id), folds[entry.id] == nil, attemptFolds[entry.id] == nil
                else { break }
                if let tail = tailAttemptId {
                    if entry.attempt?.id != tail { break }
                } else {
                    tailAttemptId = .some(entry.attempt?.id)
                }
                activeToolEntries.insert(entry, at: 0)
                index -= 1
            }
        }
        let visibleActive = activeToolEntries.filter { WorkLog.isVisibleInGroup($0.work!, expandedToolGroupEntry: true) }
        let activeAnchor = activeToolEntries.first
        let latestVisible = visibleActive.last
        let latestRunning = visibleActive.last { WorkLog.isActiveTurnActivity($0.work!) }
        let keepsActivityLive = latestRunning != nil || (latestVisible.map { WorkLog.indicatesSuccess($0.work!) } ?? false)
        let latestToolFailed = latestRunning == nil && latestVisible.map {
            $0.work!.toolLifecycleStatus != .declined && WorkLog.displayIndicatesFailure($0.work!)
        } == true
        let latestThought = visibleActive.last { $0.work!.itemType == .reasoning && !($0.work!.detail?.jsTrimmed.isEmpty ?? true) }
        var activeWorkRow: TimelineRow?
        if let anchor = activeAnchor, let latestVisible, !latestToolFailed {
            let groupId = workGroupId(anchor.id)
            activeWorkRow = TimelineRow(
                id: keepsActivityLive ? liveActivityRowId : "work-live:\(anchor.id)", createdAt: anchor.createdAt,
                kind: .workLive(
                    entry: (latestRunning ?? latestVisible).work!, groupedEntries: visibleActive.map { $0.work! }, groupId: groupId,
                    expanded: input.expandedWorkGroupIds.contains(groupId), active: keepsActivityLive, thought: latestThought?.work))
        }
        let activeWorkEntryIds = activeWorkRow != nil || latestToolFailed ? Set(activeToolEntries.map(\.id)) : []

        // A bare `/compact` turn is the compaction itself: one compaction row stands in for its prompt and working
        // indicator from the moment the turn starts, and an answered "compact before continuing?" question folds
        // into the compaction it asked for (MessagesTimeline.logic.ts:1551-1655, 0345e852ed).
        var compactionRuns: [RunId: String?] = [:]
        var compactedRunIds = Set<RunId>()
        var pendingResumeAge: [RunId: String] = [:]
        var resumeAgeByEntryId: [String: String] = [:]
        for entry in entries {
            if let m = entry.message, let run = m.runId, IdleCompaction.isCommand(m) {
                compactionRuns[run] = .some(IdleCompaction.reason(m))
            } else if let w = entry.work, let run = w.runId {
                if w.sourceActivityKind == "context-compaction" {
                    compactedRunIds.insert(run)
                    if let age = pendingResumeAge.removeValue(forKey: run) { resumeAgeByEntryId[entry.id] = age }
                }
                if let age = w.questionAnswer.flatMap(IdleCompaction.resumeAge) { pendingResumeAge[run] = age }
            }
        }
        func compactionTitle(_ run: RunId?, _ entryId: String) -> String? {
            guard let run else { return nil }
            if let reason = compactionRuns[run] ?? nil { return IdleCompaction.titles[reason] }
            return resumeAgeByEntryId[entryId].map { "Context compacted after \($0) idle" }
        }
        let activeCompactionEntry = entries.first { $0.work.map { $0.sourceActivityKind == "context-compaction" && isInActiveRun($0) } ?? false }
        let activeRunIsCompaction = input.isWorking && unsettled.map { compactionRuns[$0] != nil } == true
        // The item can finish before its run settles; only other work should keep activity visible.
        let compactionRunFinished = activeRunIsCompaction && unsettled.map { compactedRunIds.contains($0) } == true && activeCompactionEntry == nil
        let compactionOnlyRunFinished = compactionRunFinished && !entries.contains { e in
            runId(e) == unsettled && e.work?.sourceActivityKind != "context-compaction" && !(e.message.map(IdleCompaction.isCommand) ?? false)
        }
        let runningCompactionRunId = activeRunIsCompaction && !compactionRunFinished ? unsettled : nil
        // Compacting on return holds back the message the user just sent, so the working row says why it is
        // waiting. Any other compaction shows only its live divider, never both.
        let activeCompactionRunId: RunId? = runningCompactionRunId.flatMap { (compactionRuns[$0] ?? nil) == "onReturn" ? $0 : nil }
            ?? activeCompactionEntry.flatMap { resumeAgeByEntryId[$0.id] != nil ? $0.work?.runId : nil }
        let compactingLabel: String? = activeCompactionRunId == nil ? nil
            : activeCompactionEntry.flatMap { resumeAgeByEntryId[$0.id] }.map { "Compacting after \($0) idle…" } ?? IdleCompaction.compactingLabels["onReturn"]
        let hasActiveCompaction = activeCompactionEntry != nil || (activeRunIsCompaction && !compactionRunFinished)

        var rows: [TimelineRow] = []
        var hasActivityRow = false
        func expandedBody(_ groupId: String, _ createdAt: T3Timestamp, _ grouped: [WorkLogEntry]) -> TimelineRow {
            TimelineRow(id: "\(groupId):details", createdAt: createdAt, kind: .work(groupedEntries: grouped, isExpandedToolGroup: true, displayLabel: nil))
        }
        func appendWorkingRow() {
            if compactionOnlyRunFinished { return }
            if runningCompactionRunId != nil, activeCompactionRunId == nil { return }
            rows.append(TimelineRow(id: workingRowId, createdAt: input.activeTurnStartedAt, kind: .working(compacting: compactingLabel)))
        }

        var index = 0
        while index < entries.count {
            defer { index += 1 }
            let entry = entries[index]
            if input.isWorking, index == activeTurnHeaderIndex { appendWorkingRow() }
            if let row = activeWorkRow, entry.id == latestVisible?.id {
                rows.append(row)
                if case .workLive(_, let grouped, let groupId, let expanded, let active, _) = row.kind {
                    hasActivityRow = hasActivityRow || active
                    if expanded { rows.append(expandedBody(groupId, row.createdAt!, grouped)) }
                }
            }
            // The interrupt result is the marker; the request is transient bookkeeping.
            if entry.eventItem?.item.type == .runInterruptRequest { continue }
            if let fold = folds[entry.id] {
                rows.append(TimelineRow(
                    id: "turn-fold:\(fold.runId.rawValue)", createdAt: fold.createdAt,
                    kind: .turnFold(runId: fold.runId, label: fold.label, expanded: input.expandedRunIds.contains(fold.runId))))
            }
            if collapsed.contains(entry.id) { continue }
            if let fold = attemptFolds[entry.id] {
                rows.append(TimelineRow(
                    id: "attempt-fold:\(fold.attemptId.rawValue)", createdAt: fold.createdAt,
                    kind: .attemptFold(runId: fold.runId, attemptId: fold.attemptId, label: "Superseded attempt",
                                       expanded: input.expandedAttemptIds.contains(fold.attemptId))))
            }
            if collapsedSuperseded.contains(entry.id) || activeWorkEntryIds.contains(entry.id) { continue }

            switch entry.kind {
            case .work(let work) where work.sourceActivityKind == "context-compaction":
                let active = isInActiveRun(work)
                if active, let run = activeCompactionRunId, work.runId == run { continue }
                let reason = work.runId.flatMap { compactionRuns[$0] ?? nil }
                let failed = work.structuredPayload?.status == .failed
                let failure = failed ? work.structuredPayload?.string("summary")?.jsTrimmed.nonEmpty : nil
                var label = active ? reason.flatMap { IdleCompaction.compactingLabels[$0] } ?? work.label : work.label
                // The title leads the token counts in place of "Context compacted".
                if let title = compactionTitle(work.runId, entry.id), label.hasPrefix("Context compacted") {
                    label = title + label.dropFirst("Context compacted".count)
                }
                rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt,
                                        kind: .contextCompaction(label: label, active: active, failed: failed, failure: failure)))

            case .work(let work) where work.runId.map({ compactedRunIds.contains($0) }) == true
                && work.questionAnswer.flatMap(IdleCompaction.resumeAge) != nil:
                continue

            case .work(let work):
                if (work.runId.map { failed.contains($0) } ?? false) || (work.itemType == .error && work.toolLifecycleStatus == .failed)
                    || work.tone == .error || work.sourceActivityKind == "runtime.error" || work.itemType == .systemNotice
                    || work.itemType == .notification || work.questionAnswer != nil
                {
                    rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt, kind: .work(groupedEntries: [work], isExpandedToolGroup: false, displayLabel: nil)))
                    continue
                }
                var grouped = [work]
                var cursor = index + 1
                while cursor < entries.count {
                    let next = entries[cursor]
                    guard let nextWork = next.work, nextWork.sourceActivityKind != "context-compaction", nextWork.tone != .error,
                        nextWork.sourceActivityKind != "runtime.error", nextWork.itemType != .systemNotice,
                        nextWork.itemType != .notification, nextWork.questionAnswer == nil, !activeWorkEntryIds.contains(next.id), !collapsed.contains(next.id),
                        !collapsedSuperseded.contains(next.id), folds[next.id] == nil, attemptFolds[next.id] == nil,
                        nextWork.runId == work.runId, next.attempt?.id == entry.attempt?.id
                    else { break }
                    grouped.append(nextWork)
                    cursor += 1
                }
                index = cursor - 1
                let visible = grouped.filter { WorkLog.isVisibleInGroup($0, expandedToolGroupEntry: isInActiveRun($0)) }
                guard !visible.isEmpty else { continue }
                let groupId = workGroupId(entry.id)
                let expanded = input.expandedWorkGroupIds.contains(groupId)
                let activeInProgress = visible.filter(isInActiveRun)
                if let latestActive = activeInProgress.last {
                    rows.append(TimelineRow(
                        id: "work-live:\(entry.id)", createdAt: entry.createdAt,
                        kind: .workLive(entry: latestActive, groupedEntries: visible, groupId: groupId, expanded: expanded, active: true, thought: nil)))
                    hasActivityRow = true
                    if expanded { rows.append(expandedBody(groupId, entry.createdAt, visible)) }
                } else if visible.count == 1, WorkLog.isToolLike(visible[0]) {
                    let single = visible[0]
                    let label = WorkLog.toolGroupAction(single) == .edit
                        ? WorkLog.summarizeToolGroup(visible).summary : WorkLog.singleToolCallLabel(single)
                    rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt, kind: .work(groupedEntries: visible, isExpandedToolGroup: false, displayLabel: label)))
                } else {
                    let primarySource = visible.first { $0.toolSource != nil }
                    let primaryIcon = primarySource?.toolSource.flatMap { source in
                        visible.first { $0.toolSource?.key == source.key && $0.toolIcon != nil }?.toolIcon ?? source.icon
                    }
                    let latestTool = visible.last(where: WorkLog.isToolLike)
                    let single = visible.count == 1 ? visible[0] : nil
                    let usesSingleLabel = single.map { WorkLog.isToolLike($0) && WorkLog.toolGroupAction($0) != .edit } ?? false
                    let summary = usesSingleLabel ? WorkLog.singleToolCallLabel(single!)
                        : single.map { !WorkLog.isToolLike($0) ? $0.label : nil } ?? nil
                    rows.append(TimelineRow(id: "work-toggle:\(entry.id)", createdAt: entry.createdAt, kind: .workToggle(TimelineRow.WorkToggle(
                        runId: work.runId, groupId: groupId, hiddenCount: visible.count, expanded: expanded,
                        summary: summary ?? WorkLog.summarizeToolGroup(visible).summary,
                        summaryKind: WorkLog.toolGroupSummaryKind(visible),
                        toolSurface: primarySource?.toolSurface ?? visible.last { $0.toolSurface != nil }?.toolSurface,
                        toolIcon: primaryIcon ?? visible.last { $0.toolIcon != nil }?.toolIcon,
                        summaryToolIcon: usesSingleLabel ? WorkLog.toolPresentation(single!, fallbackStatus: .completed)?.icon : nil,
                        hasFailure: latestTool.map(WorkLog.displayIndicatesFailure) ?? false))))
                    if expanded { rows.append(expandedBody(groupId, entry.createdAt, visible)) }
                }

            case .proposedPlan(let plan):
                rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt, kind: .proposedPlan(plan)))

            case .htmlRender(let page, _):
                rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt, kind: .htmlRender(page)))

            case .mcpApp(let app, _):
                rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt, kind: .mcpApp(app)))

            case .event(let row):
                // Adjacent subagent cards from one run and provider turn merge into one row.
                if row.item.type == .subagent, let previous = rows.last, case .event(let prev, let subagents, let summary) = previous.kind,
                    prev.item.type == .subagent, prev.item.runId == row.item.runId, prev.item.providerTurnId == row.item.providerTurnId
                {
                    rows[rows.count - 1].kind = .event(prev, subagents: (subagents ?? [prev]) + [row], resourceSummary: summary)
                    continue
                }
                rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt, kind: .event(row, subagents: nil, resourceSummary: false)))

            case .message(let message, _) where message.runId != nil && IdleCompaction.isCommand(message):
                let run = message.runId!
                guard !compactedRunIds.contains(run), run != activeCompactionRunId else { continue }
                let pending = run == runningCompactionRunId
                let label = pending ? (compactionRuns[run] ?? nil).flatMap { IdleCompaction.compactingLabels[$0] } ?? "Compacting context" : "Context compaction"
                rows.append(TimelineRow(id: "compaction:\(run.rawValue)", createdAt: entry.createdAt, kind: .contextCompaction(label: label, active: pending)))

            case .message(let message, let projected):
                let stillInProgress = message.role == .assistant && runIsActiveResponse(message.runId)
                // While the turn runs, the latest answer is only provisionally terminal.
                let showMeta = message.role == .assistant && terminalIds.contains(message.id) && !stillInProgress
                rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt, kind: .message(
                    message, projectedItem: projected, showAssistantMeta: showMeta, showAssistantCopyButton: showMeta,
                    assistantCopyStreaming: message.streaming || stillInProgress,
                    turnDiffSummary: message.role == .assistant ? summaryByMessageId[message.id] : nil)))
            }
        }

        if input.isWorking, !head, !rows.contains(where: { $0.id == workingRowId }), activeTurnHeaderIndex == entries.count {
            appendWorkingRow()
        }
        // `compactionAwaitingRow` (MessagesTimeline.tsx:946-952): a `/compact` runs and neither a live compaction
        // row nor a compacting working row shows yet. The header reads "Compacting…" and Thinking keeps its height, blank.
        let compacting = input.isCompacting && !rows.contains { row in
            switch row.kind {
            case .contextCompaction(_, true, _, _), .working(_?): true
            default: false
            }
        }
        if compacting, let i = rows.firstIndex(where: { $0.id == workingRowId }) {
            rows[i].kind = .working(compacting: "Compacting…")
        }
        if input.isWorking, input.latestRun?.turnEnded != true, !head, !hasActiveCompaction, !compactionOnlyRunFinished,
           !hasActivityRow || latestToolFailed {
            // A failed latest tool hands the row back to thinking; its group stays reachable.
            if latestToolFailed, let anchor = activeAnchor {
                let groupId = workGroupId(anchor.id)
                let expanded = input.expandedWorkGroupIds.contains(groupId)
                rows.append(TimelineRow(id: liveActivityRowId, createdAt: input.activeTurnStartedAt,
                                        kind: .thinking(groupId: groupId, expanded: expanded, compacting: compacting)))
                if expanded { rows.append(expandedBody(groupId, anchor.createdAt, visibleActive.map { $0.work! })) }
            } else {
                rows.append(TimelineRow(id: liveActivityRowId, createdAt: input.activeTurnStartedAt,
                                        kind: .thinking(groupId: nil, expanded: nil, compacting: compacting)))
            }
        }

        var collapsedFoldMembers = Set<String>()
        for fold in folds.values where !input.expandedRunIds.contains(fold.runId) { collapsedFoldMembers.formUnion(fold.entryIds) }
        var result = attachTrailingToolGroupsToAssistant(attachCreatedThreadSummaries(rows, entries, collapsedFoldMembers: collapsedFoldMembers))
        for i in result.indices.dropLast() where result[i].isWorkLog && result[i + 1].isWorkLog {
            result[i].continuesWorkLog = true
        }
        return result
    }

    // MARK: Updates (L:2010-2165)

    /// The rows of one input and where each message's rows sit, so a streaming update can patch
    /// them in place (`MessagesTimelineRowsProjection`).
    public struct Derived: Sendable {
        public var input: TimelineRowsInput
        public var rows: [TimelineRow]
        /// Message id to its `message` and `assistantMeta` rows, counted back from the last row, so
        /// rows put in front by a history page leave them valid.
        var messageRowsFromEnd: [String: [Int]]
        /// Run and attempt to its last entry, counted back from the last entry. Built on the first
        /// history page, then kept up to date by each page.
        var lastScopeUseFromEnd: [ScopeKey: Int]?

        public init(_ input: TimelineRowsInput) {
            self.input = input
            rows = TimelineRows.derive(input)
            messageRowsFromEnd = [:]
            addMessageRows(0..<rows.count)
        }

        /// The indices of a message's rows.
        func messageRows(_ id: String) -> [Int] {
            (messageRowsFromEnd[id] ?? []).map { rows.count - 1 - $0 }
        }

        private mutating func addMessageRows(_ range: Range<Int>) {
            for index in range {
                if let m = rows[index].message { messageRowsFromEnd[m.id.rawValue, default: []].append(rows.count - 1 - index) }
            }
        }

        /// An older history page put `count` entries in front of the previous ones (`input` holds
        /// all of them; every later entry and the context stayed). Derives only the page and the
        /// old rows up to the first prompt that no run or attempt before it reaches past, and
        /// keeps every row after that prompt. Returns how many leading rows gave way to how many
        /// new ones, or nil, leaving `self` as it was, when the page needs a full pass.
        ///
        /// Cutting there is exact: everything the row pass shares across entries is keyed by run
        /// or attempt (turn and attempt folds, failures, interrupts, final answers, created-chat
        /// summaries), runless turns and work groups end at a prompt, the footer search and
        /// subagent merging stop at a message row, and the live tail sits after the last prompt.
        public mutating func prepend(_ input: TimelineRowsInput, count: Int) -> (replaced: Int, inserted: Int)? {
            let entries = input.entries, old = self.input.entries, n = entries.count
            guard count > 0, n == old.count + count, !rows.isEmpty, input.sameContext(self.input) else { return nil }
            var lastUse = lastScopeUseFromEnd ?? TimelineRows.lastScopeUse(old)
            // Where the last use of any run or attempt seen so far lies.
            var reach = -1
            var cut: Int?
            for i in 0..<n {
                let entry = entries[i]
                if i >= count, i > reach, entry.message?.role == .user, TimelineRows.startsResponse(entry) { cut = i; break }
                TimelineRows.forEachScope(entry) { key in reach = max(reach, lastUse[key].map { n - 1 - $0 } ?? i) }
            }
            guard let cut, let first = messageRows(entries[cut].id).first, rows[first].id == entries[cut].id else { return nil }
            for i in stride(from: count - 1, through: 0, by: -1) {
                TimelineRows.forEachScope(entries[i]) { key in if lastUse[key] == nil { lastUse[key] = n - 1 - i } }
            }
            let head = TimelineRows.derive(Array(entries[..<cut]), input, head: true)
            for row in rows[..<first] { if let m = row.message { messageRowsFromEnd[m.id.rawValue] = nil } }
            rows.replaceSubrange(0..<first, with: head)
            addMessageRows(0..<head.count)
            lastScopeUseFromEnd = lastUse
            self.input = input
            return (first, head.count)
        }
    }

    /// A run or an attempt, the scopes the row pass groups entries by.
    enum ScopeKey: Hashable, Sendable {
        case run(RunId)
        case attempt(RunAttemptId)
    }

    /// Every run and attempt an entry belongs to or names.
    static func forEachScope(_ entry: TimelineEntry, _ body: (ScopeKey) -> Void) {
        if let attempt = entry.attempt {
            body(.attempt(attempt.id))
            body(.run(attempt.runId))
        }
        if let id = runId(entry) { body(.run(id)) }
        if let id = entry.message?.runId { body(.run(id)) }
        if let work = entry.work {
            if let id = work.runId { body(.run(id)) }
            if let id = work.projectedItem?.item.runId { body(.run(id)) }
        }
        if let id = entry.eventItem?.item.runId { body(.run(id)) }
    }

    /// Each scope's last entry, counted back from the last entry.
    static func lastScopeUse(_ entries: [TimelineEntry]) -> [ScopeKey: Int] {
        var last: [ScopeKey: Int] = [:]
        for (i, entry) in entries.enumerated().reversed() {
            forEachScope(entry) { key in if last[key] == nil { last[key] = entries.count - 1 - i } }
        }
        return last
    }

    /// Port of `replaceStreamingMessageRows`: when the only change since `previous` is the text of
    /// streaming answers (the entries at `changedEntries`), their rows get the new text and every
    /// other row stays as it was. Returns the new state and the row indices that changed, or nil
    /// when the update needs a full pass.
    public static func patchingStreamingText(_ previous: Derived, input: TimelineRowsInput, changedEntries: [Int]) -> (Derived, [Int])? {
        guard input.entries.count == previous.input.entries.count, input.sameContext(previous.input) else { return nil }
        var next = previous
        next.input = input
        var changedRows: [Int] = []
        for index in changedEntries {
            let entry = input.entries[index], old = previous.input.entries[index]
            guard case .message(let message, let projected) = entry.kind, case .message(let oldMessage, let oldProjected) = old.kind,
                entry.id == old.id, entry.createdAt == old.createdAt, entry.attempt == old.attempt
            else { return nil }
            if projected != oldProjected {
                guard let projected, let oldProjected, isStreamingTextUpdate(oldProjected, projected) else { return nil }
            }
            if message == oldMessage, projected == oldProjected { continue }
            guard isStreamingTextUpdate(oldMessage, message) else { return nil }
            for rowIndex in previous.messageRows(message.id.rawValue) {
                switch next.rows[rowIndex].kind {
                case .message(_, _, let meta, let copy, let copyStreaming, let summary):
                    next.rows[rowIndex].kind = .message(
                        message, projectedItem: projected, showAssistantMeta: meta, showAssistantCopyButton: copy,
                        assistantCopyStreaming: copyStreaming, turnDiffSummary: summary)
                case .assistantMeta(_, _, let copy, let copyStreaming):
                    next.rows[rowIndex].kind = .assistantMeta(message, projectedItem: projected, showAssistantCopyButton: copy, assistantCopyStreaming: copyStreaming)
                default:
                    return nil
                }
                changedRows.append(rowIndex)
            }
        }
        return (next, changedRows)
    }

    /// `isStreamingMessageTextUpdate` (session-logic.ts:893-906): text and update time don't
    /// change a streaming answer's rows.
    static func isStreamingTextUpdate(_ previous: ChatMessage, _ next: ChatMessage) -> Bool {
        guard previous.role == .assistant, next.role == .assistant, previous.streaming, next.streaming else { return false }
        var same = previous
        same.text = next.text
        same.updatedAt = next.updatedAt
        return same == next
    }

    /// `isStreamingTurnItemTextUpdate` (session-logic.ts:908-929).
    static func isStreamingTextUpdate(_ previous: ProjectedTurnItem, _ next: ProjectedTurnItem) -> Bool {
        let a = previous.item, b = next.item
        guard a.type == .assistantMessage, b.type == .assistantMessage, a.streaming, b.streaming,
            previous.position == next.position, previous.visibility == next.visibility,
            previous.sourceThreadId == next.sourceThreadId, previous.sourceItemId == next.sourceItemId,
            (a.startedAt ?? a.updatedAt) == (b.startedAt ?? b.updatedAt),
            case .object(var x) = a.raw, case .object(var y) = b.raw
        else { return false }
        for key in ["text", "updatedAt"] {
            x[key] = nil
            y[key] = nil
        }
        return x == y
    }

    // MARK: Post passes (L:1151-1244, 1958-2004)

    /// `attachCreatedThreadSummaries`: created chats re-appear right after the run's final answer
    /// as summary cards, even when the work that created them folded away.
    /// `collapsedFoldMembers`: every entry of a closed fold's segment (a8bb769d65), so a card a steer's segment folds
    /// moves under the answer too.
    static func attachCreatedThreadSummaries(_ rows: [TimelineRow], _ entries: [TimelineEntry], collapsedFoldMembers: Set<String>) -> [TimelineRow] {
        var terminalIndexes: [RunId: Int] = [:]
        for (index, row) in rows.enumerated() {
            if case .message(let m, _, true, _, _, _) = row.kind, let runId = m.runId { terminalIndexes[runId] = index }
        }
        var createdByRun: [RunId: [TimelineRow]] = [:]
        for entry in entries {
            let projected: ProjectedTurnItem? = switch entry.kind {
            case .work(let w): w.projectedItem
            case .event(let p): p
            default: nil
            }
            guard let projected, projected.item.type == .threadCreated, let runId = projected.item.runId else { continue }
            createdByRun[runId, default: []].append(TimelineRow(
                id: "summary:\(entry.id)", createdAt: entry.createdAt, kind: .event(projected, subagents: nil, resourceSummary: true)))
        }
        guard !createdByRun.isEmpty else { return rows }
        return rows.enumerated().flatMap { index, row -> [TimelineRow] in
            if case .event(let p, _, _) = row.kind, p.item.type == .threadCreated, let runId = p.item.runId,
                let terminal = terminalIndexes[runId], collapsedFoldMembers.contains(row.id) || index > terminal
            {
                return []
            }
            if case .message(let m, _, true, _, _, _) = row.kind, let runId = m.runId {
                return [row] + (createdByRun[runId] ?? [])
            }
            return [row]
        }
    }

    /// `attachTrailingToolGroupsToAssistant`: when tool rows trail the final answer, the
    /// answer's footer moves below them as an `assistant-meta` row.
    static func attachTrailingToolGroupsToAssistant(_ rows: [TimelineRow]) -> [TimelineRow] {
        var withoutMeta = Set<String>()
        var metaAfterIndex: [Int: TimelineRow] = [:]
        for (messageIndex, row) in rows.enumerated() {
            guard case .message(let message, let projected, true, let copyButton, let copyStreaming, _) = row.kind,
                message.role == .assistant, let runId = message.runId
            else { continue }
            var lastTrailing = -1
            var hasTrailingToolGroup = false
            for index in rows.indices.dropFirst(messageIndex + 1) {
                let candidate = rows[index]
                switch candidate.kind {
                case .message: break
                case .workToggle(let toggle) where toggle.runId == runId:
                    hasTrailingToolGroup = true
                    lastTrailing = index
                    continue
                case .event(let p, _, true) where p.item.runId == runId:
                    hasTrailingToolGroup = true
                    lastTrailing = index
                    continue
                case .work(let grouped, let isExpanded, _) where grouped.contains(where: { $0.runId == runId }):
                    if !isExpanded, grouped.contains(where: {
                        WorkLog.isToolLike($0) || ($0.projectedItem?.item.type == .error && $0.projectedItem?.item.status == .failed)
                    }) {
                        hasTrailingToolGroup = true
                    }
                    if hasTrailingToolGroup { lastTrailing = index }
                    continue
                default:
                    continue
                }
                break
            }
            guard lastTrailing >= 0 else { continue }
            withoutMeta.insert(row.id)
            metaAfterIndex[lastTrailing] = TimelineRow(
                id: "assistant-meta:\(message.id.rawValue)", createdAt: rows[lastTrailing].createdAt ?? message.updatedAt,
                kind: .assistantMeta(message, projectedItem: projected, showAssistantCopyButton: copyButton, assistantCopyStreaming: copyStreaming))
        }
        guard !metaAfterIndex.isEmpty else { return rows }
        var result: [TimelineRow] = []
        for (index, row) in rows.enumerated() {
            if withoutMeta.contains(row.id), case .message(let m, let p, _, _, let streaming, let summary) = row.kind {
                var copy = row
                copy.kind = .message(m, projectedItem: p, showAssistantMeta: false, showAssistantCopyButton: false, assistantCopyStreaming: streaming, turnDiffSummary: summary)
                result.append(copy)
            } else {
                result.append(row)
            }
            if let meta = metaAfterIndex[index] { result.append(meta) }
        }
        return result
    }

    /// `resolveAssistantMessageCopyState` (L:695-710): copy shows only for non-empty, settled text.
    ///
    /// // ponytail: copies the raw text; port `renderCodexDirectivesForCopy` when Codex directives
    /// appear in answers.
    public static func copyState(text: String?, showCopyButton: Bool, streaming: Bool) -> (text: String?, visible: Bool) {
        let hasText = !(text?.jsTrimmed.isEmpty ?? true)
        return (hasText ? text : nil, showCopyButton && hasText && !streaming)
    }
}
