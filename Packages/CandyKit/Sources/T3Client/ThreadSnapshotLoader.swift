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
