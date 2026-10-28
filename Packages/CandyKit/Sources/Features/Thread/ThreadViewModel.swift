import CoreGraphics
import Foundation
import T3Protocol
import T3Store

/// View state of one row that the row pass doesn't know about. It travels with the row so a
/// recycled view shows the same thing, and it is part of the measured-height cache key.
struct TimelineRowUI: Hashable {
    /// Work log entries (and thoughts) whose details are open, limited to this row's entries.
    var expandedEntries: Set<String> = []
    /// A long user message shows in full, or a folded agent or automation message is open.
    var messageExpanded = false
    /// A folded message's sender thread title, or its automation's task title (TimelineUserMessageRow.tsx:142-152, 298-302).
    var foldTitle: String?
    /// A long plan shows in full.
    var planExpanded = false
    /// The changed files card's fold-all state and the folders toggled since.
    var filesExpanded = false
    var folderOverrides: [String: Bool] = [:]
    /// Fetched output of this row's open entries whose output the stream left out.
    var outputs: [String: ToolOutputState] = [:]
    /// A secret request's answer in flight, and the error of the last one.
    var secretSubmitting = false
    var secretError: String?
    /// The height an MCP App reported for itself, in points.
    var webContentHeight: Double?
    /// The heights an HTML render reported for itself, by width.
    var htmlHeights = HtmlRenderHeights()
    /// An MCP App asked to be closed; the row shows "Show app".
    var appClosed = false
    var subagentRecords: [JSONValue] = []
    /// A workflow opening's coordinator row from the parent thread, once that projection loaded.
    var workflowCoordinator: JSONValue?
    /// Runs of this row's preparation failures that a Retry can prepare again.
    var retryRunIds: Set<RunId> = []
}

/// What MCP App rows ask of the environment (McpAppFrame.tsx: `mcpAppEnvironment`, `useTurnItemDetail`).
public struct McpAppActions {
    /// One RPC on the thread's environment (`mcpApps.callTool`, `toolInfo`, `readResource`, `updateModelContext`).
    public var request: @MainActor (String, JSONValue) async throws -> JSONValue
    /// The stored tool item (`orchestration.getTurnItem`): the wire timeline omits its input and output.
    public var turnItem: @MainActor (ThreadId, TurnItemId) async -> JSONValue?
    /// Sends a chat message from the app, or nil when messages are not available here.
    public var sendMessage: (@MainActor (String) async throws -> Void)?
    public init(request: @escaping @MainActor (String, JSONValue) async throws -> JSONValue,
                turnItem: @escaping @MainActor (ThreadId, TurnItemId) async -> JSONValue?,
                sendMessage: (@MainActor (String) async throws -> Void)?) {
        self.request = request; self.turnItem = turnItem; self.sendMessage = sendMessage
    }
}

/// An omitted tool output while its row is open (V2ItemInspector.tsx:149-175).
enum ToolOutputState: Hashable {
    /// "Loading output…"
    case loading
    /// "Couldn't load output: <message>"
    case failed(String)
    case fetched(TurnItemDetail.Fetched)
    case live(text: String, truncated: Bool, running: Bool)
}

/// One row as the timeline draws it.
struct TimelineItem: Hashable {
    var row: TimelineRow
    var ui = TimelineRowUI()
    var id: String { row.id }
}

/// The read-only thread: the projection, the expand and collapse state, and the rows derived from
/// both. Expansion lives here, not in the row views, so recycling a view never loses it.
@MainActor
public final class ThreadViewModel {
    public private(set) var projection: ThreadProjection?
    /// Shown in the breadcrumb.
    public var projectTitle = ""
    public var onEditPrompt: ((ChatMessage) -> Void)?
    /// Makes read paths workspace relative in labels and details.
    public var workspaceRoot: String?
    /// File chip clicks in messages (`MarkdownView.onOpenFile`); nil shows the chip's copy menu.
    public var openFile: ((FileLinkMeta, _ inEditor: Bool) -> Void)?
    /// "Run in terminal" on shell code blocks in finished assistant answers (ChatView.tsx:5105-5116, 11385).
    public var runShellCommand: ((String) -> Void)?
    /// A sent image at a pixel side (`assets.createUrl` for the attachment, decoded at that size).
    public var onOpenAttachment: ((JSONValue, _ download: Bool) -> Void)?
    public var attachmentMediaURL: (@Sendable (_ attachmentId: String) async -> URL?)?
    public var attachmentImage: (@Sendable (_ attachmentId: String, _ side: Int, _ cover: Bool) async -> CGImage?)?
    /// A click on a sent image: the message's images and the one clicked.
    public var onExpandImage: (([ExpandedImagePreviewView.Item], Int) -> Void)?

