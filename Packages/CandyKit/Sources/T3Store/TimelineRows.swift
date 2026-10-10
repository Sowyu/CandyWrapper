import Foundation
import T3Protocol

/// `TimelineLatestRun` (MessagesTimeline.logic.ts:507-510).
public struct TimelineLatestRun: Sendable, Hashable {
    public var runId: RunId
    public var status: ThreadStatus
    public var requestedAt: T3Timestamp?
    public var startedAt: T3Timestamp?
    public var completedAt: T3Timestamp?

    public init(runId: RunId, status: ThreadStatus, requestedAt: T3Timestamp? = nil, startedAt: T3Timestamp? = nil, completedAt: T3Timestamp? = nil) {
        self.runId = runId
        self.status = status
        self.requestedAt = requestedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// One timeline row (`MessagesTimelineRow`, MessagesTimeline.logic.ts:514-648). Ids are stable
/// across derivations, so the view can diff by `id`.
///
/// Skipped: `html-render`, `mcp-app` (web content, later milestone) and `worktree-setup`
/// (composer state). `durationStart` and `revertTurnCount` are left out: the renderer never reads
/// the first, and rollback is out of scope for a read-only view.
public struct TimelineRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
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
        /// "Working for 12s" header; `createdAt` is the turn start.
        case working
        /// Placeholder while running with no visible activity.
        case thinking(groupId: String?, expanded: Bool?)
        /// Header of a settled group of tool calls.
        case workToggle(WorkToggle)
        /// "Worked for 22s" header of a settled turn.
        case turnFold(runId: RunId, label: String, expanded: Bool)
        case attemptFold(runId: RunId, attemptId: RunAttemptId, label: String, expanded: Bool)
        case contextCompaction(label: String, active: Bool)
        /// fork, handoff, interrupt result, secret request, subagent (grouped), created-thread summary.
        case event(ProjectedTurnItem, subagents: [ProjectedTurnItem]?, resourceSummary: Bool)
        case proposedPlan(ProposedPlan)
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
    }

    /// `init(projection:)` against the previous update: only changed rows are rebuilt. `changed`
    /// lists the entries replaced in place; nil when the entry list changed shape.
    public static func derive(projection: ThreadProjection, memo: inout Memo) -> (input: TimelineRowsInput, changed: [Int]?) {
        let rows = TimelineEntries.projectingQuestionHistory(projection.visibleTurnItems, requests: projection.runtimeRequests)
        let (entries, changed) = TimelineEntries.derive(
            visibleTurnItems: rows, attempts: projection.attempts, nodes: projection.nodes, plans: projection.plans, memo: &memo.entries)
        let state = TimelineRunState(projection: projection)
        // Equal summaries keep the old array, so the row pass sees the same value cheaply.
        if projection.checkpoints != memo.checkpoints || projection.messages != memo.messages {
            let summaries = TurnDiffs.summaries(projection)
            if summaries != memo.summaries { memo.summaries = summaries }
            memo.checkpoints = projection.checkpoints
            memo.messages = projection.messages
        }
        let input = TimelineRowsInput(
            entries: entries, latestRun: state.latestRun, runningRunId: state.runningRunId, isWorking: state.isWorking,
            runlessWorkActive: state.runlessWorkStartedAt != nil,
            activeTurnStartedAt: state.activeTurnStartedAt, turnDiffSummaries: memo.summaries)
        return (input, changed)
    }

