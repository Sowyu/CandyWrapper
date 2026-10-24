import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The commands the composer, the Mac's relay and the helper all send, and how the helper reads the shared settings.
@Suite struct OrchestrationCommandsTests {
    let haiku = ModelSelection(instanceId: ProviderInstanceId(rawValue: "claudeAgent"), model: "claude-haiku-5-5", selections: [])

    @Test func messagesQueueBehindARunningTurn() {
        let queued = OrchestrationCommands.message(threadId: "t", messageId: "m", text: "hi", selection: haiku, queue: true)
        #expect(queued["dispatchMode"]?["type"]?.stringValue == "queue_after_active")
        #expect(queued["deliveryIntent"] == nil)
        let now = OrchestrationCommands.message(threadId: "t", messageId: "m", text: "hi", selection: haiku, queue: false)
        #expect(now["dispatchMode"]?["type"]?.stringValue == "start_immediately")
        #expect(now["deliveryIntent"]?.stringValue == "auto")
        #expect(now["modelSelection"]?["model"]?.stringValue == "claude-haiku-5-5")
    }

    @Test func relayLaunchesKeepTheirTitle() {
        let payload = OrchestratorRelayHost.launch("t", "p", "Worker", "go", haiku, "full-access", .object(["type": .string("root")]))
        #expect(payload["generateTitle"] == .bool(false))
        #expect(payload["initialMessage"]?["text"]?.stringValue == "go")
    }

    /// The helper merges the settings task into the defaults with no stamps of its own, so every synced setting wins.
    @Test func aReaderWithNoStampsTakesEverySyncedSetting() {
        let stamp = OrchestratorSettingsSync.Stamp(at: 1, by: "mac")
        let doc = OrchestratorSettingsSync.Document(settings: [
            "handsOff": .init(value: .array([.string("env-b:thread-2")]), stamp: stamp),
            "crewLimit": .init(value: .number(2), stamp: stamp),
        ])
        let merged = OrchestratorSettingsSync.merge(config: OrchestratorConfig(), stamps: [:], documents: [doc], machine: "env-a")
        #expect(merged.config.isHandsOff(ThreadId("env-b:thread-2")))
        #expect(merged.config.crewLimit == 2)
        #expect(merged.config.askFirstMinutes == OrchestratorConfig().askFirstMinutes)
    }
}
