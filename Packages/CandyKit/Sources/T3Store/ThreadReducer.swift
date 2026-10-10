import T3Protocol

/// `ThreadHistoryMeta` (packages/client-runtime/src/state/threadHistoryMerge.ts:7-28): the paging
/// state of a bounded window.
public struct ThreadHistoryMeta: Sendable, Equatable {
    public var historyCursor: String?
    public var hasMoreHistory = false
    public var loading = false
    public var error: String?
    /// True after at least one older page was merged.
    public var expanded = false
    /// Max local turn ordinal known for a partial window; nil when unknown.
    public var latestLocalTurnOrdinal: Int?

    public init(historyCursor: String? = nil, hasMoreHistory: Bool = false, latestLocalTurnOrdinal: Int? = nil) {
        self.historyCursor = historyCursor
        self.hasMoreHistory = hasMoreHistory
        self.latestLocalTurnOrdinal = latestLocalTurnOrdinal
    }

    /// `shouldShowLoadEarlierControl` (threadHistoryMerge.ts:152-154).
    public var showsLoadEarlierControl: Bool { hasMoreHistory || error != nil }

    /// The window is incomplete, so events for items outside it may be dropped (threads.ts:500-507).
    var isPartial: Bool { hasMoreHistory || historyCursor != nil }
}

/// `EnvironmentThreadState.status` (RT/threadState.ts:6), minus the cache states the app owns.
public enum ThreadSyncStatus: Sendable, Equatable {
    case empty, synchronizing, live, deleted
}

/// What one batch of thread items changed.
public struct ThreadChangeSet: Sendable, Equatable {
    /// The projection differs from before the batch.
    public var projectionChanged = false
    /// A snapshot replaced the projection, so row identity may not carry over.
    public var reset = false
    public var historyChanged = false
    public var synchronized = false
    public var deleted = false

    public init() {}

    public var isEmpty: Bool { !projectionChanged && !reset && !historyChanged && !synchronized && !deleted }

    public mutating func merge(_ later: ThreadChangeSet) {
        projectionChanged = projectionChanged || later.projectionChanged
        reset = reset || later.reset
        historyChanged = historyChanged || later.historyChanged
        synchronized = synchronized || later.synchronized
        deleted = deleted || later.deleted
    }
}

/// Ports of T3's pure thread projection functions
/// (packages/client-runtime/src/state/orchestrationV2Projection.ts,
/// packages/shared/src/orchestrationV2Timeline.ts, threadHistoryMerge.ts).
public enum ThreadReduction {
    // MARK: Visibility (orchestrationV2Timeline.ts:42-112)

