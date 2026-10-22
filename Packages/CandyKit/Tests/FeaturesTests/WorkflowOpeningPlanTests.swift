import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The workflow opening block shows the plan from the parent's coordinator row (WorkflowOpeningBlock.tsx:39-104).
@MainActor
struct WorkflowOpeningPlanTests {
    static func item(coordinator: JSONValue?) -> TimelineItem {
        var message = ChatMessage(id: MessageId("script"), role: .user, text: "export const meta = { name: 'Review' }\nawait agent('A')",
                                  createdAt: T3Timestamp("2026-10-21T12:00:00Z"))
        message.workflowOpening = true
        var ui = TimelineRowUI()
        ui.workflowCoordinator = coordinator
        return TimelineItem(row: TimelineRow(id: "opening", createdAt: message.createdAt, kind: .message(
            message, projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false,
            assistantCopyStreaming: false, turnDiffSummary: nil)), ui: ui)
    }

    @Test func planShowsPhasesAndMembers() throws {
        let coordinator = try JSONValue(parsing: Data(#"""
        {"id":"sub-1","childThreadId":"wf","status":"running","title":"Review the repo","driver":"claudeAgent","providerInstanceId":"claude",
         "workflow":{"name":"Review","phases":[{"index":0,"title":"Scan"}],"agents":[
          {"index":0,"label":"Scan sources","state":"running","phaseIndex":0,"prompt":"Read `src` and list risks","startedAt":1760090000000},
          {"index":1,"label":"Scan tests","state":"completed","phaseIndex":0,"result":"All green"},
          {"index":2,"label":"Summarize","state":"queued"}]}}
        """#.utf8))
        let row = WorkflowOpeningRowView()
        row.context = TimelineContext()
        row.configure(Self.item(coordinator: nil))
        let bare = row.height(forWidth: 600)
        row.configure(Self.item(coordinator: coordinator))
        row.frame = NSRect(x: 0, y: 0, width: 600, height: row.height(forWidth: 600))
        row.layoutSubtreeIfNeeded()
        let links = row.subviews.compactMap { $0 as? SubagentCardLinkView }
        #expect(links.map { $0.presentation?.title } == ["Scan sources", "Scan tests", "Summarize"])
        // The settled member shows its result, the running one its prompt without backticks, the queued one no detail.
        #expect(links.map { $0.presentation?.detail } == ["Read src and list risks", "All green", nil])
        // Header with description, the phase heading and its rows, the unphased row, each after `gap-3`.
        #expect(row.frame.height == bare + 2 + 16 + 12 + 18 + 46 + 46 + 12 + 36)
        #expect(links[0].frame.minY < links[1].frame.minY && links[1].frame.maxY < links[2].frame.minY)
        let labels = row.subviews.compactMap { ($0 as? LabelView)?.text }
        #expect(labels.contains("Review") && labels.contains("Scan") && labels.contains("1/2"))
        #expect(labels.contains("3 agents · 2 working · 1 done"))
        try FileManager.default.createDirectory(atPath: "/tmp/candywrapper-fidelity", withIntermediateDirectories: true)
        for dark in [false, true] {
            try Snapshot.writePNG(Snapshot.image(of: row, size: row.frame.size, scale: 2, dark: dark),
                                  to: URL(fileURLWithPath: "/tmp/candywrapper-fidelity/workflow-opening-\(dark ? "dark" : "light").png"))
        }
    }
}
