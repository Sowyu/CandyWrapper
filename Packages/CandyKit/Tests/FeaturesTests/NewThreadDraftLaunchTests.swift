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

    /// The draft picker (DraftHeroHeadline.tsx:211-247 in 2994): only a draft with content moves; it takes the new
    /// project's slot, drops machine-specific picks, and an empty draft it displaces is discarded.
    @Test func pickerMovesADraftWithContentToTheChosenProject() {
        #expect(!DraftProjectMove.hasUserContent(prompt: "  \n", attachmentCount: 0))
        #expect(DraftProjectMove.hasUserContent(prompt: "", attachmentCount: 1))
        #expect(DraftProjectMove.hasUserContent(prompt: "fix it", attachmentCount: 0))
        var open = Self.draft("env1:t1")
        open.branch = "main"; open.worktreePath = "/w"; open.envMode = .worktree
        let empty = DraftSession(draftId: "draft-2", threadId: "env2:t2", projectId: "env2:project-2", createdAt: Date())
        let kept = DraftSession(draftId: "draft-3", threadId: "env2:t3", projectId: "env2:project-2", createdAt: Date())
        let r = DraftProjectMove.move(open, to: ProjectId("env2:project-2"), key: "group-2",
                                      in: ["group-1": open, "group-2": empty], keep: { _ in false })
        #expect(r.sessions.keys.sorted() == ["group-2"])
        #expect(r.moved.draftId == "draft-1" && r.moved.projectId == "env2:project-2" && r.moved.threadId == "env2:t1")
        #expect(r.moved.branch == nil && r.moved.worktreePath == nil && r.moved.envMode == .worktree)
        let k = DraftProjectMove.move(open, to: ProjectId("env2:project-2"), key: "group-2",
                                      in: ["group-1": open, "group-2": kept], keep: { _ in true })
        #expect(k.sessions["draft:draft-3"] == kept && k.sessions["group-2"]?.draftId == "draft-1")
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
