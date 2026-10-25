import Foundation
import T3Protocol
import Testing
@testable import T3Store

// The relay to every machine (docs/orchestrator.md, "Every machine"): calls go to the machine they name, and the
// limits hold there too.

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(_ minutes: Double) -> T3Timestamp { T3Timestamp(now.addingTimeInterval(-minutes * 60)) }

/// Two machines: "mini", where the Orchestrator runs, and "book", another Mac.
@MainActor
private final class FakeMachines {
    var config = OrchestratorConfig()
    var snapshots: [String: ShellSnapshot] = [:]
    var connected: Set<String> = ["mini", "book"]
    var labels = ["mini": "miniko", "book": "MacBook"]
    /// Every request, in order: the machine, the method and the payload.
    var requests: [(machine: String, method: String, payload: JSONValue)] = []
    var projection = #"{"thread":{"id":"w1","title":"Worker","projectId":"p2","lineage":{"rootThreadId":"w1","parentThreadId":null,"relationshipToParent":null}},"runs":[],"attempts":[],"nodes":[],"subagents":[],"providerSessions":[],"providerThreads":[],"providerTurns":[],"runtimeRequests":[],"messages":[{"id":"m1","threadId":"w1","role":"user","text":"Fix the test","streaming":false,"createdAt":"2027-01-15T08:00:00.000Z","updatedAt":"2027-01-15T08:00:00.000Z"},{"id":"m2","threadId":"w1","role":"assistant","text":"STATUS done","streaming":false,"createdAt":"2027-01-15T08:01:00.000Z","updatedAt":"2027-01-15T08:01:00.000Z"}],"plans":[],"turnItems":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],"contextTransfers":[],"visibleTurnItems":[],"updatedAt":"2027-01-15T08:01:00.000Z"}"#

    init() {
        config.machines["mini"] = OrchestratorMachine(threadId: "orch", briefDigest: "")
        config.models = [OrchestratorModelRow(id: "e", label: "Everyday work", instanceId: "claudeAgent", model: "claude-haiku-5-5", isDefault: true)]
        snapshots["mini"] = ShellSnapshot(schemaVersion: 1, snapshotSequence: 1,
                                          threads: [thread("orch") { $0.title = "Orchestrator" }, thread("a1") { $0.title = "Mini thread"; $0.projectId = "p1" }],
                                          projects: [project("p1") { $0.title = "CandyWrapper" }])
        snapshots["book"] = ShellSnapshot(schemaVersion: 1, snapshotSequence: 1,
                                          threads: [thread("w1") { $0.title = "Book thread"; $0.projectId = "p2" }],
                                          projects: [project("p2") { $0.title = "Website" }])
    }

    func edit(_ machine: String, _ id: String, _ change: (inout ThreadShell) -> Void) {
        guard var s = snapshots[machine], let i = s.threads.firstIndex(where: { $0.id.rawValue == id }) else { return }
        change(&s.threads[i])
        snapshots[machine] = s
    }

    var relay: OrchestratorRelay {
        OrchestratorRelay(host: OrchestratorRelayHost(
            machines: { [unowned self] in
                [OrchestratorMachineRef(id: "mini", label: labels["mini"]!, isHome: true, connected: connected.contains("mini")),
                 OrchestratorMachineRef(id: "book", label: labels["book"]!, isHome: false, connected: connected.contains("book"))]
            },
            snapshot: { [unowned self] in snapshots[$0] },
            request: { [unowned self] machine, method, payload in
                requests.append((machine, method, payload))
                if method == "orchestration.getThreadProjection" { return try JSONDecoder().decode(JSONValue.self, from: Data(projection.utf8)) }
                return .object(["sequence": .number(2)])
            },
            config: { [unowned self] in config },
            update: { [unowned self] change in change(&config) },
            rows: { [unowned self] _ in config.models },
            runtimeMode: { _ in "full-access" },
            message: { id, text, _, queue in .object(["type": .string("message.dispatch"), "threadId": .string(id), "text": .string(text), "queue": .bool(queue)]) },
            launch: { id, project, title, text, selection, _, workspace in
                .object(["threadId": .string(id), "projectId": .string(project), "title": .string(title), "text": .string(text),
                         "model": .string(selection.model), "workspaceStrategy": workspace])
            },
            orchestrator: { ThreadId("orch").scoped(to: "mini") },
            now: { now }))
    }

