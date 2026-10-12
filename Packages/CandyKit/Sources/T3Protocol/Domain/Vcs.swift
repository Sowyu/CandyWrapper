import Foundation

// Git and source control wire types (packages/contracts/src/git.ts, sourceControl.ts) and the RPC
// payloads the branch toolbar and git actions send (protocol.md 9.2).

/// `SourceControlProviderInfo` (sourceControl.ts): the repository's host as the server detected it.
public struct SourceControlProviderInfo: Codable, Hashable, Sendable {
    public var kind: String
    public var name: String
    public var baseUrl: String
    public init(kind: String, name: String = "", baseUrl: String = "") { self.kind = kind; self.name = name; self.baseUrl = baseUrl }
}

/// `VcsStatusResult` (git.ts:272-276): the local part (working tree, ref) and the remote part
/// (upstream, ahead and behind, change request) merged, as `applyGitStatusStreamEvent` keeps it.
public struct VcsStatus: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        public var path: String
        public var insertions: Int
        public var deletions: Int
        public init(path: String, insertions: Int, deletions: Int) { self.path = path; self.insertions = insertions; self.deletions = deletions }
    }
    public struct WorkingTree: Codable, Hashable, Sendable {
        public var files: [File]
        public var insertions: Int
        public var deletions: Int
        public init(files: [File] = [], insertions: Int = 0, deletions: Int = 0) { self.files = files; self.insertions = insertions; self.deletions = deletions }
    }
    public struct BranchChanges: Codable, Hashable, Sendable {
        public var baseRef: String?
        public var insertions: Int
        public var deletions: Int
    }
    /// `VcsStatusChangeRequest`.
    public struct ChangeRequest: Codable, Hashable, Sendable {
        public var number: Int
        public var title: String
        public var url: String
        public var baseRef: String
        public var headRef: String
        public var state: String
        public var isDraft: Bool?
        public init(number: Int, title: String, url: String, baseRef: String, headRef: String, state: String, isDraft: Bool? = nil) {
            self.number = number; self.title = title; self.url = url; self.baseRef = baseRef; self.headRef = headRef; self.state = state; self.isDraft = isDraft
        }
    }

    // Local.
    public var isRepo: Bool
    public var sourceControlProvider: SourceControlProviderInfo?
    public var hasPrimaryRemote: Bool
    public var isDefaultRef: Bool
    public var refName: String?
    public var hasWorkingTreeChanges: Bool
    public var workingTree: WorkingTree
    public var branchChanges: BranchChanges?
    // Remote (`EMPTY_GIT_STATUS_REMOTE` when the server has none yet).
    public var hasUpstream: Bool
    public var aheadCount: Int
    public var behindCount: Int
    public var aheadOfDefaultCount: Int?
    public var pr: ChangeRequest?

    public init(isRepo: Bool = true, sourceControlProvider: SourceControlProviderInfo? = nil, hasPrimaryRemote: Bool = false,
                isDefaultRef: Bool = false, refName: String? = nil, hasWorkingTreeChanges: Bool = false,
                workingTree: WorkingTree = WorkingTree(), branchChanges: BranchChanges? = nil, hasUpstream: Bool = false,
                aheadCount: Int = 0, behindCount: Int = 0, aheadOfDefaultCount: Int? = nil, pr: ChangeRequest? = nil) {
        self.isRepo = isRepo; self.sourceControlProvider = sourceControlProvider; self.hasPrimaryRemote = hasPrimaryRemote
        self.isDefaultRef = isDefaultRef; self.refName = refName; self.hasWorkingTreeChanges = hasWorkingTreeChanges
        self.workingTree = workingTree; self.branchChanges = branchChanges; self.hasUpstream = hasUpstream
        self.aheadCount = aheadCount; self.behindCount = behindCount; self.aheadOfDefaultCount = aheadOfDefaultCount; self.pr = pr
    }

    private enum CodingKeys: String, CodingKey {
        case isRepo, sourceControlProvider, hasPrimaryRemote, isDefaultRef, refName, hasWorkingTreeChanges, workingTree, branchChanges
        case hasUpstream, aheadCount, behindCount, aheadOfDefaultCount, pr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isRepo = try c.decodeIfPresent(Bool.self, forKey: .isRepo) ?? true
        sourceControlProvider = try c.decodeIfPresent(SourceControlProviderInfo.self, forKey: .sourceControlProvider)
        hasPrimaryRemote = try c.decodeIfPresent(Bool.self, forKey: .hasPrimaryRemote) ?? false
        isDefaultRef = try c.decodeIfPresent(Bool.self, forKey: .isDefaultRef) ?? false
        refName = try c.decodeIfPresent(String.self, forKey: .refName)
        hasWorkingTreeChanges = try c.decodeIfPresent(Bool.self, forKey: .hasWorkingTreeChanges) ?? false
        workingTree = try c.decodeIfPresent(WorkingTree.self, forKey: .workingTree) ?? WorkingTree()
        branchChanges = try c.decodeIfPresent(BranchChanges.self, forKey: .branchChanges)
        hasUpstream = try c.decodeIfPresent(Bool.self, forKey: .hasUpstream) ?? false
        aheadCount = try c.decodeIfPresent(Int.self, forKey: .aheadCount) ?? 0
        behindCount = try c.decodeIfPresent(Int.self, forKey: .behindCount) ?? 0
        aheadOfDefaultCount = try c.decodeIfPresent(Int.self, forKey: .aheadOfDefaultCount)
        pr = try c.decodeIfPresent(ChangeRequest.self, forKey: .pr)
    }

    /// The local fields of `local` with this status's remote fields (`mergeGitStatusParts`).
    func withLocal(_ local: VcsStatus) -> VcsStatus {
        var next = local
        next.hasUpstream = hasUpstream; next.aheadCount = aheadCount; next.behindCount = behindCount
        next.aheadOfDefaultCount = aheadOfDefaultCount; next.pr = pr
        return next
    }

    /// This status's local fields with `remote`'s remote fields; nil clears them (`EMPTY_GIT_STATUS_REMOTE`).
    func withRemote(_ remote: VcsStatus?) -> VcsStatus {
        var next = self
        next.hasUpstream = remote?.hasUpstream ?? false
        next.aheadCount = remote?.aheadCount ?? 0
        next.behindCount = remote?.behindCount ?? 0
        next.aheadOfDefaultCount = remote?.aheadOfDefaultCount
        next.pr = remote?.pr
        return next
    }

    /// `applyGitStatusStreamEvent` (shared/git.ts:397-422) for one `subscribeVcsStatus` event
    /// (`snapshot{local, remote}`, `localUpdated{local}`, `remoteUpdated{remote}`). Unknown tags keep `current`.
    public static func apply(_ event: JSONValue, to current: VcsStatus?) -> VcsStatus? {
        guard case .object(let o) = event, let tag = o["_tag"]?.stringValue else { return current }
        func decode(_ key: String) -> VcsStatus? {
            guard let v = o[key], v != .null else { return nil }
            return try? v.decode(as: VcsStatus.self)
        }
        switch tag {
        case "snapshot":
            guard let local = decode("local") else { return current }
            return local.withRemote(decode("remote"))
        case "localUpdated":
            guard let local = decode("local") else { return current }
            return (current ?? local.withRemote(nil)).withLocal(local)
        case "remoteUpdated":
            return (current ?? VcsStatus()).withRemote(decode("remote"))
        default:
            return current
        }
    }
}

