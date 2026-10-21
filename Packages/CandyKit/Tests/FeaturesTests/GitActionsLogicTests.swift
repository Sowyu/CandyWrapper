import Foundation
import Testing
import T3Protocol
@testable import Features

/// GitActionsControl.logic.ts and BranchToolbar.logic.ts ports, checked against the cases in T3's
/// GitActionsControl.logic.test.ts and BranchToolbar.logic.test.ts.
struct GitActionsLogicTests {
    typealias L = GitActionsLogic

    static func status(ref: String? = "feature/x", changes: Bool = false, upstream: Bool = true, ahead: Int = 0, behind: Int = 0,
                       aheadOfDefault: Int? = nil, pr: String? = nil, isDefault: Bool = false, remote: Bool = true,
                       provider: String? = nil) -> VcsStatus {
        VcsStatus(sourceControlProvider: provider.map { SourceControlProviderInfo(kind: $0) }, hasPrimaryRemote: remote,
                  isDefaultRef: isDefault, refName: ref, hasWorkingTreeChanges: changes,
                  workingTree: VcsStatus.WorkingTree(files: changes ? [.init(path: "a.swift", insertions: 2, deletions: 1)] : []),
                  hasUpstream: upstream, aheadCount: ahead, behindCount: behind, aheadOfDefaultCount: aheadOfDefault,
                  pr: pr.map { VcsStatus.ChangeRequest(number: 1, title: "t", url: "u", baseRef: "main", headRef: "x", state: $0) })
    }

    @Test func quickActions() {
        func q(_ s: VcsStatus?, busy: Bool = false, isDefault: Bool = false, remote: Bool = true) -> (String, L.QuickAction.Kind, GitStackedAction?, Bool) {
            let a = L.quickAction(s, busy: busy, isDefaultRef: isDefault, hasPrimaryRemote: remote)
            return (a.label, a.kind, a.action, a.disabled)
        }
        #expect(q(nil) == ("Commit", .showHint, nil, true))
        #expect(q(Self.status(), busy: true) == ("Commit", .showHint, nil, true))
        #expect(q(Self.status(ref: nil)).0 == "Commit")
        #expect(q(Self.status(changes: true)) == ("Commit, push & PR", .runAction, .commitPushPr, false))
        #expect(q(Self.status(changes: true, provider: "gitlab")).0 == "Commit, push & MR")
        #expect(q(Self.status(changes: true), isDefault: true) == ("Commit & push", .runAction, .commitPush, false))
        #expect(q(Self.status(changes: true, pr: "open")) == ("Commit & push", .runAction, .commitPush, false))
        #expect(q(Self.status(changes: true, upstream: false), remote: false) == ("Commit", .runAction, .commit, false))
        #expect(q(Self.status(upstream: false), remote: false) == ("Publish repository", .openPublish, nil, false))
        #expect(q(Self.status(upstream: false)) == ("Push", .showHint, nil, true))
        #expect(q(Self.status(upstream: false, ahead: 1)) == ("Push & create PR", .runAction, .createPr, false))
        #expect(q(Self.status(upstream: false, ahead: 1), isDefault: true) == ("Push", .runAction, .commitPush, false))
        #expect(q(Self.status(ahead: 1, behind: 1)) == ("Sync ref", .showHint, nil, true))
        #expect(q(Self.status(behind: 2)) == ("Pull", .runPull, nil, false))
        #expect(q(Self.status(ahead: 1, pr: "open")) == ("Push", .runAction, .push, false))
        #expect(q(Self.status(pr: "open")) == ("Commit", .showHint, nil, true))
        #expect(q(Self.status(aheadOfDefault: 2)) == ("Create PR", .runAction, .createPr, false))
        #expect(q(Self.status(aheadOfDefault: 2), isDefault: true) == ("Commit", .showHint, nil, true))
        #expect(L.quickAction(Self.status(), busy: false).hint == "Branch is up to date. No action needed.")
    }

