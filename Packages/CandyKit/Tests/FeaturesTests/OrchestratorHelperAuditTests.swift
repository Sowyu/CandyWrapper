import AgentConfig
import Foundation
import Testing
@testable import Features

/// Existing failure, opt-in for the parent's centralized audit run. No app or server is needed.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CW_ORCHESTRATOR_AUDIT_REGRESSIONS"] == "1"))
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
    }
}
