import Foundation
import Testing
import T3Protocol
@testable import T3Store

extension JSONValue {
    init<T: Encodable>(_ value: T) { self = try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
}

extension JSONValue: ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b })) }
}

/// The run list logic, from the cases of 5258 packages/client-runtime/src/workflows.test.ts.
@Suite struct WorkflowRunsTests {
    static func at(_ minute: Int, _ second: Int = 0) -> String { String(format: "2026-11-01T00:%02d:%02d.000Z", minute, second) }

    static func run(_ id: String, _ fields: [String: JSONValue] = [:]) -> WorkflowRun {
        var o: [String: JSONValue] = [
            "runId": .string(id), "workflow": .string("release"), "version": .number(1), "title": .string(id),
            "status": .string("running"), "detail": .null, "result": .null, "pauses": .number(0), "retired": .bool(false),
            "resumesAt": .null, "parentRunId": .null, "parentStep": .null, "startedAt": .string(at(0)),
            "updatedAt": .string(at(0)), "endedAt": .null,
        ]
        o.merge(fields) { _, new in new }
        return decode(.object(o))
    }

    static func question(_ runId: String, _ request: JSONValue = ["title": "Ship?"], kind: String? = nil) -> WorkflowQuestion {
        var o: [String: JSONValue] = ["runId": .string(runId), "name": "approve", "request": request, "askedAt": .string(at(1)), "thread": .null]
        if let kind { o["kind"] = .string(kind) }
        return decode(.object(o))
    }

    static func decode<T: Decodable>(_ v: JSONValue) -> T {
        try! JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }

    static let registered: [WorkflowSummary] = decode([
        ["name": "release", "version": 1, "triggers": ["webhook tags"]],
        ["name": "check", "version": 1, "triggers": []],
        ["name": "report", "version": 2, "triggers": ["daily at 09:00"]],
    ])

