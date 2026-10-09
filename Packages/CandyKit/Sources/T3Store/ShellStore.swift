import T3Protocol

/// One coalesced update for the UI: the state after every item applied so far, and what changed
/// since the previous update.
public struct ShellUpdate: Sendable {
    public var snapshot: ShellSnapshot?
    public var changes: ShellChangeSet
    public var afterSequence: Int?
    public var isSynchronized: Bool
}

/// Owns the shell reducer off the main thread. It doesn't know about the transport: feed it
/// decoded items through `consume(_:)` or `apply(_:)`.
///
/// Publishing is pull based so the UI decides the cadence. When the first change lands after a
/// `takeUpdate()`, the store calls `onChange` once. The app hops to its frame scheduler there
/// and calls `takeUpdate()` on the next frame, which returns every change since the last take
/// folded into one change set. No timer lives here, and a burst of items between two frames
/// becomes one update.
public actor ShellStore {
    private var reducer = ShellReducer()
    private var pending: ShellChangeSet?
    private let onChange: @Sendable () -> Void

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    public var afterSequence: Int? { reducer.afterSequence }
    public var snapshot: ShellSnapshot? { reducer.snapshot }

    /// Applies items that arrived together, for example one RPC Chunk.
    public func apply(_ items: [ShellStreamItem]) {
        let changes = reducer.apply(items)
        guard !changes.isEmpty else { return }
        if pending == nil {
            pending = changes
            onChange()
        } else {
            pending?.merge(changes)
        }
    }

    /// Drains the coalesced changes. Nil when nothing changed since the last take.
    public func takeUpdate() -> ShellUpdate? {
        guard let changes = pending else { return nil }
        pending = nil
        return ShellUpdate(
            snapshot: reducer.snapshot, changes: changes,
            afterSequence: reducer.afterSequence, isSynchronized: reducer.isSynchronized)
    }

    /// Reads items until the sequence ends or throws. Runs off the actor and hops in per item;
    /// the change sets fold together until the UI takes them.
    public nonisolated func consume<S: AsyncSequence>(_ items: S) async throws
    where S.Element == ShellStreamItem {
        for try await item in items { await apply([item]) }
    }

    /// Same as above for a transport that yields whole chunks.
    public nonisolated func consume<S: AsyncSequence>(chunks: S) async throws
    where S.Element == [ShellStreamItem] {
        for try await chunk in chunks { await apply(chunk) }
    }
}
