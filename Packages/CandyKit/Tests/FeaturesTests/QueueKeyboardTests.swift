import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Arrow keys on a queued row's grip (QueuedRunsControl.tsx:350-359): up moves before the previous
/// run, down before the run two below or to the end; edges, saving rows and a busy queue do nothing.
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