    /// Port of `createOrchestrationV2TurnItemVisibility`: rolled-back runs hide their items, a
    /// cancelled queued message never shows, and a superseded attempt's interrupt result hides
    /// unless its run also has an interrupt request.
    static func visibility(runs: [Run], attempts: [RunAttempt], items: [TurnItem]) -> (TurnItem) -> Bool {
        let statuses = Dictionary(runs.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last })
        var supersededRoots: [RunId: Set<NodeId>] = [:]
        for attempt in attempts where attempt.status == "superseded" {
            supersededRoots[attempt.runId, default: []].insert(attempt.rootNodeId)
        }
        let interruptRuns = Set(items.filter { $0.type == .runInterruptRequest }.map(\.runId))
        return { item in
            let status = item.runId.flatMap { statuses[$0] }
            if status == .rolledBack { return false }
            if status == .cancelled, item.type == .userMessage, item.inputIntent == .queuedTurn { return false }
            if item.type == .runInterruptResult, let runId = item.runId, let nodeId = item.nodeId,
                supersededRoots[runId]?.contains(nodeId) == true, !interruptRuns.contains(runId)
            {
                return false
            }
            return true
        }
    }

    static func isVisible(_ item: TurnItem, in projection: ThreadProjection) -> Bool {
        visibility(runs: projection.runs, attempts: projection.attempts, items: projection.turnItems)(item)
    }

    static func renumbered(_ rows: [ProjectedTurnItem]) -> [ProjectedTurnItem] {
        var rows = rows
        for index in rows.indices where rows[index].position != index { rows[index].position = index }
        return rows
    }

    /// Port of `activeVisibleTurnItems`: drops local rows that became invisible.
    static func activeVisibleTurnItems(_ projection: ThreadProjection) -> [ProjectedTurnItem] {
        let isVisible = visibility(runs: projection.runs, attempts: projection.attempts, items: projection.turnItems)
        let kept = projection.visibleTurnItems.filter { !$0.isLocal || isVisible($0.item) }
        return kept.count == projection.visibleTurnItems.count ? projection.visibleTurnItems : renumbered(kept)
    }

    /// Port of `shouldDropMissingPartialTurnItem`: in a partial window, an item that isn't in
    /// the window and is older than its watermark belongs to unloaded history.
    static func shouldDropMissingPartialTurnItem(_ projection: ThreadProjection, _ item: TurnItem, latestLocalTurnOrdinal: Int?) -> Bool {
        if projection.visibleTurnItems.contains(where: { $0.sourceItemId == item.id }) { return false }
        if let watermark = latestLocalTurnOrdinal, item.ordinal <= watermark { return true }
        let oldest = projection.visibleTurnItems.filter(\.isLocal).map(\.item.ordinal).min()
        return oldest.map { item.ordinal < $0 } ?? false
    }

    /// Port of `upsertVisibleTurnItem`: local rows stay ordered by `(ordinal, id)`.
    static func upsertVisibleTurnItem(_ projection: ThreadProjection, _ item: TurnItem, partial: Bool, latestLocalTurnOrdinal: Int?) -> [ProjectedTurnItem] {
        let rows = projection.visibleTurnItems
        let index = rows.firstIndex { $0.sourceItemId == item.id }
        let next = ProjectedTurnItem(local: item)
        if let index, rows[index].isLocal, rows[index].sourceThreadId == next.sourceThreadId, rows[index].item == item {
            return rows
        }
        if index == nil, partial, shouldDropMissingPartialTurnItem(projection, item, latestLocalTurnOrdinal: latestLocalTurnOrdinal) {
            return rows
        }
        var updated = rows
        if let index { updated.remove(at: index) }
        let insertion = updated.firstIndex {
            $0.isLocal && ($0.item.ordinal > item.ordinal || ($0.item.ordinal == item.ordinal && $0.item.id.rawValue > item.id.rawValue))
        }
        updated.insert(next, at: insertion ?? updated.endIndex)
        return renumbered(updated)
    }

    static func upsert<T: Identifiable>(_ list: inout [T], _ value: T) {
        if let index = list.firstIndex(where: { $0.id == value.id }) { list[index] = value } else { list.append(value) }
    }

    static func upsertJSON(_ list: inout [JSONValue], _ value: JSONValue) {
        let id = value["id"]
        if let id, let index = list.firstIndex(where: { $0["id"] == id }) { list[index] = value } else { list.append(value) }
    }

    /// Port of `applyOrchestrationV2ProjectionEvent` (orchestrationV2Projection.ts:152-286).
    /// Returns nil (no change) for another thread's event and for a partial-window item that
    /// belongs to unloaded history.
    public static func apply(
        _ projection: ThreadProjection, _ event: ThreadEvent, partial: Bool = false, latestLocalTurnOrdinal: Int? = nil
    ) -> ThreadProjection? {
        guard event.threadId == projection.thread.id else { return nil }
        var next = projection
        next.updatedAt = event.occurredAt
        switch event.payload {
        case .thread(let thread):
            // Visited tracking is read state, not activity: no updatedAt bump.
            if event.type == .threadVisited || event.type == .threadMarkedUnread { next.updatedAt = projection.updatedAt }
            next.thread = thread
        case .run(let run):
            upsert(&next.runs, run)
            next.visibleTurnItems = activeVisibleTurnItems(next)
        case .attempt(let attempt):
            upsert(&next.attempts, attempt)
            next.visibleTurnItems = activeVisibleTurnItems(next)
        case .node(let node): upsert(&next.nodes, node)
        case .runtimeRequest(let request): upsert(&next.runtimeRequests, request)
        case .message(let message): upsert(&next.messages, message)
        case .plan(let plan): upsert(&next.plans, plan)
        case .checkpoint(let checkpoint): upsert(&next.checkpoints, checkpoint)
        case .turnItem(let item):
            if partial, !projection.turnItems.contains(where: { $0.id == item.id }),
                shouldDropMissingPartialTurnItem(projection, item, latestLocalTurnOrdinal: latestLocalTurnOrdinal)
            {
                return nil
            }
            let previous = projection.turnItems.first { $0.id == item.id }
            upsert(&next.turnItems, item)
            // Only interrupt requests can change another item's visibility.
            if item.type == .runInterruptRequest || previous?.type == .runInterruptRequest {
                next.visibleTurnItems = activeVisibleTurnItems(next)
            }
            if isVisible(item, in: next) {
                next.visibleTurnItems = upsertVisibleTurnItem(next, item, partial: partial, latestLocalTurnOrdinal: latestLocalTurnOrdinal)
            } else if let index = next.visibleTurnItems.firstIndex(where: { $0.sourceItemId == item.id }) {
                next.visibleTurnItems.remove(at: index)
                next.visibleTurnItems = renumbered(next.visibleTurnItems)
            }
        case .json(let payload):
            switch event.type {
            case .subagentUpdated: upsertJSON(&next.subagents, payload)
            case .providerSessionAttached, .providerSessionUpdated: upsertJSON(&next.providerSessions, payload)
            case .providerSessionDetached:
                next.providerSessions.removeAll { $0["id"] == payload["providerSessionId"] }
            case .providerThreadUpdated: upsertJSON(&next.providerThreads, payload)
            case .providerTurnUpdated:
                // Keep the previous token usage when the update omits it.
                var turn = payload
                if turn["tokenUsage"] == nil, case .object(var fields) = turn,
                    let usage = next.providerTurns.first(where: { $0["id"] == payload["id"] })?["tokenUsage"]
                {
                    fields["tokenUsage"] = usage
                    turn = .object(fields)
                }
                upsertJSON(&next.providerTurns, turn)
            case .runBackgroundWorkCancelled:
                if let runId = payload["runId"]?.stringValue, let index = next.runs.firstIndex(where: { $0.id.rawValue == runId }) {
                    next.runs[index].restartCancelledBackgroundWork = payload["restartCancelledBackgroundWork"]
                }
            case .checkpointScopeCreated: upsertJSON(&next.checkpointScopes, payload)
            case .contextHandoffUpdated: upsertJSON(&next.contextHandoffs, payload)
            case .contextTransferCreated, .contextTransferUpdated: upsertJSON(&next.contextTransfers, payload)
            default: break // checkpoint.rollback-requested only bumps updatedAt.
            }
        }
        return next
    }

    // MARK: History pages (threadHistoryMerge.ts:62-149)

    /// Port of `mergeOlderHistoryIntoProjection`: dedupes by `sourceThreadId:sourceItemId`, keeps
    /// live values of rows already present, prepends the page in server order and renumbers.
    public static func mergeOlderHistory(_ projection: ThreadProjection, _ olderItems: [ProjectedTurnItem]) -> ThreadProjection {
        guard !olderItems.isEmpty else { return projection }
        func key(_ row: ProjectedTurnItem) -> String { "\(row.sourceThreadId.rawValue):\(row.sourceItemId.rawValue)" }
        let threadId = projection.thread.id
        let currentByKey = Dictionary(projection.visibleTurnItems.map { (key($0), $0) }, uniquingKeysWith: { _, last in last })
        var turnItemOrder = projection.turnItems.map(\.id)
        var turnItemById = Dictionary(projection.turnItems.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var pageKeys = Set<String>()
        var page: [ProjectedTurnItem] = []
        for pageRow in olderItems {
            let k = key(pageRow)
            if pageKeys.contains(k) { continue }
            var row = currentByKey[k] ?? pageRow
            let rowIsLocal = row.isLocal || row.sourceThreadId == threadId
            if currentByKey[k] == nil, rowIsLocal, let currentItem = turnItemById[row.sourceItemId] {
                // Hidden live items stay hidden; paging may reveal retained interrupt requests.
                guard currentItem.type == .runInterruptRequest, isVisible(currentItem, in: projection) else { continue }
                row.item = currentItem
            }
            pageKeys.insert(k)
            page.append(row)
            if rowIsLocal, turnItemById[row.sourceItemId] == nil {
                turnItemById[row.sourceItemId] = row.item
                turnItemOrder.append(row.sourceItemId)
            }
        }
        guard !page.isEmpty else { return projection }
        let visible = page + projection.visibleTurnItems.filter { !pageKeys.contains(key($0)) }
        if visible == projection.visibleTurnItems { return projection }
        var merged = projection
        merged.turnItems = turnItemOrder.compactMap { turnItemById[$0] }
        merged.visibleTurnItems = renumbered(visible)
        return merged
    }
}

