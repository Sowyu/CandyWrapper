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
    /// Every projection change in the set only grew the text of a streaming answer or reasoning
    /// item, so what reads runs, requests, plans or ids can skip it.
    public var onlyStreamingText = false

    public init() {}

    public var isEmpty: Bool { !projectionChanged && !reset && !historyChanged && !synchronized && !deleted }

    public mutating func merge(_ later: ThreadChangeSet) {
        if later.projectionChanged {
            onlyStreamingText = projectionChanged ? onlyStreamingText && later.onlyStreamingText : later.onlyStreamingText
        }
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
    /// Only rolled back, cancelled and queued runs and superseded attempts can hide an item, so a thread with none
    /// answers true without a lookup, and the interrupt scan runs only with superseded attempts
    /// (`createOrchestrationV2TurnItemVisibility`, orchestrationV2Timeline.ts:75-120 at 4928, #28965).
    static func visibility(runs: [Run], attempts: [RunAttempt], items: [TurnItem]) -> (TurnItem) -> Bool {
        var statuses: [RunId: ThreadStatus] = [:]
        for run in runs {
            if run.status == .rolledBack || run.status == .cancelled || run.status == .queued { statuses[run.id] = run.status }
            else { statuses[run.id] = nil }
        }
        var supersededRoots: [RunId: Set<NodeId>] = [:]
        for attempt in attempts where attempt.status == "superseded" {
            supersededRoots[attempt.runId, default: []].insert(attempt.rootNodeId)
        }
        if statuses.isEmpty, supersededRoots.isEmpty { return { _ in true } }
        let interruptRuns = supersededRoots.isEmpty ? [] : Set(items.lazy.filter { $0.type == .runInterruptRequest }.map(\.runId))
        return { item in
            let status = item.runId.flatMap { statuses[$0] }
            if status == .rolledBack { return false }
            // A steer can return to the queue before delivery: its item stays out until its run starts
            // (orchestrationV2Timeline.ts at 4928, #23420). Cancelled queued input never shows.
            if status == .cancelled || status == .queued, item.type == .userMessage, item.inputIntent == .queuedTurn { return false }
            if item.type == .runInterruptResult, let runId = item.runId, let nodeId = item.nodeId,
                supersededRoots[runId]?.contains(nodeId) == true, !interruptRuns.contains(runId)
            {
                return false
            }
            return true
        }
    }

    /// `visibility` for one item, looking up only what that item needs: every streamed update asks it, and building
    /// the whole-thread tables each time cost a pass over every run and item.
    static func isVisible(_ item: TurnItem, in projection: ThreadProjection) -> Bool {
        let status = item.runId.flatMap { id in projection.runs.last { $0.id == id }?.status }
        if status == .rolledBack { return false }
        if status == .cancelled || status == .queued, item.type == .userMessage, item.inputIntent == .queuedTurn { return false }
        guard item.type == .runInterruptResult, let runId = item.runId, let nodeId = item.nodeId,
              projection.attempts.contains(where: { $0.runId == runId && $0.status == "superseded" && $0.rootNodeId == nodeId })
        else { return true }
        return projection.turnItems.contains { $0.type == .runInterruptRequest && $0.runId == runId }
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
        // Streamed updates land on the newest rows, so search from the end (orchestrationV2Projection.ts:420-424 at 4928).
        let index = rows.lastIndex { $0.sourceItemId == item.id }
        let next = ProjectedTurnItem(local: item)
        if let index, rows[index].isLocal, rows[index].sourceThreadId == next.sourceThreadId, rows[index].item == item {
            return rows
        }
        // Same ordinal and the next row local or none: removing and inserting it again would put it back here.
        if let index, rows[index].isLocal, rows[index].sourceThreadId == next.sourceThreadId, rows[index].item.ordinal == item.ordinal,
           index == rows.count - 1 || rows[index + 1].isLocal
        {
            var updated = rows
            updated[index] = ProjectedTurnItem(position: rows[index].position, visibility: next.visibility, sourceThreadId: next.sourceThreadId,
                                               sourceItemId: next.sourceItemId, item: item)
            return updated.indices.contains(index) && updated[index].position == index ? updated : renumbered(updated)
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

    /// `restoreQueuedUserItems` (orchestrationV2Projection.ts at 4928, #23420): a queued run's user item stays hidden
    /// until the run leaves the queue, and its update can arrive before or after the run's, so the run's update
    /// brings it back. Items never received stay absent.
    static func restoreQueuedUserItems(_ projection: ThreadProjection, _ runId: RunId) -> [ProjectedTurnItem] {
        var current = projection
        for item in projection.turnItems where item.runId == runId && item.type == .userMessage && item.inputIntent == .queuedTurn {
            guard isVisible(item, in: current) else { continue }
            current.visibleTurnItems = upsertVisibleTurnItem(current, item, partial: false, latestLocalTurnOrdinal: nil)
        }
        return current.visibleTurnItems
    }

    static func upsert<T: Identifiable>(_ list: inout [T], _ value: T) {
        // Updates land on the newest entries; ids are unique, so the last match is the only one.
        if let index = list.lastIndex(where: { $0.id == value.id }) { list[index] = value } else { list.append(value) }
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
            // Visited tracking and tags are read state, not activity: no updatedAt bump (4928 orchestrationV2Projection.ts:324-328).
            if event.type == .threadVisited || event.type == .threadMarkedUnread || event.type == .threadTagsUpdated {
                next.updatedAt = projection.updatedAt
            }
            next.thread = thread
        case .run(let run):
            let wasQueued = projection.runs.contains { $0.id == run.id && $0.status == .queued }
            upsert(&next.runs, run)
            next.visibleTurnItems = activeVisibleTurnItems(next)
            if wasQueued, run.status != .queued { next.visibleTurnItems = restoreQueuedUserItems(next, run.id) }
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
            let previous = projection.turnItems.last { $0.id == item.id }
            var item = item
            // An update keeps the anchor's deferred cursor (orchestrationV2Projection.ts:420-429 at 4928).
            if let previous, previous.raw["deferredWork"] != nil, item.raw["deferredWork"] == nil {
                item = item.settingDeferredWork(previous.deferredWork)
            }
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
            case .threadVisitRecorded:
                // Read state: no updatedAt bump (4928 orchestrationV2Projection.ts:329-333).
                next.updatedAt = projection.updatedAt
                if let thread = next.thread.applyingVisit(payload) { next.thread = thread }
            case .threadPullRequestLinkUpdated:
                // `thread.pull-request-link-updated` (orchestrationV2Projection.ts:297-301).
                if let thread = next.thread.applyingPullRequestLink(payload) { next.thread = thread }
            default: break // checkpoint.rollback-requested only bumps updatedAt.
            }
        }
        return next
    }

    // MARK: History pages (threadHistoryMerge.ts:62-149)

    /// Port of `mergeOlderHistoryIntoProjection` (threadHistoryMerge.ts:86-180 at 4928): dedupes by
    /// `sourceThreadId:sourceItemId`, keeps live values of rows already present and renumbers. A plain page
    /// interleaves at the rows both lists share (#29711). With `work`, the page is a deferred work group: its
    /// rows go between the anchor and the group's last ordinal, and the anchor keeps `deferredWork` with the
    /// next cursor until the group is complete (#26240).
    public static func mergeOlderHistory(
        _ projection: ThreadProjection, _ olderItems: [ProjectedTurnItem], work: (anchorId: TurnItemId, nextCursor: String?)? = nil
    ) -> ThreadProjection {
        if olderItems.isEmpty, work == nil { return projection }
        func key(_ row: ProjectedTurnItem) -> String { "\(row.sourceThreadId.rawValue):\(row.sourceItemId.rawValue)" }
        let threadId = projection.thread.id
        let start = work.flatMap { w in projection.visibleTurnItems.firstIndex { $0.sourceItemId == w.anchorId } }
        let anchor = start.map { projection.visibleTurnItems[$0] }
        let deferred = anchor?.item.deferredWork
        if work != nil, deferred == nil { return projection }
        let currentByKey = Dictionary(projection.visibleTurnItems.map { (key($0), $0) }, uniquingKeysWith: { _, last in last })
        var turnItemOrder = projection.turnItems.map(\.id)
        var turnItemById = Dictionary(projection.turnItems.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var pageKeys = Set<String>()
        var page: [ProjectedTurnItem] = []
        for pageRow in olderItems {
            if let anchor, let deferred,
               pageRow.sourceThreadId != anchor.sourceThreadId || pageRow.item.ordinal < anchor.item.ordinal
                || pageRow.item.ordinal > deferred.lastOrdinal
            {
                continue
            }
            let k = key(pageRow)
            if pageKeys.contains(k) { continue }
            var row = currentByKey[k] ?? pageRow
            let rowIsLocal = row.isLocal || row.sourceThreadId == threadId
            if currentByKey[k] == nil, rowIsLocal, let currentItem = turnItemById[row.sourceItemId] {
                // Hidden live items stay hidden. Snapshots also keep interrupt requests and pending request
                // cards outside the window; their history page shows them (c15e49a77c, #26435).
                let revealed: Set<TurnItemType> = [.runInterruptRequest, .approvalRequest, .userInputRequest]
                guard revealed.contains(currentItem.type), isVisible(currentItem, in: projection) else { continue }
                row.item = currentItem
            }
            pageKeys.insert(k)
            page.append(row)
            if rowIsLocal, turnItemById[row.sourceItemId] == nil {
                turnItemById[row.sourceItemId] = row.item
                turnItemOrder.append(row.sourceItemId)
            }
        }
        if page.isEmpty, work == nil { return projection }
        let current = projection.visibleTurnItems
        var visible: [ProjectedTurnItem]
        if let work, let start, let anchor, let deferred {
            var end = start + 1
            while end < current.count {
                let row = current[end]
                if row.sourceThreadId != anchor.sourceThreadId || row.visibility == "synthetic" || row.item.ordinal > deferred.lastOrdinal { break }
                end += 1
            }
            var updated = anchor
            updated.item = anchor.item.settingDeferredWork(work.nextCursor.map {
                TurnItem.DeferredWork(cursor: $0, itemCount: deferred.itemCount, lastOrdinal: deferred.lastOrdinal)
            })
            let section = (page + current[start..<end].filter { !pageKeys.contains(key($0)) })
                .map { $0.sourceItemId == anchor.sourceItemId ? updated : $0 }
            // A stable sort, like `Array.prototype.sort`.
            let ordered = section.enumerated().sorted { ($0.element.item.ordinal, $0.offset) < ($1.element.item.ordinal, $1.offset) }.map(\.element)
            visible = Array(current[..<start]) + ordered + Array(current[end...])
            if anchor.isLocal, turnItemById[updated.item.id] != nil { turnItemById[updated.item.id] = updated.item }
        } else {
            visible = interleave(current, page, pageKeys: pageKeys, key: key)
        }
        if visible == current { return projection }
        var merged = projection
        merged.turnItems = turnItemOrder.compactMap { turnItemById[$0] }
        merged.visibleTurnItems = renumbered(visible)
        return merged
    }

    /// `interleavePage` (threadHistoryMerge.ts:53-84 at 4928): a page is a contiguous range, so current rows
    /// before its first shared row are older, and new page rows sit just before the next row both lists share.
    static func interleave(
        _ current: [ProjectedTurnItem], _ page: [ProjectedTurnItem], pageKeys: Set<String>, key: (ProjectedTurnItem) -> String
    ) -> [ProjectedTurnItem] {
        var currentIndex: [String: Int] = [:]
        for (index, row) in current.enumerated() { currentIndex[key(row)] = index }
        var merged: [ProjectedTurnItem] = []
        merged.reserveCapacity(current.count + page.count)
        var pending: [ProjectedTurnItem] = []
        var next = 0
        func emitCurrent(through end: Int) {
            while next < end {
                if !pageKeys.contains(key(current[next])) { merged.append(current[next]) }
                next += 1
            }
        }
        for row in page {
            guard let index = currentIndex[key(row)] else { pending.append(row); continue }
            emitCurrent(through: index + 1)
            merged += pending
            merged.append(row)
            pending = []
        }
        merged += pending
        emitCurrent(through: current.count)
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
        changes.onlyStreamingText = Self.growsStreamingText(event, in: current)
        return changes
    }

    /// A `message.updated` or `turn-item.updated` that changes only the text and update time of an
    /// assistant message or reasoning item that was and still is streaming.
    static func growsStreamingText(_ event: ThreadEvent, in projection: ThreadProjection) -> Bool {
        switch event.payload {
        case .message(let message):
            guard message.streaming, let old = projection.messages.last(where: { $0.id == message.id }), old.streaming else { return false }
            var same = old
            same.text = message.text
            same.updatedAt = message.updatedAt
            return same == message
        case .turnItem(let item):
            guard item.streaming, item.type == .assistantMessage || item.type == .reasoning,
                  let old = projection.turnItems.last(where: { $0.id == item.id }), old.streaming, old.type == item.type,
                  case .object(var x) = old.raw, case .object(var y) = item.raw
            else { return false }
            for key in ["text", "updatedAt"] { x[key] = nil; y[key] = nil }
            return x == y
        default:
            return false
        }
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
    ///
    /// A plain load (no `throughEntryId`) keeps paging while the page holds no turn start, so one
    /// click reveals a whole earlier turn (`keepPaging` and `startsTurn`, threads.ts:78-87 and :811-819
    /// at 4928, #24417). `nextCursor` is the cursor to load next, nil when the load is done.
    @discardableResult
    public mutating func applyHistoryPage(
        _ page: ThreadHistoryPage, requestCursor: String, throughEntryId: String? = nil
    ) -> ThreadChangeSet {
        applyHistoryPageContinuing(page, requestCursor: requestCursor, throughEntryId: throughEntryId).changes
    }

    /// A user message opens a turn unless it steers a running one; every notification is a response
    /// boundary (`startsTurn`, threads.ts:78-87 at 4928).
    static func startsTurn(_ item: TurnItem) -> Bool {
        item.type == .notification
            || (item.type == .userMessage && item.inputIntent != .steer && item.inputIntent != .promotedQueuedToSteer)
    }

    public mutating func applyHistoryPageContinuing(
        _ page: ThreadHistoryPage, requestCursor: String, throughEntryId: String? = nil
    ) -> (changes: ThreadChangeSet, nextCursor: String?) {
        var changes = ThreadChangeSet()
        guard history.historyCursor == requestCursor, let current = projection else { return (changes, nil) }
        let keepPaging = throughEntryId == nil && page.hasMoreHistory
            && !page.items.contains { Self.startsTurn($0.item) }
        // "History did not advance." (threads.ts:820-825): a page that repeats its cursor ends the load.
        let next = keepPaging && page.nextCursor != requestCursor ? page.nextCursor : nil
        let merged = ThreadReduction.mergeOlderHistory(current, page.items)
        changes.projectionChanged = merged != current
        projection = merged
        // `applyHistoryPageMeta` keeps the partial-window watermark.
        let watermark = history.latestLocalTurnOrdinal
        history = ThreadHistoryMeta(historyCursor: page.nextCursor, hasMoreHistory: page.hasMoreHistory, latestLocalTurnOrdinal: watermark)
        history.expanded = true
        history.loading = next != nil
        changes.historyChanged = true
        return (changes, next)
    }

    // MARK: Deferred work (threads.ts:727-860 at 4928, #26240)

    /// The `view: "work"` page request for an anchor row's folded group, or nil when the anchor is gone or its
    /// group is complete.
    public func deferredWorkRequest(anchorId: TurnItemId) -> ThreadHistoryRequest? {
        guard status != .deleted, let cursor = deferredWorkCursor(anchorId) else { return nil }
        return ThreadHistoryRequest(threadId: threadId, cursor: cursor, throughEntryId: anchorId.rawValue, view: .work)
    }

    func deferredWorkCursor(_ anchorId: TurnItemId) -> String? {
        projection?.visibleTurnItems.first { $0.sourceItemId == anchorId }?.item.deferredWork?.cursor
    }

    public enum DeferredWorkResult: Equatable, Sendable {
        /// Merged; load `next` too while it is non-nil.
        case loaded(next: String?)
        /// The anchor is gone or already complete.
        case noop
        case failed(String)
    }

    /// Merges one page of a deferred group at its anchor. A page for a cursor the anchor no longer holds is
    /// dropped (`isCurrent`, threads.ts:745-753).
    @discardableResult
    public mutating func applyDeferredWorkPage(
        _ page: ThreadHistoryPage, anchorId: TurnItemId, requestCursor: String
    ) -> (ThreadChangeSet, DeferredWorkResult) {
        var changes = ThreadChangeSet()
        guard let current = projection, status != .deleted else { return (changes, .noop) }
        let cursor = deferredWorkCursor(anchorId)
        guard cursor == requestCursor else {
            return (changes, cursor == nil ? .noop : .failed("Work history changed. Try again."))
        }
        if let next = page.nextCursor, next == requestCursor { return (changes, .failed("Work history did not advance.")) }
        let merged = ThreadReduction.mergeOlderHistory(current, page.items, work: (anchorId, page.nextCursor))
        changes.projectionChanged = merged != current
        projection = merged
        history.expanded = true
        changes.historyChanged = true
        return (changes, .loaded(next: page.nextCursor))
    }

    /// A load-earlier request was cancelled (its view moved to another connection): the control
    /// becomes usable again without an error. Port of `clearActiveHistoryLoading`
    /// (threadHistoryMerge.ts:38-50), which T3 runs when the request's fiber is interrupted.
    @discardableResult
    public mutating func cancelHistoryLoad(requestCursor: String) -> ThreadChangeSet {
        var changes = ThreadChangeSet()
        guard history.historyCursor == requestCursor, history.loading else { return changes }
        history.loading = false
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

    /// A failed wire reference invalidates the resume cursor. Keep the last rendered data
    /// until a fresh authoritative snapshot arrives, and clear the history loading state.
    public mutating func resetForResynchronization() {
        lastSequence = nil
        if status != .deleted { status = projection == nil ? .empty : .synchronizing }
        history.loading = false
    }

    /// The `subscribeThread` input for this state (threads.ts:873-893). Resumes after the last
    /// sequence once data exists; otherwise asks for a bounded, compact snapshot.
    public func subscribeInput(requestCompletionMarker: Bool = true) -> SubscribeThreadInput {
        SubscribeThreadInput(
            threadId: threadId,
            afterSequence: projection == nil ? nil : lastSequence,
            requestCompletionMarker: requestCompletionMarker ? true : nil,
            acceptBoundedSnapshot: true,
            acceptCompactTurnItems: true,
            acceptDeferredWork: true)
    }
}
