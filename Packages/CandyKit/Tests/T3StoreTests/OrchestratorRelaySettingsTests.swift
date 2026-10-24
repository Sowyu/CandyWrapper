import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The settings the Mac writes into the "while closed" task and the helper reads back, and the commands both send.
@Suite struct OrchestratorRelaySettingsTests {
    func config() -> OrchestratorConfig {
        var c = OrchestratorConfig()
        c.crewLimit = 2
        c.askFirstMinutes = 5
        c.handsOff = ["env-b:thread-2", "env-a:thread-1"]
        c.closedCheckMinutes = nil
        c.relayedAt = ["env-a:thread-9": 42]
        return c
    }

    @Test func roundTripsThroughTheTaskPrompt() throws {
        let settings = OrchestratorRelaySettings(config())
        let prompt = OrchestratorBrief.scheduledCheck(settings: settings)
        // The Mac and the helper both find the check task by this prefix.
        #expect(prompt.hasPrefix("Scheduled check:"))
        let parsed = try #require(OrchestratorRelaySettings.parse(prompt))
        #expect(parsed == settings)
        #expect(parsed.handsOff == ["env-a:thread-1", "env-b:thread-2"])
        #expect(parsed.closedCheckMinutes == nil)
    }

    @Test func applyingKeepsTheRelaysOwnMemory() {
        var helper = OrchestratorConfig()
        helper.relayWorkers = ["env-b:worker"]
        OrchestratorRelaySettings(config()).apply(to: &helper)
        #expect(helper.crewLimit == 2 && helper.askFirstMinutes == 5 && helper.isHandsOff(ThreadId("env-a:thread-1")))
        #expect(helper.relayWorkers == ["env-b:worker"])
        #expect(helper.relayedAt.isEmpty)
    }

    @Test func aPromptWithoutABlockOrWithABrokenOneHasNoSettings() {
        #expect(OrchestratorRelaySettings.parse(OrchestratorBrief.scheduledCheckPrompt) == nil)
        #expect(OrchestratorRelaySettings.parse("x\n```orchestrator-config\n{\"crewLimit\":\n```") == nil)
    }

    @Test func messagesQueueBehindARunningTurn() {
        let selection = ModelSelection(instanceId: ProviderInstanceId(rawValue: "claudeAgent"), model: "claude-haiku-5-5", selections: [])
        let queued = OrchestrationCommands.message(threadId: "t", messageId: "m", text: "hi", selection: selection, queue: true)
        #expect(queued["dispatchMode"]?["type"]?.stringValue == "queue_after_active")
        #expect(queued["deliveryIntent"] == nil)
        let now = OrchestrationCommands.message(threadId: "t", messageId: "m", text: "hi", selection: selection, queue: false)
        #expect(now["dispatchMode"]?["type"]?.stringValue == "start_immediately")
        #expect(now["deliveryIntent"]?.stringValue == "auto")
        #expect(now["modelSelection"]?["model"]?.stringValue == "claude-haiku-5-5")
    }

    @Test func relayLaunchesKeepTheirTitle() {
        let selection = ModelSelection(instanceId: ProviderInstanceId(rawValue: "claudeAgent"), model: "claude-haiku-5-5", selections: [])
        let payload = OrchestratorRelayHost.launch("t", "p", "Worker", "go", selection, "full-access", .object(["type": .string("root")]))
        #expect(payload["generateTitle"] == .bool(false))
        #expect(payload["initialMessage"]?["text"]?.stringValue == "go")
    }
}
