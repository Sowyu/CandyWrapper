import Foundation
import T3Protocol

/// `ChangeRequestTerminology` (shared/sourceControl.ts:23-140): "PR" and "pull request" unless the
/// repository's host calls them otherwise (GitLab "MR", an unknown host "change request").
public struct ChangeRequestTerminology: Equatable, Sendable {
    public var shortLabel: String
    public var singular: String
    public static let `default` = ChangeRequestTerminology(shortLabel: "PR", singular: "pull request")

    public static func of(_ provider: SourceControlProviderInfo?) -> ChangeRequestTerminology {
        of(kind: provider?.kind)
    }

    public var title: String { singular.prefix(1).uppercased() + singular.dropFirst() }

    /// Host wording from source-control-core/src/shared/definition.ts and each host client.
    public static func of(kind: String?) -> ChangeRequestTerminology {
        switch kind {
        case nil, "github", "gitcafe", "forgejo", "azure-devops", "bitbucket": .default
        case "gitlab": ChangeRequestTerminology(shortLabel: "MR", singular: "merge request")
        default: ChangeRequestTerminology(shortLabel: "change request", singular: "change request")
        }
    }
}

/// GitActionsControl.logic.ts and the menu's disabled reasons (GitActionsControl.tsx:290-358).
public enum GitActionsLogic {
    public enum MenuItemId: String, Sendable { case commit, push, pr }

    /// `GitActionMenuItem`.
    public struct MenuItem: Equatable, Sendable {
        public var id: MenuItemId
        public var label: String
        public var disabled: Bool
        /// `dialogAction`: commit opens the dialog, push and create PR run at once.
        public var action: GitStackedAction
    }

    /// `GitQuickAction`.
    public struct QuickAction: Equatable, Sendable {
        public enum Kind: Sendable, Equatable { case runAction, runPull, openPublish, showHint }
        public var label: String
        public var disabled: Bool
        public var kind: Kind
        public var action: GitStackedAction?
        public var hint: String?
    }

    public struct DialogCopy: Equatable, Sendable {
        public var title: String
        public var description: String
        public var continueLabel: String
    }

    /// `GIT_ACTION_SUCCESS_VISIBLE_MS`: the inline success row stays 10 s.
    public static let successVisibleSeconds: TimeInterval = 10

    /// `buildMenuItems` (logic.ts:174-249).
    public static func menuItems(_ status: VcsStatus?, busy: Bool, hasPrimaryRemote: Bool = true) -> [MenuItem] {
        guard let s = status else { return [] }
        let terms = ChangeRequestTerminology.of(s.sourceControlProvider)
        let hasBranch = s.refName != nil
        let hasChanges = s.hasWorkingTreeChanges
        let hasOpenPr = s.pr?.state == "open"
        let isBehind = s.behindCount > 0
        let hasDefaultBranchDelta = (s.aheadOfDefaultCount ?? s.aheadCount) > 0
        let canPushWithoutUpstream = hasPrimaryRemote && !s.hasUpstream
        let canCommit = !busy && hasChanges
        let canPush = !busy && hasBranch && !isBehind && s.aheadCount > 0 && (s.hasUpstream || canPushWithoutUpstream)
        let canCreatePr = !busy && hasBranch && !hasChanges && !hasOpenPr && hasDefaultBranchDelta && !isBehind
            && (s.hasUpstream || canPushWithoutUpstream)
        let commit = MenuItem(id: .commit, label: "Commit", disabled: !canCommit, action: .commit)
        guard hasPrimaryRemote else { return [commit] }
        let push = MenuItem(id: .push, label: "Push", disabled: !canPush, action: .push)
        if hasOpenPr { return [commit, push] }
        return [commit, push, MenuItem(id: .pr, label: "Create \(terms.shortLabel)", disabled: !canCreatePr, action: .createPr)]
    }

