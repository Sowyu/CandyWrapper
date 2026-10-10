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
/// // ponytail: no disk cache (T3 persists settled snapshots); add it when cold opens of huge threads still feel slow
public actor ThreadStore {
    private var reducer: ThreadReducer
    private var pending: ThreadChangeSet?
    private let onChange: @Sendable () -> Void

    public init(threadId: ThreadId, onChange: @escaping @Sendable () -> Void) {
        reducer = ThreadReducer(threadId: threadId)
        self.onChange = onChange
    }

    public var projection: ThreadProjection? { reducer.projection }
    public var history: ThreadHistoryMeta { reducer.history }
    public var status: ThreadSyncStatus { reducer.status }
    public var lastSequence: Int? { reducer.lastSequence }

    /// The input for the next `orchestration.subscribeThread` call.
    public func subscribeInput(requestCompletionMarker: Bool = true) -> SubscribeThreadInput {
        reducer.subscribeInput(requestCompletionMarker: requestCompletionMarker)
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
            onChange()
        } else {
            pending?.merge(changes)
        }
    }
}
