import AgentConfig
import Foundation
import Testing
@testable import Features

/// Regression for audit OH-5 (docs/research/responsiveness-audit-2026-10-26/orchestrator-helper.md). No app or server is needed.
@MainActor
@Suite(.serialized)
struct OrchestratorHelperAuditTests {
    @Test func earlierReadCompletionDoesNotClearQueuedMutationBusyState() {
        let store = ConnectorsStore()
        var submitted: [String] = []
        store.actions.load = { _ in submitted.append("read") }
        store.actions.apply = { _, _ in submitted.append("change") }
        store.load(["fixture"])
        // Add remains available while the first read is pending.
        store.apply(["fixture": [.addServer(NewMCPServer(name: "fixture", agents: [.claude], command: "fixture"))]])
        #expect(submitted == ["read", "change"])
        #expect(store.busy.contains("fixture"))
        // ConnectorsController completes the earlier read, then starts the queued mutation.
        store.set("fixture", .loaded(AgentConfigSnapshot()))
        #expect(store.busy.contains("fixture"), "The queued mutation still owns this machine's busy state")
        store.set("fixture", .loaded(AgentConfigSnapshot()), endsChange: true)
        #expect(!store.busy.contains("fixture"))
    }
}
