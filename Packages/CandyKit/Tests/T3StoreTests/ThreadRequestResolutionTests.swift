import Testing
import T3Protocol
@testable import T3Store

struct ThreadRequestResolutionTests {
    @Test func announcesFirstStateAndRemovalsButNotOnlyAdditions() {
        var tracker = ThreadRequestResolutionTracker()
        #expect(tracker.update(pending: ["one"]))
        #expect(!tracker.update(pending: ["one"]))
        #expect(!tracker.update(pending: ["one", "two"]))
        #expect(tracker.update(pending: ["two"]))
        #expect(tracker.update(pending: []))
        #expect(!tracker.update(pending: []))
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
