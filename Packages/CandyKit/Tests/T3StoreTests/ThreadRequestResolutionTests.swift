import Testing
import T3Protocol
@testable import T3Store

struct ThreadRequestResolutionTests {
    @Test func announcesFirstStateAndRemovalsButNotOnlyAdditions() {
        var tracker = ThreadRequestResolutionTracker()
        var announced: [Bool] = []
        for pending in [["one"], ["one"], ["one", "two"], ["two"], [], []] as [Set<String>] {
            announced.append(tracker.update(pending: pending))
        }
        #expect(announced == [true, false, false, true, true, false])
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
