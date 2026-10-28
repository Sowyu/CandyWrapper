import Testing
import T3Protocol
@testable import T3Store

struct ThreadRequestResolutionTests {
    @Test func announcesFirstStateAndRemovalsButNotOnlyAdditions() {
        var tracker = ThreadRequestResolutionTracker()
        let changed1 = tracker.update(pending: ["one"])
        #expect(changed1)
        let changed2 = tracker.update(pending: ["one"])
        #expect(!changed2)
        let changed3 = tracker.update(pending: ["one", "two"])
        #expect(!changed3)
        let changed4 = tracker.update(pending: ["two"])
        #expect(changed4)
        let changed5 = tracker.update(pending: [])
        #expect(changed5)
        let changed6 = tracker.update(pending: [])
        #expect(!changed6)
    }

    @Test func cleanupScopesRequestsAndAttachmentsToTheirThreadAndEnvironment() {
        let thread = ThreadId("t").scoped(to: "sandbox-a")
        let other = ThreadId("t").scoped(to: "sandbox-b")
        let keys = [thread.rawValue + "\u{0}answered\u{0}q", thread.rawValue + "\u{0}pending\u{0}q",
                    other.rawValue + "\u{0}answered\u{0}q", thread.rawValue + "x\u{0}answered\u{0}q"]
        #expect(ThreadRequestResolutionTracker.resolvedDraftKeys(keys, threadId: thread, pending: ["pending"]) == [keys[0]])
        #expect(ThreadRequestResolutionTracker.resolvedDraftKeys(keys, threadId: thread, pending: []).count == 2)
    }
}