    @Test func whatWaitsOnAPersonComesFirstThenEachWorkflow() {
        let g = WorkflowRuns.group(Self.registered, [
            Self.run("done", ["status": "completed", "endedAt": .string(Self.at(9))]),
            Self.run("busy"),
            Self.run("parent", ["status": "waiting", "detail": "check"]),
            Self.run("child", ["workflow": "check", "status": "paused", "parentRunId": "parent", "parentStep": "check"]),
            Self.run("asks", ["workflow": "old", "status": "waiting", "detail": "approve"]),
            Self.run("orphan", ["workflow": "old", "status": "completed", "endedAt": .string(Self.at(8)), "parentRunId": "x"]),
        ], [Self.question("asks")])
        #expect(g.needsYou.map(\.run.runId) == ["parent", "asks"])
        #expect(g.needsYou[0].children.map(\.run.runId) == ["child"])
        let sections = g.workflows.map { "\($0.name)|\(WorkflowRuns.triggerLine($0))|\(($0.active + $0.finished).map(\.run.runId))" }
        #expect(sections == [
            "release|Starts on webhook tags|[\"busy\", \"done\"]",
            "old|No longer registered on this server|[\"orphan\"]",
            "check|Runs as part of other workflows|[]",
            "report|Starts on daily at 09:00|[]",
        ])
        #expect(WorkflowRuns.all(g).map(\.run.runId) == ["parent", "child", "asks", "busy", "done", "orphan"])
        #expect(WorkflowRuns.defaultRunId(g) == "child")
    }

    @Test func opensARunUnderWayElseTheNewest() {
        let quiet = WorkflowRuns.group(Self.registered, [
            Self.run("old", ["endedAt": .string(Self.at(2)), "updatedAt": .string(Self.at(2))]), Self.run("live", ["workflow": "report"]),
        ], [])
        #expect(WorkflowRuns.defaultRunId(quiet) == "live")
        let over = WorkflowRuns.group(Self.registered, [
            Self.run("first", ["endedAt": .string(Self.at(2)), "updatedAt": .string(Self.at(2))]),
            Self.run("last", ["workflow": "report", "endedAt": .string(Self.at(5)), "updatedAt": .string(Self.at(5))]),
        ], [])
        #expect(WorkflowRuns.defaultRunId(over) == "last")
        #expect(WorkflowRuns.defaultRunId(WorkflowRuns.group(Self.registered, [], [])) == nil)
    }

    @Test func aRunGetsTheThreadListsWordAndWhatItIsAt() {
        func told(_ f: [String: JSONValue], _ q: [WorkflowQuestion] = []) -> String {
            let n = WorkflowRuns.all(WorkflowRuns.group([], [Self.run("a", f)], q))[0]
            return "\(WorkflowRuns.state(n).word): \(WorkflowRuns.now(n))"
        }
        #expect(told(["status": "waiting", "detail": "agent review"]) == "Working: review is working")
        #expect(told(["status": "waiting", "detail": "sleep night"]) == "Sleeping: Sleeping at night")
        #expect(told(["status": "waiting", "detail": "queue gpu"]) == "Queued: Queued for gpu")
        #expect(told(["status": "waiting", "detail": "ci"]) == "Waiting: Waiting for ci")
        #expect(told(["status": "waiting", "detail": "approve"], [Self.question("a")]) == "Needs you: Asks: Ship?")
        #expect(told(["status": "paused", "detail": "build: exit 1\n  at build.ts"]) == "Paused: build: exit 1")
        #expect(told(["status": "completed", "endedAt": .string(Self.at(1)), "result": ["merged": "ba6ac73"]]) == "Done: merged: ba6ac73")
        #expect(told(["status": "cancelled", "endedAt": .string(Self.at(1)), "detail": "superseded"]) == "Cancelled: superseded")
    }

    @Test func aParentSaysWhatItsChildWaitsOn() {
        let g = WorkflowRuns.group([], [
            Self.run("child", ["parentRunId": "parent", "status": "waiting", "title": "Check web"]),
            Self.run("parent", ["status": "waiting", "detail": "check"]),
        ], [Self.question("child")])
        let parent = WorkflowRuns.all(g)[0]
        #expect(WorkflowRuns.state(parent).word == "Needs you")
        #expect(WorkflowRuns.now(parent) == "Check web: Asks: Ship?")
    }

    @Test func sortsRunsIntoTheThreeLists() {
        let g = WorkflowRuns.group([], [
            Self.run("old", ["status": "completed", "endedAt": .string(Self.at(1)), "updatedAt": .string(Self.at(1))]),
            Self.run("busy", ["updatedAt": .string(Self.at(2))]),
            Self.run("stuck", ["status": "paused", "updatedAt": .string(Self.at(3))]),
            Self.run("new", ["status": "completed", "endedAt": .string(Self.at(4)), "updatedAt": .string(Self.at(4))]),
        ], [])
        let l = WorkflowRuns.lists(g)
        #expect(l[.needsYou]!.map(\.run.runId) == ["stuck"])
        #expect(l[.running]!.map(\.run.runId) == ["busy"])
        #expect(l[.all]!.map(\.run.runId) == ["stuck", "busy", "new", "old"])
        #expect(WorkflowRuns.defaultTab(g) == .needsYou)
        #expect(WorkflowRuns.defaultTab(WorkflowRuns.group([], [Self.run("busy")], [])) == .running)
        #expect(WorkflowRuns.defaultTab(WorkflowRuns.group([], [Self.run("old", ["status": "completed", "endedAt": .string(Self.at(1))])], [])) == .all)
        let invoked = WorkflowRuns.lists(WorkflowRuns.group([], [Self.run("parent"), Self.run("child", ["workflow": "check", "parentRunId": "parent"]), Self.run("other")], []))[.all]!
        #expect(invoked.filter { WorkflowRuns.involves($0, "check") }.map(\.run.runId) == ["parent"])
    }

    @Test func countsOpenQuestionsByKind() {
        let registered: [WorkflowSummary] = Self.decode([[
            "name": "release", "version": 1, "triggers": [],
            "asks": [["kind": "feature", "label": "Feature wanted?"], ["kind": "intended", "label": "Bug or intended?"], ["kind": "partly", "label": "Partly fixed"]],
        ]])
        let needsYou = WorkflowRuns.lists(WorkflowRuns.group(registered, [
            Self.run("a", ["status": "waiting"]), Self.run("b", ["status": "waiting"]),
            Self.run("child", ["status": "waiting", "parentRunId": "b"]), Self.run("c", ["status": "waiting"]),
            Self.run("stuck", ["status": "paused"]),
        ], [
            Self.question("a", kind: "intended"), Self.question("a", kind: "feature"), Self.question("child", kind: "intended"),
            Self.question("b", kind: "retired"), Self.question("c"),
        ]))[.needsYou]!
        let kinds = WorkflowRuns.questionKinds([(registered, needsYou)])
        #expect(kinds == [.init(kind: "feature", label: "Feature wanted?", count: 1), .init(kind: "intended", label: "Bug or intended?", count: 2),
                          .init(kind: "", label: nil, count: 2)])
        func asking(_ k: String) -> [String] { needsYou.filter { WorkflowRuns.asksKind(registered, $0, k) }.map(\.run.runId).sorted() }
        #expect(asking("intended") == ["a", "b"])
        #expect(asking("feature") == ["a"])
        #expect(asking("") == ["b", "c"])
        #expect(asking("retired") == [])
        let plain: ([WorkflowSummary], [WorkflowRunNode]) = ([], WorkflowRuns.lists(WorkflowRuns.group([], [Self.run("c", ["status": "waiting"])], [Self.question("c")]))[.needsYou]!)
        #expect(WorkflowRuns.questionKinds([plain]) == [])
        let typed: ([WorkflowSummary], [WorkflowRunNode]) = (registered, WorkflowRuns.lists(WorkflowRuns.group(registered, [Self.run("a", ["status": "waiting"])], [Self.question("a", kind: "feature")]))[.needsYou]!)
        #expect(WorkflowRuns.questionKinds([typed, plain]) == [.init(kind: "feature", label: "Feature wanted?", count: 1), .init(kind: "", label: nil, count: 1)])
        #expect(WorkflowRuns.questionKinds([typed, plain], picked: "intended") == [
            .init(kind: "feature", label: "Feature wanted?", count: 1), .init(kind: "intended", label: "Bug or intended?", count: 0), .init(kind: "", label: nil, count: 1),
        ])
        #expect(WorkflowRuns.questionKinds([plain], picked: "intended") == [.init(kind: "intended", label: "intended", count: 0), .init(kind: "", label: nil, count: 1)])
        #expect(WorkflowRuns.questionKinds([typed], picked: "") == [.init(kind: "feature", label: "Feature wanted?", count: 1), .init(kind: "", label: nil, count: 0)])
    }

    @Test func leavesOutWhatAWorkflowSkipped() {
        let runs = [Self.run("ignored", ["status": "skipped", "endedAt": .string(Self.at(1))]), Self.run("parent"),
                    Self.run("child", ["status": "skipped", "endedAt": .string(Self.at(1)), "parentRunId": "parent"])]
        let hidden = WorkflowRuns.listed(runs, showSkipped: false)
        #expect(hidden.runs.map(\.runId) == ["parent", "child"] && hidden.skipped == 1)
        #expect(WorkflowRuns.listed(runs, showSkipped: true).runs.count == 3)
    }

    @Test func chipLettersAndToneAreStable() {
        #expect(WorkflowRuns.chip("nightly-report").letters == "NR")
        #expect(WorkflowRuns.chip("issue").letters == "IS")
        #expect(WorkflowRuns.chip("issue") == WorkflowRuns.chip("issue"))
        #expect(WorkflowRuns.chip("𠮷野-report").letters == "𠮷R")
        #expect(WorkflowRuns.chip("a𝒜b").letters == "A𝒜")
    }

    @Test func refreshKeyFollowsAnEndedRunOnly() {
        let ended = Self.run("old", ["endedAt": .string(Self.at(5)), "updatedAt": .string(Self.at(5))])
        let snapshot = WorkflowRunsSnapshot(runs: [ended, Self.run("busy", ["updatedAt": .string(Self.at(6))])])
        #expect(WorkflowRuns.refreshKey(snapshot, runId: "old") == Self.at(5))
        #expect(WorkflowRuns.refreshKey(snapshot, runId: "busy") == nil)
    }

    @Test func readsAQuestionsTitleChoicesBodyAndLinks() {
        let a = WorkflowRuns.read(Self.question("r", ["title": "Ship it?", "choices": ["yes", 2], "data": ["body": "Diff is small."]]))
        #expect(a == .init(title: "Ship it?", choices: [.init(value: "yes", description: nil, requireReason: false)], body: "Diff is small.", links: []))
        #expect(WorkflowRuns.read(Self.question("r", .null)) == .init(title: "approve", choices: [], body: nil, links: []))
        let b = WorkflowRuns.read(Self.question("r", [
            "title": "Build this?", "choices": ["Yes", "No"],
            "choiceDetails": [["value": "No", "description": "It is closed", "requireReason": true]],
            "links": [["label": "The request", "url": "https://example.com/1"], ["label": "Script", "url": "javascript:alert(1)"],
                      ["label": " ", "url": "https://example.com/2"]],
        ]))
        #expect(b.choices == [.init(value: "Yes", description: nil, requireReason: false), .init(value: "No", description: "It is closed", requireReason: true)])
        #expect(b.links == [.init(label: "The request", url: "https://example.com/1")])
    }

    @MainActor @Test func theStoreFoldsChangesAndStartsOverOnResubscribe() {
        let store = WorkflowRunsStore()
        var changes = 0
        store.onChange = { changes += 1 }
        store.apply(.snapshot(.init(runs: [Self.run("a")])))
        store.apply(Self.decode(["_tag": "changed", "runs": [JSONValue(Self.run("b", ["startedAt": .string(Self.at(2))]))], "removed": ["a"], "questions": [], "closed": []]))
        #expect(store.snapshot?.runs.map(\.runId) == ["b"] && changes == 2)
        store.subscribed()
        #expect(store.snapshot == nil)
    }
}
