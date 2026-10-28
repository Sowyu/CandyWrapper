import Foundation
import T3Protocol

/// One coalesced update for a thread view.
public struct ThreadUpdate: Sendable {
    public var projection: ThreadProjection?
    public var history: ThreadHistoryMeta
    public var status: ThreadSyncStatus
    public var changes: ThreadChangeSet
    public var lastSequence: Int?
}

/// Owns one thread's reducer off the main thread, like `ShellStore`. It doesn't know about the
/// transport: feed it decoded `subscribeThread` items, the HTTP bounded snapshot and history
/// pages. Publishing is pull based: the first change after a `takeUpdate()` calls `onChange`
/// once, and `takeUpdate()` returns every change since the last take folded together.
///
/// The app keeps a closed thread's store for a while and reopens from it (T3's retention,
/// RT/threadRetention.ts): the view shows the retained projection at once and the new
/// subscription resumes after `lastSequence`.
/// With a `ThreadCache`, an empty store first fills itself from disk (T3's `cache.loadThread`,
/// threads.ts:186-232), so the view paints before the network and the subscription resumes
/// after the cached sequence; settled states go back to the cache.
public actor ThreadStore {
    private var wireRestorer = ThreadWireRestorer()
    private var wireSubscription: UUID?
    private var reducer: ThreadReducer
    private var pending: ThreadChangeSet?
    /// Gets whether the first change only grew a streaming text (`ThreadChangeSet.onlyStreamingText`).
    private let onChange: @Sendable (_ onlyStreamingText: Bool) -> Void
    private let cache: ThreadCache?
    private let cacheKey: ThreadCache.Key
    private var cacheRead = false
    private var requestResolution = ThreadRequestResolutionTracker()
    private let onRequestsResolved: (@Sendable (Set<String>) -> Void)?
    /// The last offer or removal sent to the cache.
    private var cacheTask: Task<Void, Never>?
    /// The sequence and paging state last loaded from or offered to the cache.
    private var cached: (sequence: Int, history: ThreadHistoryMeta)?

    public init(threadId: ThreadId, cache: ThreadCache? = nil, environmentId: String = "", onChange: @escaping @Sendable () -> Void, onRequestsResolved: (@Sendable (Set<String>) -> Void)? = nil) {
        self.init(threadId: threadId, cache: cache, environmentId: environmentId, onFirstChange: { _ in onChange() }, onRequestsResolved: onRequestsResolved)
    }

    /// `onFirstChange` learns whether the change that starts a window only grew a streaming text, so
    /// the caller can wait for T3's second message of the pair only while text streams.
    public init(threadId: ThreadId, cache: ThreadCache? = nil, environmentId: String = "", onFirstChange: @escaping @Sendable (_ onlyStreamingText: Bool) -> Void, onRequestsResolved: (@Sendable (Set<String>) -> Void)? = nil) {
        reducer = ThreadReducer(threadId: threadId)
        self.onChange = onFirstChange
        self.onRequestsResolved = onRequestsResolved
        self.cache = cache
        cacheKey = ThreadCache.Key(environmentId: environmentId, threadId: threadId)
    }

    /// Fills an empty store from the disk cache, once. True when it did.
    @discardableResult
    public func restoreFromCache() -> Bool {
        guard !cacheRead else { return false }
        cacheRead = true
        guard reducer.projection == nil, let cache,
              let snapshot = OpenTiming.measure("disk cache", "", { cache.load(cacheKey) })
        else { return false }
        wireRestorer.seed(snapshot.projection)
        let changes = reducer.applySnapshot(snapshot)
        cached = (snapshot.snapshotSequence, reducer.history)
        OpenTiming.mark("disk cache restored", "\(reducer.projection?.visibleTurnItems.count ?? 0) rows, sequence \(snapshot.snapshotSequence)")
        publish(changes, authoritative: false)
        return true
    }

    /// Writes the queued snapshot now; the thread's view closed. Waits for the offers and removals
    /// already sent first, so the newest state is the one written.
    public func flushCache() async {
        await cacheTask?.value
        await cache?.flush(cacheKey)
    }

    public var projection: ThreadProjection? { reducer.projection }
    public var history: ThreadHistoryMeta { reducer.history }
    public var status: ThreadSyncStatus { reducer.status }
    public var lastSequence: Int? { reducer.lastSequence }

    /// The input for the next `orchestration.subscribeThread` call. A scoped caller claims
    /// its UUID before HTTP bootstrap and keeps the same UUID across reconnects and retries.
    public func subscribeInput(requestCompletionMarker: Bool = true, subscription: UUID? = nil) -> SubscribeThreadInput {
        restoreFromCache()
        // Cancellation does not stop an already running payload closure. In particular, an
        // old HTTP bootstrap can finish after its replacement has claimed this store.
        if let subscription, subscription != wireSubscription, !Task.isCancelled {
            wireSubscription = subscription
            wireRestorer = ThreadWireRestorer()
            if let projection = reducer.projection { wireRestorer.seed(projection) }
        }
        var input = reducer.subscribeInput(requestCompletionMarker: requestCompletionMarker)
        input.acceptDedupedBodies = true
        input.acceptCompactIds = true
        return input
    }

    /// Restores a raw stream value before reducers or caches see it. Keep transport arrival
    /// order even for stale sequences: the server remembers the records it delivered.
    /// Values from a replaced subscription return before they can affect those records.
    public func applyWire(_ json: JSONValue, subscription: UUID? = nil) throws {
        if let subscription, subscription != wireSubscription { return }
        let item = try OpenTiming.measure("typed decode", "") { try wireRestorer.decode(json) }
        publish(reducer.apply([item]))
    }

    /// Forces the next subscription to request a snapshot after a restoration error.
    /// The retained projection stays visible while that snapshot loads.
    public func resetForResynchronization(subscription: UUID? = nil) {
        if let subscription, subscription != wireSubscription { return }
        wireRestorer = ThreadWireRestorer()
        reducer.resetForResynchronization()
    }

    /// Applies items that arrived together, for example one RPC Chunk.
    public func apply(_ items: [ThreadStreamItem]) {
        for item in items {
            if case .snapshot(let snapshot) = item { wireRestorer.seed(snapshot.projection) }
        }
        publish(OpenTiming.measure("reducer", "\(items.count) items") { reducer.apply(items) })
    }

    /// Seeds the thread from `GET .../bounded` before the socket opens.
    public func applySnapshot(_ snapshot: ThreadDetailSnapshot, subscription: UUID? = nil) {
        if let subscription, subscription != wireSubscription { return }
        wireRestorer.seed(snapshot.projection)
        publish(reducer.applySnapshot(snapshot))
    }

    /// Marks a load-earlier request as running and returns what to fetch, or nil.
    public func beginLoadEarlier(throughEntryId: String? = nil) -> ThreadHistoryRequest? {
        let request = reducer.beginLoadEarlier(throughEntryId: throughEntryId)
        if request != nil {
            var changes = ThreadChangeSet()
            changes.historyChanged = true
            publish(changes)
        }
        return request
    }

    public func applyHistoryPage(_ page: ThreadHistoryPage, requestCursor: String) {
        publish(reducer.applyHistoryPage(page, requestCursor: requestCursor))
    }

    public func failHistoryLoad(requestCursor: String, message: String) {
        publish(reducer.failHistoryLoad(requestCursor: requestCursor, message: message))
    }

    public func cancelHistoryLoad(requestCursor: String) {
        publish(reducer.cancelHistoryLoad(requestCursor: requestCursor))
    }

    /// Everything the store holds as one reset update, for a view that starts showing a retained
    /// store. Clears what was pending, so the next change calls `onChange` again. Nil without data.
    public func currentUpdate() -> ThreadUpdate? {
        guard reducer.projection != nil else { return nil }
        pending = nil
        var changes = ThreadChangeSet()
        changes.projectionChanged = true
        changes.reset = true
        changes.historyChanged = true
        return ThreadUpdate(
            projection: reducer.projection, history: reducer.history, status: reducer.status,
            changes: changes, lastSequence: reducer.lastSequence)
    }

    /// Drains the coalesced changes. Nil when nothing changed since the last take.
    public func takeUpdate() -> ThreadUpdate? {
        guard let changes = pending else { return nil }
        pending = nil
        return ThreadUpdate(
            projection: reducer.projection, history: reducer.history, status: reducer.status,
            changes: changes, lastSequence: reducer.lastSequence)
    }

    /// Reads chunks until the sequence ends or throws, hopping in per chunk.
    public nonisolated func consume<S: AsyncSequence>(chunks: S) async throws
    where S.Element == [ThreadStreamItem] {
        for try await chunk in chunks { await apply(chunk) }
    }

    private func publish(_ changes: ThreadChangeSet, authoritative: Bool = true) {
        guard !changes.isEmpty else { return }
        if authoritative, onRequestsResolved != nil, reducer.status == .live || reducer.status == .deleted {
            let ids = Set((reducer.projection?.runtimeRequests ?? []).filter { $0.status == "pending" }.map(\.id))
            if requestResolution.update(pending: ids) { onRequestsResolved?(ids) }
        }
        if pending == nil {
            pending = changes
            onChange(changes.projectionChanged && changes.onlyStreamingText && !changes.reset)
        } else {
            pending?.merge(changes)
        }
        updateCache(changes)
    }

    /// Settled states go to the cache, a deletion clears it (threads.ts:386-430).
    private func updateCache(_ changes: ThreadChangeSet) {
        guard let cache else { return }
        let key = cacheKey
        if changes.deleted {
            cached = nil
            let previous = cacheTask
            cacheTask = Task { await previous?.value; await cache.remove(key) }
            return
        }
        guard let projection = reducer.projection, let sequence = reducer.lastSequence,
              ThreadCache.shouldPersist(projection, history: reducer.history)
        else { return }
        var history = reducer.history
        history.loading = false
        history.error = nil
        if let cached, cached.sequence == sequence, cached.history == history { return }
        cached = (sequence, history)
        // Chained, so an offer never overtakes an earlier one or a removal.
        let previous = cacheTask
        cacheTask = Task { await previous?.value; await cache.offer(key, sequence: sequence, projection: projection, history: history) }
    }
}
