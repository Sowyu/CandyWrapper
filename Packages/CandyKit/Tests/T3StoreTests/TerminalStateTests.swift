import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// The drawer's state, the sidebar's terminal activity and the attach stream's state machine.
struct TerminalStateTests {
    static func snapshot(_ status: TerminalSessionStatus, history: String = "") -> TerminalSessionSnapshot {
        TerminalSessionSnapshot(threadId: "t", terminalId: "term-1", cwd: "/repo", status: status, history: history, label: "zsh", updatedAt: "x")
    }

    @Test func drawerHeightClamp() {
        #expect(TerminalDrawerState.clampHeight(100, windowHeight: 800) == 180)
        #expect(TerminalDrawerState.clampHeight(700, windowHeight: 800) == 600)
        #expect(TerminalDrawerState.clampHeight(280.4, windowHeight: 800) == 280)
        // A short window still allows 180.
        #expect(TerminalDrawerState.clampHeight(300, windowHeight: 200) == 180)
    }

    @Test func drawerEnsureAndClose() {
        var state = TerminalDrawerState()
        state.ensure("term-1")
        state.ensure("term-2")
        #expect(state.open && state.terminalIds == ["term-1", "term-2"] && state.resolvedActiveId == "term-2")
        state.height = 400
        state.close("term-2")
        #expect(state.resolvedActiveId == "term-1" && state.height == 400)
        state.close("term-1")
        #expect(state == TerminalDrawerState()) // closed, default height
    }

    @Test func activityCountsRunningSubprocesses() {
        func summary(_ thread: String, _ id: String, running: Bool) -> TerminalSummary {
            TerminalSummary(threadId: thread, terminalId: id, cwd: "/", status: .running, hasRunningSubprocess: running, label: "", updatedAt: "x")
        }
        var activity = TerminalActivity()
        let r0 = activity.apply(.snapshot([summary("a", "term-1", running: true), summary("a", "term-2", running: true), summary("b", "term-1", running: false)]))
        #expect(r0)
        #expect(activity.runningThreads == ["a": 2])
        let r1 = activity.apply(.upsert(summary("b", "term-1", running: false)))
        #expect(!r1)
        let r2 = activity.apply(.remove(threadId: "a", terminalId: "term-2"))
        #expect(r2)
        #expect(activity.runningThreads == ["a": 1])
        #expect(activity.terminalIds(threadId: "a") == ["term-1"])
    }

    @Test func attachSnapshotThenOutput() {
        var model = TerminalSessionModel()
        #expect(!model.canResize)
        let first = model.apply(.snapshot(Self.snapshot(.running, history: "old\r\n")))
        #expect(first.actions == [.reset("old\r\n")] && first.resendSize && !first.sessionEnded)
        #expect(model.canResize)
        let r3 = model.apply(.output("x"))
        #expect(r3.actions == [.write("x")])
        let r4 = model.apply(.cleared)
        #expect(r4.actions == [.reset("")])
        let r5 = model.apply(.activity(hasRunningSubprocess: true, label: "top"))
        #expect(r5 == .init())
        #expect(model.hasRunningSubprocess && model.label == "top")
    }

    @Test func exitHandledOnce() {
        var model = TerminalSessionModel()
        _ = model.apply(.snapshot(Self.snapshot(.running)))
        let exit = model.apply(.exited(code: 0, signal: nil))
        #expect(exit.actions == [.message("Process exited")] && exit.sessionEnded)
        #expect(!model.canResize)
        // The following `closed` does not close twice.
        let r6 = model.apply(.closed)
        #expect(r6 == .init())
        // A restart re-arms it.
        _ = model.apply(.restarted(Self.snapshot(.running)))
        let r7 = model.apply(.closed)
        #expect(r7.actions == [.message("Terminal closed")])
    }

    @Test func attachToExitedSession() {
        var model = TerminalSessionModel()
        let outcome = model.apply(.snapshot(Self.snapshot(.exited, history: "bye\r\n")))
        #expect(outcome.actions == [.reset("bye\r\n"), .message("Process exited")] && outcome.sessionEnded)
        #expect(TerminalSessionModel.messageText("Process exited") == "\r\n[terminal] Process exited\r\n")
    }
}
