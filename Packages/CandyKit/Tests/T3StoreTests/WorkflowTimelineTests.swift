import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// The run's timeline, from the cases of 5258 packages/client-runtime/src/workflows.test.ts:394-735.
@Suite struct WorkflowTimelineTests {
    static func at(_ m: Int) -> String { WorkflowRunsTests.at(m) }

    static func step(_ name: String, _ kind: String, _ start: String, _ end: String?, status: String? = nil, detail: String? = nil) -> WorkflowStep {
        WorkflowRunsTests.decode(.object([
            "name": .string(name), "kind": .string(kind), "status": .string(status ?? (end == nil ? "running" : "completed")),
            "attempts": .number(1), "detail": detail.map(JSONValue.string) ?? .null, "threadId": .null, "environmentId": .null,
            "result": .null, "said": .null, "startedAt": .string(start), "endedAt": end.map(JSONValue.string) ?? .null,
        ]))
    }

    static func names(_ rows: [WorkflowFeedRow]) -> [String] {
        rows.map {
            switch $0 {
            case .quick(let steps, _, _): "quick:" + steps.map(\.name).joined(separator: ",")
            case .beat(let b): "\(b.kind):\(b.name)\(b.parallel ? ":parallel" : "")"
            case .together(let bs): bs.map(\.name).joined(separator: "+")
            }
        }
    }

    @Test func keepsTheBeatsAndFoldsTheBookkeeping() {
        let parent = WorkflowRunsTests.run("r", ["startedAt": .string(Self.at(0)), "endedAt": .string(Self.at(10))])
        let child = WorkflowRunsTests.run("c", ["parentRunId": "r", "parentStep": "check", "title": "Check web"])
        let rows = WorkflowTimeline.rows(run: parent, steps: [
            Self.step("load", "step", Self.at(0), Self.at(0)), Self.step("switch", "step", Self.at(0), Self.at(0)),
            Self.step("triage", "agent", Self.at(0), Self.at(3)),
            Self.step("review-a", "agent", Self.at(3), Self.at(5)), Self.step("review-b", "agent", Self.at(3), Self.at(6)),
            Self.step("record", "step", Self.at(6), Self.at(6)), Self.step("check/start", "step", Self.at(6), Self.at(6)),
            Self.step("check", "wait", Self.at(6), Self.at(8)), Self.step("build", "step", Self.at(8), Self.at(9)),
            Self.step("publish", "step", Self.at(9), Self.at(9), status: "failed", detail: "503"),
        ], children: [child], nowMs: WorkflowTimeline.ms(Self.at(10)))
        #expect(Self.names(rows) == ["quick:load,switch", "agent:triage", "agent:review-a:parallel", "agent:review-b:parallel",
                                     "quick:record", "run:check", "step:build", "step:publish"])
        let feed = WorkflowTimeline.feed(rows)
        #expect(Self.names(feed) == ["quick:load,switch", "agent:triage", "review-a+review-b", "quick:record", "run:check",
                                     "step:build", "step:publish"])
        #expect(WorkflowTimeline.focus(feed, status: "waiting", ended: false, questions: ["approve"]) == "question:approve")
        #expect(WorkflowTimeline.focus(feed, status: "paused", ended: false, questions: []) == "step:publish")
        #expect(WorkflowTimeline.focus(feed, status: "completed", ended: true, questions: []) == "end")
        #expect(WorkflowTimeline.pausedBeat(feed, status: "paused")?.name == "publish")
        let caught = WorkflowTimeline.feed(WorkflowTimeline.rows(run: WorkflowRunsTests.run("r"), steps: [
            Self.step("lint", "agent", Self.at(0), Self.at(2), status: "failed", detail: "timed out"), Self.step("build", "agent", Self.at(2), Self.at(4)),
        ], children: [], nowMs: WorkflowTimeline.ms(Self.at(10))))
        #expect(WorkflowTimeline.pausedBeat(caught, status: "paused") == nil)
        #expect(WorkflowTimeline.focus(caught, status: "paused", ended: false, questions: []) == "pause")
    }

    @Test func measuresAStepUnderWayUpToNowAndNeverRunsBackwards() {
        let rows = WorkflowTimeline.rows(run: WorkflowRunsTests.run("r"), steps: [Self.step("fix", "agent", Self.at(1), nil)], children: [],
                                         nowMs: WorkflowTimeline.ms(Self.at(4)))
        guard case .beat(let fix) = rows[0] else { Issue.record("no beat"); return }
        #expect(fix.endMs - fix.startMs == 180_000)
        let wide = WorkflowTimeline.rows(run: WorkflowRunsTests.run("r", ["startedAt": .string(Self.at(1))]),
                                         steps: [Self.step("a", "sleep", Self.at(1), Self.at(2))] + ["b", "c", "d", "e", "f"].map { Self.step($0, "sleep", Self.at(1), nil) },
                                         children: [], nowMs: WorkflowTimeline.ms(Self.at(0)))
        #expect(Self.names(WorkflowTimeline.feed(wide)).count == 1)
    }

    @Test func wordsReadAsT3Says() {
        #expect([9, 342, 9_700, 9_949, 9_950, 4_000, 12_400, 59_499, 59_500].map { WorkflowTimeline.stepTime(Double($0)) }
                == ["0.1s", "0.3s", "9.7s", "9.9s", "10s", "4s", "12s", "59s", "1m 0s"])
        #expect(WorkflowTimeline.oneLine("## Done\n\nI added `clamp` next to **sum**. Tests pass.") == "I added clamp next to sum.")
        #expect(WorkflowTimeline.oneLine("- See [the issue](https://x.test/2) first") == "See the issue first")
        let said = "It is a real bug.\n\n**Where:** line 5.\n\n**Reproduced:** yes, with 3660 seconds."
        #expect(WorkflowTimeline.saidStart(said, limit: 200) == nil)
        #expect(WorkflowTimeline.saidStart(said, limit: 40) == "It is a real bug.\n\n**Where:** line 5.")
        #expect(WorkflowTimeline.saidStart(said, limit: 10) == "It is a real bug.")
        #expect(WorkflowTimeline.saidStart(String(repeating: "这个问题出现在解析器中。", count: 60), limit: 10) == "这个问题出现在解析器…")
        #expect(WorkflowTimeline.saidStart(String(repeating: "😀", count: 30), limit: 9) == String(repeating: "😀", count: 4) + "…")
        let s = WorkflowTimeline.agentSummary(result: .object(["kind": "bug", "reproduced": .bool(true), "surfaces": .array(["web", "desktop"]), "prUrl": .null]),
                                              said: "Reproduced on main.")
        #expect(s.said == "Reproduced on main." && s.facts.map { "\($0.label)=\($0.value)" } == ["kind=bug", "reproduced=yes", "surfaces=web, desktop"])
    }
}
