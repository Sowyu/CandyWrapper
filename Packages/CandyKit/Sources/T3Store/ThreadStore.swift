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
    private var reducer: ThreadReducer
    private var pending: ThreadChangeSet?
    /// Gets whether the first change only grew a streaming text (`ThreadChangeSet.onlyStreamingText`).
    private let onChange: @Sendable (_ onlyStreamingText: Bool) -> Void
    private let cache: ThreadCache?
    private let cacheKey: ThreadCache.Key
    private var cacheRead = false
    /// The sequence and paging state last loaded from or offered to the cache.
    private var cached: (sequence: Int, history: ThreadHistoryMeta)?

    public init(threadId: ThreadId, cache: ThreadCache? = nil, environmentId: String = "", onChange: @escaping @Sendable () -> Void) {
        self.init(threadId: threadId, cache: cache, environmentId: environmentId, onFirstChange: { _ in onChange() })
    }

    /// `onFirstChange` learns whether the change that starts a window only grew a streaming text, so
    /// the caller can wait for T3's second message of the pair only while text streams.
    public init(threadId: ThreadId, cache: ThreadCache? = nil, environmentId: String = "", onFirstChange: @escaping @Sendable (_ onlyStreamingText: Bool) -> Void) {
        reducer = ThreadReducer(threadId: threadId)
        self.onChange = onFirstChange
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
        let changes = reducer.applySnapshot(snapshot)
        cached = (snapshot.snapshotSequence, reducer.history)
        OpenTiming.mark("disk cache restored", "\(reducer.projection?.visibleTurnItems.count ?? 0) rows, sequence \(snapshot.snapshotSequence)")
        publish(changes)
        return true
    }

    /// Writes the queued snapshot now; the thread's view closed.
    public func flushCache() async {
        await cache?.flush(cacheKey)
    }

    public var projection: ThreadProjection? { reducer.projection }
    public var history: ThreadHistoryMeta { reducer.history }
    public var status: ThreadSyncStatus { reducer.status }
    public var lastSequence: Int? { reducer.lastSequence }

    /// The input for the next `orchestration.subscribeThread` call.
    public func subscribeInput(requestCompletionMarker: Bool = true) -> SubscribeThreadInput {
        restoreFromCache()
        return reducer.subscribeInput(requestCompletionMarker: requestCompletionMarker)
    }

    /// Applies items that arrived together, for example one RPC Chunk.
    public func apply(_ items: [ThreadStreamItem]) {
        publish(OpenTiming.measure("reducer", "\(items.count) items") { reducer.apply(items) })
    }

    /// Seeds the thread from `GET .../bounded` before the socket opens.
    public func applySnapshot(_ snapshot: ThreadDetailSnapshot) {
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

    private func publish(_ changes: ThreadChangeSet) {
        guard !changes.isEmpty else { return }
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
            Task { await cache.remove(key) }
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
        Task { await cache.offer(key, sequence: sequence, projection: projection, history: history) }
    }
}