/// `VcsRef` (git.ts:80-87).
public struct VcsRef: Codable, Hashable, Sendable {
    public var name: String
    public var isRemote: Bool?
    public var remoteName: String?
    public var current: Bool
    public var isDefault: Bool
    public var worktreePath: String?
    public init(name: String, isRemote: Bool? = nil, remoteName: String? = nil, current: Bool = false, isDefault: Bool = false, worktreePath: String? = nil) {
        self.name = name; self.isRemote = isRemote; self.remoteName = remoteName; self.current = current; self.isDefault = isDefault; self.worktreePath = worktreePath
    }
}

/// `VcsListRefsResult` (git.ts:292-298).
public struct VcsListRefsResult: Codable, Hashable, Sendable {
    public var refs: [VcsRef]
    public var isRepo: Bool
    public var hasPrimaryRemote: Bool
    public var nextCursor: Int?
    public var totalCount: Int
}

/// `GitStackedAction` (git.ts:18-24).
public enum GitStackedAction: String, Codable, Sendable, CaseIterable {
    case commit, push
    case createPr = "create_pr"
    case commitPush = "commit_push"
    case commitPushPr = "commit_push_pr"
}

/// `GitRunStackedActionResult` (git.ts:329-355), the parts the client reads.
public struct GitRunStackedActionResult: Decodable, Hashable, Sendable {
    public struct Branch: Decodable, Hashable, Sendable { public var status: String; public var name: String? }
    public struct Toast: Decodable, Hashable, Sendable {
        public struct Cta: Decodable, Hashable, Sendable {
            public struct RunAction: Decodable, Hashable, Sendable { public var kind: GitStackedAction }
            public var kind: String
            public var label: String?
            public var url: String?
            public var action: RunAction?
        }
        public var title: String
        public var description: String?
        public var cta: Cta
    }
    public var action: GitStackedAction
    public var branch: Branch
    public var toast: Toast
}

