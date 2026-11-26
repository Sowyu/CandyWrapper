import Foundation
import Testing
@testable import T3Protocol

/// Wire changes between nightly 4928 and 5258 (docs/research/nightly-diff-5258-wire.md).
struct Nightly5258WireTests {
    static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func decode<T: Decodable>(_ t: T.Type, _ s: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(s.utf8))
    }

    /// B1: clearing a bound thread sends `unbindThread` (ScheduledTasksSettings.tsx:1680), and nothing else does.
    @Test func clearingTheThreadSendsUnbind() throws {
        let list = Self.json(#"{"tasks":[{"id":"st1","title":"T","prompt":"P","enabled":true,"schedule":{"type":"interval","everyMs":900000},"projectId":"p1","threadId":"t1"}]}"#)
        let task = try #require(ScheduledTask.list(list).first)
        let draft = ScheduledTaskLogic.draft(task)
        #expect(draft.savedThreadId == "t1")
        func send(_ d: ScheduledTaskDraft) throws -> JSONValue {
            try ScheduledTaskLogic.upsertInput(d, projectId: "p1", projectExists: true, selection: ("c", "m"), storedSecret: false).get()
        }
        let kept = try send(draft)
        #expect(kept["threadId"] == .string("t1") && kept["unbindThread"] == nil)
        let cleared = try send(ScheduledTaskLogic.unbind(draft))
        #expect(cleared["threadId"] == .null && cleared["unbindThread"] == .bool(true))
        var fresh = ScheduledTaskDraft()
        fresh.title = "T"; fresh.prompt = "P"; fresh.projectId = "p1"
        #expect(try send(fresh)["unbindThread"] == nil)
    }

    /// B2: workflow agent steps stay out of thread lists (orchestrationV2.ts:195, 203-207), and `workflowRun`
    /// decodes on the shell and the full thread (:165-174, :521, :2436).
    @Test func workflowStepsAreNotListed() throws {
        let step = try Self.decode(ThreadLineage.self, #"{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"t1","workflowStep":true}"#)
        #expect(step.workflowStep == true && !step.isListedLineage)
        let plain = try Self.decode(ThreadLineage.self, #"{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"t1"}"#)
        #expect(plain.workflowStep == nil && plain.isListedLineage)
        let origin = #"{"environmentId":"e1","runId":"wr1","workflow":"release","step":"build"}"#
        let thread = try Self.decode(AppThread.self, #"{"id":"t1","title":"T","lineage":{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"t1","workflowStep":true},"workflowRun":\#(origin)}"#)
        #expect(thread.workflowRun == WorkflowOrigin(environmentId: "e1", runId: "wr1", workflow: "release", step: "build"))
        #expect(thread.lineage?.isListedLineage == false)
    }
}
