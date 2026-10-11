import Foundation
import T3Protocol

/// `EnvMode` (BranchToolbar.logic.ts:26-27): run in the project's checkout or in a new worktree.
public enum EnvMode: String, Codable, Sendable { case local, worktree }

/// BranchToolbar.logic.ts and shared/git.ts helpers the branch toolbar uses.
public enum BranchToolbarLogic {
    /// `resolveLocalCheckoutBranchMismatch` (BranchToolbar.logic.ts:250-264): a Current checkout thread whose
    /// branch differs from the branch the checkout is on now.
    public static func localCheckoutBranchMismatch(envMode: EnvMode, worktreePath: String?, threadBranch: String?,
                                                    currentBranch: String?) -> (threadBranch: String, currentBranch: String)? {
        guard envMode == .local, worktreePath == nil else { return nil }
        guard let threadBranch, !threadBranch.isEmpty, let currentBranch, !currentBranch.isEmpty, threadBranch != currentBranch else { return nil }
        return (threadBranch, currentBranch)
    }

    /// `resolveEnvModeLabel`.
    public static func envModeLabel(_ mode: EnvMode) -> String { mode == .worktree ? "New worktree" : "Current checkout" }

    /// `resolveCurrentWorkspaceLabel`.
    public static func currentWorkspaceLabel(_ worktreePath: String?) -> String {
        worktreePath != nil ? "Current worktree" : envModeLabel(.local)
    }

    /// `resolveLockedWorkspaceLabel`: a locked worktree thread without a path is still creating it.
    public static func lockedWorkspaceLabel(_ worktreePath: String?, mode: EnvMode) -> String {
        if worktreePath != nil { return "Worktree" }
        return mode == .worktree ? envModeLabel(.worktree) : "Local checkout"
    }

    /// The run context's label (BranchToolbar.tsx:196-202).
    public static func workspaceLabel(mode: EnvMode, worktreePath: String?, modeLocked: Bool, forceNewWorktree: Bool = false) -> String {
        if forceNewWorktree { return envModeLabel(.worktree) }
        if modeLocked { return lockedWorkspaceLabel(worktreePath, mode: mode) }
        return mode == .worktree ? envModeLabel(.worktree) : currentWorkspaceLabel(worktreePath)
    }

    public struct PreviousWorktree: Equatable, Sendable {
        public var branch: String?
        public var worktreePath: String
        public init(branch: String?, worktreePath: String) { self.branch = branch; self.worktreePath = worktreePath }
    }

    public struct ThreadWorkspace: Sendable {
        public var branch: String?
        public var worktreePath: String?
        public var updatedAt: Date?
        public var archived: Bool
        public init(branch: String?, worktreePath: String?, updatedAt: Date?, archived: Bool = false) {
            self.branch = branch; self.worktreePath = worktreePath; self.updatedAt = updatedAt; self.archived = archived
        }
    }

    /// `resolvePreviousWorktreeSeed`: the project's most recently updated worktree other than the current one.
    public static func previousWorktree(_ threads: [ThreadWorkspace], currentWorktreePath: String?) -> PreviousWorktree? {
        var latest: (PreviousWorktree, Date)?
        for t in threads {
            guard let path = t.worktreePath, !path.isEmpty, path != currentWorktreePath, !t.archived, let at = t.updatedAt else { continue }
            if latest == nil || at > latest!.1 { latest = (PreviousWorktree(branch: t.branch, worktreePath: path), at) }
        }
        return latest?.0
    }

    /// `resolvePreviousWorktreeLabel`.
    public static func previousWorktreeLabel(_ seed: PreviousWorktree) -> String {
        seed.branch.map { "Previous worktree (\($0))" } ?? "Previous worktree"
    }

    /// `resolveBranchToolbarValue`: a new worktree shows its chosen base, otherwise the checkout's ref.
    public static func toolbarValue(mode: EnvMode, worktreePath: String?, threadBranch: String?, currentGitBranch: String?) -> String? {
        if mode == .worktree && worktreePath == nil { return threadBranch ?? currentGitBranch }
        return currentGitBranch ?? threadBranch
    }

    /// `resolveBranchTriggerLabel`.
    public static func triggerLabel(worktreePath: String?, mode: EnvMode, branch: String?, branchIsRemote: Bool?, startFromOrigin: Bool) -> String {
        guard let branch else { return "Select ref" }
        if mode == .worktree && worktreePath == nil {
            let base = startFromOrigin && branchIsRemote == false ? "origin/\(branch)" : branch
            return "From \(base)"
        }
        return branch
    }

    /// `resolveEffectiveEnvMode` for a draft (no server thread).
    public static func draftEnvMode(worktreePath: String?, draftMode: EnvMode?) -> EnvMode {
        if worktreePath != nil { return .local }
        return draftMode == .worktree ? .worktree : .local
    }

    /// `resolveDraftEnvModeAfterBranchChange`.
    public static func envModeAfterBranchChange(nextWorktreePath: String?, currentWorktreePath: String?, mode: EnvMode) -> EnvMode {
        if nextWorktreePath != nil { return .worktree }
        if mode == .worktree && currentWorktreePath == nil { return .worktree }
        return .local
    }

