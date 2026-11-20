import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// `presentRunStop` (4928 threadExecution.ts:534-581).
struct RunStopTests {
    func run(_ id: String, _ ordinal: Int, _ status: String) -> Run {
        try! JSONDecoder().decode(Run.self, from: Data(#"{"id":"\#(id)","threadId":"t","ordinal":\#(ordinal),"status":"\#(status)","requestedAt":"2026-11-19T00:00:00.000Z"}"#.utf8))
    }
    func item(_ type: String, run: String, extra: String = "") throws -> TurnItem {
        try TurnItem(json: JSONValue(parsing: Data(#"{"id":"\#(type)-\#(run)","threadId":"t","type":"\#(type)","runId":"\#(run)","ordinal":1,"status":"completed","startedAt":"2026-11-19T00:00:01.000Z","updatedAt":"2026-11-19T00:00:02.000Z"\#(extra)}"#.utf8)))
    }

    @Test func stopStates() throws {
        let runs = [run("r1", 1, "completed"), run("r2", 2, "running"), run("r3", 3, "queued")]
        #expect(RunStop.present(runs: runs, turnItems: []) == nil)
        let request = try item("run_interrupt_request", run: "r2")
        let stopping = RunStop.present(runs: runs, turnItems: [request])
        #expect(stopping?.state == .stopping && stopping?.runId == RunId("r2") && stopping?.background == false)
        #expect(stopping?.requestedAt.raw == "2026-11-19T00:00:01.000Z")
        let stuck = try item("run_interrupt_request", run: "r2", extra: #","unresponsiveAt":"2026-11-19T00:00:31.000Z""#)
        #expect(RunStop.present(runs: runs, turnItems: [stuck])?.state == .unresponsive)
        #expect(RunStop.present(runs: runs, turnItems: [stuck, try item("run_interrupt_result", run: "r2")]) == nil)
        // A run that already ended counts only once its background Stop went unanswered.
        let ended = [run("r1", 1, "interrupted")]
        #expect(RunStop.present(runs: ended, turnItems: [try item("run_interrupt_request", run: "r1")]) == nil)
        let background = try item("run_interrupt_request", run: "r1", extra: #","unresponsiveAt":"2026-11-19T00:00:31.000Z""#)
        #expect(RunStop.present(runs: ended, turnItems: [background])?.background == true)
    }
}
