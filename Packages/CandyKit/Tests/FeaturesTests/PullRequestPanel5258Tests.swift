import AppKit
import Testing
@testable import T3Protocol
@testable import Features

/// 5258: a pull request's Summary comes back with its order and scroll (#42179,
/// PullRequestSummaryTab.tsx:478-487, PullRequestDetailPanel.tsx:342).
@MainActor
struct PullRequestSummaryMemoryTests {
    @Test func eachPullRequestKeepsItsOrderAndScroll() throws {
        PullRequestSummaryView.memory = [:]
        var a = try PullRequestFixtures.detail()
        a.body = (0..<80).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        var b = a
        b.url += "-other"
        let panel = PullRequestDetailView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        panel.show(a)
        panel.layoutSubtreeIfNeeded()
        panel.summary.stack.scroll(toTop: 300)
        panel.summary.orderButton.action?()
        // Condensing the header refunds its height, so read where it landed.
        let left = panel.summary.scrollTarget.top
        #expect(left > 100 && panel.condensed)
        panel.show(b)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.summary.scrollTarget.top == 0)
        #expect(panel.summary.orderButton.title == "Newest first")
        #expect(!panel.condensed)
        panel.show(a)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.summary.scrollTarget.top == left)
        #expect(panel.condensed)
        #expect(panel.summary.orderButton.title == "Oldest first")
        // A new view, as when the panel closed and reopened, restores it too.
        let reopened = PullRequestDetailView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        reopened.show(a)
        reopened.layoutSubtreeIfNeeded()
        #expect(reopened.summary.scrollTarget.top == left)
        #expect(reopened.condensed)
    }
}

/// 5258: a clicked pull request pane scrolls from the keyboard (#39319).
@MainActor
struct PullRequestKeyScrollTests {
    @Test func keysMoveTheFocusedPane() {
        let at = { (key: UInt16, flags: NSEvent.ModifierFlags, top: CGFloat) in
            KeyScroll.target(keyCode: key, flags: flags, top: top, page: 300, max: 1000)
        }
        #expect(at(125, [], 0) == 40)
        #expect(at(126, [], 20) == 0)
        #expect(at(121, [], 0) == 270)
        #expect(at(49, [.shift], 500) == 230)
        #expect(at(119, [], 0) == 1000)
        #expect(at(126, [.command], 500) == 0)
        #expect(at(125, [.option], 0) == nil)
        #expect(at(0, [], 0) == nil)
    }
}
