import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// Scoped refs, the merged shell and project groups across environments (L-multi-environment.md 3.1-3.3).
struct EnvironmentScopeTests {
    @Test func keysSplitAtTheFirstColon() {
        #expect(EnvironmentScope.key("env-a", "thread:1") == "env-a:thread:1")
        #expect(EnvironmentScope.split("env-a:thread:1")! == ("env-a", "thread:1"))
        #expect(EnvironmentScope.split("plain") == nil)
        #expect(EnvironmentScope.localId(of: "plain") == "plain")
        let id = ThreadId("t1").scoped(to: "env-a")
        #expect(id.rawValue == "env-a:t1")
        #expect(id.environmentId == "env-a")
        #expect(id.localId == ThreadId("t1"))
    }

    @Test func scopingRewritesEveryReference() {
        let child = thread("child") {
            $0.projectId = "p1"
            $0.lineage = ThreadLineage(parentThreadId: "parent", relationshipToParent: nil, rootThreadId: "parent")
            $0.forkedFrom = ForkedFrom(type: "thread", threadId: "parent")
            $0.pendingBackgroundTasks = [PendingBackgroundTask(taskId: "t", kind: .subagent, childThreadId: "grandchild")]
        }
        let scoped = EnvironmentScope.scope(ShellSnapshot(schemaVersion: 1, snapshotSequence: 9, threads: [child],
                                                          archivedThreads: [thread("old")], projects: [project("p1")]),
                                            environmentId: "env-b")
        let t = scoped.threads[0]
        #expect(t.id == "env-b:child")
        #expect(t.projectId == "env-b:p1")
        #expect(t.lineage.parentThreadId == "env-b:parent")
        #expect(t.lineage.rootThreadId == "env-b:parent")
        #expect(t.forkedFrom?.threadId == "env-b:parent")
        #expect(t.backgroundTasks.first?.childThreadId == "env-b:grandchild")
        #expect(scoped.archivedThreads[0].id == "env-b:old")
        #expect(scoped.projects[0].id == "env-b:p1")
        #expect(scoped.snapshotSequence == 9)
        let match = EnvironmentScope.scope(ThreadSearchMatch(threadId: "child", projectId: "p1", source: "message", snippet: "x"), "env-b")
        #expect(match.threadId == "env-b:child" && match.projectId == "env-b:p1")
    }

    @Test func mergeConcatenatesInOrderAndForgetsRemoved() {
        var shells = MergedShell()
        #expect(shells.merged(order: ["a"]) == nil)
        shells.set(ShellSnapshot(schemaVersion: 1, snapshotSequence: 3, threads: [thread("t")], projects: [project("p")]), environmentId: "a")
        shells.set(ShellSnapshot(schemaVersion: 1, snapshotSequence: 7, threads: [thread("t")], projects: [project("p")]), environmentId: "b")
        // The same local ids on two servers stay apart.
        let merged = shells.merged(order: ["a", "b"])!
        #expect(merged.threads.map(\.id) == ["a:t", "b:t"])
        #expect(merged.projects.map(\.id) == ["a:p", "b:p"])
        #expect(shells.merged(order: ["b", "a"])!.threads.map(\.id) == ["b:t", "a:t"])
        // A newer shell for one environment replaces only its part.
        shells.set(ShellSnapshot(schemaVersion: 1, snapshotSequence: 8, threads: [thread("u")]), environmentId: "b")
        #expect(shells.merged(order: ["a", "b"])!.threads.map(\.id) == ["a:t", "b:u"])
        shells.remove("b")
        #expect(shells.merged(order: ["a", "b"])!.threads.map(\.id) == ["a:t"])
        shells.remove("a")
        #expect(shells.merged(order: ["a", "b"]) == nil)
    }

