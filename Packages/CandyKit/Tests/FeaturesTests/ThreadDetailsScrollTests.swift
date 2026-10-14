import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import T3Store
@testable import Features

/// A long Lineage in a short window: the details card stays inside the chat canvas, the group's rows sit in
/// T3's 13.5rem list, and scrolling the list and then the card brings the last row into view
/// (ThreadDetailsCard.tsx:122-135, ThreadRelationshipsControl.tsx:82-114).
@MainActor
struct ThreadDetailsScrollTests {
    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    static func scrollToEnd(_ area: ScrollAreaView) {
        let clip = area.scrollView.contentView.bounds.height
        area.scroll(to: NSPoint(x: 0, y: max(0, (area.scrollView.documentView?.frame.height ?? 0) - clip)))
    }

    /// 1100pt wide puts the card inline, 700pt makes it the popover.
    @Test(arguments: [1100, 700] as [CGFloat])
    func thirtyAgentsFitAndScrollToTheLastRow(width: CGFloat) throws {
        let projection = try #require(try ThreadPreview.projections().first)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: width, height: 420))
        let window = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        window.contentView = panel
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        panel.setDetailsOpen(true)
        #expect(panel.detailsInline == (width > 1000))

        let card = panel.detailsCard
        var lineage = ThreadRelationships.Lineage()
        lineage.previous = (1...30).map { ThreadLineageFidelityTests.lineageRow(["subagent", "completed", "Agent \($0)"], index: $0) }
        card.lineage.lineage = lineage
        card.lineage.previousExpanded = true
        while let more = Self.views(ThreadLineageShowMoreView.self, in: card).first { more.performAction() }
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()

        // The card ends inside the panel and is shorter than its content.
        #expect(!card.isHidden)
        #expect(panel.bounds.contains(card.frame), "card \(card.frame) runs past \(panel.bounds)")
        #expect(card.preferredHeight > card.frame.height)
        let list = try #require(Self.views(ThreadLineageRowListView.self, in: card).first)
        #expect(list.frame.height == ThreadLineageRowListView.maxHeight)

        let rows = Self.views(ThreadLineageRowView.self, in: card)
        #expect(rows.count == 30)
        let last = try #require(rows.first { $0.row.title == "Agent 30" })
        Self.scrollToEnd(list.area)
        Self.scrollToEnd(card.scrollArea)
        panel.layoutSubtreeIfNeeded()
        // The last row shows whole: inside its list's clip and inside the card's border.
        let inList = list.area.scrollView.contentView.convert(last.bounds, from: last)
        #expect(list.area.scrollView.contentView.bounds.contains(inList))
        let inCard = card.convert(last.bounds, from: last)
        #expect(card.bounds.insetBy(dx: 1, dy: 1).contains(inCard), "last row \(inCard) outside \(card.bounds)")
    }
}