    /// `resolveQuickAction` (logic.ts:251-405).
    public static func quickAction(_ status: VcsStatus?, busy: Bool, isDefaultRef: Bool = false, hasPrimaryRemote: Bool = true) -> QuickAction {
        if busy { return QuickAction(label: "Commit", disabled: true, kind: .showHint, hint: "Git action in progress.") }
        guard let s = status else { return QuickAction(label: "Commit", disabled: true, kind: .showHint, hint: "Git status is unavailable.") }
        let hasBranch = s.refName != nil
        let hasChanges = s.hasWorkingTreeChanges
        let hasOpenPr = s.pr?.state == "open"
        let isAhead = s.aheadCount > 0
        let hasDefaultBranchDelta = (s.aheadOfDefaultCount ?? s.aheadCount) > 0
        let isBehind = s.behindCount > 0
        let terms = ChangeRequestTerminology.of(s.sourceControlProvider)
        func run(_ label: String, _ action: GitStackedAction) -> QuickAction { QuickAction(label: label, disabled: false, kind: .runAction, action: action) }
        func hint(_ label: String, _ text: String) -> QuickAction { QuickAction(label: label, disabled: true, kind: .showHint, hint: text) }
        let upToDate = "Branch is up to date. No action needed."

        guard hasBranch else { return hint("Commit", "Create and checkout a ref before pushing or opening a \(terms.singular).") }
        if hasChanges {
            if !s.hasUpstream && !hasPrimaryRemote { return run("Commit", .commit) }
            if hasOpenPr || isDefaultRef { return run("Commit & push", .commitPush) }
            return run("Commit, push & \(terms.shortLabel)", .commitPushPr)
        }
        if !s.hasUpstream {
            if !hasPrimaryRemote { return QuickAction(label: "Publish repository", disabled: false, kind: .openPublish) }
            if !isAhead { return hasOpenPr ? hint("Commit", upToDate) : hint("Push", "No local commits to push.") }
            if hasOpenPr || isDefaultRef { return run("Push", isDefaultRef ? .commitPush : .push) }
            return run("Push & create \(terms.shortLabel)", .createPr)
        }
        if isAhead && isBehind { return hint("Sync ref", "Branch has diverged from upstream. Rebase/merge first.") }
        if isBehind { return QuickAction(label: "Pull", disabled: false, kind: .runPull) }
        if isAhead {
            if hasOpenPr || isDefaultRef { return run("Push", isDefaultRef ? .commitPush : .push) }
            return run("Push & create \(terms.shortLabel)", .createPr)
        }
        if hasOpenPr && s.hasUpstream { return hint("Commit", upToDate) }
        if hasDefaultBranchDelta && !isDefaultRef { return run("Create \(terms.shortLabel)", .createPr) }
        return hint("Commit", upToDate)
    }

    /// `getMenuActionDisabledReason` (GitActionsControl.tsx:290-358).
    public static func disabledReason(_ item: MenuItem, status: VcsStatus?, busy: Bool, hasPrimaryRemote: Bool) -> String? {
        guard item.disabled else { return nil }
        if busy { return "Git action in progress." }
        guard let s = status else { return "Git status is unavailable." }
        let hasBranch = s.refName != nil
        let hasChanges = s.hasWorkingTreeChanges
        let isAhead = s.aheadCount > 0
        let isBehind = s.behindCount > 0
        let terms = ChangeRequestTerminology.of(s.sourceControlProvider)
        switch item.id {
        case .commit:
            return hasChanges ? "Commit is currently unavailable." : "Worktree is clean. Make changes before committing."
        case .push:
            if !hasBranch { return "Detached HEAD: check out a branch before pushing." }
            if hasChanges { return "Commit or stash local changes before pushing." }
            if isBehind { return "Branch is behind upstream. Pull/rebase before pushing." }
            if !s.hasUpstream && !hasPrimaryRemote { return "Add an \"origin\" remote before pushing." }
            if !isAhead { return "No local commits to push." }
            return "Push is currently unavailable."
        case .pr:
            if !hasBranch { return "Detached HEAD: check out a branch before creating a \(terms.singular)." }
            if hasChanges { return "Commit local changes before creating a \(terms.singular)." }
            if !s.hasUpstream && !hasPrimaryRemote { return "Add an \"origin\" remote before creating a \(terms.singular)." }
            if !isAhead { return "No local commits to include in a \(terms.singular)." }
            if isBehind { return "Branch is behind upstream. Pull/rebase before creating a \(terms.singular)." }
            return "Create \(terms.singular) is currently unavailable."
        }
    }

