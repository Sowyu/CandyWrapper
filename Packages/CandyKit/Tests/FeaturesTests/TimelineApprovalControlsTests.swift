import AppKit
import Testing
import T3Protocol
import T3Store
import DesignSystem
@testable import Features

@MainActor
struct TimelineApprovalControlsTests {
    @Test func timelineShowsCompleteSelectableDetailAndRetainsAllResponseGuards() throws {
        let panel = ApprovalPanelView()
        panel.placement = .floating
        panel.usesCompleteDetail = true
        let command = (0..<30).map { "command line \($0)" }.joined(separator: "\n")
        let approval = PendingApproval(requestId: "r", requestKind: .command, detail: command, canRespond: true)
        panel.configure(approval, pendingCount: 1, threadId: "t")
        panel.frame = NSRect(x: 0, y: 0, width: 400, height: panel.preferredHeight(width: 400))
        panel.layoutSubtreeIfNeeded()
        let scroll = try #require(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        let detail = try #require(scroll.documentView as? NSTextView)
        #expect(detail.string == command && detail.isSelectable && !detail.isEditable)
        #expect(detail.frame.height > scroll.frame.height)
        func buttons(_ view: NSView) -> [ButtonView] { view.subviews.flatMap { ($0 as? ButtonView).map { [$0] } ?? buttons($0) } }
        let approve = try #require(buttons(panel).first { $0.title == "Approve" })
        var responses = 0
        panel.onRespond = { _, _ in responses += 1 }
        panel.canOperateThread = false
        #expect(!approve.isEnabled)
        approve.action?()
        #expect(responses == 0)
        panel.canOperateThread = true
        panel.isResponding = true
        #expect(!approve.isEnabled)
        approve.action?()
        #expect(responses == 0)
        panel.isResponding = false
        approve.action?()
        #expect(responses == 1)
        var gone = approval; gone.canRespond = false
        panel.configure(gone, pendingCount: 1, threadId: "t")
        #expect(buttons(panel).filter { $0.title == "Approve" }.allSatisfy { !$0.isEnabled })
    }
}
