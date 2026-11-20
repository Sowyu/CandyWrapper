import Testing
import T3Protocol
@testable import T3Store

/// #34697: 4928 Sidebar.logic.test.ts "titles the window with live work and requests only" and
/// branding.logic.ts `resolveWindowTitle`.
struct WindowTitleTests {
    let running = ThreadRuntimeSummary(status: .running, updatedAt: "2026-03-09T10:00:00.000Z")

    @Test func statusNamesLiveWorkAndRequestsOnly() {
        typealias W = WindowTitle
        #expect(W.threadStatus(hasPendingApprovals: true, hasPendingUserInput: false, runtime: running) == "Needs approval")
        #expect(W.threadStatus(hasPendingApprovals: false, hasPendingUserInput: true, runtime: nil) == "Needs your input")
        #expect(W.threadStatus(hasPendingApprovals: false, hasPendingUserInput: false, runtime: running) == "Working")
        #expect(W.threadStatus(hasPendingApprovals: false, hasPendingUserInput: false, runtime: running, blockedOnThreadWait: true) == "Working")
        for status: ThreadStatus in [.idle, .failed, .completed] {
            #expect(W.threadStatus(hasPendingApprovals: false, hasPendingUserInput: false,
                                   runtime: ThreadRuntimeSummary(status: status, updatedAt: "2026-03-09T10:00:00.000Z")) == nil)
        }
        #expect(W.threadStatus(hasPendingApprovals: false, hasPendingUserInput: false, runtime: nil) == nil)
    }

    @Test func titles() {
        #expect(WindowTitle.resolve(appName: "CandyWrapper", projectTitle: nil, threadTitle: nil) == "CandyWrapper")
        #expect(WindowTitle.resolve(appName: "CandyWrapper", projectTitle: "demo", threadTitle: "Fix login") == "demo / Fix login")
        #expect(WindowTitle.resolve(appName: "CandyWrapper", projectTitle: " ", threadTitle: "Fix login") == "Fix login")
        // The screen reader title leads with the status, then the thread, then the project.
        #expect(WindowTitle.resolve(appName: "CandyWrapper", projectTitle: "demo", threadTitle: "Fix login", screenReader: .some("Working")) == "Working: Fix login - demo")
        #expect(WindowTitle.resolve(appName: "CandyWrapper", projectTitle: "demo", threadTitle: "Fix login", screenReader: .some(nil)) == "Fix login - demo")
        #expect(WindowTitle.resolve(appName: "CandyWrapper", projectTitle: nil, threadTitle: "", screenReader: .some("Working")) == "Working: CandyWrapper")
    }
}
