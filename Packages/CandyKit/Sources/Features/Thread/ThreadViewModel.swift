import CoreGraphics
import Foundation
import T3Protocol
import T3Store

/// View state of one row that the row pass doesn't know about. It travels with the row so a
/// recycled view shows the same thing, and it is part of the measured-height cache key.
struct TimelineRowUI: Hashable {
    /// Work log entries (and thoughts) whose details are open, limited to this row's entries.
    var expandedEntries: Set<String> = []
    /// A long user message shows in full.
    var messageExpanded = false
    /// A long plan shows in full.
    var planExpanded = false
    /// The changed files card's fold-all state and the folders toggled since.
    var filesExpanded = false
    var folderOverrides: [String: Bool] = [:]
    /// Fetched output of this row's open entries whose output the stream left out.
    var outputs: [String: ToolOutputState] = [:]
}

/// An omitted tool output while its row is open (V2ItemInspector.tsx:149-175).
enum ToolOutputState: Hashable {
    /// "Loading output…"
    case loading
    /// "Couldn't load output: <message>"
    case failed(String)
    case fetched(TurnItemDetail.Fetched)
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
    /// Makes read paths workspace relative in labels and details.
    public var workspaceRoot: String?
    /// File chip clicks in messages (`MarkdownView.onOpenFile`); nil shows the chip's copy menu.
    // ponytail: unwired; the app sets it once the files panel and open-in-editor exist
    public var openFile: ((FileLinkMeta, _ inEditor: Bool) -> Void)?
    /// A sent image at a pixel side (`assets.createUrl` for the attachment, decoded at that size).
    public var attachmentImage: (@Sendable (_ attachmentId: String, _ side: Int, _ cover: Bool) async -> CGImage?)?
    /// A click on a sent image: the message's images and the one clicked.
    public var onExpandImage: (([ExpandedImagePreviewView.Item], Int) -> Void)?

    /// Turn folds, superseded attempts and tool groups the user opened (row pass inputs).
    private var expandedRunIds: Set<RunId> = []
    private var expandedAttemptIds: Set<RunAttemptId> = []
    private var expandedWorkGroupIds: Set<String> = []
    private var expandedEntries: Set<String> = []
    private var expandedMessages: Set<String> = []
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

    /// Runs `orchestration.getTurnItem` and resolves the result off the main thread. Nil (previews,
    /// tests) leaves omitted output unfetched.
    public typealias TurnItemLoader = @Sendable (GetTurnItemInput, TurnItemType) async throws -> TurnItemDetail.Fetched
    public var turnItemLoader: TurnItemLoader?
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
    private var rowsTask: Task<Void, Never>?
    private var rowsWanted = false
    /// Bumped when the thread changes, so a late result for the old thread is dropped.
    private var generation = 0
    /// Threads with at least this many visible rows update off the main thread. A full row pass
    /// over 5,700 rows takes about 30 ms and the incremental entry pass about 3 ms; below this
    /// both fit well inside a frame, and tests and small threads stay synchronous.
    // ponytail: a fixed count; time each pass and adapt if threads with heavy rows below it stutter
    var backgroundRowsThreshold = 1_500
    /// Main-thread milliseconds spent applying rows that were derived off the main thread, since
    /// the last `rowsSettled()` (benchmarks).
    private var offMainApplyCost: Double = 0

    /// Replaces the projection (nil clears the view) and re-derives the rows that changed.
    public func setProjection(_ projection: ThreadProjection?) {
        if projection == nil, self.projection == nil { return }
        let threadChanged = projection?.thread.id != self.projection?.thread.id
        self.projection = projection
        if threadChanged {
            pipeline = TimelinePipeline()
            generation += 1
            rowsTask = nil
            rowsWanted = false
            expandedRunIds = []; expandedAttemptIds = []; expandedWorkGroupIds = []
            expandedEntries = []; expandedMessages = []; expandedPlans = []
            expandedChangedFiles = []; folderOverrides = [:]
            dropOutputs()
        }
        projectionDirty = true
        derive()
    }

    /// Waits for a row request running off the main thread. Returns the main-thread milliseconds
    /// spent applying such results since the last call (benchmarks and tests).
    @discardableResult func rowsSettled() async -> Double {
        while let task = rowsTask { await task.value }
        defer { offMainApplyCost = 0 }
        return offMainApplyCost
    }

    func toggleRun(_ id: RunId) { expandedRunIds.formSymmetricDifference([id]); derive() }
    func toggleAttempt(_ id: RunAttemptId) { expandedAttemptIds.formSymmetricDifference([id]); derive() }
    func toggleGroup(_ id: String) { expandedWorkGroupIds.formSymmetricDifference([id]); derive() }
    func toggleEntry(_ id: String) {
        expandedEntries.formSymmetricDifference([id])
        if !expandedEntries.contains(id), outputs[id] != nil { scheduleEviction(id) }
        refreshItems()
    }
    func toggleMessage(_ id: String) { expandedMessages.formSymmetricDifference([id]); refreshItems() }
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
            let confirmed = Set(projection?.messages.map(\.id) ?? [])
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
        apply(rows: items.map(\.row), change: .all)
    }

    /// Hands rows to the view with their UI state; `change` says which differ from `items`.
    private func apply(rows: [TimelineRow], change: TimelineChange) {
        switch change {
        case .rows(let changed) where rows.count == items.count:
            for i in changed { items[i] = item(rows[i]) }
        case .tail(let first) where first <= items.count && first <= rows.count:
            items.removeSubrange(first...)
            items += rows[first...].map(item)
        default:
            items = rows.map(item)
        }
        OpenTiming.measure("timeline apply", "\(items.count) rows") { onChange?(change) }
    }
    private func item(_ row: TimelineRow) -> TimelineItem {
        var ui = TimelineRowUI()
        switch row.kind {
        case .work(let entries, _, _) where !expandedEntries.isEmpty:
            for e in entries where expandedEntries.contains(e.id) {
                ui.expandedEntries.insert(e.id)
                if let state = output(for: e) { ui.outputs[e.id] = state }
            }
        case .workLive(_, _, _, _, _, let thought?) where expandedEntries.contains(thought.id):
            ui.expandedEntries = [thought.id]
        case .message(let m, _, _, _, _, let summary):
            ui.messageExpanded = !expandedMessages.isEmpty && expandedMessages.contains(m.id.rawValue)
            if let run = summary?.runId {
                ui.filesExpanded = expandedChangedFiles.contains(run)
                ui.folderOverrides = folderOverrides[run] ?? [:]
            }
        case .proposedPlan(let p): ui.planExpanded = expandedPlans.contains(p.id.rawValue)
        default: break
        }
        return TimelineItem(row: row, ui: ui)
    }
    // MARK: Omitted tool output

    /// The output state of an open entry. Starts a fetch when the stream left its output out and
    /// this revision isn't fetched yet: on expand, and again when a live item settles.
    private func output(for e: WorkLogEntry) -> ToolOutputState? {
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
        outputTasks.values.forEach { $0.cancel() }
        outputTasks = [:]
        outputs = [:]
    }
}
