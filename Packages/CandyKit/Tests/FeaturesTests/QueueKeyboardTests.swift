import AppKit
import Testing
import DesignSystem
import T3Store
import T3Protocol
@testable import Features

/// Send now uses the same action while running or stopped; questions and in-flight commands block editing.
@MainActor
struct QueueKeyboardTests {
    @Test func defaultQueueLivesInTheTimelineFooter() throws {
        let panel = ComposerFidelityTests.panel(width: 844, dark: false)
        panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
        panel.queue.state = .init(items: [.init(runId: "queued", messageId: "message", text: "Next message")], canPromoteToSteer: true)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.queue.isDescendant(of: panel.timeline))
        #expect(panel.timeline.layoutProblems().isEmpty)
        panel.queue.state = .init()
        panel.layoutSubtreeIfNeeded()
        #expect(panel.queue.superview == nil && panel.queue.isHidden)
        #expect(panel.timeline.layoutProblems().isEmpty)
    }

    @Test func openQuestionsBlockEditingAndBusyQueuesWait() {
        #expect(ComposerLogic.queuedEditBlockedReason(openQuestionCount: 0) == nil)
        let reason = ComposerLogic.queuedEditBlockedReason(openQuestionCount: 1)
        #expect(reason == "Answer the question to edit queued messages")
        let view = QueuedRunsView()
        view.state = .init(items: [.init(runId: "a", messageId: nil, text: "queued")])
        view.editBlockedReason = reason
        var edits = 0
        view.onEdit = { _ in edits += 1 }
        view.edit(0)
        #expect(edits == 0)
        view.editBlockedReason = nil
        view.edit(0)
        #expect(edits == 1)
        view.isBusy = true
        view.edit(0)
        #expect(edits == 1)
    }

    @Test func senderTitlesRefreshWithoutChangingTheQueue() {
        let view = QueuedRunsView()
        let message = ChatMessage(id: "m", role: .user, text: "Review", createdAt: "2026-10-28T00:00:00Z", createdBy: "agent", senderThreadId: "sender")
        view.state = .init(items: [.init(runId: "r", messageId: "m", text: "Review", message: message)])
        func labels(_ root: NSView) -> [LabelView] { root.subviews.flatMap { ($0 as? LabelView).map { [$0] } ?? labels($0) } }
        #expect(labels(view).contains { $0.text == "Agent" })
        view.senderThreadTitles = ["sender": "Review helper"]
        #expect(labels(view).contains { $0.text == "Review helper" })
        view.senderThreadTitles = ["sender": "  New title  "]
        #expect(labels(view).contains { $0.text == "New title" })
    }

    @Test func runningAndStoppedQueuesBothOfferSendNow() {
        for running in [false, true] {
            let view = QueuedRunsView()
            view.state = .init(items: [.init(runId: "a", messageId: "m", text: "queued")],
                               canPromoteToSteer: running, canSendNow: !running)
            func buttons(_ root: NSView) -> [ButtonView] {
                root.subviews.flatMap { ($0 as? ButtonView).map { [$0] } ?? buttons($0) }
            }
            let send = buttons(view).first { $0.title == "Send now" }
            #expect(send?.isEnabled == true)
            var sent: RunId?
            view.onSteer = { sent = $0 }
            send?.action?()
            #expect(sent == "a")
        }
    }
    @Test func arrowReorder() {
        let ids = ["a", "b", "c"].map { RunId($0) }
        let view = QueuedRunsView()
        view.state = ComposerLogic.QueueState(items: ids.map { .init(runId: $0, messageId: nil, text: $0.rawValue) }
                                              + [.init(runId: nil, messageId: nil, text: "saving")], canReorder: true)
        var moves: [(RunId, RunId?)] = []
        view.onReorder = { moves.append(($0, $1)) }
        #expect(!view.moveByKey(0, up: true))
        #expect(view.moveByKey(1, up: true))
        #expect(view.moveByKey(0, up: false))
        #expect(view.moveByKey(1, up: false))
        #expect(!view.moveByKey(2, up: false))
        #expect(!view.moveByKey(3, up: true)) // the saving row has no run
        #expect(moves.map(\.0) == [ids[1], ids[0], ids[1]])
        #expect(moves.map(\.1) == [ids[0], ids[2], nil])
        view.isBusy = true
        #expect(!view.moveByKey(1, up: true) && moves.count == 3)
    }
}
