import AppKit
import Testing
import T3Protocol
@testable import Features

/// Arrow keys on a queued row's grip (QueuedRunsControl.tsx:350-359): up moves before the previous
/// run, down before the run two below or to the end; edges, saving rows and a busy queue do nothing.
@MainActor
struct QueueKeyboardTests {
    @Test func openQuestionsBlockEditingWithoutBlockingReorder() {
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
