import AppKit
import Testing
import DesignSystem
import T3Store
@testable import Features

@MainActor
struct TimelineRowPlacementTests {
    @Test(.threadDesign(true))
    func fractionalRowsMeetWithoutAnExtraGap() throws {
        let projection = try #require(try ThreadPreview.projections(transcript: "3824-panel-threads.jsonl")
            .first { $0.thread.title == "Document Hello Demo" })
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
        let panel = ThreadPanelView(frame: NSRect(x: 256, y: 0, width: 360, height: 780))
        surface.addSubview(panel)
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        panel.timeline.scroll(toFraction: 0)
        let rows = panel.model.items.compactMap { panel.timeline.view(forRow: $0.id) }
        let user = try #require(rows.compactMap { $0 as? UserMessageRowView }.first)
        let fold = try #require(rows.compactMap { $0 as? TurnFoldRowView }.first)
        // Five 22.75pt lines make this bubble end between device pixels.
        #expect(user.frame.maxY * 2 != (user.frame.maxY * 2).rounded())
        #expect(fold.frame.minY == user.frame.maxY)
        let rule = try #require(fold.subviews.compactMap { $0 as? FillView }.first)
        // MessagesTimeline.tsx:1435,1636: pb-1.5 outside the bordered fold.
        #expect(rule.frame.maxY + 6 == fold.bounds.height)
    }
}