    /// The menu's footnotes (GitActionsControl.tsx:1745-1757): detached HEAD and behind upstream, in warning.
    public static func menuNotes(_ status: VcsStatus?) -> [String] {
        guard let s = status else { return [] }
        if s.refName == nil { return ["Detached HEAD: create and check out a branch to enable push and \(ChangeRequestTerminology.of(s.sourceControlProvider).singular) actions."] }
        if !s.hasWorkingTreeChanges && s.behindCount > 0 && s.aheadCount == 0 { return ["Behind upstream. Pull/rebase first."] }
        return []
    }

    /// `requiresDefaultBranchConfirmation` (logic.ts:407-418).
    public static func requiresDefaultBranchConfirmation(_ action: GitStackedAction, isDefaultRef: Bool) -> Bool {
        isDefaultRef && action != .commit
    }

    /// `resolveDefaultBranchActionDialogCopy` (logic.ts:420-458).
    public static func defaultBranchDialogCopy(action: GitStackedAction, branchName: String, includesCommit: Bool,
                                               terminology terms: ChangeRequestTerminology = .default) -> DialogCopy {
        let suffix = " on \"\(branchName)\". You can continue on this ref or create a feature ref and run the same action there."
        if action == .push || action == .commitPush {
            if includesCommit {
                return DialogCopy(title: "Commit & push to default ref?", description: "This action will commit and push changes\(suffix)",
                                  continueLabel: "Commit & push to \(branchName)")
            }
            return DialogCopy(title: "Push to default ref?", description: "This action will push local commits\(suffix)",
                              continueLabel: "Push to \(branchName)")
        }
        if includesCommit {
            return DialogCopy(title: "Commit, push & create \(terms.shortLabel) from default ref?",
                              description: "This action will commit, push, and create a \(terms.singular)\(suffix)",
                              continueLabel: "Commit, push & create \(terms.shortLabel)")
        }
        return DialogCopy(title: "Push & create \(terms.shortLabel) from default ref?",
                          description: "This action will push local commits and create a \(terms.singular)\(suffix)",
                          continueLabel: "Push & create \(terms.shortLabel)")
    }

    /// `resolveFeatureBranchUnavailableReason` (logic.ts:395-405): the server names the feature
    /// branch from the uncommitted changes, so a clean tree can't use it.
    public static func featureBranchUnavailableReason(branchName: String, hasWorkingTreeChanges: Bool) -> String? {
        hasWorkingTreeChanges ? nil
            : "There are no changes to commit, so a feature branch can't be named. Create a branch yourself or continue on \(branchName)."
    }

    /// `includesCommit` in `runGitActionWithToast` (GitActionsControl.tsx:1335-1339).
    public static func includesCommit(_ action: GitStackedAction, status: VcsStatus?, featureBranch: Bool) -> Bool {
        let canCommit = action == .commit || action == .commitPush || action == .commitPushPr
        return canCommit && (action == .commit || (status?.hasWorkingTreeChanges ?? false) || featureBranch)
    }

    /// `resolveGitActionProgressPresentation` (logic.ts:79-106): the running button's status line.
    public static func progressStatus(isPull: Bool, currentLabel: String?) -> String {
        let label = currentLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty && label != "Running source control action" { return label }
        return isPull ? "Pulling latest changes..." : "Starting source control action..."
    }

    /// `formatGitActionElapsed` (logic.ts:108-122).
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    /// The pull result's inline copy (GitActionsControl.tsx:1546-1551).
    public static func pullSuccess(_ r: VcsPullResult) -> (title: String, description: String) {
        r.status == "pulled"
            ? ("Pulled", "Updated \(r.refName) from \(r.upstreamRef ?? "upstream")")
            : ("Already up to date", "\(r.refName) is already synchronized.")
    }

    /// T3 3814 GitActionsControl.tsx:1228-1234 omits the repeated PR title after creation.
    public static func inlineSuccess(_ result: GitRunStackedActionResult, terminology: ChangeRequestTerminology = .default) -> (title: String, description: String?) {
        result.pr?.status == "created" ? ("Created \(terminology.shortLabel)", nil) : (result.toast.title, result.toast.description)
    }