/// `GitActionProgressEvent` (git.ts:451-500). Exactly one `action_finished` or `action_failed` ends the stream.
public enum GitActionProgressEvent: Sendable, Equatable {
    case started(phases: [String])
    case phaseStarted(label: String)
    case hookStarted(name: String)
    case hookOutput(text: String)
    case hookFinished
    case finished(GitRunStackedActionResult)
    case failed(message: String)

    public init?(json: JSONValue) {
        guard case .object(let o) = json, let kind = o["kind"]?.stringValue else { return nil }
        switch kind {
        case "action_started":
            guard case .array(let p)? = o["phases"] else { return nil }
            self = .started(phases: p.compactMap(\.stringValue))
        case "phase_started": self = .phaseStarted(label: o["label"]?.stringValue ?? "")
        case "hook_started": self = .hookStarted(name: o["hookName"]?.stringValue ?? "")
        case "hook_output": self = .hookOutput(text: o["text"]?.stringValue ?? "")
        case "hook_finished": self = .hookFinished
        case "action_finished":
            guard let r = o["result"], let result = try? r.decode(as: GitRunStackedActionResult.self) else { return nil }
            self = .finished(result)
        case "action_failed": self = .failed(message: o["message"]?.stringValue ?? "An error occurred.")
        default: return nil
        }
    }
}

/// `VcsPullResult` (git.ts:358-362).
public struct VcsPullResult: Decodable, Hashable, Sendable {
    public var status: String
    public var refName: String
    public var upstreamRef: String?
}

/// `SourceControlProviderDiscoveryItem` (sourceControl.ts:161-166). `Option` fields arrive as
/// `{"_tag":"Some","value":...}` or `{"_tag":"None"}`.
public struct SourceControlProviderDiscovery: Hashable, Sendable {
    public var kind: String
    public var label: String
    public var status: String
    public var installHint: String
    public var authStatus: String
    public var account: String?
    public var host: String?
    public var detail: String?

    public init(kind: String, label: String, status: String, installHint: String, authStatus: String,
                account: String? = nil, host: String? = nil, detail: String? = nil) {
        self.kind = kind; self.label = label; self.status = status; self.installHint = installHint
        self.authStatus = authStatus; self.account = account; self.host = host; self.detail = detail
    }

    static func option(_ v: JSONValue?) -> String? {
        guard case .object(let o)? = v else { return v?.stringValue }
        return o["_tag"]?.stringValue == "Some" ? o["value"]?.stringValue : nil
    }

    /// The `sourceControlProviders` of a `server.discoverSourceControl` result.
    public static func list(_ result: JSONValue) -> [SourceControlProviderDiscovery] {
        guard case .array(let items)? = result.objectValue?["sourceControlProviders"] else { return [] }
        return items.compactMap { item in
            guard case .object(let o) = item, let kind = o["kind"]?.stringValue else { return nil }
            let auth = o["auth"]?.objectValue ?? [:]
            return SourceControlProviderDiscovery(
                kind: kind, label: o["label"]?.stringValue ?? kind, status: o["status"]?.stringValue ?? "missing",
                installHint: o["installHint"]?.stringValue ?? "", authStatus: auth["status"]?.stringValue ?? "unknown",
                account: option(auth["account"]), host: option(auth["host"]), detail: option(auth["detail"]))
        }
    }
}

/// `SourceControlPublishRepositoryResult` (sourceControl.ts:103-110).
public struct SourceControlPublishResult: Decodable, Hashable, Sendable {
    public struct Repository: Decodable, Hashable, Sendable { public var nameWithOwner: String; public var url: String }
    public var repository: Repository
    public var remoteName: String
    public var branch: String
    public var status: String
}