/// The thread stream reducer: a snapshot, then events, deduped by store sequence. Pure and
/// synchronous; `ThreadStore` wraps it for concurrency. Port of the apply path in
/// packages/client-runtime/src/state/threads.ts:438-612.
public struct ThreadReducer: Sendable {
    public let threadId: ThreadId
    public private(set) var projection: ThreadProjection?
    /// The resume cursor for `subscribeThread`: the highest sequence applied or skipped.
    public private(set) var lastSequence: Int?
    public private(set) var history = ThreadHistoryMeta()
    public private(set) var status: ThreadSyncStatus = .empty

    public init(threadId: ThreadId) {
        self.threadId = threadId
    }

    /// Applies a batch in arrival order and returns what changed.
    @discardableResult
    public mutating func apply<S: Sequence>(_ items: S) -> ThreadChangeSet where S.Element == ThreadStreamItem {
        var changes = ThreadChangeSet()
        for item in items {
            guard status != .deleted else { break }
            switch item {
            case .synchronized:
                if projection != nil {
                    status = .live
                    changes.synchronized = true
                }
            case .snapshot(let snapshot):
                changes.merge(applySnapshot(snapshot))
            case .event(let sequence, let event):
                guard advance(to: sequence) else { continue }
                changes.merge(applyEvent(event))
            case .unknownEvent(let sequence, _), .unknown(_, let sequence?):
                // An event from a newer server still moves the resume cursor past it.
                _ = advance(to: sequence)
            case .unknown(_, nil):
                break
            }
        }
        return changes
    }

