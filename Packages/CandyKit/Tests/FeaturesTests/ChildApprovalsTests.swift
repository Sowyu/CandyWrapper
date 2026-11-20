import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// #28516: subagents' approvals listed in the parent above the composer (ChildThreadApprovals.tsx at 4928).
@MainActor
struct ChildApprovalsTests {
    private func entry(_ child: String, _ request: String, live: Bool = true) -> ChildApproval {
        ChildApproval(threadId: ThreadId("env:\(child)"), title: "Child \(child)",
                      approval: PendingApproval(requestId: request, requestKind: .command, detail: "git push", canRespond: live))
    }

    @Test func listsEveryApprovalAndKeepsCardsAcrossUpdates() {
        let view = ChildApprovalsView(frame: NSRect(x: 0, y: 0, width: 480, height: 10))
        #expect(view.isEmpty && view.subviews.isEmpty)
        view.set([entry("a", "r1"), entry("b", "r2")])
        let h = view.height(forWidth: 480)
        #expect(h > 100 && h <= ChildApprovalsView.maxHeight)
        view.frame.size.height = h
        view.layoutSubtreeIfNeeded()
        let cards = view.subviews.first.flatMap { ($0 as? NSScrollView)?.documentView?.subviews } ?? []
        #expect(cards.count == 2)
        view.set([entry("b", "r2")])
        let kept = view.subviews.first.flatMap { ($0 as? NSScrollView)?.documentView?.subviews } ?? []
        #expect(kept.count == 1 && kept.first === cards.last)
        // Many cards scroll inside `max-h-80`.
        view.set((0..<8).map { entry("c\($0)", "r\($0)") })
        #expect(view.height(forWidth: 480) == ChildApprovalsView.maxHeight)
        view.set([])
        #expect(view.isEmpty && view.subviews.isEmpty)
    }

    @Test func answersThroughTheChildThread() async {
        let view = ChildApprovalsView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        var answered: [(ThreadId, String, ApprovalDecision)] = []
        view.onRespond = { thread, request, decision in answered.append((thread, request, decision)); return nil }
        let child = entry("a", "r1")
        view.set([child])
        #expect(await view.respond(child, .accept) == nil)
        #expect(answered.count == 1 && answered[0].0 == ThreadId("env:a") && answered[0].1 == "r1" && answered[0].2 == .accept)
    }

    @Test func sitsAboveTheComposerAndMovesTheTimelineUp() throws {
        ThemeRuntime.apply(ThemeRuntimeInput())
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let projection = try #require(try ThreadPreview.projections().first)
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        let inset = panel.timeline.bottomInset
        panel.childApprovals.set([entry("a", "r1")])
        panel.layoutSubtreeIfNeeded()
        #expect(!panel.composer.isHidden)
        #expect(!panel.childApprovals.isHidden)
        #expect(panel.childApprovals.frame.maxY <= panel.composer.frame.minY - ChildApprovalsView.gap + 0.5)
        #expect(panel.timeline.bottomInset > inset)
        panel.childApprovals.set([])
        panel.layoutSubtreeIfNeeded()
        #expect(panel.childApprovals.isHidden && panel.timeline.bottomInset == inset)
    }
}
