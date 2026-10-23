import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// Redesign's subagent strip: which subagents it lists, in what order, with what status, and when the pill shows.
@Suite struct SubagentStripTests {
    private func agent(_ id: String, child: String?, status: String, run: String = "run-2", origin: String = "app_owned",
                       started: Bool = true, extra: String = "") -> JSONValue {
        let childField = child.map { "\"\($0)\"" } ?? "null"
        let json = """
            {"id":"\(id)","threadId":"parent","runId":"\(run)","origin":"\(origin)","driver":"claudeAgent",
             "providerInstanceId":"claude","childThreadId":\(childField),"prompt":"Sleep then reply ok","title":"Task \(id)",
             "model":"claude-haiku-5-5","status":"\(status)","result":null,
             "startedAt":\(started ? "\"2026-10-23T10:00:00.000Z\"" : "null"),"completedAt":null\(extra)}
            """
        return try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func child(_ id: String, _ edit: (inout ThreadShell) -> Void = { _ in }) -> ThreadShell {
        thread(id) {
            $0.lineage.parentThreadId = "parent"
            $0.lineage.relationshipToParent = .subagent
            $0.title = "Child \(id)"
            edit(&$0)
        }
    }

    @Test func activeRowsComeNewestFirstThenThisTurnsFinishedOnes() {
        let records = [agent("a", child: "c1", status: "completed"), agent("b", child: "c2", status: "running"),
                       agent("c", child: nil, status: "pending"), agent("d", child: "c4", status: "failed"),
                       agent("e", child: "c5", status: "completed", run: "run-1")]
        let strip = SubagentStrip.make(subagents: records, shells: [child("c1"), child("c2"), child("c4"), child("c5")],
                                       latestRunId: "run-2", parent: nil)
        // Active newest first (c, b), then this turn's finished ones newest first (d, a); run-1's "e" is left out.
        #expect(strip.rows.map(\.label) == ["Subagent 3", "Subagent 2", "Subagent 4", "Subagent 1"])
        #expect(strip.rows.map(\.status) == [.running, .running, .failed, .done])
        #expect(strip.rows.map(\.finished) == [false, false, true, true])
        // The child's shell title wins; a missing child falls back to the record's title.
        #expect(strip.rows.map(\.title) == ["Task c", "Child c2", "Child c4", "Child c1"])
        #expect(strip.activeCount == 2)
        #expect(strip.pillText == "2")
        #expect(strip.isVisible)
    }

    @Test func hiddenWithoutWorkingSubagents() {
        #expect(!SubagentStrip.make(subagents: [], shells: [], latestRunId: nil, parent: nil).isVisible)
        let done = SubagentStrip.make(subagents: [agent("a", child: "c1", status: "completed")], shells: [child("c1")],
                                      latestRunId: "run-2", parent: nil)
        #expect(!done.isVisible)
        // Still listed, so it can open while another subagent runs.
        #expect(done.rows.count == 1)
    }

    @Test func finishedRowsAreCapped() {
        let records = (1...10).map { agent("f\($0)", child: nil, status: "completed") } + [agent("live", child: nil, status: "running")]
        let strip = SubagentStrip.make(subagents: records, shells: [], latestRunId: "run-2", parent: nil)
        #expect(strip.rows.count == 1 + SubagentStrip.finishedCap)
        #expect(strip.rows[1].label == "Subagent 10")
    }

    @Test func waitingAndNeedsInputStatuses() {
        let question = PendingRuntimeRequestSummary(id: "request-1", kind: .userInput, createdAt: "2026-10-23T10:00:00.000Z", blocking: true)
        let asking = child("c1") {
            $0.status = .waiting
            $0.activityRunStatus = .waiting
            $0.activityRunStartedAt = .value("2026-10-23T10:00:00.000Z")
            $0.pendingRuntimeRequest = question
        }
        let records = [agent("a", child: "c1", status: "running"), agent("b", child: "c2", status: "waiting")]
        let strip = SubagentStrip.make(subagents: records, shells: [asking, child("c2")], latestRunId: "run-2", parent: nil)
        #expect(strip.rows.map(\.status) == [.waiting, .needsInput])
        #expect(strip.activeCount == 2)
    }

    @Test func parentWaitingReadsWaitingOn() {
        let records = [agent("a", child: nil, status: "running"), agent("b", child: nil, status: "running")]
        let idle = thread("parent") {
            $0.status = .completed
            $0.pendingBackgroundTasks = [PendingBackgroundTask(taskId: "a", kind: .subagent), PendingBackgroundTask(taskId: "b", kind: .subagent)]
        }
        let waiting = SubagentStrip.make(subagents: records, shells: [], latestRunId: "run-2", parent: idle)
        #expect(waiting.parentWaiting)
        #expect(waiting.pillText == "Waiting on 2")
        let working = thread("parent") { $0.status = .running; $0.activityRunStatus = .running }
        let running = SubagentStrip.make(subagents: records, shells: [], latestRunId: "run-2", parent: working)
        #expect(!running.parentWaiting)
        #expect(running.pillText == "2")
    }

    @Test func stopFollowsLineageRules() {
        let app = SubagentStrip.make(subagents: [agent("a", child: nil, status: "running")], shells: [], latestRunId: "run-2", parent: nil)
        #expect(app.rows.first?.canStop == true)
        let unstarted = SubagentStrip.make(subagents: [agent("a", child: nil, status: "pending", started: false)], shells: [],
                                           latestRunId: "run-2", parent: nil)
        #expect(unstarted.rows.first?.canStop == false)
        let weak = SubagentStrip.make(subagents: [agent("a", child: nil, status: "running", origin: "provider_native")], shells: [],
                                      latestRunId: "run-2", parent: nil)
        #expect(weak.rows.first?.canStop == false)
        let strong = agent("a", child: nil, status: "running", origin: "provider_native",
                           extra: ",\"nativeTaskRef\":{\"strength\":\"strong\",\"nativeId\":\"task-1\"}")
        #expect(SubagentStrip.make(subagents: [strong], shells: [], latestRunId: "run-2", parent: nil).rows.first?.canStop == true)
        let done = SubagentStrip.make(subagents: [agent("a", child: nil, status: "completed")], shells: [], latestRunId: "run-2", parent: nil)
        #expect(done.rows.first?.canStop == false)
    }
}