/// RPC tags and payloads (contracts rpc.ts:1287-1367, sourceControl at 748 and 1151).
public enum VcsRPC {
    public static let subscribeStatus = "subscribeVcsStatus"
    public static let refreshStatus = "vcs.refreshStatus"
    public static let listRefs = "vcs.listRefs"
    public static let switchRef = "vcs.switchRef"
    public static let createRef = "vcs.createRef"
    public static let pull = "vcs.pull"
    public static let initRepo = "vcs.init"
    public static let runStackedAction = "git.runStackedAction"
    public static let discoverSourceControl = "server.discoverSourceControl"
    public static let publishRepository = "sourceControl.publishRepository"

    /// `VCS_REF_LIST_LIMIT` (web state/queries.ts:40).
    public static let refPageLimit = 100

    public static func cwd(_ cwd: String) -> JSONValue { .object(["cwd": .string(cwd)]) }

    /// `vcs.listRefs`: the query rides only when non-empty, the cursor only past the first page.
    public static func listRefsInput(cwd: String, query: String = "", cursor: Int? = nil, limit: Int = refPageLimit) -> JSONValue {
        var o: [String: JSONValue] = ["cwd": .string(cwd), "limit": .number(Double(limit))]
        if !query.isEmpty { o["query"] = .string(query) }
        if let cursor { o["cursor"] = .number(Double(cursor)) }
        return .object(o)
    }

    /// The diff panel's comparison targets: one kind of ref with the matching remotes (DiffPanel.tsx:416-449).
    public static func baseRefsInput(cwd: String, remote: Bool) -> JSONValue {
        .object(["cwd": .string(cwd), "includeMatchingRemoteRefs": .bool(true), "refKind": .string(remote ? "remote" : "local"),
                 "limit": .number(Double(refPageLimit))])
    }

    public static func switchRefInput(cwd: String, refName: String) -> JSONValue {
        .object(["cwd": .string(cwd), "refName": .string(refName)])
    }

    /// `createRef` in BranchToolbarBranchSelector.tsx:498-505: always switches to the new ref.
    public static func createRefInput(cwd: String, refName: String) -> JSONValue {
        .object(["cwd": .string(cwd), "refName": .string(refName), "switchRef": .bool(true)])
    }

    /// `runGitActionWithToast` (GitActionsControl.tsx:1372-1382): optional fields ride only when set.
    public static func runStackedActionInput(actionId: String, cwd: String, action: GitStackedAction, commitMessage: String? = nil,
                                             featureBranch: Bool = false, filePaths: [String]? = nil,
                                             threadId: String? = nil, projectId: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["actionId": .string(actionId), "cwd": .string(cwd), "action": .string(action.rawValue)]
        if let commitMessage, !commitMessage.isEmpty { o["commitMessage"] = .string(commitMessage) }
        if featureBranch { o["featureBranch"] = .bool(true) }
        if let filePaths { o["filePaths"] = .array(filePaths.map(JSONValue.string)) }
        if let threadId { o["threadId"] = .string(threadId) }
        if let projectId { o["projectId"] = .string(projectId) }
        return .object(o)
    }

    /// `submitPublishRepository` (GitActionsControl.tsx:637-645).
    public static func publishInput(cwd: String, provider: String, repository: String, visibility: String,
                                    remoteName: String, protocol proto: String) -> JSONValue {
        let remote = remoteName.trimmingCharacters(in: .whitespaces)
        return .object(["cwd": .string(cwd), "provider": .string(provider),
                        "repository": .string(repository.trimmingCharacters(in: .whitespacesAndNewlines)),
                        "visibility": .string(visibility), "remoteName": .string(remote.isEmpty ? "origin" : remote),
                        "protocol": .string(proto)])
    }
}

/// The user-facing text of a git or source control failure: the `message` getters of `GitCommandError`,
/// `TextGenerationError`, `GitManagerError` and `SourceControlProviderError` (git.ts:382-449,
/// sourceControl.ts:174-190), else the error's own `message` or `detail`.
public enum GitErrorText {
    public static func message(_ error: RPCTypedError) -> String {
        let f = error.fields
        func s(_ k: String) -> String { f[k]?.stringValue ?? "" }
        switch error.tag {
        case "GitCommandError":
            let reason = f["reason"]?.stringValue.map { " (\($0))" } ?? ""
            return "Git command failed in \(s("operation")) (\(s("cwd"))): \(s("detail"))\(reason)"
        case "TextGenerationError": return "Text generation failed in \(s("operation")): \(s("detail"))"
        case "GitManagerError": return "Git manager failed in \(s("operation")): \(s("detail"))"
        case "SourceControlProviderError": return "Source control provider \(s("provider")) failed in \(s("operation")): \(s("detail"))"
        default: return error.message ?? "An error occurred."
        }
    }
}
