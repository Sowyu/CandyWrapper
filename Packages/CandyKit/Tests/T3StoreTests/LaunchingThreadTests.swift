import Testing
import T3Protocol
@testable import T3Store

/// #33783 (threadInbox.test.ts at 4928): a thread this client is launching reads as preparing until its run lands.
struct LaunchingThreadTests {
    @Test func runLessLaunchReadsAsPreparingUntilItsRunLands() {
        let fresh = T3StoreTests.thread("t") { $0.latestRunId = nil; $0.activeProviderThreadId = nil }
        #expect(SidebarThread(fresh).runtime == nil)
        let launching = SidebarThread(fresh, launching: true)
        #expect(launching.runtime?.status == .preparing)
        #expect(SidebarModel.isThreadWorking(launching))
        let running = T3StoreTests.thread("t") { $0.latestRunId = RunId("r") }
        #expect(SidebarThread(running, launching: true).runtime == SidebarThread(running).runtime)
    }
}