    /// A shell update with 1,000 threads rescopes only what changed, and the result equals a full rescope.
    @Test func anUpdateRescopesOnlyChangedThreads() {
        var shells = MergedShell()
        var snapshot = ShellSnapshot(schemaVersion: 1, snapshotSequence: 1, threads: (0..<1_000).map { thread("t\($0)") },
                                     projects: [project("p")])
        shells.set(snapshot, environmentId: "a")
        #expect(shells.lastRescoped == 1_001)
        snapshot.threads[500].title = "renamed"
        shells.set(snapshot, environmentId: "a")
        #expect(shells.lastRescoped == 1)
        #expect(shells.lastChangedThreadIds == [EnvironmentScope.scope(snapshot.threads[500], "a").id])
        #expect(shells.merged(order: ["a"])?.threads == EnvironmentScope.scope(snapshot, environmentId: "a").threads)
        // A new thread first shifts every other one; they are still reused.
        snapshot.threads.insert(thread("new"), at: 0)
        shells.set(snapshot, environmentId: "a")
        #expect(shells.lastRescoped == 1)
        #expect(shells.merged(order: ["a"])?.threads == EnvironmentScope.scope(snapshot, environmentId: "a").threads)
        snapshot.threads.removeLast()
        shells.set(snapshot, environmentId: "a")
        #expect(shells.lastRescoped == 0)
    }

    /// The remembered groups never outlive a change of projects or primary.
    @Test func cachedProjectGroupsFollowEveryChange() {
        let a = [EnvironmentScope.scope(project("p1") { $0.workspaceRoot = "/w/a" }, "local"),
                 EnvironmentScope.scope(project("p2") { $0.workspaceRoot = "/w/b" }, "remote")]
        var b = a
        b[1].workspaceRoot = "/w/a"
        b[1].repositoryIdentity = identity("github.com/x/a")
        b[0].repositoryIdentity = identity("github.com/x/a")
        for (projects, primary) in [(a, "local"), (a, "local"), (b, "local"), (b, "remote"), (a, "remote")] {
            #expect(SidebarModel.buildProjectGroups(projects, preferredEnvironmentId: primary)
                == SidebarModel.computeProjectGroups(projects, grouping: .init(mode: .repository), preferredEnvironmentId: primary))
        }
    }

    @Test func sameRepositoryMergesAcrossEnvironmentsWithThePrimaryAsRepresentative() {
        let remote = EnvironmentScope.scope(project("p1") { $0.title = "repo"; $0.workspaceRoot = "/srv/repo"; $0.repositoryIdentity = identity("github.com/x/repo") }, "remote")
        let local = EnvironmentScope.scope(project("p9") { $0.title = "repo"; $0.workspaceRoot = "/Users/me/repo"; $0.repositoryIdentity = identity("github.com/x/repo") }, "local")
        let groups = SidebarModel.buildProjectGroups([remote, local], preferredEnvironmentId: "local")
        #expect(groups.count == 1)
        #expect(groups[0].representative.id == "local:p9")
        #expect(Set(groups[0].memberProjectIds) == ["remote:p1", "local:p9"])
        // Without a primary member the first one represents the group.
        #expect(SidebarModel.buildProjectGroups([remote, local]).first?.representative.id == "remote:p1")
    }

    @Test func samePathOnTwoEnvironmentsDoesNotCollapse() {
        // No repository identity: the physical key `env:path` decides, so two machines stay two groups.
        let a = EnvironmentScope.scope(project("p") { $0.workspaceRoot = "/w/demo" }, "a")
        let b = EnvironmentScope.scope(project("p") { $0.workspaceRoot = "/w/demo/" }, "b")
        let groups = SidebarModel.buildProjectGroups([a, b])
        #expect(groups.map(\.key) == ["a:/w/demo", "b:/w/demo"])
        // Within one environment the same path still collapses to the freshest project.
        let a2 = EnvironmentScope.scope(project("q") { $0.workspaceRoot = "/w/demo"; $0.updatedAt = "2030-01-01T00:00:00.000Z" }, "a")
        let one = SidebarModel.buildProjectGroups([a, a2])
        #expect(one.count == 1 && one[0].representative.id == "a:q" && one[0].memberProjectIds == ["a:p", "a:q"])
    }

    @Test func threadsFromAllEnvironmentsSortByTimeOnly() {
        // threadSort.ts: environment is not a sort key.
        let older = EnvironmentScope.scope(thread("x") { $0.updatedAt = "2026-01-01T00:00:00.000Z"; $0.latestUserMessageAt = nil }, "a")
        let newer = EnvironmentScope.scope(thread("y") { $0.updatedAt = "2026-02-01T00:00:00.000Z"; $0.latestUserMessageAt = nil }, "b")
        #expect(SidebarModel.getThreadSortTimestamp(newer, .updatedAt) > SidebarModel.getThreadSortTimestamp(older, .updatedAt))
    }
}
