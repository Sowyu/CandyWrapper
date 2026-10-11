import Foundation
import Testing
@testable import Features
import T3Protocol
import T3Store

/// A draft's first send must never launch with a thread id that may already exist: T3's `thread.create`
/// rewrites an existing thread and the message lands in its history (bug seen 2026-10-11).
struct NewThreadDraftLaunchTests {
    static let env = "env1"
    static let existing = "env1:thread-already-created"

    static func draft(_ threadId: String = existing) -> DraftSession {
        DraftSession(draftId: "draft-1", threadId: threadId, projectId: "env1:project-1", createdAt: Date(timeIntervalSince1970: 0))
    }

    /// Two apps on one defaults domain: app B still holds the draft app A already launched as `existing`.
    /// B's send, or New thread while A's launch is in flight, starts from that stored session.
    @Test func launchNeverReusesTheStoredThreadId() {
        var sessions = ["group-1": Self.draft()]
        var ids = ["fresh-1"].makeIterator()
        let (launch, key) = NewThreadDraftLaunch.begin(Self.draft(), in: &sessions, newId: { ids.next()! })
        #expect(launch.threadId != Self.existing)
        #expect(launch.threadId == "env1:fresh-1")
        #expect(launch.draftId == "draft-1")
        #expect(key == "group-1")
        // In flight, New thread finds no session to reopen.
        #expect(sessions.isEmpty)
    }

    @Test func failedLaunchRestoresWithAnotherThreadId() {
        var sessions: [String: DraftSession] = [:]
        let launch = Self.draft("env1:launched")
        let restored = NewThreadDraftLaunch.restore(launch, key: "group-1", in: &sessions, newId: { "fresh-2" })
        #expect(restored?.threadId == "env1:fresh-2")
        #expect(sessions["group-1"] == restored)
        // A draft the user opened since keeps its place.
        var taken = ["group-1": Self.draft("env1:other")]
        #expect(NewThreadDraftLaunch.restore(launch, key: "group-1", in: &taken) == nil)
        #expect(taken["group-1"]?.threadId == "env1:other")
    }
}
