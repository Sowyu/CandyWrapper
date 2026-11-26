import Testing
import T3Protocol
@testable import T3Store
@testable import Features

/// `RemoteSubagentRow` (5258 ThreadRelationshipsControl.tsx:294-377, #41798): "on {label} · " then the elapsed
/// time, or the status when it failed or has no start.
@MainActor struct RemoteSubagentRowTests {
    private func row(_ status: String, startedAt: String?) -> ThreadRelationships.Lineage.Row {
        var agent = ProjectedSubagent(id: "a", childThreadId: nil, origin: "app_owned", driver: "codex", providerInstanceId: "codex",
                                      title: "Fix", model: nil, status: status, progress: nil, result: nil,
                                      startedAt: startedAt.map { T3Timestamp($0) }, completedAt: nil)
        let remote = RemoteTaskChild(environmentId: "b", threadId: "t", label: "Studio Mac")
        agent.remoteChild = remote
        let edge = ThreadRelationshipEdge(sourceThreadId: "p", targetThreadId: "t", kind: .subagent, status: status)
        var r = ThreadRelationships.Lineage.Row(threadId: "t", edge: edge, status: status, isParent: false, isSubagent: true,
                                                isMergeTarget: false, missing: true, title: "Fix", agent: agent, child: nil, relationship: "Subagent")
        r.remote = remote
        return r
    }

    @Test func showsWhereItRunsThenTheTime() {
        let start = T3Timestamp("2026-11-25T10:00:00.000Z").epochMs!
        #expect(ThreadLineageRowView.trailingText(row("running", startedAt: "2026-11-25T10:00:00.000Z"), nowMs: start + 42_000) == "on Studio Mac · 42s")
        #expect(ThreadLineageRowView.trailingText(row("failed", startedAt: "2026-11-25T10:00:00.000Z"), nowMs: start) == "on Studio Mac · Failed")
        #expect(ThreadLineageRowView.trailingText(row("pending", startedAt: nil), nowMs: start) == "on Studio Mac · Queued")
    }
}
