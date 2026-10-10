import AppKit
import Testing
import T3Protocol
@testable import Features

/// Arrow keys on a queued row's grip (QueuedRunsControl.tsx:350-359): up moves before the previous
/// run, down before the run two below or to the end; edges, saving rows and a busy queue do nothing.
@MainActor
struct QueueKeyboardTests {
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
