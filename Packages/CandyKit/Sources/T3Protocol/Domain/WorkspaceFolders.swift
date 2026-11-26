import Foundation

// Multi-repository projects (5258 packages/contracts/src/workspaceFolders.ts, rpc.ts:506-511, 1711-1744;
// T3 commits 60863edc41, 924d9c1fff, 29c852eada). A 4928 server has none of these methods.

/// `WorkspaceFolder` (:9-16). `state` is `git`, `plain` or `missing`.
public struct WorkspaceFolder: Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var state: String
    /// Found inside the project folder by the server, not added by someone.
    public var discovered: Bool?
}

/// `WorkspaceListFoldersResult` (:23-27): the repositories found inside the project folder now, then the added ones.
public struct WorkspaceListFoldersResult: Codable, Hashable, Sendable {
    public var folders: [WorkspaceFolder]
}

/// `WorkspaceScannedFolder` (:34-42). `source` is `child` (one level under the scanned folder) or `code-workspace`.
public struct WorkspaceScannedFolder: Codable, Hashable, Sendable {
    public var path: String
    public var name: String
    public var isGitRepository: Bool
    public var source: String
}

/// `WorkspaceScanFoldersResult` (:44-52).
public struct WorkspaceScanFoldersResult: Codable, Hashable, Sendable {
    public var workspaceRoot: String
    public var isGitRepository: Bool
    /// The `.code-workspace` file the folders came from, when one was read.
    public var codeWorkspaceFile: String?
    public var folders: [WorkspaceScannedFolder]
}

/// `TaskFolderRepository` (:58-64): a tracked repository's own worktree inside a thread's task folder.
public struct TaskFolderRepository: Codable, Hashable, Sendable {
    public var repositoryPath: String
    public var worktreePath: String
    public var name: String
}

/// `TaskFolder` (:70-83): the folder a worktree thread of a multi-repository project works in, with the project
/// folder and each chosen repository at the same relative places, every repository on the thread's branch.
public struct TaskFolder: Codable, Hashable, Sendable {
    public var root: String
    public var projectId: ProjectId
    public var projectRoot: String
    /// The folder `root` stands in for: a path below it sits at the same place below `root`.
    public var anchor: String
    /// Where the project folder sits inside `root`: the thread's `worktreePath`.
    public var projectPath: String
    /// False when the project folder is not a repository; `projectPath` then links to its files.
    public var projectIsWorktree: Bool
    public var repositories: [TaskFolderRepository]
}

/// `WorktreeLayoutCommand` (:109-115): one of a project's `t3.json` `worktreeLayout` commands. `kind` is
/// `create` or `remove`; `approved` means a person approved this exact text for this project.
public struct WorktreeLayoutCommand: Codable, Hashable, Sendable {
    public var kind: String
    public var command: String
    public var approved: Bool
}

/// RPC tags and payloads. Scopes: `workspace.addTaskFolderRepository` needs `source-control:write` and
/// `workspace.approveLayoutCommands` needs `terminal:operate` (clientRpcPermissions.ts:74-76).
public enum WorkspaceRPC {
    public static let listFolders = "workspace.listFolders"
    public static let scanFolders = "workspace.scanFolders"
    public static let taskFolder = "workspace.taskFolder"
    public static let addTaskFolderRepository = "workspace.addTaskFolderRepository"
    public static let layoutCommands = "workspace.layoutCommands"
    public static let approveLayoutCommands = "workspace.approveLayoutCommands"

    /// `TASK_FOLDER_DEFAULT_REPOSITORIES_MAX` (:55): a new worktree thread isolates every tracked repository by
    /// default only up to this many.
    public static let defaultRepositoriesMax = 8

    /// `listFolders` and `layoutCommands`. The first answers `WorkspaceListFoldersResult`, the second
    /// `{commands: [WorktreeLayoutCommand]}`, empty without a `worktreeLayout`.
    public static func project(_ projectId: ProjectId) -> JSONValue { .object(["projectId": .string(projectId.rawValue)]) }

    /// `scanFolders`, answering `WorkspaceScanFoldersResult`.
    public static func scanInput(workspaceRoot: String) -> JSONValue { .object(["workspaceRoot": .string(workspaceRoot)]) }

    /// `taskFolder` takes a thread's `worktreePath` or any path inside its task folder and answers
    /// `{taskFolder: TaskFolder | null}`, null for a single checkout.
    public static func taskFolderInput(worktreePath: String) -> JSONValue { .object(["worktreePath": .string(worktreePath)]) }

    /// `addTaskFolderRepository`, answering the updated `TaskFolder`.
    public static func addRepositoryInput(threadId: ThreadId, repositoryPath: String) -> JSONValue {
        .object(["threadId": .string(threadId.rawValue), "repositoryPath": .string(repositoryPath)])
    }

    /// `approveLayoutCommands` (:128-139): `command` is the text the person was shown, so a file that changed
    /// since is not approved unseen; nil withdraws the approval. Answers like `layoutCommands`.
    public static func approveInput(projectId: ProjectId, approvals: [(kind: String, command: String?)]) -> JSONValue {
        .object(["projectId": .string(projectId.rawValue), "approvals": .array(approvals.map {
            .object(["kind": .string($0.kind), "command": $0.command.map(JSONValue.string) ?? .null])
        })])
    }

    /// `project.update` fields (project.ts:253-257), applied to the server's list so two clients' edits merge.
    /// Added folders carry no `discovered`; removals name tracked paths.
    public static func trackFoldersFields(track: [(path: String, name: String)] = [], untrack: [String] = []) -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        if !track.isEmpty { o["trackFolders"] = .array(track.map { .object(["path": .string($0.path), "name": .string($0.name)]) }) }
        if !untrack.isEmpty { o["untrackFolders"] = .array(untrack.map(JSONValue.string)) }
        return o
    }
}

/// Repository checkpoint scopes (5258 orchestrationV2.ts:1096-1103): checkpoint scopes stay raw JSON in
/// `ThreadProjection.checkpointScopes`, so these read the new keys.
public enum CheckpointScopeFields {
    /// A repository scope's folder name.
    public static func label(_ scope: JSONValue) -> String? { scope["label"]?.stringValue }
    /// Set on a repository scope: the tracked Git folder it covers, which stays the same when `cwd` moves. Such a
    /// scope uses kind `manual`. T3 leaves repository scopes out when it picks a rewind checkpoint.
    public static func repositoryPath(_ scope: JSONValue) -> String? { scope["repositoryPath"]?.stringValue }
}