    public struct SelectionTarget: Equatable, Sendable {
        public var checkoutCwd: String
        public var nextWorktreePath: String?
        public var reuseExistingWorktree: Bool
    }

    /// `resolveBranchSelectionTarget`: a ref checked out in another worktree is reused there.
    public static func selectionTarget(projectCwd: String, worktreePath: String?, ref: VcsRef) -> SelectionTarget {
        if let path = ref.worktreePath {
            return SelectionTarget(checkoutCwd: path, nextWorktreePath: path == projectCwd ? nil : path, reuseExistingWorktree: true)
        }
        let next = worktreePath != nil && ref.isDefault ? nil : worktreePath
        return SelectionTarget(checkoutCwd: next ?? projectCwd, nextWorktreePath: next, reuseExistingWorktree: false)
    }

    /// `sanitizeNewRefName` (shared/git.ts:313-315): trimmed, whitespace runs become one dash.
    public static func sanitizeNewRefName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[ \\t\\n\\r\\f\\x{0B}]+", with: "-", options: .regularExpression)
    }

    /// `deriveLocalBranchNameFromRemoteRef`: `origin/feature/x` becomes `feature/x`.
    public static func localBranchName(fromRemote name: String) -> String {
        guard let i = name.firstIndex(of: "/"), i != name.startIndex, name.index(after: i) != name.endIndex else { return name }
        return String(name[name.index(after: i)...])
    }

    /// `isTemporaryWorktreeBranch` (shared/git.ts:14-26, 143-145).
    public static func isTemporaryWorktreeBranch(_ name: String) -> Bool {
        let hex = "[0-9a-f]{8}", uuid = "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"
        let pattern = "^(?:t3[-/]\(hex)|t3code(?:[-/]\(hex)|/\(uuid)))$"
        return name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().range(of: pattern, options: .regularExpression) != nil
    }

    /// The picker's synthetic rows (BranchToolbarBranchSelector.tsx:303-317).
    public static let createRefPrefix = "__create_new_branch__:"

    /// `shouldIncludeBranchPickerItem`: substring match, also on the query's sanitized name; the create row stays.
    public static func includes(_ item: String, normalizedQuery q: String, createItem: String?) -> Bool {
        if q.isEmpty || item == createItem { return true }
        let lower = item.lowercased()
        if lower.contains(q) { return true }
        let sanitized = sanitizeNewRefName(q)
        return !sanitized.isEmpty && sanitized != q && lower.contains(sanitized)
    }

    /// The picker rows for `refs` and the typed query: every ref, then "Create new ref" when the query names
    /// a ref that doesn't exist and creating is allowed, filtered by `includes`.
    public static func pickerItems(refs: [VcsRef], query: String, canCreate: Bool) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let createItem = canCreate && !trimmed.isEmpty ? createRefPrefix + trimmed : nil
        var items = refs.map(\.name)
        if let createItem, !refs.contains(where: { $0.name == sanitizeNewRefName(trimmed) }) { items.append(createItem) }
        let q = trimmed.lowercased()
        return q.isEmpty ? items : items.filter { includes($0, normalizedQuery: q, createItem: createItem) }
    }

    /// `BranchPickerRefItem`'s trailing word: current, worktree, remote or default.
    public static func refBadge(_ ref: VcsRef, projectCwd: String?) -> String? {
        if ref.current { return "current" }
        if let path = ref.worktreePath, let projectCwd, path != projectCwd { return "worktree" }
        if ref.isRemote == true { return "remote" }
        if ref.isDefault { return "default" }
        return nil
    }

    /// `branchStatusText`.
    public static func statusText(loading: Bool, loadingMore: Bool, hasNextPage: Bool, shown: Int, total: Int) -> String? {
        if loading { return "Loading refs..." }
        if loadingMore { return "Loading more refs..." }
        if hasNextPage { return "Showing \(shown) of \(total) refs" }
        return nil
    }

    /// The `launchThread` workspace strategy for a draft's first send (client-runtime commands.ts:646-669,
    /// ChatView.tsx:9218-9230 and 9876-9903): a new worktree from the chosen base, an existing worktree, or
    /// the project root on the draft's branch.
    public static func workspaceStrategy(mode: EnvMode, branch: String?, worktreePath: String?, startFromOrigin: Bool) -> JSONValue {
        if mode == .worktree, worktreePath == nil, let branch {
            var o: [String: JSONValue] = ["type": .string("worktree"), "baseRef": .string(branch)]
            if startFromOrigin { o["startFromOrigin"] = .bool(true) }
            return .object(o)
        }
        if let worktreePath {
            var o: [String: JSONValue] = ["type": .string("existing_worktree"), "worktreePath": .string(worktreePath)]
            if let branch { o["branch"] = .string(branch) }
            return .object(o)
        }
        var o: [String: JSONValue] = ["type": .string("root")]
        if let branch { o["branch"] = .string(branch) }
        return .object(o)
    }
}
