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
                                       latestTurn: ["run-2"], parent: nil)
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
        #expect(!SubagentStrip.make(subagents: [], shells: [], latestTurn: [], parent: nil).isVisible)
        let done = SubagentStrip.make(subagents: [agent("a", child: "c1", status: "completed")], shells: [child("c1")],
                                      latestTurn: ["run-2"], parent: nil)
        #expect(!done.isVisible)
        // Still listed, so it can open while another subagent runs.
        #expect(done.rows.count == 1)
    }

    @Test func finishedRowsAreCapped() {
        let records = (1...10).map { agent("f\($0)", child: nil, status: "completed") } + [agent("live", child: nil, status: "running")]
        let strip = SubagentStrip.make(subagents: records, shells: [], latestTurn: ["run-2"], parent: nil)
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
        let strip = SubagentStrip.make(subagents: records, shells: [asking, child("c2")], latestTurn: ["run-2"], parent: nil)
        #expect(strip.rows.map(\.status) == [.waiting, .needsInput])
        #expect(strip.activeCount == 2)
    }

    @Test func parentWaitingReadsWaitingOn() {
        let records = [agent("a", child: nil, status: "running"), agent("b", child: nil, status: "running")]
        let idle = thread("parent") {
            $0.status = .completed
            $0.pendingBackgroundTasks = [PendingBackgroundTask(taskId: "a", kind: .subagent), PendingBackgroundTask(taskId: "b", kind: .subagent)]
        }
        let waiting = SubagentStrip.make(subagents: records, shells: [], latestTurn: ["run-2"], parent: idle)
        #expect(waiting.parentWaiting)
        #expect(waiting.pillText == "Waiting on 2")
        let working = thread("parent") { $0.status = .running; $0.activityRunStatus = .running }
        let running = SubagentStrip.make(subagents: records, shells: [], latestTurn: ["run-2"], parent: working)
        #expect(!running.parentWaiting)
        #expect(running.pillText == "2")
    }

    @Test func stopFollowsLineageRules() {
        let app = SubagentStrip.make(subagents: [agent("a", child: nil, status: "running")], shells: [], latestTurn: ["run-2"], parent: nil)
        #expect(app.rows.first?.canStop == true)
        let unstarted = SubagentStrip.make(subagents: [agent("a", child: nil, status: "pending", started: false)], shells: [],
                                           latestTurn: ["run-2"], parent: nil)
        #expect(unstarted.rows.first?.canStop == false)
        let weak = SubagentStrip.make(subagents: [agent("a", child: nil, status: "running", origin: "provider_native")], shells: [],
                                      latestTurn: ["run-2"], parent: nil)
        #expect(weak.rows.first?.canStop == false)
        let strong = agent("a", child: nil, status: "running", origin: "provider_native",
                           extra: ",\"nativeTaskRef\":{\"strength\":\"strong\",\"nativeId\":\"task-1\"}")
        #expect(SubagentStrip.make(subagents: [strong], shells: [], latestTurn: ["run-2"], parent: nil).rows.first?.canStop == true)
        let done = SubagentStrip.make(subagents: [agent("a", child: nil, status: "completed")], shells: [], latestTurn: ["run-2"], parent: nil)
        #expect(done.rows.first?.canStop == false)
    }

    @Test func oneRowPerChildThreadNumberedByFirstAppearance() {
        // c1 got a second task (a follow-up turn); both say running, the later one wins and keeps number 1.
        let records = [agent("a", child: "c1", status: "completed", run: "run-1"), agent("b", child: "c2", status: "running"),
                       agent("c", child: "c1", status: "running"), agent("d", child: nil, status: "running")]
        let strip = SubagentStrip.make(subagents: records, shells: [child("c1"), child("c2")], latestTurn: ["run-2"], parent: nil)
        #expect(strip.rows.map(\.label) == ["Subagent 3", "Subagent 2", "Subagent 1"])
        #expect(strip.rows.map(\.id) == ["d", "b", "c"])
        #expect(strip.rows.map(\.key) == ["agent:d", "thread:c2", "thread:c1"])
        #expect(strip.activeCount == 3)
    }

    @Test func aLiveTaskOutranksALaterSettledOne() {
        let records = [agent("a", child: "c1", status: "running"), agent("b", child: "c1", status: "completed")]
        let strip = SubagentStrip.make(subagents: records, shells: [child("c1")], latestTurn: ["run-2"], parent: nil)
        #expect(strip.rows.map(\.id) == ["a"])
        #expect(strip.rows.first?.status == .running)
    }

    private func run(_ ordinal: Int, _ status: String, requested: String, started: String?, work: String? = nil) -> Run {
        func q(_ s: String?) -> String { s.map { "\"2026-10-23T\($0)Z\"" } ?? "null" }
        let json = """
            {"id":"run-\(ordinal)","threadId":"parent","ordinal":\(ordinal),"status":"\(status)","requestedAt":\(q(requested)),
             "startedAt":\(q(started)),"completedAt":null\(work.map { ",\"workStartedAt\":\(q($0))" } ?? "")}
            """
        return try! JSONDecoder().decode(Run.self, from: Data(json.utf8))
    }

    /// The v1.13.1 release check (sandbox thread 29cb962a): "Hi subagent" finished while "Sleep 90 subagent" ran, and T3
    /// queued a wake run for the parent and cancelled it before it started. That run was the newest, so Hi's done row
    /// dropped out of the strip.
    @Test func aCancelledWakeRunKeepsTheTurnsDoneRows() {
        let runs = [run(1, "running", requested: "21:41:53.763", started: "21:41:53.788"),
                    run(2, "cancelled", requested: "21:42:10.281", started: nil)]
        #expect(SubagentStrip.latestTurn(runs) == ["run-1"])
        let records = [agent("sleep", child: "c1", status: "running", run: "run-1"),
                       agent("hi", child: "c2", status: "completed", run: "run-1")]
        let strip = SubagentStrip.make(subagents: records, shells: [child("c1"), child("c2")],
                                       latestTurn: SubagentStrip.latestTurn(runs), parent: nil)
        #expect(strip.rows.map(\.id) == ["sleep", "hi"])
        #expect(strip.rows.map(\.status) == [.running, .done])
    }

    /// Sandbox thread 33d18fa7: Task A finished while Task B ran, and the wake run that answered it (ordinal 11) carried
    /// run 10's start as its work start. The next user turn (16) has no work start and leaves 10 and 11 behind.
    @Test func wakeRunsShareTheTurnAndANewUserTurnEndsIt() {
        var runs = [run(9, "completed", requested: "12:00:00.000", started: "12:00:00.010"),
                    run(10, "completed", requested: "12:11:12.079", started: "12:11:12.103"),
                    run(11, "completed", requested: "12:11:34.192", started: "12:11:34.202", work: "12:11:12.103")]
        #expect(SubagentStrip.latestTurn(runs) == ["run-10", "run-11"])
        let records = [agent("a", child: "c1", status: "completed", run: "run-10"),
                       agent("b", child: "c2", status: "running", run: "run-10"),
                       agent("old", child: "c3", status: "completed", run: "run-9")]
        let strip = SubagentStrip.make(subagents: records, shells: [child("c1"), child("c2"), child("c3")],
                                       latestTurn: SubagentStrip.latestTurn(runs), parent: nil)
        #expect(strip.rows.map(\.id) == ["b", "a"])
        runs.append(run(16, "running", requested: "12:14:33.765", started: "12:14:33.790"))
        #expect(SubagentStrip.latestTurn(runs) == ["run-16"])
        #expect(SubagentStrip.latestTurn([run(1, "queued", requested: "12:00:00.000", started: nil)]) == ["run-1"])
        #expect(SubagentStrip.latestTurn([]).isEmpty)
    }
}