    /// Turn folds, superseded attempts and tool groups the user opened (row pass inputs).
    private var findOpenedRuns: Set<RunId> = []
    private var findOpenedAttempts: Set<RunAttemptId> = []
    private var findOpenedMessages: Set<String> = []
    private var expandedRunIds: Set<RunId> = []
    private var expandedAttemptIds: Set<RunAttemptId> = []
    private var expandedWorkGroupIds: Set<String> = []
    private var expandedEntries: Set<String> = []
    private var expandedMessages: Set<String> = []
    /// The parent thread's subagents while this thread opens with a workflow script (`useThreadProjection` of the
    /// parent, ChatView.tsx:1044-1060), nil until that projection loads. The opening block shows the workflow's plan.
    public var parentSubagents: [JSONValue]? {
        didSet { if parentSubagents != oldValue { refreshItems() } }
    }
    private var expandedPlans: Set<String> = []
    /// Per run, like T3's `threadChangedFilesExpandedById` (kept for the thread, not persisted).
    private var expandedChangedFiles: Set<RunId> = []
    /// Per run, folder path to open; cleared when the run's fold-all changes (ChangedFilesTree.tsx).
    private var folderOverrides: [RunId: [String: Bool]] = [:]
    private(set) var items: [TimelineItem] = []

    /// Rows changed; the panel re-applies them.
    var onChange: (@MainActor (TimelineChange) -> Void)?
    /// The changed files card asks for a run's diff, at a file (`onOpenTurnDiff`).
    public var onOpenTurnDiff: (@MainActor (RunId, String?) -> Void)?
    /// A signed URL for an attachment shown inline as HTML (`assets.createUrl`, `disposition: inline`).
    public var webAssetURL: (@MainActor (_ attachmentId: String, _ fileName: String) async -> URL?)?
    /// A link an HTML render asked to open, and whether Cmd or Ctrl was down: it opens like a chat link.
    public var onOpenWebLink: (@MainActor (URL, _ modified: Bool) -> Void)?
    /// An app shortcut a focused HTML render passed on (`t3/notifications/keydown`).
    public var onFrameShortcut: (@MainActor (KeyStroke) -> Void)?
    /// An error toast: title and message.
    public var showError: (@MainActor (String, String) -> Void)?
    /// Opens another thread of this environment by its local id (`onOpenThread`): a created thread's
    /// "Open chat", a subagent card, a fork divider, "Open thread".
    public var onOpenThread: (@MainActor (ThreadId) -> Void)?
    public var environmentId: String?
    /// A live, unarchived thread's title by local id (`threadReadTargetTitle`): `t3_thread_read` rows name it.
    public var threadTitle: (@MainActor (ThreadId) -> String?)?
    /// A thread this machine knows by local id, archived ones included (`useThreadShell`), with its project:
    /// thread chips and `t3-thread://` links show its title and project icon (ThreadContextChip.tsx:17-19).
    public var linkedThread: (@MainActor (ThreadId) -> MarkdownContextChips.LinkedThread?)?
    /// Folded agent rows' sender titles for one `apply` pass, since `linkedThread` searches every shell.
    private var foldTitles: [String: String?] = [:]
    /// "Open automation": Settings > Scheduled Tasks with that task's editor.
    public var onOpenScheduledTask: (@MainActor (String) -> Void)?
    /// The open thread's environment's scheduled task titles by id (`scheduledTasksLive`): folded automation rows show them.
    public var scheduledTaskTitles: [String: String] = [:] { didSet { if scheduledTaskTitles != oldValue { refreshItems() } } }
    public var mcpApp: McpAppActions?
    /// The environment's providers: handoff dividers name their models by them (V2LifecycleRow.tsx:592-640).
    public var providers: [ServerProvider] = [] {
        didSet {
            guard providers != oldValue else { return }
            for item in items {
                if case .event(let p, _, _) = item.row.kind, p.item.type == .handoff { refreshRow(item.id) }
            }
        }
    }
    private var webContentHeights: [String: Double] = [:]
    private var closedApps: Set<String> = []
    /// By attachment id, so the height outlives the row view and its web view.
    private var htmlHeights: [String: HtmlRenderHeights] = [:]

