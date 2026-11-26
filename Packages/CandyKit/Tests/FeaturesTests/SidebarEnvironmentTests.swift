import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The machine icon on remote rows and the project badge (K-connect-ui.md section 1), over a shell
/// merged from two environments.
@MainActor
struct SidebarEnvironmentTests {
    let nowMs = TimestampFormat.nowMs(SidebarPreview.referenceNow)

    /// The reference shell twice: once as this machine, once as a Mac mini.
    func merged() -> ShellSnapshot {
        var shells = MergedShell()
        shells.set(SidebarPreview.referenceSnapshot(), environmentId: "local")
        shells.set(SidebarPreview.referenceSnapshot(), environmentId: "mini")
        return shells.merged(order: ["local", "mini"])!
    }

    var environments: SidebarEnvironments {
        SidebarEnvironments(primaryId: "local", labels: ["local": "This device", "mini": "Mac mini"], machines: ["mini": "mac-mini"])
    }

    /// T3 5258 (#40736): every row with a known environment starts its meta line with the machine and label,
    /// the primary environment's included; unknown machine kinds draw `server`.
    @Test func everyRowCarriesItsEnvironment() {
        var state = SidebarListState()
        state.environments = environments
        let rows = SidebarListBuilder.items(snapshot: merged(), state: state, nowMs: nowMs)
            .compactMap { if case .row(let r) = $0 { r } else { nil } }
        #expect(rows.count == 16)
        #expect(rows.filter { $0.id.environmentId == "local" }.allSatisfy { $0.environmentLabel == "This device" && $0.environmentMachine == "server" && $0.hasMetaLine })
        #expect(rows.filter { $0.id.environmentId == "mini" }.allSatisfy { $0.environmentLabel == "Mac mini" && $0.environmentMachine == "mac-mini" })
        let unlabeled = SidebarListBuilder.items(snapshot: merged(), state: SidebarListState(), nowMs: nowMs)
            .compactMap { if case .row(let r) = $0 { r } else { nil } }
        #expect(unlabeled.allSatisfy { $0.environmentLabel == nil })
    }

    /// `formatWorktreePathForDisplay` (worktreeCleanup.ts:32-42) for the hover card's worktree row.
    @Test func worktreeShowsItsLastPathPart() {
        #expect(SidebarThreadHoverCardModel.worktreeDisplay("/Users/me/.t3/worktrees/app/fix-sidebar/") == "fix-sidebar")
        #expect(SidebarThreadHoverCardModel.worktreeDisplay("C:\\wt\\feature") == "feature")
        #expect(SidebarThreadHoverCardModel.worktreeDisplay("  ") == nil)
        #expect(SidebarThreadHoverCardModel.worktreeDisplay(nil) == nil)
    }

    @Test func projectBadgeSaysOnOrAlsoOn() {
        let envs = environments
        let both = SidebarModel.buildProjectGroups(merged().projects, preferredEnvironmentId: "local")
        // The reference projects have no repository identity, so each environment keeps its own group.
        #expect(both.count == 2)
        #expect(SidebarEnvironments.span(both))
        #expect(envs.badge(both[0]) == nil)
        #expect(envs.badge(both[1])! == ("mac-mini", "On Mac mini"))
        // One repository on both machines: "Also on".
        let repo = identity("github.com/x/demo")
        let local = EnvironmentScope.scope(project("p") { $0.repositoryIdentity = repo }, "local")
        let remote = EnvironmentScope.scope(project("p") { $0.repositoryIdentity = repo; $0.workspaceRoot = "/srv/demo" }, "mini")
        let mixed = SidebarModel.buildProjectGroups([local, remote], preferredEnvironmentId: "local")
        #expect(mixed.count == 1)
        #expect(envs.badge(mixed[0])! == ("mac-mini", "Also on Mac mini"))
        // One environment only: no badges at all.
        #expect(!SidebarEnvironments.span(SidebarModel.buildProjectGroups([local])))
    }

    @Test func scopePopupShowsBadgesOnlyAcrossEnvironments() {
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: merged(), primaryEnvironmentId: "local")
        let view = SidebarProjectScopeView(groups: groups, selectedKey: nil, minimumWidth: 200, environments: environments)
        #expect(view.items.compactMap(\.badge?.description) == ["On Mac mini"])
        let single = SidebarListBuilder.projectScopeGroups(snapshot: SidebarPreview.referenceSnapshot())
        #expect(SidebarProjectScopeView(groups: single, selectedKey: nil, minimumWidth: 200).items.allSatisfy { $0.badge == nil })
    }

    @Test func removedEnvironmentPicksAreDropped() {
        let store = ComposerSelectionStore(defaults: nil)
        store.setRuntimeMode("mini:t1", .approvalRequired)
        store.setRuntimeMode("local:t1", .approvalRequired)
        store.setRuntimeMode("draft-1", .approvalRequired)
        store.removeDrafts { $0.hasPrefix("mini:") || $0 == "draft-1" }
        #expect(Set(store.drafts.keys) == ["local:t1"])
    }
}

private func project(_ id: String, _ edit: (inout ProjectShell) -> Void) -> ProjectShell {
    var p = SidebarPreview.referenceSnapshot().projects[0]
    p.id = ProjectId(id)
    edit(&p)
    return p
}

private func identity(_ key: String) -> RepositoryIdentity {
    try! JSONDecoder().decode(RepositoryIdentity.self, from: Data("""
        {"canonicalKey":"\(key)","locator":{"source":"git-remote","remoteName":"origin","remoteUrl":"https://\(key).git"}}
        """.utf8))
}