    /// `resolveThreadBranchUpdate` (logic.ts:460-470): the branch a `featureBranch` run created.
    public static func createdBranch(_ result: GitRunStackedActionResult) -> String? {
        result.branch.status == "created" ? result.branch.name : nil
    }

    // MARK: Commit dialog

    /// The dialog's file selection (GitActionsControl.tsx:1210-1213): every file is in until excluded;
    /// `filePaths` rides only when some are excluded.
    public struct CommitSelection: Equatable, Sendable {
        public var files: [VcsStatus.File]
        public var excluded: Set<String> = []
        public init(files: [VcsStatus.File]) { self.files = files }
        public var selected: [VcsStatus.File] { files.filter { !excluded.contains($0.path) } }
        public var allSelected: Bool { excluded.isEmpty }
        public var noneSelected: Bool { selected.isEmpty }
        public var filePaths: [String]? { allSelected ? nil : selected.map(\.path) }
        public var totals: (insertions: Int, deletions: Int) {
            selected.reduce((0, 0)) { ($0.0 + $1.insertions, $0.1 + $1.deletions) }
        }
        public mutating func toggle(_ path: String) {
            if excluded.contains(path) { excluded.remove(path) } else { excluded.insert(path) }
        }
        /// The header checkbox: all in, or all out when all were in.
        public mutating func toggleAll() { excluded = allSelected ? Set(files.map(\.path)) : [] }
    }

    // MARK: Publish

    public struct PublishProvider: Equatable, Sendable {
        public var kind: String
        public var label: String
        public var host: String
        public var pathPlaceholder: String
    }

    /// `PUBLISH_PROVIDER_OPTIONS` (GitActionsControl.tsx:200-248).
    public static let publishProviders = [
        PublishProvider(kind: "forgejo", label: "Forgejo / Gitea", host: "your server", pathPlaceholder: "owner/repo"),
        PublishProvider(kind: "github", label: "GitHub", host: "github.com", pathPlaceholder: "owner/repo"),
        PublishProvider(kind: "gitlab", label: "GitLab", host: "gitlab.com", pathPlaceholder: "group/project"),
        PublishProvider(kind: "bitbucket", label: "Bitbucket", host: "bitbucket.org", pathPlaceholder: "workspace/repository"),
        PublishProvider(kind: "azure-devops", label: "Azure DevOps", host: "dev.azure.com", pathPlaceholder: "project/repository"),
    ]

    /// `getPublishProviderReadiness` (GitActionsControl.tsx:263-288).
    public static func publishReadiness(_ kind: String, discovered: [SourceControlProviderDiscovery]) -> (ready: Bool, hint: String?) {
        guard let d = discovered.first(where: { $0.kind == kind }) else {
            return (false, "Provider status unavailable. Open Settings -> Source Control and rescan.")
        }
        if d.status != "available" { return (false, d.installHint) }
        if d.authStatus == "unauthenticated" {
            return (false, d.detail ?? "\(d.label) is not authenticated. Open Settings -> Source Control for setup guidance.")
        }
        return (true, nil)
    }

    /// `sortedPublishProviderOptions`: ready providers first, then by label.
    public static func sortedPublishProviders(_ discovered: [SourceControlProviderDiscovery]) -> [PublishProvider] {
        publishProviders.sorted { a, b in
            let ra = publishReadiness(a.kind, discovered: discovered).ready, rb = publishReadiness(b.kind, discovered: discovered).ready
            if ra != rb { return ra }
            return a.label.localizedCompare(b.label) == .orderedAscending
        }
    }

    /// `canSubmitPublishRepository`: an owner and a name around the first slash.
    public static func isPublishPathValid(_ repository: String) -> Bool {
        let parts = repository.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard let owner = parts.first?.trimmingCharacters(in: .whitespaces), !owner.isEmpty else { return false }
        return !parts.dropFirst().joined(separator: "/").trimmingCharacters(in: .whitespaces).isEmpty
    }
}