    /// An HTML render reported its height at a frame width; the row re-measures when it changed.
    func setHtmlRenderHeight(_ rowId: String, attachmentId: String, width: Double, _ height: Double) {
        guard htmlHeights[attachmentId, default: .init()].set(height, width: width) else { return }
        refreshRow(rowId)
    }

    /// A framed page or app reported its height; the row re-measures when it changed.
    func setWebContentHeight(_ rowId: String, _ height: Double) {
        guard webContentHeights[rowId] != height else { return }
        webContentHeights[rowId] = height
        refreshRow(rowId)
    }

    func setAppClosed(_ rowId: String, _ closed: Bool) {
        guard closedApps.contains(rowId) != closed else { return }
        if closed { closedApps.insert(rowId) } else { closedApps.remove(rowId) }
        refreshRow(rowId)
    }

    /// `secrets.answerRequest` with the input; nil on success, else the message the card shows.
    public var answerSecret: (@MainActor (JSONValue) async -> String?)?
    private var secretStates: [String: (submitting: Bool, error: String?)] = [:]

    /// Sends a secret request's answer; the row shows the progress and any error.
    func answerSecretRequest(_ rowId: String, _ input: JSONValue) {
        guard let answerSecret, secretStates[rowId]?.submitting != true else { return }
        secretStates[rowId] = (true, nil)
        refreshRow(rowId)
        Task { [weak self] in
            let failure = await answerSecret(input)
            guard let self else { return }
            self.secretStates[rowId] = failure.map { (false, $0) }
            self.refreshRow(rowId)
        }
    }