    /// Seeds or resets the thread from a snapshot (socket `snapshot` item or the HTTP bounded
    /// snapshot). Progressive history meta comes with it; a legacy full snapshot clears it.
    @discardableResult
    public mutating func applySnapshot(_ snapshot: ThreadDetailSnapshot) -> ThreadChangeSet {
        var changes = ThreadChangeSet()
        guard status != .deleted else { return changes }
        lastSequence = snapshot.snapshotSequence
        projection = snapshot.restoringLocalVisibleTurnItems()
        history = snapshot.hasProgressiveHistory
            ? ThreadHistoryMeta(
                historyCursor: snapshot.historyCursor.value, hasMoreHistory: snapshot.hasMoreHistory ?? false,
                latestLocalTurnOrdinal: snapshot.latestLocalTurnOrdinal.value)
            : ThreadHistoryMeta()
        if status == .empty { status = .synchronizing }
        changes.projectionChanged = true
        changes.reset = true
        changes.historyChanged = true
        return changes
    }

    /// Dedupe by sequence: false for a replayed or stale item.
    private mutating func advance(to sequence: Int) -> Bool {
        if let last = lastSequence, sequence <= last { return false }
        lastSequence = sequence
        return true
    }

    private mutating func applyEvent(_ event: ThreadEvent) -> ThreadChangeSet {
        var changes = ThreadChangeSet()
        if event.type == .threadDeleted, event.threadId == threadId {
            status = .deleted
            changes.deleted = true
            return changes
        }
        guard let current = projection else { return changes }
        let partial = history.isPartial
        guard let next = ThreadReduction.apply(current, event, partial: partial, latestLocalTurnOrdinal: history.latestLocalTurnOrdinal)
        else { return changes }
        if partial, case .turnItem(let item) = event.payload,
            history.latestLocalTurnOrdinal.map({ item.ordinal > $0 }) ?? true
        {
            history.latestLocalTurnOrdinal = item.ordinal
            changes.historyChanged = true
        }
        projection = next
        changes.projectionChanged = true
        return changes
    }

    // MARK: Load earlier (threads.ts:637-749)

    /// Starts a load-earlier request. Nil when there is nothing to load, the thread is gone or a
    /// load is already running. Pass the returned cursor back with the page.
    public mutating func beginLoadEarlier(throughEntryId: String? = nil) -> ThreadHistoryRequest? {
        guard status != .deleted, projection != nil, history.hasMoreHistory, !history.loading,
            let cursor = history.historyCursor
        else { return nil }
        history.loading = true
        history.error = nil
        return ThreadHistoryRequest(threadId: threadId, cursor: cursor, throughEntryId: throughEntryId)
    }

    /// Merges an older page. Ignored when the cursor moved while the request was in flight
    /// (`isActiveHistoryRequestCursor`, threadHistoryMerge.ts:30-36).
    @discardableResult
    public mutating func applyHistoryPage(_ page: ThreadHistoryPage, requestCursor: String) -> ThreadChangeSet {
        var changes = ThreadChangeSet()
        guard history.historyCursor == requestCursor, let current = projection else { return changes }
        let merged = ThreadReduction.mergeOlderHistory(current, page.items)
        changes.projectionChanged = merged != current
        projection = merged
        // `applyHistoryPageMeta` keeps the partial-window watermark.
        let watermark = history.latestLocalTurnOrdinal
        history = ThreadHistoryMeta(historyCursor: page.nextCursor, hasMoreHistory: page.hasMoreHistory, latestLocalTurnOrdinal: watermark)
        history.expanded = true
        changes.historyChanged = true
        return changes
    }

    /// Records a failed page load for the control's error text.
    @discardableResult
    public mutating func failHistoryLoad(requestCursor: String, message: String) -> ThreadChangeSet {
        var changes = ThreadChangeSet()
        guard history.historyCursor == requestCursor, history.loading else { return changes }
        history.loading = false
        history.error = message
        changes.historyChanged = true
        return changes
    }

    /// The `subscribeThread` input for this state (threads.ts:873-893). Resumes after the last
    /// sequence once data exists; otherwise asks for a bounded, compact snapshot.
    public func subscribeInput(requestCompletionMarker: Bool = true) -> SubscribeThreadInput {
        SubscribeThreadInput(
            threadId: threadId,
            afterSequence: projection == nil ? nil : lastSequence,
            requestCompletionMarker: requestCompletionMarker ? true : nil,
            acceptBoundedSnapshot: true,
            acceptCompactTurnItems: true)
    }
}
