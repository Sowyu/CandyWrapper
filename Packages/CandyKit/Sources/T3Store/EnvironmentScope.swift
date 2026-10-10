import Foundation
import T3Protocol

/// Scoped refs (client-runtime environment/scoped.ts:11-47): above the wire every project and thread
/// id carries its environment as `"<environmentId>:<localId>"`. Environment ids contain no colon, so
/// the first colon splits them; local ids may contain colons. The app scopes each environment's
/// shell before merging, so the sidebar, drafts and per-thread stores key by scoped ids, and it
/// strips the scope again for anything sent to a server.
public enum EnvironmentScope {
    public static func key(_ environmentId: String, _ localId: String) -> String { environmentId + ":" + localId }

    /// The environment and local id of a scoped key, or nil for an unscoped one.
    public static func split(_ key: String) -> (environmentId: String, localId: String)? {
        guard let colon = key.firstIndex(of: ":"), colon != key.startIndex else { return nil }
        return (String(key[..<colon]), String(key[key.index(after: colon)...]))
    }

    public static func environmentId(of key: String) -> String? { split(key)?.environmentId }

    /// The id the server knows. An unscoped key comes back unchanged.
    public static func localId(of key: String) -> String { split(key)?.localId ?? key }

    // MARK: Snapshots

    /// Rewrites every project and thread reference the client joins on.
    public static func scope(_ snapshot: ShellSnapshot, environmentId env: String) -> ShellSnapshot {
        var out = snapshot
        out.projects = snapshot.projects.map { scope($0, env) }
        out.threads = snapshot.threads.map { scope($0, env) }
        out.archivedThreads = snapshot.archivedThreads.map { scope($0, env) }
        return out
    }

    public static func scope(_ project: ProjectShell, _ env: String) -> ProjectShell {
        var p = project
        p.id = ProjectId(key(env, project.id.rawValue))
        return p
    }

    public static func scope(_ thread: ThreadShell, _ env: String) -> ThreadShell {
        func t(_ id: ThreadId) -> ThreadId { ThreadId(key(env, id.rawValue)) }
        var s = thread
        s.id = t(thread.id)
        s.projectId = ProjectId(key(env, thread.projectId.rawValue))
        s.lineage.parentThreadId = thread.lineage.parentThreadId.map(t)
        s.lineage.rootThreadId = t(thread.lineage.rootThreadId)
        s.forkedFrom?.threadId = thread.forkedFrom?.threadId.map(t)
        s.pendingBackgroundTasks = thread.pendingBackgroundTasks?.map { task in
            var task = task
            task.childThreadId = task.childThreadId.map(t)
            return task
        }
        return s
    }

    public static func scope(_ match: ThreadSearchMatch, _ env: String) -> ThreadSearchMatch {
        var m = match
        m.threadId = ThreadId(key(env, match.threadId.rawValue))
        m.projectId = ProjectId(key(env, match.projectId.rawValue))
        return m
    }

}

/// One shell over every environment, each scoped. A change rescopes only its own environment.
/// `snapshotSequence` means nothing in the merge; each environment's store keeps its own cursor.
/// Thread order needs nothing extra: T3 sorts threads across environments by timestamp only
/// (threadSort.ts:98-139), which the sidebar already does.
public struct MergedShell: Sendable {
    private var scoped: [String: ShellSnapshot] = [:]

    public init() {}

    public mutating func set(_ snapshot: ShellSnapshot, environmentId: String) {
        scoped[environmentId] = EnvironmentScope.scope(snapshot, environmentId: environmentId)
    }

    public mutating func remove(_ environmentId: String) { scoped[environmentId] = nil }

    /// The environments in `order` that have a shell, concatenated. Nil when none has one.
    public func merged(order: [String]) -> ShellSnapshot? {
        let parts = order.compactMap { scoped[$0] }
        guard !parts.isEmpty else { return nil }
        var merged = ShellSnapshot(schemaVersion: parts.map(\.schemaVersion).max() ?? 1, snapshotSequence: 0)
        for part in parts {
            merged.projects += part.projects
            merged.threads += part.threads
            merged.archivedThreads += part.archivedThreads
        }
        return merged
    }
}

extension TaggedID {
    /// The environment of a scoped id (`EnvironmentScope`).
    public var environmentId: String? { EnvironmentScope.environmentId(of: rawValue) }
    /// The id the environment's server knows.
    public var localId: Self { Self(EnvironmentScope.localId(of: rawValue)) }
    public func scoped(to environmentId: String) -> Self { Self(EnvironmentScope.key(environmentId, rawValue)) }
}
