import AppKit
import Testing
import T3Protocol
import T3Store
import DesignSystem
@testable import Features

private func projected(_ json: String) -> ProjectedTurnItem {
    var fields = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    let defaults: [String: Any] = [
        "threadId": "thread-1", "runId": NSNull(), "nodeId": NSNull(), "providerThreadId": NSNull(),
        "providerTurnId": NSNull(), "nativeItemRef": NSNull(), "parentItemId": NSNull(), "ordinal": 0,
        "status": "completed", "title": NSNull(), "startedAt": NSNull(), "completedAt": NSNull(),
        "updatedAt": "2026-01-01T00:00:00Z",
    ]
    for (key, value) in defaults where fields[key] == nil { fields[key] = value }
    let item = try! JSONDecoder().decode(TurnItem.self, from: JSONSerialization.data(withJSONObject: fields))
    return ProjectedTurnItem(local: item)
}

/// Where T3 MCP effects lead in the timeline (WP7.15): rows about another thread open it, and T3
/// tool rows wear T3's glyphs (V2LifecycleRow.tsx:159-231, MessagesTimeline.tsx:4051-4092, 5267-5303).
@MainActor
struct T3McpTimelineTests {
    @Test func rowsAboutAnotherThreadOpenIt() {
        let forkedFrom = projected(#"{"id":"f1","type":"fork","source":{"type":"run","threadId":"source-thread","runId":"r1"},"targetThreadId":"thread-1"}"#)
        #expect(EventRowView.openTarget(forkedFrom)?.0 == ThreadId("source-thread"))
        #expect(EventRowView.openTarget(forkedFrom)?.1 == "Open source conversation")
        let forkNode = projected(#"{"id":"f2","type":"fork","source":{"type":"node","nodeId":"n1"},"targetThreadId":"fork-thread"}"#)
        #expect(EventRowView.openTarget(forkNode)?.0 == ThreadId("fork-thread"))
        #expect(EventRowView.openTarget(forkNode)?.1 == "Open fork")
        let created = projected(#"{"id":"c1","type":"thread_created","targetThreadId":"sibling","title":"MCP sibling"}"#)
        #expect(EventRowView.openTarget(created)?.0 == ThreadId("sibling"))
        let subagent = projected(#"{"id":"s1","type":"subagent","subagentId":"a1","childThreadId":"child"}"#)
        #expect(EventRowView.openTarget(subagent)?.0 == ThreadId("child"))
        let unlinked = projected(#"{"id":"s2","type":"subagent","subagentId":"a2"}"#)
        #expect(EventRowView.openTarget(unlinked) == nil)
    }

    @Test func t3ToolsWearT3Glyphs() {
        #expect(WorkIcons.tool("t3-code") == .brandT3Wordmark)
        #expect(WorkIcons.tool("browser") == .brandBrowserApp)
        #expect(WorkIcons.tool("device") == .smartphone)
        #expect(WorkIcons.tool("pull-request") == .gitPullRequestArrow)
        #expect(WorkIcons.tool(nil) == nil)
        #expect(WorkIcons.summary("thread-create") == .brandT3Wordmark)
        #expect(WorkIcons.summary("browser") == .brandBrowserApp)
        func entry(_ tool: String) -> WorkLogEntry {
            var e = WorkLogEntry(id: "d", createdAt: "2026-10-11T07:00:00Z", label: tool, tone: .tool)
            e.itemType = .dynamicTool
            e.structuredPayload = projected(#"{"id":"d","type":"dynamic_tool","toolName":"\#(tool)","input":{}}"#).item
            return e
        }
        #expect(WorkIcons.entry(entry("mcp__t3-code__delegate_task")) == .brandT3Wordmark)
        #expect(WorkIcons.entry(entry("mcp__t3-code__preview_open")) == .brandBrowserApp)
        #expect(WorkIcons.entry(entry("mcp__t3-code__device_list")) == .smartphone)
        #expect(WorkIcons.entry(entry("mcp__other__thing")) == .wrench)
    }
}
