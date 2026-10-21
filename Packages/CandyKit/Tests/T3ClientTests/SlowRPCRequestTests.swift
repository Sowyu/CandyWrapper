import Testing
@testable import T3Client

struct SlowRPCRequestTests {
    @Test func thresholdsFollowMethodCost() {
        #expect(SlowRPCRequestTracker.threshold(for: "server.getConfig") == 15)
        #expect(SlowRPCRequestTracker.threshold(for: "server.refreshProviders") == 120)
        #expect(SlowRPCRequestTracker.threshold(for: "server.updateProvider") == 120)
        #expect(SlowRPCRequestTracker.threshold(for: "server.updateServer") == 120)
        #expect(SlowRPCRequestTracker.threshold(for: "vcs.refreshStatus") == 120)
        #expect(SlowRPCRequestTracker.threshold(for: "orchestration.subscribeShell") == nil)
        #expect(SlowRPCRequestTracker.threshold(for: "pullRequests.list") == nil)
        #expect(SlowRPCRequestTracker.threshold(for: "server.getUsageSummary") == nil)
        #expect(SlowRPCRequestTracker.threshold(for: "server.reportClientActivity") == nil)
    }
}