    @Test func menuItemsAndReasons() {
        let clean = Self.status(ahead: 1)
        let items = L.menuItems(clean, busy: false)
        #expect(items.map(\.label) == ["Commit", "Push", "Create PR"])
        #expect(items.map(\.disabled) == [true, false, false])
        #expect(L.disabledReason(items[0], status: clean, busy: false, hasPrimaryRemote: true) == "Worktree is clean. Make changes before committing.")
        #expect(L.disabledReason(items[1], status: clean, busy: false, hasPrimaryRemote: true) == nil)
        // No primary remote: commit only. An open PR drops the PR entry.
        #expect(L.menuItems(clean, busy: false, hasPrimaryRemote: false).map(\.id) == [.commit])
        #expect(L.menuItems(Self.status(ahead: 1, pr: "open"), busy: false).map(\.id) == [.commit, .push])
        // Behind: push and PR are off with their reasons.
        let behind = Self.status(ahead: 1, behind: 1)
        let b = L.menuItems(behind, busy: false)
        #expect(b[1].disabled && b[2].disabled)
        #expect(L.disabledReason(b[1], status: behind, busy: false, hasPrimaryRemote: true) == "Branch is behind upstream. Pull/rebase before pushing.")
        #expect(L.disabledReason(b[2], status: behind, busy: false, hasPrimaryRemote: true) == "Branch is behind upstream. Pull/rebase before creating a pull request.")
        // Changes block push and PR creation.
        let dirty = Self.status(changes: true, ahead: 1)
        let d = L.menuItems(dirty, busy: false)
        #expect(!d[0].disabled && !d[1].disabled && d[2].disabled)
        #expect(L.disabledReason(d[2], status: dirty, busy: false, hasPrimaryRemote: true) == "Commit local changes before creating a pull request.")
        #expect(L.disabledReason(L.menuItems(clean, busy: true)[1], status: clean, busy: true, hasPrimaryRemote: true) == "Git action in progress.")
        // Footnotes.
        #expect(L.menuNotes(Self.status(ref: nil)).first?.hasPrefix("Detached HEAD") == true)
        #expect(L.menuNotes(Self.status(behind: 1)) == ["Behind upstream. Pull/rebase first."])
        #expect(L.menuNotes(Self.status(ahead: 1, behind: 1)).isEmpty)
    }

    @Test func defaultBranchDialog() {
        #expect(L.requiresDefaultBranchConfirmation(.push, isDefaultRef: true))
        #expect(!L.requiresDefaultBranchConfirmation(.commit, isDefaultRef: true))
        #expect(!L.requiresDefaultBranchConfirmation(.push, isDefaultRef: false))
        let copy = L.defaultBranchDialogCopy(action: .commitPush, branchName: "main", includesCommit: true)
        #expect(copy.title == "Commit & push to default ref?")
        #expect(copy.continueLabel == "Commit & push to main")
        #expect(copy.description.hasPrefix("This action will commit and push changes on \"main\"."))
        #expect(L.defaultBranchDialogCopy(action: .createPr, branchName: "main", includesCommit: false).title == "Push & create PR from default ref?")
        #expect(L.includesCommit(.commitPush, status: Self.status(changes: true), featureBranch: false))
        #expect(!L.includesCommit(.commitPush, status: Self.status(), featureBranch: false))
        #expect(L.includesCommit(.commitPush, status: Self.status(), featureBranch: true))
    }

    @Test func progressAndCopy() {
        #expect(L.progressStatus(isPull: true, currentLabel: nil) == "Pulling latest changes...")
        #expect(L.progressStatus(isPull: false, currentLabel: "Running source control action") == "Starting source control action...")
        #expect(L.progressStatus(isPull: false, currentLabel: " Committing... ") == "Committing...")
        #expect(L.elapsed(59.9) == "59s")
        #expect(L.elapsed(125) == "2m 5s")
        #expect(L.pullSuccess(VcsPullResultFixture.make("pulled", "main", "origin/main")) == ("Pulled", "Updated main from origin/main"))
        #expect(L.pullSuccess(VcsPullResultFixture.make("skipped_up_to_date", "main", nil)).title == "Already up to date")
    }

    @Test func commitSelection() {
        var s = L.CommitSelection(files: [.init(path: "a", insertions: 1, deletions: 2), .init(path: "b", insertions: 3, deletions: 0)])
        #expect(s.allSelected && s.filePaths == nil)
        s.toggle("b")
        #expect(s.filePaths == ["a"] && s.totals.insertions == 1 && s.totals.deletions == 2)
        s.toggleAll() // partial: all back in
        #expect(s.allSelected)
        s.toggleAll() // all in: all out
        #expect(s.noneSelected && s.filePaths == [])
    }

