import Foundation
import T3Protocol

/// Moves a cold thread's bounded snapshot onto HTTP, where the server can compress it.
/// A missing route or failed fetch leaves the socket's snapshot path available.
/// T3: packages/client-runtime/src/state/boundedThreadSnapshotHttp.ts:24-57.
public actor ThreadSnapshotLoader {
    private let fetch: @Sendable () async throws -> ThreadDetailSnapshot
    private var attempted = false

    public init(http: EnvironmentHTTP, token: String, threadId: ThreadId) {
        var boundedHTTP = http
        boundedHTTP.timeout = 6
        let client = boundedHTTP
        fetch = {
            try await client.get(ThreadHistoryRequest.boundedSnapshotPath(threadId), token: token,
                                 as: ThreadDetailSnapshot.self)
        }
    }

    /// Test seam for unavailable, cancelled and concurrent requests.
    package init(fetch: @escaping @Sendable () async throws -> ThreadDetailSnapshot) {
        self.fetch = fetch
    }

    /// The first cold open of a server that pages snapshots (`threadSnapshotPagination` in its config) skips HTTP:
    /// that server sends the same bounded window over the socket, compressed, so the open costs one round trip
    /// instead of an HTTP request and then the subscription, and no new connection when the HTTP pool has gone idle.
    /// A later cold attempt, after that open failed or its session dropped, asks HTTP once. T3 4928 does the same
    /// (client-runtime state/threads.ts:990-1047, #33306).
    public func load(serverPagesSnapshots: Bool) async -> ThreadDetailSnapshot? {
        if serverPagesSnapshots, !socketOpenTried {
            socketOpenTried = true
            return nil
        }
        return await load()
    }

    private var socketOpenTried = false

    /// The snapshot a subscription without a retained sequence applies before it subscribes, or nil to let the
    /// socket send it. Waits for the session's config at most `configDeadline`; without it the open takes the HTTP
    /// path, and a config that arrives later changes nothing for this open. A session that ends during the wait
    /// loads nothing, and the next session's open decides again, as T3 interrupts the open with its session.
    public func coldOpen(supervisor: ConnectionSupervisor, config feed: ServerConfigFeed,
                         configDeadline: Duration = ServerConfigFeed.threadOpenConfigDeadline) async -> ThreadDetailSnapshot? {
        let generation = await supervisor.state.generation
        let config = await feed.initialConfig(generation: generation, within: configDeadline)
        guard await supervisor.state.generation == generation, await supervisor.currentConnection != nil else { return nil }
        return await load(serverPagesSnapshots: config?["threadSnapshotPagination"]?.boolValue == true)
    }

    /// Called only without a retained sequence. Try once per subscription owner, including
    /// when an old host lacks the route; reconnects continue through the socket.
    public func load() async -> ThreadDetailSnapshot? {
        guard !attempted, !Task.isCancelled else { return nil }
        attempted = true
        do {
            let snapshot = try await fetch()
            try Task.checkCancellation()
            return snapshot
        } catch {
            return nil
        }
    }
}
