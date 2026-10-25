import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// What a T3 MCP tool call leaves in the timeline (WP7.15): who sent a message (userMessage.ts) and
/// the `t3_thread_read` target (MessagesTimeline.logic.ts:182-209).
@Suite struct T3McpEffectsTests {
    @Test func scheduledTaskMessagesAreAutomation() {
        let p = UserMessagePresentation.resolve(id: "m1", isUser: true, text: "reply hi", createdBy: "agent", scheduledTaskId: "scheduled-task:1")
        #expect(p == UserMessagePresentation(text: "reply hi", attribution: .automation, scheduledTaskId: "scheduled-task:1"))
    }

    @Test func legacyAutomationPrefixIsStripped() {
        let text = "[Triggered by schedule task: Say hi]\n\nreply hi"
        let byId = UserMessagePresentation.resolve(id: "scheduled-task-message:task-7:3:manual", isUser: true, text: text, createdBy: "user", scheduledTaskId: nil)
        #expect(byId == UserMessagePresentation(text: "reply hi", attribution: .automation, scheduledTaskId: "task-7"))
        let byAgent = UserMessagePresentation.resolve(id: "m2", isUser: true, text: text, createdBy: "agent", scheduledTaskId: nil)
        #expect(byAgent == UserMessagePresentation(text: "reply hi", attribution: .automation, scheduledTaskId: nil))
        // A user who types the prefix keeps it.
        let typed = UserMessagePresentation.resolve(id: "m3", isUser: true, text: text, createdBy: "user", scheduledTaskId: nil)
        #expect(typed == UserMessagePresentation(text: text, attribution: nil, scheduledTaskId: nil))
    }

    /// Prompt recall takes only what the user typed (composerPromptHistory.ts:131-132).
    @Test func typedByUserSkipsAutomationsAndAgents() {
        func m(_ createdBy: String?, task: String? = nil, role: ChatMessage.Role = .user) -> ChatMessage {
            ChatMessage(id: MessageId("m"), role: role, text: "hi", createdAt: "2026-01-01T00:00:00Z", createdBy: createdBy, scheduledTaskId: task)
        }
        #expect(UserMessagePresentation.isTypedByUser(m("user")))
        #expect(UserMessagePresentation.isTypedByUser(m(nil)))
        #expect(!UserMessagePresentation.isTypedByUser(m("agent")))
        #expect(!UserMessagePresentation.isTypedByUser(m("user", task: "scheduled-task:1")))
        #expect(!UserMessagePresentation.isTypedByUser(m("user", role: .assistant)))
    }

    /// `creationSource: "server"` is T3 Code's own message, any other agent message is another agent's (userMessage.ts:80-87).
    @Test func agentMessagesSplitByCreationSource() {
        let agent = UserMessagePresentation.resolve(id: "m", isUser: true, text: "hi", createdBy: "agent", creationSource: "web", scheduledTaskId: nil)
        #expect(agent.attribution == .agent)
        let server = UserMessagePresentation.resolve(id: "m", isUser: true, text: "/compact", createdBy: "agent", creationSource: "server", scheduledTaskId: nil)
        #expect(server.attribution == .t3code)
    }

    @Test func agentAndAssistantMessagesAreNotAutomation() {
        #expect(!UserMessagePresentation.resolve(id: "m", isUser: true, text: "reply ok", createdBy: "agent", scheduledTaskId: nil).isAutomation)
        let assistant = UserMessagePresentation.resolve(id: "m", isUser: false, text: "[Triggered by schedule task: x]\n\nhi", createdBy: nil, scheduledTaskId: "t")
        #expect(assistant == UserMessagePresentation(text: "[Triggered by schedule task: x]\n\nhi", attribution: nil, scheduledTaskId: nil))
    }

    @Test func threadReadTargetsItsThread() {
        func entry(_ name: String, _ input: String) -> WorkLogEntry {
            var e = WorkLogEntry(id: "d", createdAt: "2026-10-11T07:41:00Z", label: "Read a T3 thread", tone: .tool)
            e.structuredPayload = turnItem(#"{"id":"d","type":"dynamic_tool","toolName":"\#(name)","input":\#(input)}"#)
            return e
        }
        #expect(WorkLog.threadReadTargetId(entry("mcp__t3-code__t3_thread_read", #"{"threadId":" thread-2 "}"#)) == "thread-2")
        #expect(WorkLog.threadReadTargetId(entry("t3_thread_read", #"{"threadId":"  "}"#)) == nil)
        #expect(WorkLog.threadReadTargetId(entry("t3_thread_list", #"{"threadId":"thread-2"}"#)) == nil)
        #expect(WorkLog.threadReadLabelPrefix("Read a T3 thread") == "Read thread")
        #expect(WorkLog.threadReadLabelPrefix("Reading a T3 thread") == "Reading thread")
        #expect(WorkLog.threadReadLabelPrefix("Listed T3 threads") == nil)
    }
}
