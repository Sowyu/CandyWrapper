// Repository sections on the thread details card for multi-repository threads (5258
// packages/client-runtime/src/state/threadRepositories.ts, 739 lines; apps/web/src/components/chat/
// ThreadRepositorySections.tsx, 374; ThreadDetailsPanel.tsx:185-305; #42919 67918f51cc).
//
// Plan, smallest end-to-end slice first:
// 1. Read only (this file and `ThreadRepositorySectionsView`): a thread whose project tracks folders lists the
//    repositories it changed, from the projection's repository checkpoint scopes, most recently changed first.
//    Each row reads `vcs.status` with `includeRemote: false` for its folder and shows the name, the branch (or
//    "Not a Git repository", "Detached HEAD"), the branch's pull request number and the working tree's +/- counts.
//    Four show, then "Show N more" / "Show fewer". With none, "Repositories appear here once this thread changes
//    them." The plain project folder loses "Initialize Git" (`show.git` is false while it tracks folders).
// 2. The git control per repository: a row expands into `GitActionsControl` for that folder (commit, push, PR).
//    CW's `GitController` drives exactly one cwd, the thread's, so this needs a second controller instance keyed
//    by repository path. Left for now.
// 3. Pins ("Other repositories...", `threadRepositoryPinsStore.ts`): a per-thread list of tracked folders the user
//    added, persisted client-side under `t3code:thread-repository-pins`, read from `workspace.listFolders`, with
//    "Remove from this thread" in an expanded section. Left.
// 4. Task folders (`filesystem.taskFolder`, `TaskFolder` is decoded): a worktree thread lists its task folder's
//    worktrees instead, changed ones first, and "Other repositories..." adds a worktree through
//    `filesystem.addTaskFolderRepository`. Left; it needs the task folder query on the details card.
import Foundation
import T3Protocol

public enum ThreadRepositories {
    /// `THREAD_REPOSITORY_SECTIONS_VISIBLE`.
    public static let visibleCount = 4

    /// `ThreadRepositoryScope`: a tracked Git repository the thread reaches.
    public struct Scope: Sendable, Equatable {
        public let scopeId: String
        public let name: String
        /// Stable identity, the tracked folder.
        public let repositoryPath: String
        /// Where Git runs.
        public let cwd: String
    }

    /// `ThreadRepositorySection` with origin `changed`.
    public struct Section: Sendable, Equatable {
        public let key: String
        public let name: String
        public let cwd: String
    }

    /// `threadRepositoryScopes` (threadRepositories.ts:182-199): repository scopes by name, then path.
    public static func scopes(_ projection: ThreadProjection) -> [Scope] {
        projection.checkpointScopes.compactMap { scope -> Scope? in
            guard let path = CheckpointScopeFields.repositoryPath(scope), let id = scope["id"]?.stringValue else { return nil }
            let cwd = scope["cwd"]?.stringValue ?? path
            let name = CheckpointScopeFields.label(scope)
                ?? cwd.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? cwd
            return Scope(scopeId: id, name: name, repositoryPath: path, cwd: cwd)
        }
        .sorted { a, b in
            let order = a.name.localizedCompare(b.name)
            return order != .orderedSame ? order == .orderedAscending : a.repositoryPath < b.repositoryPath
        }
    }

    /// `threadChangedRepositories` (:421-441): most recently changed first; one never checkpointed sorts last.
    public static func changed(_ projection: ThreadProjection) -> [Scope] {
        let scopes = scopes(projection)
        guard scopes.count > 1 else { return scopes }
        var last: [String: Int] = [:]
        for checkpoint in projection.checkpoints where checkpoint.runId != nil {
            let ordinal = checkpoint.ordinalWithinScope ?? -1
            if ordinal > (last[checkpoint.scopeId.rawValue] ?? -1) { last[checkpoint.scopeId.rawValue] = ordinal }
        }
        // Stable: equal ranks keep the name order.
        return scopes.enumerated().sorted { a, b in
            let la = last[a.element.scopeId] ?? -1, lb = last[b.element.scopeId] ?? -1
            return la != lb ? la > lb : a.offset < b.offset
        }.map(\.element)
    }

    /// `threadRepositorySections` without pins or a task folder (:531-588): the changed repositories, never the
    /// thread's own folder, four unless `showAll`.
    public static func sections(changed: [Scope], threadCwd: String?, showAll: Bool) -> (visible: [Section], hidden: [Section]) {
        var seen: Set<String> = threadCwd.map { [$0] } ?? []
        var all: [Section] = []
        for scope in changed where seen.insert(scope.repositoryPath).inserted {
            all.append(Section(key: scope.repositoryPath, name: scope.name, cwd: scope.cwd))
        }
        if showAll || all.count <= visibleCount { return (all, []) }
        return (Array(all.prefix(visibleCount)), Array(all.dropFirst(visibleCount)))
    }

    /// `RepositorySectionSummary` (:712-739) from a `vcs.status` reply.
    public struct Summary: Sendable, Equatable {
        public let branch: String?
        public let isRepository: Bool
        public let changedFiles: Int
        public let insertions: Int
        public let deletions: Int
        public let pullRequestNumber: Int?

        public init(branch: String?, isRepository: Bool, changedFiles: Int, insertions: Int, deletions: Int, pullRequestNumber: Int?) {
            self.branch = branch; self.isRepository = isRepository; self.changedFiles = changedFiles
            self.insertions = insertions; self.deletions = deletions; self.pullRequestNumber = pullRequestNumber
        }

        public init?(status: JSONValue?) {
            guard let status, case .object = status else { return nil }
            let tree = status["workingTree"]
            let files: Int = if case .array(let list)? = tree?["files"] { list.count } else { 0 }
            self.init(branch: status["refName"]?.stringValue, isRepository: status["isRepo"]?.boolValue ?? false,
                      changedFiles: files, insertions: tree?["insertions"]?.intValue ?? 0, deletions: tree?["deletions"]?.intValue ?? 0,
                      pullRequestNumber: status["pr"]?["number"]?.intValue)
        }
    }
}
