import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// The Workflows page's list rules (5258 WorkflowRunsView.tsx:182-336) and the feed's words (WorkflowRunFeed.tsx).
@Suite struct WorkflowsPageLogicTests {
    static func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }

    static func run(_ id: String, status: String = "running", workflow: String = "release", parent: String? = nil, ended: Bool = false, updated: Int = 0) -> String {
        """
        {"runId":"\(id)","workflow":"\(workflow)","version":1,"title":"\(id)","status":"\(status)","detail":null,"result":null,"pauses":0,
        "retired":false,"resumesAt":null,"parentRunId":\(parent.map { "\"\($0)\"" } ?? "null"),"parentStep":null,
        "startedAt":"2026-11-01T00:00:00.000Z","updatedAt":"2026-11-01T00:0\(updated):00.000Z","endedAt":\(ended ? "\"2026-11-01T00:09:00.000Z\"" : "null")}
        """
    }

    static func question(_ runId: String, kind: String? = nil) -> String {
        #"{"runId":"\#(runId)","name":"approve","request":{"title":"Ship?","choices":["Yes","No"]},"askedAt":"2026-11-01T00:01:00.000Z","thread":null\#(kind.map { #","kind":"\#($0)""# } ?? "")}"#
    }

    static let snapshot: WorkflowRunsSnapshot = decode("""
    {"workflows":[{"name":"release","version":1,"triggers":[],"asks":[{"kind":"bug","label":"Bug?"}]}],
     "runs":[\(run("asks", status: "waiting", updated: 3)),\(run("other", status: "waiting", updated: 2)),\(run("busy", updated: 1)),\(run("done", status: "completed", ended: true))],
     "questions":[\(question("asks", kind: "bug")),\(question("other"))]}
    """)

    @Test func opensOnWhatWaitsOnYouAndTheFirstRunToActOn() {
        let l = WorkflowsPageLogic.listing(Self.snapshot, selectedRunId: nil, pickedTab: nil, workflow: "", pickedKind: WorkflowRuns.everyKind, showSkipped: false)
        #expect(l.tab == .needsYou)
        #expect(l.rows.map(\.run.runId) == ["asks", "other"])
        #expect(l.shown?.run.runId == "asks")
        #expect(WorkflowsPageLogic.kindsLine(l.kinds) == "Bug? 1 · Other 1")
    }

    @Test func aRunOpenedByItsLinkIsShownInAListThatHasIt() {
        let l = WorkflowsPageLogic.listing(Self.snapshot, selectedRunId: "done", pickedTab: nil, workflow: "", pickedKind: WorkflowRuns.everyKind, showSkipped: false)
        #expect(l.tab == .all && l.currentRunId == "done")
        let missing = WorkflowsPageLogic.listing(Self.snapshot, selectedRunId: "gone", pickedTab: nil, workflow: "", pickedKind: WorkflowRuns.everyKind, showSkipped: false)
        #expect(missing.notHere && missing.shown == nil)
    }

    @Test func aPickedKindNarrowsTheListAndKeepsTheOpenRun() {
        let l = WorkflowsPageLogic.listing(Self.snapshot, selectedRunId: nil, pickedTab: .needsYou, workflow: "", pickedKind: "bug", showSkipped: false)
        #expect(l.rows.map(\.run.runId) == ["asks"])
        let open = WorkflowsPageLogic.listing(Self.snapshot, selectedRunId: "other", pickedTab: .needsYou, workflow: "", pickedKind: "bug", showSkipped: false)
        #expect(open.rows.map(\.run.runId) == ["asks", "other"])
        // The kind stays listed at zero once its last question is answered.
        let answered: WorkflowRunsSnapshot = Self.decode("""
        {"workflows":[{"name":"release","version":1,"triggers":[],"asks":[{"kind":"bug","label":"Bug?"}]}],"runs":[\(Self.run("other", status: "waiting"))],"questions":[\(Self.question("other"))]}
        """)
        let held = WorkflowsPageLogic.listing(answered, selectedRunId: nil, pickedTab: .needsYou, workflow: "", pickedKind: "bug", showSkipped: false)
        #expect(held.rows.isEmpty && held.nothing == "No questions of this kind wait on you.")
        #expect(held.kinds.first.map { "\($0.kind) \($0.label ?? "") \($0.count)" } == "bug Bug? 0")
    }

    @Test func answersAndWithdrawalsReadAsT3Says() {
        let a: JSONValue = .object(["choice": .string("Yes"), "answeredBy": .string("Chrome on Linux")])
        let read = WorkflowsPageLogic.answer(a)!
        #expect(WorkflowsPageLogic.saidLine(who: read.answeredBy, choice: read.choice, reason: read.reason) == "Chrome on Linux said Yes.")
        #expect(WorkflowsPageLogic.saidLine(who: nil, choice: "No", reason: "closed") == "You said No: closed")
        let w = WorkflowsPageLogic.withdrawal(.object(["withdrawn": .object(["by": .string("triage"), "reason": .string(" ")])]))
        #expect(w?.by == "triage" && w?.reason == nil)
        #expect(WorkflowsPageLogic.answer(.object(["withdrawn": .object(["by": .string("x")])])) == nil)
    }

    @Test func aQueuedStepSaysHowManyAreAhead() {
        let step: WorkflowStep = Self.decode(#"{"name":"build","kind":"queue","status":"running","attempts":1,"detail":null,"threadId":null,"environmentId":null,"result":null,"said":null,"ahead":2,"startedAt":"2026-11-01T00:00:00.000Z","endedAt":null}"#)
        let now = T3Timestamp.parseEpochMs("2026-11-01T00:00:12.000Z")!
        #expect(WorkflowsPageLogic.stepLine(step, nowMs: now) == "queued, 2 ahead · 12s")
    }
}
