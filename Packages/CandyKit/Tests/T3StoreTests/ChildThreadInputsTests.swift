import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// `childThreadInputsAtom` against threadShell.ts in the 3105 tree (109aaae6c).
struct ChildThreadInputsTests {
    static func child(_ id: String, of parent: String, _ edit: (inout ThreadShell) -> Void = { _ in }) -> ThreadShell {
        thread(id) {
            $0.lineage.parentThreadId = ThreadId(parent)
            $0.lineage.relationshipToParent = .subagent
            $0.pendingRuntimeRequest = PendingRuntimeRequestSummary(id: RuntimeRequestId("q-\(id)"), kind: .userInput, createdAt: "2026-10-14T00:00:00.000Z")
            edit(&$0)
        }
    }

    static func live(_ status: ThreadStatus) -> (inout ThreadShell) -> Void {
        { $0.activityRunStatus = status; $0.activityRunStartedAt = .value("2026-10-14T00:00:00.000Z") }
    }

    @Test func questionsCountWhileTheChildRunLives() {
        let threads = [
            thread("root"),
            Self.child("live", of: "root", Self.live(.waiting)),
            // The run ended: the parent no longer waits on the answer.
            Self.child("ended", of: "root") { $0.activityRunStatus = nil; $0.activityRunStartedAt = .null },
            // A grandchild still asks the root.
            Self.child("deep", of: "live", Self.live(.running)),
            // An older server: the latest run's status decides.
            Self.child("old", of: "root") { $0.status = .waiting },
            Self.child("native", of: "root") { Self.live(.running)(&$0); $0.creationSource = "provider" },
        ]
        #expect(ChildThreadInputs.pending(for: "root", in: threads).map(\.id.rawValue) == ["live", "old", "deep"])
    }

    /// T3 3824 #26367 (threadShell.ts:96-98): the coordinator answers its children's questions, so a question
    /// flags no thread above it, while the child's own banner still counts it.
    @Test func aSubagentQuestionStaysOffItsParents() {
        let threads = [thread("root"), Self.child("ask", of: "root", Self.live(.waiting))]
        #expect(PendingSubagentRequests.byThread(threads).isEmpty)
        #expect(ChildThreadInputs.pending(for: "root", in: threads).map(\.id.rawValue) == ["ask"])
    }

    /// `pendingSubagentRequestsByThread` and the snooze it ends (threadShell.test.ts, threadSnoozed.test.ts, T3 f4df794777).
    @Test func aSubagentRequestReachesEveryThreadAboveIt() {
        let approval = { (t: inout ThreadShell) in
            Self.live(.running)(&t)
            t.pendingRuntimeRequest = PendingRuntimeRequestSummary(id: RuntimeRequestId("a-\(t.id.rawValue)"), kind: "command_approval",
                                                                   createdAt: "2026-10-14T00:00:00.000Z")
        }
        let threads = [
            thread("root") { $0.snoozedUntil = "2999-01-01T00:00:00.000Z"; $0.snoozedAt = "2026-10-14T00:00:00.000Z" },
            Self.child("mid", of: "root") { $0.pendingRuntimeRequest = nil },
            Self.child("ask", of: "mid", Self.live(.waiting)),
            Self.child("approve", of: "mid", approval),
            Self.child("other", of: "root", Self.live(.waiting)),
            Self.child("native", of: "other") { Self.live(.running)(&$0); $0.creationSource = "provider" },
            Self.child("auth", of: "other") { Self.live(.running)(&$0); $0.pendingRuntimeRequest?.kind = .authRefresh },
        ]
        let requests = PendingSubagentRequests.byThread(threads)
        // An approval outranks a question.
        #expect(requests["root"] == .approval && requests["mid"] == .approval && requests["other"] == nil)
        #expect(ChildThreadInputs.title(ChildThreadInputs.pending(for: "mid", in: threads)) == "2 subagents need you")
        let root = SidebarThread(threads[0], pendingSubagentRequest: requests["root"])
        #expect(!SidebarModel.effectiveSnoozed(root, nowMs: 0))
        #expect(!SidebarModel.canSnooze(root, nowMs: 0))
        #expect(SidebarModel.resolveSidebarThreadStatus(root) == .approval)
        #expect(SidebarModel.effectiveSnoozed(SidebarThread(threads[0]), nowMs: 0))
    }
}