    @Test func publishReadiness() {
        let ready = SourceControlProviderDiscovery(kind: "github", label: "GitHub", status: "available", installHint: "", authStatus: "authenticated", account: "me")
        let missing = SourceControlProviderDiscovery(kind: "gitlab", label: "GitLab", status: "missing", installHint: "Install glab", authStatus: "unknown")
        let signedOut = SourceControlProviderDiscovery(kind: "forgejo", label: "Forgejo", status: "available", installHint: "", authStatus: "unauthenticated")
        let all = [ready, missing, signedOut]
        #expect(L.publishReadiness("github", discovered: all).ready)
        #expect(L.publishReadiness("gitlab", discovered: all).hint == "Install glab")
        #expect(L.publishReadiness("forgejo", discovered: all).hint == "Forgejo is not authenticated. Open Settings -> Source Control for setup guidance.")
        #expect(L.publishReadiness("bitbucket", discovered: all).hint == "Provider status unavailable. Open Settings -> Source Control and rescan.")
        #expect(L.sortedPublishProviders(all).first?.kind == "github")
        #expect(L.sortedPublishProviders([]).map(\.label) == ["Azure DevOps", "Bitbucket", "Forgejo / Gitea", "GitHub", "GitLab"])
        #expect(L.isPublishPathValid("me/repo") && L.isPublishPathValid("group/sub/project"))
        #expect(!L.isPublishPathValid("me/") && !L.isPublishPathValid("/repo") && !L.isPublishPathValid("repo"))
    }
}

enum VcsPullResultFixture {
    static func make(_ status: String, _ ref: String, _ upstream: String?) -> VcsPullResult {
        var o: [String: JSONValue] = ["status": .string(status), "refName": .string(ref)]
        o["upstreamRef"] = upstream.map(JSONValue.string) ?? .null
        return try! JSONValue.object(o).decode(as: VcsPullResult.self)
    }
}

struct BranchToolbarLogicTests {
    typealias B = BranchToolbarLogic

    @Test func labels() {
        #expect(B.workspaceLabel(mode: .local, worktreePath: nil, modeLocked: false) == "Current checkout")
        #expect(B.workspaceLabel(mode: .local, worktreePath: "/wt", modeLocked: false) == "Current worktree")
        #expect(B.workspaceLabel(mode: .worktree, worktreePath: nil, modeLocked: false) == "New worktree")
        #expect(B.workspaceLabel(mode: .worktree, worktreePath: "/wt", modeLocked: true) == "Worktree")
        #expect(B.workspaceLabel(mode: .local, worktreePath: nil, modeLocked: true) == "Local checkout")
        #expect(B.workspaceLabel(mode: .local, worktreePath: nil, modeLocked: false, forceNewWorktree: true) == "New worktree")
        #expect(B.triggerLabel(worktreePath: nil, mode: .worktree, branch: "main", branchIsRemote: false, startFromOrigin: true) == "From main (remote)")
        #expect(B.triggerLabel(worktreePath: nil, mode: .worktree, branch: "origin/x", branchIsRemote: true, startFromOrigin: true) == "From origin/x")
        #expect(B.triggerLabel(worktreePath: nil, mode: .local, branch: "main", branchIsRemote: nil, startFromOrigin: true) == "main")
        #expect(B.triggerLabel(worktreePath: nil, mode: .local, branch: nil, branchIsRemote: nil, startFromOrigin: false) == "Select ref")
        #expect(B.toolbarValue(mode: .worktree, worktreePath: nil, threadBranch: "base", currentGitBranch: "main") == "base")
        #expect(B.toolbarValue(mode: .local, worktreePath: nil, threadBranch: "base", currentGitBranch: "main") == "main")
    }

    @Test func previousWorktree() {
        let d = { (s: Double) in Date(timeIntervalSince1970: s) }
        let threads = [
            B.ThreadWorkspace(branch: "a", worktreePath: "/wt/a", updatedAt: d(10)),
            B.ThreadWorkspace(branch: "b", worktreePath: "/wt/b", updatedAt: d(30), archived: true),
            B.ThreadWorkspace(branch: "c", worktreePath: "/wt/c", updatedAt: d(20)),
            B.ThreadWorkspace(branch: "root", worktreePath: nil, updatedAt: d(40)),
        ]
        #expect(B.previousWorktree(threads, currentWorktreePath: nil) == .init(branch: "c", worktreePath: "/wt/c"))
        #expect(B.previousWorktree(threads, currentWorktreePath: "/wt/c") == .init(branch: "a", worktreePath: "/wt/a"))
        #expect(B.previousWorktreeLabel(.init(branch: "c", worktreePath: "/wt/c")) == "Previous worktree (c)")
    }

