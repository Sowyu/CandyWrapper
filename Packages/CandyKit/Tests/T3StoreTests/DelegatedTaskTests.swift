import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Tasks a linked environment delegates here (4928 #30428, #37500): they show under their parent while the client
/// lists it, and an open one selects the parent's row.
@Suite struct DelegatedTaskTests {
    static func shell(_ threads: [ThreadShell]) -> ShellSnapshot {
        ShellSnapshot(schemaVersion: 1, snapshotSequence: 0, threads: threads, projects: [baseProject])
    }

    @Test func decodesDelegatedFromAndToleratesNull() throws {
        var json = baseThreadJSON
        json.removeLast() // "}"
        let task = try JSONDecoder().decode(ThreadShell.self, from: Data((json + #","delegatedFrom":{"environmentId":"mini","threadId":"parent","title":"Plan"}}"#).utf8))
        #expect(task.delegatedFrom == DelegatedFrom(environmentId: "mini", threadId: "parent", title: "Plan"))
        let mcp = try JSONDecoder().decode(ThreadShell.self, from: Data((json + #","delegatedFrom":null}"#).utf8))
        #expect(mcp.delegatedFrom == nil)
        // The client flag never goes on the wire.
        let lineage = String(decoding: try JSONEncoder().encode(task.lineage), as: UTF8.self)
        #expect(!lineage.contains("delegatedUnderParent"))
    }

    @Test func aTaskFromAListedParentShowsUnderIt() throws {
        var shells = MergedShell()
        shells.set(Self.shell([thread("parent")]), environmentId: "mini")
        let task = thread("task") { $0.delegatedFrom = DelegatedFrom(environmentId: "mini", threadId: "parent", title: "Plan") }
        let orphan = thread("orphan") { $0.delegatedFrom = DelegatedFrom(environmentId: "gone", threadId: "x", title: "Old") }
        shells.set(Self.shell([task, orphan]), environmentId: "local")
        let merged = try #require(shells.merged(order: ["mini", "local"]))
        let byId = Dictionary(uniqueKeysWithValues: merged.threads.map { ($0.id, $0) })
        #expect(byId["local:task"]?.delegatedFrom?.threadId == "mini:parent")
        #expect(byId["local:task"]?.lineage.isListed == false)
        // A parent the client can't reach leaves the task listed, so its work is never out of reach.
        #expect(byId["local:orphan"]?.lineage.isListed == true)
        // Without the parent's environment in the merge, the task is listed again.
        let alone = try #require(shells.merged(order: ["local"]))
        #expect(alone.threads.filter { !$0.lineage.isListed }.isEmpty)
        // Opening the task selects the parent's row; the parent and an unknown id stay themselves.
        #expect(SidebarModel.resolveListedAncestorThreadId("local:task", threads: merged.threads) == "mini:parent")
        #expect(SidebarModel.resolveListedAncestorThreadId("mini:parent", threads: merged.threads) == "mini:parent")
        #expect(SidebarModel.resolveListedAncestorThreadId("nope", threads: merged.threads) == "nope")
    }

    @Test func subagentsResolveThroughTheirLineageAndCyclesStop() {
        let root = thread("root")
        let child = thread("child") { $0.lineage.parentThreadId = "root"; $0.lineage.relationshipToParent = .subagent }
        let grandchild = thread("grand") { $0.lineage.parentThreadId = "child"; $0.lineage.relationshipToParent = .subagent }
        #expect(SidebarModel.resolveListedAncestorThreadId("grand", threads: [root, child, grandchild]) == "root")
        let a = thread("a") { $0.lineage.parentThreadId = "b"; $0.lineage.relationshipToParent = .subagent }
        let b = thread("b") { $0.lineage.parentThreadId = "a"; $0.lineage.relationshipToParent = .subagent }
        #expect(SidebarModel.resolveListedAncestorThreadId("a", threads: [a, b]) == "a")
    }
}
