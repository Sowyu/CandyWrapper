import AppKit
import Testing
import DesignSystem
import T3Store
import T3Protocol
@testable import Features

/// Send now uses the same action while running or stopped; questions and in-flight commands block editing.
@MainActor
struct QueueKeyboardTests {
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
        func buttons(_ root: NSView) -> [ButtonView] { root.subviews.flatMap { ($0 as? ButtonView).map { [$0] } ?? buttons($0) } }
        #expect(buttons(view).contains { $0.title == "Agent" })
        view.senderThreadTitles = ["sender": "Review helper"]
        #expect(buttons(view).contains { $0.title == "Review helper" })
        view.senderThreadTitles = ["sender": "  New title  "]
        #expect(buttons(view).contains { $0.title == "New title" })
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
}