    /// Everything but the entries matches `other`: the row pass would fold and group the same way.
    func sameContext(_ other: TimelineRowsInput) -> Bool {
        latestRun == other.latestRun && runningRunId == other.runningRunId && isWorking == other.isWorking
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
            TimelineLatestRun(runId: $0.id, status: $0.status, requestedAt: $0.requestedAt, startedAt: $0.startedAt, completedAt: $0.completedAt)
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
        case .proposedPlan: return nil
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
                entry.message?.role != .user, !entry.isPersistentResourceCard, !liveSubagentEntryIds.contains(entry.id),
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
        for entry in entries {
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
        }
        var order: [RunId] = []
        var groups: [RunId: Group] = [:]
        var runlessFailedKeys = Set<RunId>()
        var runlessKey: RunId?
        var pendingBoundary: (createdAt: T3Timestamp, anchorEntryId: String)?
        for (index, entry) in entries.enumerated() {
            if startsResponse(entry) {
                pendingBoundary = index + 1 < entries.count ? (entry.createdAt, entries[index + 1].id) : nil
                let boundaryRunId = entry.message?.runId ?? entry.work?.runId
                runlessKey = boundaryRunId == nil ? RunId("runless:\(entry.id)") : nil
                continue
            }
            guard let runId = foldRunId(entry, runlessKey: runlessKey) else { continue }
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
                hidden.insert(entry.id)
            }
            // A lone compaction stays visible; it folds only with other work.
            let hidesNonCompaction = group.entries.contains { hidden.contains($0.id) && $0.work?.sourceActivityKind != "context-compaction" }
            guard !hidden.isEmpty, hidesNonCompaction, let first = group.entries.first, let last = group.entries.last else { continue }

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
            folds[group.anchorEntryId] = TurnFold(
                runId: runId, anchorEntryId: group.anchorEntryId, createdAt: group.startBoundary ?? first.createdAt,
                hiddenEntryIds: hidden, label: label)
        }
        return folds
    }

    // MARK: Pre-passes (L:1246-1299)

    /// `settleSupersededReasoning`: a later entry ends thinking even without a completion.
    ///
    /// Skipped: `withoutSubagentDelegationRows`, which hides `delegate_task` tool rows whose child
    /// card exists. It needs `compactDynamicToolOutput`; add it when delegate threads matter.
    static func rowEntries(_ entries: [TimelineEntry]) -> [TimelineEntry] {
        entries.enumerated().map { index, entry in
            guard index < entries.count - 1, var work = entry.work, work.itemType == .reasoning, work.toolLifecycleStatus == .inProgress
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
        let entries = rowEntries(input.entries)
        var summaryByMessageId: [MessageId: TurnDiffSummary] = [:]
        for summary in input.turnDiffSummaries { if let id = summary.assistantMessageId { summaryByMessageId[id] = summary } }
        let terminalIds = terminalAssistantMessageIds(entries)
        let unsettled = unsettledRunId(input.latestRun, runningRunId: input.runningRunId)
        let failed = failedRunIds(entries, latestRun: input.latestRun)
        let liveSubagents = liveSubagentCardEntryIds(entries)
        let attemptFolds = supersededAttemptFolds(entries, unfoldedRunIds: failed, liveSubagentEntryIds: liveSubagents)
        let activeResponseRunIds = activeVisualResponseRunIds(entries, unsettledRunId: unsettled, isWorking: input.isWorking)
        let runlessWorkActive = input.isWorking && input.runlessWorkActive
        let folds = turnFolds(
            entries, terminalIds: terminalIds, latestRun: input.latestRun, unfoldedRunIds: activeResponseRunIds.union(failed),
            runlessWorkActive: runlessWorkActive, liveSubagentEntryIds: liveSubagents)
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
        let activeTurnHeaderIndex = input.isWorking ? lastResponseBoundaryIndex(entries) + 1 : entries.count

        // Contiguous trailing work of the active run collapses into one live row that survives
        // between actions (#8984).
        var activeToolEntries: [TimelineEntry] = []
        if input.isWorking, unsettled != nil || runlessWorkActive {
            var tailAttemptId: RunAttemptId??
            var index = entries.count - 1
            while index >= activeTurnHeaderIndex {
                let entry = entries[index]
                guard let w = entry.work, w.tone != .error, w.sourceActivityKind != "runtime.error",
                    w.itemType != .systemNotice, w.itemType != .notification, runIsActiveResponse(w.runId),
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

        var rows: [TimelineRow] = []
        var hasActivityRow = false
        var hasActiveCompaction = false
        func expandedBody(_ groupId: String, _ createdAt: T3Timestamp, _ grouped: [WorkLogEntry]) -> TimelineRow {
            TimelineRow(id: "\(groupId):details", createdAt: createdAt, kind: .work(groupedEntries: grouped, isExpandedToolGroup: true, displayLabel: nil))
        }
        func appendWorkingRow() {
            rows.append(TimelineRow(id: workingRowId, createdAt: input.activeTurnStartedAt, kind: .working))
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
                hasActiveCompaction = hasActiveCompaction || active
                rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt, kind: .contextCompaction(label: work.label, active: active)))

            case .work(let work):
                if (work.runId.map { failed.contains($0) } ?? false) || (work.itemType == .error && work.toolLifecycleStatus == .failed)
                    || work.tone == .error || work.sourceActivityKind == "runtime.error" || work.itemType == .systemNotice
                    || work.itemType == .notification
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
                        nextWork.itemType != .notification, !activeWorkEntryIds.contains(next.id), !collapsed.contains(next.id),
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

            case .event(let row):
                // Adjacent subagent cards from one run and provider turn merge into one row.
                if row.item.type == .subagent, let previous = rows.last, case .event(let prev, let subagents, let summary) = previous.kind,
                    prev.item.type == .subagent, prev.item.runId == row.item.runId, prev.item.providerTurnId == row.item.providerTurnId
                {
                    rows[rows.count - 1].kind = .event(prev, subagents: (subagents ?? [prev]) + [row], resourceSummary: summary)
                    continue
                }
                rows.append(TimelineRow(id: entry.id, createdAt: entry.createdAt, kind: .event(row, subagents: nil, resourceSummary: false)))

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

        if input.isWorking, !rows.contains(where: { $0.id == workingRowId }), activeTurnHeaderIndex == entries.count {
            appendWorkingRow()
        }
        if input.isWorking, !hasActiveCompaction, !hasActivityRow || latestToolFailed {
            // A failed latest tool hands the row back to thinking; its group stays reachable.
            if latestToolFailed, let anchor = activeAnchor {
                let groupId = workGroupId(anchor.id)
                let expanded = input.expandedWorkGroupIds.contains(groupId)
                rows.append(TimelineRow(id: liveActivityRowId, createdAt: input.activeTurnStartedAt, kind: .thinking(groupId: groupId, expanded: expanded)))
                if expanded { rows.append(expandedBody(groupId, anchor.createdAt, visibleActive.map { $0.work! })) }
            } else {
                rows.append(TimelineRow(id: liveActivityRowId, createdAt: input.activeTurnStartedAt, kind: .thinking(groupId: nil, expanded: nil)))
            }
        }

        var result = attachTrailingToolGroupsToAssistant(attachCreatedThreadSummaries(rows, entries))
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
        /// Message id to the indices of its `message` and `assistantMeta` rows.
        var messageRows: [String: [Int]]

        public init(_ input: TimelineRowsInput) {
            self.input = input
            rows = TimelineRows.derive(input)
            messageRows = [:]
            for (index, row) in rows.enumerated() {
                if let m = row.message { messageRows[m.id.rawValue, default: []].append(index) }
            }
        }
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
            for rowIndex in previous.messageRows[message.id.rawValue] ?? [] {
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
    static func attachCreatedThreadSummaries(_ rows: [TimelineRow], _ entries: [TimelineEntry]) -> [TimelineRow] {
        var terminalIndexes: [RunId: Int] = [:]
        var collapsedRuns = Set<RunId>()
        for (index, row) in rows.enumerated() {
            if case .message(let m, _, true, _, _, _) = row.kind, let runId = m.runId { terminalIndexes[runId] = index }
            if case .turnFold(let runId, _, false) = row.kind { collapsedRuns.insert(runId) }
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
                let terminal = terminalIndexes[runId], collapsedRuns.contains(runId) || index > terminal
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
