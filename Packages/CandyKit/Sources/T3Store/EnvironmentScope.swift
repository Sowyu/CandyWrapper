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
///
/// Each environment keeps its last unscoped shell next to the scoped one, so an update rescopes only
/// the projects and threads whose value changed and reuses the rest.
public struct MergedShell: Sendable {
    private var raw: [String: ShellSnapshot] = [:]
    private var scoped: [String: ShellSnapshot] = [:]
    /// Projects and threads the last `set` scoped anew (the rest were reused). For tests.
    public private(set) var lastRescoped = 0
    /// The scoped ids of the threads the last `set` scoped anew: the only threads of the merge that can differ
    /// from the merge before it. Nil after a first `set` or a `remove`, when that isn't known.
    public private(set) var lastChangedThreadIds: Set<ThreadId>?

    public init() {}

    public mutating func set(_ snapshot: ShellSnapshot, environmentId env: String) {
        guard let oldRaw = raw[env], let oldScoped = scoped[env] else {
            raw[env] = snapshot
            scoped[env] = EnvironmentScope.scope(snapshot, environmentId: env)
            lastRescoped = snapshot.projects.count + snapshot.threads.count + snapshot.archivedThreads.count
            lastChangedThreadIds = nil
            return
        }
        var count = 0
        var out = snapshot
        out.projects = Self.rescope(snapshot.projects, oldRaw.projects, oldScoped.projects, &count) { EnvironmentScope.scope($0, env) }
        var changed = Set<ThreadId>()
        out.threads = Self.rescope(snapshot.threads, oldRaw.threads, oldScoped.threads, &count) {
            let scoped = EnvironmentScope.scope($0, env)
            changed.insert(scoped.id)
            return scoped
        }
        out.archivedThreads = Self.rescope(snapshot.archivedThreads, oldRaw.archivedThreads, oldScoped.archivedThreads, &count) {
            EnvironmentScope.scope($0, env)
        }
        raw[env] = snapshot
        scoped[env] = out
        lastRescoped = count
        lastChangedThreadIds = changed
    }

    /// `new` scoped, reusing the scoped copy of every item equal to its previous value. Items usually
    /// keep their place, so that is checked first; the id index is built only when one moved.
    private static func rescope<T: Identifiable & Equatable>(_ new: [T], _ oldRaw: [T], _ oldScoped: [T], _ count: inout Int,
                                                             scope: (T) -> T) -> [T] where T.ID: Hashable {
        // Unchanged keeps the same array, so later equality checks (the composer's projects) stay cheap.
        if new == oldRaw { return oldScoped }
        var index: [T.ID: Int]?
        return new.enumerated().map { i, item in
            if i < oldRaw.count, oldRaw[i] == item { return oldScoped[i] }
            if index == nil { index = Dictionary(oldRaw.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }) }
            if let j = index?[item.id], oldRaw[j] == item { return oldScoped[j] }
            count += 1
            return scope(item)
        }
    }

    public mutating func remove(_ environmentId: String) {
        raw[environmentId] = nil
        scoped[environmentId] = nil
        lastChangedThreadIds = nil
    }

    /// The environments in `order` that have a shell, concatenated. Nil when none has one.
    public func merged(order: [String]) -> ShellSnapshot? {
        let parts = order.compactMap { scoped[$0] }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 {
            var only = parts[0]
            only.snapshotSequence = 0
            return only
        }
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
