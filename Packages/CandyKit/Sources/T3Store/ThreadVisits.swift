import Foundation
import T3Protocol

/// Marks the open thread visited, as ChatView's visit effect does (apps/web/src/components/ChatView.tsx:2938-3000).
/// A visit clears the row's unread (Done) and wake marks, never its run status. Servers with visit tracking
/// (`lastVisitedAt` present on the shell) get a `thread.visit` command; older ones keep a local watermark.
public struct ThreadVisitTracker: Sendable {
    /// `VISIT_DISPATCH_THROTTLE_MS` (ChatView.tsx:622).
    public static let throttleMs: Int64 = 10_000

    public enum Decision: Equatable, Sendable {
        case none
        /// `markThreadVisited`: the local watermark moves to the thread's `updatedAt`.
        case local(T3Timestamp)
        /// Send `thread.visit` with this watermark after `delayMs` (0 sends now).
        case dispatch(T3Timestamp, delayMs: Int64)
    }

    private var lastDispatchedKey: String?
    private var lastDispatchAtMs: Int64 = 0

    public init() {}

    /// What to do for the open thread's shell. `routeKey` is the scoped thread id.
    public func decide(_ shell: ThreadShell, routeKey: String, local: T3Timestamp?, nowMs: Int64) -> Decision {
        guard let updated = shell.updatedAt.epochMs else { return .none }
        let visited = SidebarModel.resolveThreadLastVisitedAt(server: shell.lastVisitedAt, local: local)?.epochMs
        if let visited, visited >= updated { return .none }
        guard !shell.lastVisitedAt.isAbsent else { return .local(shell.updatedAt) }
        // Dedupe per watermark: the effect re-runs before the command's echo lands, and a mark-unread on the
        // open thread stays until new activity lands or the thread is reopened.
        guard lastDispatchedKey != Self.key(routeKey, shell) else { return .none }
        // An unseen completion publishes at once; mid-turn bumps ride a trailing throttle.
        let completed = SidebarModel.presentLatestRun(shell)?.completedAt?.epochMs
        let unseenCompletion = completed.map { c in visited.map { c > $0 } ?? true } ?? false
        let elapsed = nowMs - lastDispatchAtMs
        return .dispatch(shell.updatedAt, delayMs: unseenCompletion || elapsed >= Self.throttleMs ? 0 : Self.throttleMs - elapsed)
    }

    /// The command went out for this shell's watermark.
    public mutating func didDispatch(_ shell: ThreadShell, routeKey: String, nowMs: Int64) {
        lastDispatchedKey = Self.key(routeKey, shell)
        lastDispatchAtMs = nowMs
    }

    /// A new thread view (ChatView remounts): the dedupe starts over.
    public mutating func reset() { lastDispatchedKey = nil }

    private static func key(_ routeKey: String, _ shell: ThreadShell) -> String { "\(routeKey):\(shell.updatedAt.raw)" }
}

extension ThreadCommands {
    /// `visitThread` (packages/client-runtime/src/operations/commands.ts:539-548). `opened` says the user opened
    /// the thread, and `searchQuery` is the palette query that picked it (orchestrationV2.ts:2843-2852). Servers
    /// before Nightly 3669 ignore both, so callers send them only to a server whose shells carry `opens`.
    public static func visit(_ threadId: ThreadId, visitedAt: T3Timestamp, opened: Bool = false, searchQuery: String? = nil,
                             commandId: String = newCommandId()) -> JSONValue {
        var fields: [String: JSONValue] = ["visitedAt": .string(visitedAt.raw)]
        if opened { fields["opened"] = .bool(true) }
        if let searchQuery, !searchQuery.isEmpty { fields["searchQuery"] = .string(searchQuery) }
        return command("thread.visit", threadId, commandId, fields)
    }
}