    private func refreshRow(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i] = item(items[i].row)
        onChange?(.rows([i]))
    }

    /// "Fork from this response" on an assistant message: its source thread (local id) and run.
    public var inlineSkills: [ServerProviderSkill] = []
    public var onCiteSelection: ((String, AssistantSelectionText, AssistantSelectionAnchor) -> Void)?
    /// The inspector's Roll back on a ready checkpoint (V2ItemInspector.tsx:367-386).
    public var onRollbackCheckpoint: (@MainActor (_ checkpointId: String, _ scopeId: String) -> Void)?

    /// `useV2ItemSupport`'s checkpoint status for a checkpoint id.
    func checkpointStatus(_ id: String) -> String? {
        projection?.checkpoints.first { $0.id.rawValue == id }?.status
    }

    /// An inspector button.
    func perform(_ action: WorkDetail.Action) {
        switch action {
        case .openDiff(let run, let path): onOpenTurnDiff?(run, path)
        case .rollBack(let checkpoint, let scope): onRollbackCheckpoint?(checkpoint, scope)
        case .openFork(let id), .openSubagent(let id): onOpenThread?(id)
        }
    }

    /// The plan card's Save to workspace: the export text and the suggested name (ProposedPlanCard.tsx:105-163).
    public var onSavePlanToWorkspace: (@MainActor (_ contents: String, _ filename: String) -> Void)?
    /// Retry on a failed workspace preparation: dispatches `prepared-run.retry` for the run.
    public var onRetryWorkspacePreparation: (@MainActor (RunId) -> Void)?
    public var onForkFromRun: (@MainActor (ThreadId, RunId) -> Void)?

    /// Runs `orchestration.getTurnItem` and resolves the result off the main thread. Nil (previews,
    /// tests) leaves omitted output unfetched.
    public typealias TurnItemLoader = @Sendable (GetTurnItemInput, TurnItemType) async throws -> TurnItemDetail.Fetched
    public var turnItemLoader: TurnItemLoader?
    public var commandOutputEnabled = false
    public var commandOutput: (@MainActor (String, String, @escaping @MainActor (Result<CommandOutputFrame, Error>) -> Void) -> Task<Void, Never>)?
    private var commandBuffers: [String: CommandOutputBuffer] = [:]
    private var liveCommandOutputs: [String: ToolOutputState] = [:]

    func receiveCommandOutput(_ id: String, _ result: Result<CommandOutputFrame, Error>) {
        switch result {
        case .success(let frame):
            var buffer = commandBuffers[id] ?? CommandOutputBuffer()
            buffer.apply(frame); commandBuffers[id] = buffer
            liveCommandOutputs[id] = .live(text: buffer.text, truncated: buffer.truncated, running: buffer.running)
        case .failure(let error): liveCommandOutputs[id] = .failed(error.localizedDescription)
        }
        refreshItems()
    }
    func forgetCommandOutput(_ id: String) { liveCommandOutputs[id] = nil; commandBuffers[id] = nil }

    /// Per entry id: the revision fetched (`TurnItemDetail.revision`) and its state.
    private var outputs: [String: (revision: String, state: ToolOutputState)] = [:]
    private var outputTasks: [String: Task<Void, Never>] = [:]
    /// T3 drops a result 60 s after the last open row lets go of it (`idleTtlMs`, state/orchestration.ts:47-53).
    var outputIdleTTL: Duration = .seconds(60)

    public init() {}

    /// The row passes of this thread; a new one per thread.
    private var pipeline = TimelinePipeline()
    /// The projection changed since the last row request.
    private var projectionDirty = false
    /// A row request running off the main thread, and whether another came in meanwhile.
    private(set) var rowsTask: Task<Void, Never>?
    private var rowsWanted = false
    /// Bumped when the thread changes, so a late result for the old thread is dropped.
    private var generation = 0
    /// The next rows belong to another thread than the ones shown (`TimelineChange.thread`).
    /// A new thread's rows are still deriving; the shown rows belong to the previous thread.
    private(set) var threadRowsPending = false
    /// Threads with at least this many visible rows update off the main thread. A full row pass
    /// over 5,700 rows takes about 30 ms and the incremental entry pass about 3 ms; below this
    /// both fit well inside a frame, and tests and small threads stay synchronous.
    // ponytail: a fixed count; time each pass and adapt if threads with heavy rows below it stutter
    var backgroundRowsThreshold = 1_500
    /// Main-thread milliseconds spent applying rows that were derived off the main thread, since
    /// the last `rowsSettled()` (benchmarks).
    private var offMainApplyCost: Double = 0

    /// Visit marks do not change the timeline or panel chrome (T3 ee33c4c65,
    /// packages/client-runtime/src/state/threadDetail.ts:82-87, 128-159).
    /// Keep the live read state without deriving rows again. Compare every other field so a
    /// visit batched with a real update still takes the normal path.
    func acceptReadState(_ next: ThreadProjection?) -> Bool {
        guard let next, let previous = projection,
              case .object(var before) = previous.thread.raw,
              case .object(var after) = next.thread.raw else { return false }
        for key in ["lastVisitedAt", "updatedAt"] { before[key] = nil; after[key] = nil }
        guard before == after else { return false }
        var comparable = next
        comparable.thread = previous.thread
        guard comparable == previous else { return false }
        projection = next
        return true
    }

    /// Counts projection derivations, including requests coalesced behind an active pass.
    private(set) var projectionDerivationCount = 0

    /// Replaces the projection (nil clears the view) and re-derives the rows that changed.
    public func setProjection(_ projection: ThreadProjection?) {
        if projection == nil, self.projection == nil { return }
        let subagentsChanged = projection?.subagents != self.projection?.subagents
        let threadChanged = projection?.thread.id != self.projection?.thread.id
        self.projection = projection
        if threadChanged {
            pipeline = TimelinePipeline()
            generation += 1
            rowsTask = nil
            rowsWanted = false
            threadRowsPending = true
            findOpenedRuns = []; findOpenedAttempts = []; findOpenedMessages = []
            expandedRunIds = []; expandedAttemptIds = []; expandedWorkGroupIds = []
            expandedEntries = []; expandedMessages = []; expandedPlans = []
            expandedChangedFiles = []; folderOverrides = [:]
            dropOutputs()
        }
        projectionDerivationCount += 1
        projectionDirty = true
        derive()
        if subagentsChanged && !threadChanged {
            var changed: [Int] = []
            for i in items.indices {
                switch items[i].row.kind {
                case .event(let p, _, _) where p.item.type == .subagent: break
                case .work(let entries, _, _) where entries.contains(where: { SubagentCardPresentation.notificationChild($0) != nil }): break
                default: continue
                }
                let next = item(items[i].row)
                if next != items[i] { items[i] = next; changed.append(i) }
            }
            if !changed.isEmpty { onChange?(.rows(changed)) }
        }
    }

    /// Waits for a row request running off the main thread. Returns the main-thread milliseconds
    /// spent applying such results since the last call (benchmarks and tests).
    @discardableResult func rowsSettled() async -> Double {
        while let task = rowsTask { await task.value }
        defer { offMainApplyCost = 0 }
        return offMainApplyCost
    }

    /// Opens only the folds containing the server-selected match, preserving other folds.
    public func prepareThreadFind(_ match: ThreadFindResult.Match) {
        var changed = false
        if let run = match.runId.map { RunId($0) } {
            changed = expandedRunIds.insert(run).inserted
            if changed { findOpenedRuns.insert(run) }
            // Work after a steer folds under `<run>:steer:<entry>` (a8bb769d65).
            // ponytail: opens every steer segment of the run; map entries to their fold like `timelineTurnFoldRunIdsByEntryId` if that shows.
            for item in items {
                guard case .turnFold(let fold, _, _) = item.row.kind, fold.rawValue.hasPrefix("\(run.rawValue):steer:") else { continue }
                if expandedRunIds.insert(fold).inserted { findOpenedRuns.insert(fold); changed = true }
            }
            for attempt in projection?.attempts ?? [] where attempt.runId == run {
                if expandedAttemptIds.insert(attempt.id).inserted { findOpenedAttempts.insert(attempt.id); changed = true }
            }
        }
        if changed { derive() }
        if let row = items.first(where: { $0.id == match.entryId }), let message = row.row.message,
           expandedMessages.insert(message.id.rawValue).inserted { findOpenedMessages.insert(message.id.rawValue); refreshItems() }
    }

    public func closeThreadFind() {
        let changed = !findOpenedRuns.isEmpty || !findOpenedAttempts.isEmpty || !findOpenedMessages.isEmpty
        expandedRunIds.subtract(findOpenedRuns); expandedAttemptIds.subtract(findOpenedAttempts); expandedMessages.subtract(findOpenedMessages)
        findOpenedRuns = []; findOpenedAttempts = []; findOpenedMessages = []
        if changed { derive(); refreshItems() }
    }

    func toggleRun(_ id: RunId) { findOpenedRuns.remove(id); expandedRunIds.formSymmetricDifference([id]); derive() }
    func toggleAttempt(_ id: RunAttemptId) { findOpenedAttempts.remove(id); expandedAttemptIds.formSymmetricDifference([id]); derive() }
    func toggleGroup(_ id: String) { expandedWorkGroupIds.formSymmetricDifference([id]); derive() }
    func toggleEntry(_ id: String) {
        expandedEntries.formSymmetricDifference([id])
        if !expandedEntries.contains(id), outputs[id] != nil { scheduleEviction(id) }
        refreshItems()
    }
    func toggleMessage(_ id: String) { findOpenedMessages.remove(id); expandedMessages.formSymmetricDifference([id]); refreshItems() }
    func togglePlan(_ id: String) { expandedPlans.formSymmetricDifference([id]); refreshItems() }
    func toggleChangedFiles(_ run: RunId) {
        expandedChangedFiles.formSymmetricDifference([run])
        folderOverrides[run] = nil
        refreshItems()
    }
    func toggleChangedFolder(_ run: RunId, _ path: String) {
        folderOverrides[run, default: [:]][path] = !(folderOverrides[run]?[path] ?? expandedChangedFiles.contains(run))
        refreshItems()
    }

    /// Sent user messages the stream hasn't confirmed yet (`optimisticMessages`, ChatView.tsx:9763-9784).
    /// Shown after the server's rows until the projection carries their id; queued ones stay hidden
    /// (session-logic.ts:792-802).
    public var optimisticMessages: [ChatMessage] = [] {
        didSet { if optimisticMessages != oldValue { derive() } }
    }

    /// Asks the pipeline for rows of the current state. Long threads run it off the main thread,
    /// one request at a time: what arrives meanwhile waits, and only the newest state runs next.
    private func derive() {
        if rowsTask != nil { rowsWanted = true; return }
        var pending: [ChatMessage] = []
        if !optimisticMessages.isEmpty {
            let confirmed = TimelineEntries.acknowledgedUserMessageIds(projection)
            pending = optimisticMessages.filter { $0.inputIntent != .queuedTurn && !confirmed.contains($0.id) }
        }
        let request = TimelinePipeline.Request(
            projection: projection, projectionChanged: projectionDirty, expandedRunIds: expandedRunIds,
            expandedAttemptIds: expandedAttemptIds, expandedWorkGroupIds: expandedWorkGroupIds, pending: pending)
        projectionDirty = false
        let pipeline = self.pipeline
        guard (projection?.visibleTurnItems.count ?? 0) >= backgroundRowsThreshold else {
            if let result = pipeline.run(request) { apply(rows: result.rows, change: result.change) }
            return
        }
        let generation = self.generation
        rowsTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = pipeline.run(request)
            await self?.finishRows(result, generation: generation)
        }
    }

    private func finishRows(_ result: TimelinePipeline.Result?, generation: Int) {
        guard generation == self.generation else { return }
        rowsTask = nil
        if let result {
            let start = ContinuousClock.now
            apply(rows: result.rows, change: result.change)
            offMainApplyCost += OpenTiming.ms(ContinuousClock.now - start)
        }
        if rowsWanted {
            rowsWanted = false
            derive()
        }
    }

    /// The UI state changed but the rows did not.
    private func refreshItems() {
        // The shown rows are the last thread's until the new ones derive; those pick up this state then (audit TH-2).
        guard !threadRowsPending else { return }
        apply(rows: items.map(\.row), change: .all)
    }

    /// Hands rows to the view with their UI state; `change` says which differ from `items`.
    private func apply(rows: [TimelineRow], change: TimelineChange) {
        foldTitles = [:]
        var change = change
        if threadRowsPending { threadRowsPending = false; change = .thread }
        switch change {
        case .rows(let changed) where rows.count == items.count:
            for i in changed { items[i] = item(rows[i]) }
        case .tail(let first) where first <= items.count && first <= rows.count:
            items.removeSubrange(first...)
            items += rows[first...].map(item)
        case .head(let replaced, let inserted) where replaced <= items.count && items.count - replaced == rows.count - inserted:
            items.replaceSubrange(0..<replaced, with: rows[..<inserted].map(item))
        default:
            items = rows.map(item)
        }
        OpenTiming.measure("timeline apply", "\(items.count) rows") { onChange?(change) }
    }
    func item(_ row: TimelineRow) -> TimelineItem {
        var ui = TimelineRowUI()
        switch row.kind {
        case .work(let entries, _, _):
            for e in entries where !expandedEntries.isEmpty && expandedEntries.contains(e.id) {
                ui.expandedEntries.insert(e.id)
                if let state = output(for: e) { ui.outputs[e.id] = state }
            }
            for e in entries { if let run = retryablePreparationRun(e) { ui.retryRunIds.insert(run) } }
            let children = Set(entries.compactMap(SubagentCardPresentation.notificationChild))
            if !children.isEmpty {
                ui.subagentRecords = projection?.subagents.filter { children.contains($0["childThreadId"]?.stringValue ?? "") } ?? []
            }
        case .workLive(_, _, _, _, _, let thought?) where expandedEntries.contains(thought.id):
            ui.expandedEntries = [thought.id]
        case .message(let m, _, _, _, _, let summary):
            ui.messageExpanded = !expandedMessages.isEmpty && expandedMessages.contains(m.id.rawValue)
            if m.role == .user, m.createdBy == "agent" || m.scheduledTaskId != nil || m.text.hasPrefix("[Triggered by schedule task: ") {
                let p = UserMessagePresentation.resolve(m)
                switch p.attribution {
                case .automation: ui.foldTitle = p.scheduledTaskId.flatMap { scheduledTaskTitles[$0] }
                case .agent:
                    ui.foldTitle = m.senderThreadId.flatMap { id in
                        if let title = foldTitles[id] { return title }
                        let title = linkedThread?(ThreadId(id))?.title
                        foldTitles[id] = .some(title)
                        return title
                    }
                default: break
                }
            }
            if m.workflowOpening, let parentSubagents, let thread = projection?.thread.id {
                ui.workflowCoordinator = WorkflowOpening.Plan.coordinator(of: thread, in: parentSubagents)
            }
            if let run = summary?.runId {
                ui.filesExpanded = expandedChangedFiles.contains(run)
                ui.folderOverrides = folderOverrides[run] ?? [:]
            }
        case .proposedPlan(let p): ui.planExpanded = expandedPlans.contains(p.id.rawValue)
        case .event(let p, _, _) where p.item.type == .secretRequest:
            if let state = secretStates[row.id] { ui.secretSubmitting = state.submitting; ui.secretError = state.error }
        case .event(let p, let group, _) where p.item.type == .subagent:
            let ids = Set((group ?? [p]).compactMap { $0.string("subagentId") })
            ui.subagentRecords = projection?.subagents.filter { ids.contains($0["id"]?.stringValue ?? "") } ?? []
        case .htmlRender(let page):
            ui.htmlHeights = htmlHeights[page.attachmentId] ?? .init()
        case .mcpApp:
            ui.webContentHeight = webContentHeights[row.id]
            ui.appClosed = closedApps.contains(row.id)
        default: break
        }
        return TimelineItem(row: row, ui: ui)
    }
    /// `workspacePreparationRetryRunIds` for one entry (turnItemPresentation.ts:27-49): a failed preparation
    /// error whose run failed there and recorded its preparation. Older servers record none, so no Retry.
    private func retryablePreparationRun(_ e: WorkLogEntry) -> RunId? {
        guard let item = e.projectedItem?.item, item.type == .error, item.status == .failed,
              item["failure"]?["code"]?.stringValue == "workspace_preparation_failed", let runId = item.runId,
              let run = projection?.runs.first(where: { $0.id == runId }),
              run.status.rawValue == "failed", run.workspacePreparation != nil else { return nil }
        return runId
    }

    // MARK: Omitted tool output

    /// The output state of an open entry. Starts a fetch when the stream left its output out and
    /// this revision isn't fetched yet: on expand, and again when a live item settles.
    private func output(for e: WorkLogEntry) -> ToolOutputState? {
        if commandOutputEnabled, e.itemType == .commandExecution { return liveCommandOutputs[e.id] ?? .loading }
        guard let row = e.projectedItem, TurnItemDetail.needsFetch(row.item) else { return nil }
        let request = TurnItemDetail.request(row)
        let revision = request.revision ?? ""
        if let cached = outputs[e.id], cached.revision == revision { return cached.state }
        guard let loader = turnItemLoader else { return nil }
        outputs[e.id] = (revision, .loading)
        outputTasks[e.id]?.cancel()
        let id = e.id, wireType = row.item.type
        outputTasks[id] = Task { [weak self] in
            let state: ToolOutputState
            do { state = .fetched(try await loader(request, wireType)) }
            catch is CancellationError { return }
            catch {
                // `formatEnvironmentQueryError` (apps/web/src/state/query.ts:20-25).
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                state = .failed(message.isEmpty ? "The environment request failed." : message)
            }
            guard let self, !Task.isCancelled, self.outputs[id]?.revision == revision else { return }
            self.outputs[id] = (revision, state)
            self.outputTasks[id] = nil
            self.refreshItems()
        }
        return .loading
    }

    /// Whether the model still holds an output for the entry, fetched or loading.
    func holdsOutput(_ id: String) -> Bool { outputs[id] != nil }

    private func scheduleEviction(_ id: String) {
        let ttl = outputIdleTTL
        Task { [weak self] in
            try? await Task.sleep(for: ttl)
            guard let self, !self.expandedEntries.contains(id) else { return }
            self.outputs[id] = nil
            self.outputTasks.removeValue(forKey: id)?.cancel()
        }
    }

    private func dropOutputs() {
        liveCommandOutputs = [:]; commandBuffers = [:]
        outputTasks.values.forEach { $0.cancel() }
        outputTasks = [:]
        outputs = [:]
    }
}