    func run(_ line: String) async -> String { await relay.run(OrchestratorCall.parse(line)) ?? "" }
}

@Suite struct OrchestratorCallParsingTests {
    @Test func oneCallPerLineAndTheBlockLeavesTheProse() {
        let reply = OrchestratorReply.parse("""
        Checking the other machines.

        ```orchestrator-call
        {"tool":"list"}
        {"tool":"read","machine":"book","threadId":"w1","last":3}
        not json
        ```
        """)
        #expect(reply.text == "Checking the other machines.")
        #expect(reply.calls.map(\.tool) == [.list, .read, nil])
        #expect(reply.calls[1].machine == "book" && reply.calls[1].threadId == "w1" && reply.calls[1].last == 3)
        #expect(reply.calls[2].raw == "not json")
    }

    @Test func aPrettyPrintedObjectOrArrayAndT3ToolNamesParse() {
        let object = OrchestratorCall.parse("{\n  \"tool\": \"send\",\n  \"machine\": \"book\",\n  \"threadId\": \"w1\",\n  \"text\": \"go\",\n  \"confirmed\": true\n}")
        #expect(object == [OrchestratorCall(tool: .send, raw: object.first?.raw ?? "", machine: "book", threadId: "w1", text: "go", confirmed: true)])
        let array = OrchestratorCall.parse(#"[{"tool":"thread_list"},{"tool":"archive","machine":"book","threadId":"w1"}]"#)
        #expect(array.map(\.tool) == [.list, .archive])
    }

    @Test func machinesResolveByIdOrLabel() {
        let machines = [OrchestratorMachineRef(id: "env-1", label: "MacBook", isHome: false),
                        OrchestratorMachineRef(id: "env-2", label: "mini", isHome: true),
                        OrchestratorMachineRef(id: "env-3", label: "Mini", isHome: false)]
        #expect(OrchestratorMachineRef.resolve("env-1", in: machines)?.id == "env-1")
        #expect(OrchestratorMachineRef.resolve("macbook", in: machines)?.id == "env-1")
        // Two machines share the label, so only the id names one.
        #expect(OrchestratorMachineRef.resolve("mini", in: machines) == nil)
        #expect(OrchestratorMachineRef.resolve("env-3", in: machines)?.label == "Mini")
    }
}

@MainActor
@Suite struct OrchestratorRelayRoutingTests {
    @Test func listShowsEveryMachineLabelledAndSkipsTheOrchestrator() async {
        let fake = FakeMachines()
        let result = await fake.run(#"{"tool":"list"}"#)
        #expect(result.hasPrefix("Result: listed 2 threads on 2 machines"))
        #expect(result.contains("## miniko (machine mini), where you run"))
        #expect(result.contains("## MacBook (machine book)"))
        #expect(result.contains("“Mini thread” (threadId a1, project CandyWrapper)"))
        #expect(result.contains("“Book thread” (threadId w1, project Website)"))
        #expect(result.contains("Website (projectId p2)"))
        #expect(!result.contains("“Orchestrator”"))
        #expect(fake.requests.isEmpty)
        let one = await fake.run(#"{"tool":"list","machine":"MacBook"}"#)
        #expect(one.contains("MacBook") && !one.contains("miniko"))
    }

    @Test func readGoesToTheNamedMachine() async {
        let fake = FakeMachines()
        let result = await fake.run(#"{"tool":"read","machine":"MacBook","threadId":"w1","last":1}"#)
        #expect(fake.requests.map(\.machine) == ["book"])
        #expect(fake.requests.first?.method == "orchestration.getThreadProjection")
        #expect(fake.requests.first?.payload["threadId"]?.stringValue == "w1")
        #expect(result.hasPrefix("Result: read “Book thread” on MacBook"))
        #expect(result.contains("[assistant] STATUS done") && !result.contains("Fix the test"))
    }

    @Test func sendGoesToTheNamedMachineAndQueuesBehindARunningTurn() async {
        let fake = FakeMachines()
        #expect(await fake.run(#"{"tool":"send","machine":"book","threadId":"w1","text":"Next step"}"#) == "Result: sent to “Book thread” on MacBook")
        #expect(fake.requests.map(\.machine) == ["book"])
        #expect(fake.requests[0].method == "orchestration.dispatchCommand")
        #expect(fake.requests[0].payload["threadId"]?.stringValue == "w1" && fake.requests[0].payload["text"]?.stringValue == "Next step")
        #expect(fake.requests[0].payload["queue"] == .bool(false))
        fake.edit("book", "w1") { $0.status = .running }
        #expect(await fake.run(#"{"tool":"send","machine":"book","threadId":"w1","text":"Then this"}"#).contains("queued"))
        #expect(fake.requests[1].payload["queue"] == .bool(true))
    }

    @Test func aThreadOnAnotherMachineNeedsItsMachine() async {
        let fake = FakeMachines()
        let missing = await fake.run(#"{"tool":"send","threadId":"w1","text":"x"}"#)
        #expect(missing.contains("needs a \"machine\"") && missing.contains("on MacBook (machine book)"))
        // The thread lives on the MacBook, so miniko doesn't have it.
        #expect(await fake.run(#"{"tool":"read","machine":"mini","threadId":"w1"}"#).contains("there is no thread w1 on miniko"))
        #expect(await fake.run(#"{"tool":"read","machine":"studio","threadId":"w1"}"#).contains("no machine “studio”"))
        fake.connected.remove("book")
        #expect(await fake.run(#"{"tool":"read","machine":"book","threadId":"w1"}"#).contains("MacBook isn't connected"))
        #expect(fake.requests.isEmpty)
    }

    @Test func launchGoesToTheNamedMachineWithTheModelsRowAndWorktree() async {
        let fake = FakeMachines()
        let result = await fake.run(#"{"tool":"launch","machine":"book","projectId":"p2","title":"Fixer","text":"Fix it","model":"everyday work","worktree":"main"}"#)
        #expect(result.hasPrefix("Result: launched “Fixer” on MacBook (machine book, threadId "))
        #expect(fake.requests.map(\.machine) == ["book"] && fake.requests[0].method == "orchestration.launchThread")
        let p = fake.requests[0].payload
        #expect(p["projectId"]?.stringValue == "p2" && p["title"]?.stringValue == "Fixer" && p["model"]?.stringValue == "claude-haiku-5-5")
        #expect(p["workspaceStrategy"] == .object(["type": .string("worktree"), "baseRef": .string("main")]))
        let id = try! #require(p["threadId"]?.stringValue)
        #expect(fake.config.relayWorkers == [ThreadId(id).scoped(to: "book").rawValue])
        #expect(await fake.run(#"{"tool":"launch","machine":"book","projectId":"p1","text":"x"}"#).contains("needs a \"projectId\" from MacBook: Website (projectId p2)"))
        #expect(await fake.run(#"{"tool":"launch","machine":"book","projectId":"p2","text":"x","model":"Huge"}"#).contains("no Models row “Huge”"))
    }

    @Test func archiveGoesToTheNamedMachine() async {
        let fake = FakeMachines()
        #expect(await fake.run(#"{"tool":"archive","machine":"book","threadId":"w1"}"#) == "Result: archived “Book thread” on MacBook")
        #expect(fake.requests.map(\.machine) == ["book"] && fake.requests[0].payload["type"]?.stringValue == "thread.archive")
    }

    @Test func eachCallGetsItsOwnResultAndTenAtMostRun() async {
        let fake = FakeMachines()
        let lines = Array(repeating: #"{"tool":"list","machine":"book"}"#, count: 12).joined(separator: "\n")
        let result = await fake.relay.run(OrchestratorCall.parse(lines)) ?? ""
        #expect(OrchestratorRelay.summaries(result).count == 11)
        #expect(result.contains("skipped 2 more calls"))
        #expect(OrchestratorRelay.isResultMessage(result))
    }
}

@MainActor
@Suite struct OrchestratorRelayNamingTests {
    @Test func sharedLabelsGetTheirMachineIdAndListFindsByTitle() async {
        let fake = FakeMachines()
        fake.labels = ["mini": "miniko", "book": "miniko"]
        // A label two machines share names neither, so the id has to.
        #expect(await fake.run(#"{"tool":"read","machine":"miniko","threadId":"w1"}"#).contains("no machine “miniko”"))
        let missing = await fake.run(#"{"tool":"read","machine":"mini","threadId":"w1"}"#)
        #expect(missing.contains("there is no thread w1 on miniko (machine mini)"))
        #expect(await fake.run(#"{"tool":"send","machine":"book","threadId":"w1","text":"x"}"#) == "Result: sent to “Book thread” on miniko (machine book)")
        let found = await fake.run(#"{"tool":"list","title":"book"}"#)
        #expect(found.hasPrefix("Result: listed 1 thread on 2 machines") && found.contains("“Book thread”") && !found.contains("“Mini thread”"))
    }
}

@MainActor
@Suite struct OrchestratorRelayLimitTests {
    @Test func handsOffIsNeverPromptedOrArchived() async {
        let fake = FakeMachines()
        fake.config.handsOff = [ThreadId("w1").scoped(to: "book").rawValue]
        #expect(await fake.run(#"{"tool":"send","machine":"book","threadId":"w1","text":"x","confirmed":true}"#).contains("is kept out"))
        #expect(await fake.run(#"{"tool":"archive","machine":"book","threadId":"w1"}"#).contains("is kept out"))
        #expect(fake.requests.isEmpty)
        #expect(await fake.run(#"{"tool":"list"}"#).contains("Kept out: report only, never prompt it"))
    }

    @Test func askFirstRefusesUntilConfirmed() async {
        let fake = FakeMachines()
        fake.edit("book", "w1") { $0.latestUserAuthoredMessageAt = ago(3); $0.latestUserMessageAt = ago(3) }
        let refused = await fake.run(#"{"tool":"send","machine":"book","threadId":"w1","text":"x"}"#)
        #expect(refused.contains("the user wrote in “Book thread” on MacBook 3 min ago. Ask the user first"))
        #expect(fake.requests.isEmpty)
        #expect(await fake.run(#"{"tool":"send","machine":"book","threadId":"w1","text":"x","confirmed":true}"#).hasPrefix("Result: sent"))
        #expect(fake.requests.count == 1)
    }

    @Test func aRelayedPromptDoesNotStartTheAskFirstWindow() async {
        let fake = FakeMachines()
        #expect(await fake.run(#"{"tool":"send","machine":"book","threadId":"w1","text":"x"}"#).hasPrefix("Result: sent"))
        // The server records the relayed prompt as the user's, a moment after the relay noted it.
        fake.edit("book", "w1") { $0.latestUserAuthoredMessageAt = T3Timestamp(now.addingTimeInterval(1)); $0.latestUserMessageAt = T3Timestamp(now.addingTimeInterval(1)) }
        #expect(await fake.run(#"{"tool":"send","machine":"book","threadId":"w1","text":"y"}"#).hasPrefix("Result: sent"))
        // You writing there later still asks first.
        fake.edit("book", "w1") { $0.latestUserAuthoredMessageAt = T3Timestamp(now.addingTimeInterval(60)); $0.latestUserMessageAt = T3Timestamp(now.addingTimeInterval(60)) }
        #expect(await fake.run(#"{"tool":"send","machine":"book","threadId":"w1","text":"z"}"#).contains("Ask the user first"))
    }

    @Test func launchStopsAtTheWorkerLimitAcrossMachines() async {
        let fake = FakeMachines()
        fake.config.crewLimit = 2
        // One child of the Orchestrator on miniko and one relayed worker on the MacBook are running.
        fake.edit("mini", "a1") { $0.status = .running; $0.lineage.parentThreadId = ThreadId("orch") }
        fake.edit("book", "w1") { $0.status = .running }
        fake.config.relayWorkers = [ThreadId("w1").scoped(to: "book").rawValue]
        let refused = await fake.run(#"{"tool":"launch","machine":"book","projectId":"p2","text":"x"}"#)
        #expect(refused.contains("2 workers are running and the limit is 2"))
        #expect(fake.requests.isEmpty)
        fake.edit("book", "w1") { $0.status = .completed }
        #expect(await fake.run(#"{"tool":"launch","machine":"book","projectId":"p2","text":"x"}"#).hasPrefix("Result: launched"))
    }
}

@Suite struct OrchestratorEveryMachineBriefTests {
    private func inputs(_ machines: [OrchestratorMachineRef]) -> OrchestratorBrief.Inputs {
        OrchestratorBrief.Inputs(name: "Orchestrator", machine: "miniko", projects: [], crewLimit: 4, models: [], notebook: .init(),
                                 handsOff: [], askFirstMinutes: 10, machines: machines)
    }

    @Test func theBriefListsEveryMachineAndHowToReachIt() {
        let machines = [OrchestratorMachineRef(id: "mini", label: "miniko", isHome: true),
                        OrchestratorMachineRef(id: "book", label: "MacBook", isHome: false, connected: false)]
        let brief = OrchestratorBrief.render("You are {{name}}.", inputs(machines))
        #expect(brief.contains("- miniko (machine mini): you run here"))
        #expect(brief.contains("- MacBook (machine book), offline right now"))
        #expect(brief.contains("orchestrator-call"))
        #expect(brief.contains("once 4 workers run across all machines"))
        // One machine needs no relay.
        #expect(!OrchestratorBrief.render("x", inputs([machines[0]])).contains("orchestrator-call"))
    }

    @Test func aMachineGoingOfflineSendsNoUpdatedBrief() {
        let on = [OrchestratorMachineRef(id: "mini", label: "miniko", isHome: true), OrchestratorMachineRef(id: "book", label: "MacBook", isHome: false)]
        var off = on
        off[1].connected = false
        #expect(OrchestratorBrief.fingerprint("x", inputs(on)) == OrchestratorBrief.fingerprint("x", inputs(off)))
        #expect(OrchestratorBrief.fingerprint("x", inputs(on)) != OrchestratorBrief.fingerprint("x", inputs([on[0]])))
    }

    @Test func eventsFromAnotherMachineNameIt() {
        let e = OrchestratorEvent(threadId: ThreadId("w1").scoped(to: "book"), title: "Book thread", kind: .finished, permission: .free, machine: "MacBook")
        #expect(e.line == "Event: “Book thread” on MacBook (machine book) finished a turn (t3-thread://v1/w1).")
        let old = [ThreadId("w1"): thread("w1") { $0.status = .running }]
        let events = OrchestratorEvent.diff(old: old, new: [thread("w1") { $0.status = .completed }], orchestrator: ThreadId("orch"),
                                            handsOff: { _ in false }, windowMinutes: 10, now: now, machine: "MacBook")
        #expect(events.map(\.machine) == ["MacBook"])
    }
}
