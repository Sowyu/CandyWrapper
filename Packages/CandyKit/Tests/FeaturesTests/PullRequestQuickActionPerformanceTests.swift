import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct PullRequestQuickActionPerformanceTests {
    @Test func shiftKeepsRowContentAndButtons() throws {
        let entries = try PullRequestFixtures.list().entries
        let page = PullRequestsPageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var model = PullRequestsPageView.Model()
        model.body = .list
        model.groups = PullRequestListLogic.groupByInvolvement(entries, viewers: [:])
        page.model = model
        func rows(_ view: NSView) -> [PullRequestRowView] {
            view.subviews.flatMap { child in (child as? PullRequestRowView).map { [$0] } ?? rows(child) }
        }
        let mounted = rows(page)
        #expect(!mounted.isEmpty)
        let counts = mounted.map(\.configurationCount)
        let children = mounted.map { $0.subviews }
        for visible in [true, false, true] {
            model.speedMode = visible
            page.model = model
            #expect(mounted.map(\.configurationCount) == counts)
            for (row, original) in zip(mounted, children) {
                #expect(row.subviews.count == original.count)
                #expect(zip(row.subviews, original).allSatisfy { $0 === $1 })
                #expect(row.subviews.compactMap { $0 as? ButtonView }.allSatisfy { $0.isHidden != visible })
            }
        }
    }
}
