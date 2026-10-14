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
}
