import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The commands the composer sends.
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

}