    @Test func refsAndFiltering() {
        #expect(B.sanitizeNewRefName("  new  branch\tname ") == "new-branch-name")
        #expect(B.localBranchName(fromRemote: "origin/feature/x") == "feature/x")
        #expect(B.localBranchName(fromRemote: "main") == "main")
        #expect(B.isTemporaryWorktreeBranch("t3/734bbabe") && B.isTemporaryWorktreeBranch("t3code-0123abcd"))
        #expect(!B.isTemporaryWorktreeBranch("t3/feature") && !B.isTemporaryWorktreeBranch("main"))
        let refs = [VcsRef(name: "main", current: true, isDefault: true), VcsRef(name: "new-branch"), VcsRef(name: "feature/x")]
        // "new branch" still finds new-branch through its sanitized name, and offers no create row for it.
        #expect(B.pickerItems(refs: refs, query: "new branch", canCreate: true) == ["new-branch"])
        #expect(B.pickerItems(refs: refs, query: "fea", canCreate: true) == ["feature/x", B.createRefPrefix + "fea"])
        #expect(B.pickerItems(refs: refs, query: "fea", canCreate: false) == ["feature/x"])
        #expect(B.pickerItems(refs: refs, query: "", canCreate: true) == ["main", "new-branch", "feature/x"])
        #expect(B.refBadge(VcsRef(name: "x", worktreePath: "/wt"), projectCwd: "/repo") == "worktree")
        #expect(B.refBadge(VcsRef(name: "x", isDefault: true, worktreePath: "/repo"), projectCwd: "/repo") == "default")
        #expect(B.refBadge(VcsRef(name: "origin/x", isRemote: true), projectCwd: "/repo") == "remote")
        #expect(B.statusText(loading: false, loadingMore: false, hasNextPage: true, shown: 100, total: 240) == "Showing 100 of 240 refs")
    }

    @Test func selectionTargets() {
        let reuse = B.selectionTarget(projectCwd: "/repo", worktreePath: nil, ref: VcsRef(name: "x", worktreePath: "/wt/x"))
        #expect(reuse == .init(checkoutCwd: "/wt/x", nextWorktreePath: "/wt/x", reuseExistingWorktree: true))
        let root = B.selectionTarget(projectCwd: "/repo", worktreePath: nil, ref: VcsRef(name: "main", worktreePath: "/repo"))
        #expect(root.nextWorktreePath == nil && root.reuseExistingWorktree)
        let back = B.selectionTarget(projectCwd: "/repo", worktreePath: "/wt/y", ref: VcsRef(name: "main", isDefault: true))
        #expect(back == .init(checkoutCwd: "/repo", nextWorktreePath: nil, reuseExistingWorktree: false))
        #expect(B.envModeAfterBranchChange(nextWorktreePath: "/wt", currentWorktreePath: nil, mode: .local) == .worktree)
        #expect(B.envModeAfterBranchChange(nextWorktreePath: nil, currentWorktreePath: nil, mode: .worktree) == .worktree)
        #expect(B.envModeAfterBranchChange(nextWorktreePath: nil, currentWorktreePath: "/wt", mode: .worktree) == .local)
    }

    /// The `launchThread` workspace strategies (client-runtime commands.ts:646-669).
    @Test func workspaceStrategies() {
        #expect(B.workspaceStrategy(mode: .local, branch: nil, worktreePath: nil, startFromOrigin: false) == .object(["type": .string("root")]))
        #expect(B.workspaceStrategy(mode: .local, branch: "dev", worktreePath: nil, startFromOrigin: false)
                == .object(["type": .string("root"), "branch": .string("dev")]))
        #expect(B.workspaceStrategy(mode: .worktree, branch: "main", worktreePath: nil, startFromOrigin: true)
                == .object(["type": .string("worktree"), "baseRef": .string("main"), "startFromOrigin": .bool(true)]))
        #expect(B.workspaceStrategy(mode: .worktree, branch: "t3/1", worktreePath: "/wt", startFromOrigin: false)
                == .object(["type": .string("existing_worktree"), "worktreePath": .string("/wt"), "branch": .string("t3/1")]))
    }
}
