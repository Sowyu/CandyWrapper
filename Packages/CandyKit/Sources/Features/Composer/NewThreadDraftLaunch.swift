import Foundation
import T3Protocol
import T3Store

/// A new thread that exists only in the composer until its first send (T3's `DraftSessionState`). Both ids
/// are scoped: the project's environment is where the thread will be created.
public struct DraftSession: Codable, Equatable, Sendable {
    public var draftId: String
    public var threadId: String
    public var projectId: String
    public var createdAt: Date
    /// The branch toolbar's picks (`DraftThreadState`: `envMode`, `branch`, `worktreePath`, `startFromOrigin`).
    public var envMode: EnvMode?
    public var branch: String?
    public var worktreePath: String?
    public var startFromOrigin: Bool?
    public var environmentSelection: String?
    public var loadBalancedEnvironmentId: String?

    public init(draftId: String, threadId: String, projectId: String, createdAt: Date, envMode: EnvMode? = nil,
                branch: String? = nil, worktreePath: String? = nil, startFromOrigin: Bool? = nil) {
        self.draftId = draftId
        self.threadId = threadId
        self.projectId = projectId
        self.createdAt = createdAt
        self.envMode = envMode
        self.branch = branch
        self.worktreePath = worktreePath
        self.startFromOrigin = startFromOrigin
    }
}

/// A draft's first send, `orchestration.launchThread`. T3's server creates the thread with `thread.create`, which
/// never checks for an existing thread: a launch with a used thread id rewrites that thread's shell (title,
/// project, lineage, created time) and appends the message to its history (Orchestrator.ts:2183-2232,
/// ThreadLaunchService.ts:684-800). So a launch never reuses a thread id:
///
/// - the launch mints its thread id, so a stored draft's id is never sent, even one another copy of the app
///   already launched and wrote back into the shared defaults;
/// - the session leaves the store while the launch flies, so New thread mints a fresh draft instead of
///   reopening it (T3 marks it `promotedTo` and skips it, useHandleNewThread.ts:171-183).
public enum NewThreadDraftLaunch {
    /// Takes `session` out of `sessions` and returns it with a new thread id in its environment, plus the
    /// key it was stored under for `restore`.
    public static func begin(_ session: DraftSession, in sessions: inout [String: DraftSession],
                             newId: () -> String = { UUID().uuidString.lowercased() }) -> (launch: DraftSession, key: String?) {
        let key = sessions.first { $0.value.draftId == session.draftId }?.key
        sessions = sessions.filter { $0.value.draftId != session.draftId }
        var launch = session
        let env = ProjectId(session.projectId).environmentId ?? ""
        launch.threadId = ThreadId(newId()).scoped(to: env).rawValue
        return (launch, key)
    }

    /// A failed launch: the draft goes back under `key` with yet another thread id, since the server may have
    /// created the failed one. Nil when the key holds another draft by now.
    public static func restore(_ launch: DraftSession, key: String?, in sessions: inout [String: DraftSession],
                               newId: () -> String = { UUID().uuidString.lowercased() }) -> DraftSession? {
        guard let key, sessions[key] == nil else { return nil }
        var session = launch
        let env = ProjectId(session.projectId).environmentId ?? ""
        session.threadId = ThreadId(newId()).scoped(to: env).rawValue
        sessions[key] = session
        return session
    }
}
