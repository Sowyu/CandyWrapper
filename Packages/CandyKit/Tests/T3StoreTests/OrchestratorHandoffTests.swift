import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The handoff between this Mac and CandyWrapper on Android, through the "while closed" task: whoever wrote it last
/// decides who relays. Events the Mac gathers while it doesn't hold the task are dropped, and calls a "Result:" answers
/// never run twice.
@Suite struct OrchestratorHandoffTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func task(enabled: Bool, stamp: String) -> ScheduledTask {
        ScheduledTask(id: "check", title: "Orchestrator check", prompt: OrchestratorBrief.scheduledCheckPrompt, enabled: enabled,
                      schedule: .interval(everyMs: 1_800_000), projectId: "p", threadId: "orch", updatedAt: stamp)
    }

    func message(_ id: String, _ role: String, _ text: String, minutes: Double, run: String? = "run-1") -> ConversationMessage {
        var json: [String: Any] = ["id": id, "threadId": "orch", "role": role, "text": text, "streaming": false,
                                   "createdAt": T3Timestamp(start.addingTimeInterval(minutes * 60)).raw,
                                   "updatedAt": T3Timestamp(start.addingTimeInterval(minutes * 60)).raw]
        if let run { json["runId"] = run }
        return try! JSONDecoder().decode(ConversationMessage.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The phone relays (it turned the task off itself), then the Mac opens: the Mac relays nothing until its own write
    /// is what the server has, so an event the phone already sent never goes out twice.
    @Test func macOpeningWhilePhoneRelaysSendsNothingTwice() {
        var mac = OrchestratorHandoff()
        let phoneHolds = task(enabled: false, stamp: "2026-10-24T10:00:00.000Z")
        // Just opened: it hasn't written yet, so it doesn't relay; it writes the task off first.
        #expect(mac.verdict(task: phoneHolds) == .resync)
        // The batch it gathered before then is dropped, so the phone's event isn't sent again.
        var batch = OrchestratorEventBatch()
        _ = batch.add([OrchestratorEvent(threadId: ThreadId("t"), title: "Fix", kind: .finished, permission: .free)], now: start)
        let gathered = batch.flush(now: start.addingTimeInterval(batch.window))
        #expect(gathered != nil && mac.verdict(task: phoneHolds) == .resync)
        // The Mac's write lands: from now on it relays, and the phone sees the new stamp and stops.
        mac.wrote(updatedAt: "2026-10-24T10:00:05.000Z")
        #expect(mac.verdict(task: task(enabled: false, stamp: "2026-10-24T10:00:05.000Z")) == .relay)
        // The phone writing after that takes it over again; the Mac drops and takes back.
        #expect(mac.verdict(task: task(enabled: false, stamp: "2026-10-24T10:01:00.000Z")) == .resync)
        // An enabled task means the Mac reads as closed: it takes it back too.
        #expect(mac.verdict(task: task(enabled: true, stamp: "2026-10-24T10:00:05.000Z")) == .resync)
    }

    /// A call the phone already answered with "Result:" doesn't run on the Mac; one nobody answered does, once.
    @Test func callsAnsweredByTheOtherSideDontRunTwice() {
        let call = "```orchestrator-call\n{\"tool\":\"list\"}\n```"
        let messages = [
            message("a1", "assistant", "Looking.\n\n" + call, minutes: 0),
            message("r1", "user", "Result: listed 3 threads on 2 machines", minutes: 0.1, run: nil),
            message("a2", "assistant", "And again.\n\n" + call, minutes: 1),
        ]
        let open = OrchestratorHandoff.unansweredReplies(messages, run: "run-1", handled: [])
        #expect(open.map(\.id.rawValue) == ["a2"])
        // Once handled here, it doesn't run again on the next look.
        #expect(OrchestratorHandoff.unansweredReplies(messages, run: "run-1", handled: ["a2"]).isEmpty)
        #expect(OrchestratorHandoff.callDelay == .seconds(2))
    }

    /// Asleep, the Mac can't know who held the task: after it wakes it doesn't relay until it has written it back, and a
    /// takeover by the phone while it slept is caught the same way.
    @Test func macSleepAndWake() {
        var mac = OrchestratorHandoff()
        mac.wrote(updatedAt: "2026-10-24T09:00:00.000Z")
        let held = task(enabled: false, stamp: "2026-10-24T09:00:00.000Z")
        #expect(mac.verdict(task: held) == .relay)
        mac.forget() // woke
        #expect(mac.verdict(task: held) == .resync)
        #expect(mac.verdict(task: task(enabled: false, stamp: "2026-10-24T09:30:00.000Z")) == .resync)
        mac.wrote(updatedAt: "2026-10-24T09:31:00.000Z")
        #expect(mac.verdict(task: task(enabled: false, stamp: "2026-10-24T09:31:00.000Z")) == .relay)
    }

    /// Without the task nobody else can be relaying, as the phone reads the Mac's state from it.
    @Test func noTaskMeansTheMacRelays() {
        #expect(OrchestratorHandoff().verdict(task: nil) == .relay)
    }

    /// Finding the Orchestrator thread, for the Mac's adoption and the helper: a thread a check task is bound to, else the
    /// newest whose first brief (with the thread) or updated brief the searches find.
    @Test func adoptionReadsTheBriefMarker() {
        let made = T3Timestamp(start)
        func shell(_ id: String, updated minutes: Double, _ edit: (inout ThreadShell) -> Void = { _ in }) -> ThreadShell {
            var t = thread(id)
            t.createdAt = made
            t.updatedAt = T3Timestamp(start.addingTimeInterval(minutes * 60))
            edit(&t)
            return t
        }
        func match(_ id: String, _ snippet: String, after seconds: Double = 0.1, source: String = "user") -> ThreadSearchMatch {
            ThreadSearchMatch(threadId: ThreadId(id), projectId: ProjectId("p"), source: source, snippet: snippet,
                              messageCreatedAt: T3Timestamp(start.addingTimeInterval(seconds)))
        }
        let brief = "# Orchestrator brief # Who you are You are Ada…"
        let threads = [shell("old", updated: 10), shell("new", updated: 50), shell("quoted", updated: 90), shell("later", updated: 95),
                       shell("archived", updated: 99) { $0.archivedAt = T3Timestamp(start) }]
        let matches = [match("old", brief), match("new", brief), match("quoted", "…please read the # Orchestrator brief below…"),
                       match("later", brief, after: 3600), match("archived", brief), match("gone", brief)]
        func find(_ m: [ThreadSearchMatch], tasks: [ScheduledTask] = []) -> String? {
            OrchestratorHandoff.findOrchestrator(matches: m, tasks: tasks, threads: threads)?.id.rawValue
        }
        #expect(find(matches) == "new")
        #expect(find([match("new", brief, source: "assistant")]) == nil)
        #expect(find([match("later", brief, after: 3600)]) == nil)
        #expect(find([]) == nil)
        // miniko on 2026-10-24: the newest user message with the phrase was a chat message about the marker, so the search
        // never showed the first brief and the helper relayed nothing. Its check task names the thread.
        let chat = [match("old", "…he Mac adopts an existing Orchestrator thread by its `# Orchestrator brief` marker. Other…", after: 7200)]
        #expect(find(chat) == nil)
        let check = ScheduledTask(id: "scheduled-task:1", title: "Conductor check", prompt: OrchestratorBrief.scheduledCheckPrompt,
                                  enabled: false, schedule: .interval(everyMs: 3_600_000), projectId: "p", threadId: "old")
        #expect(find(chat, tasks: [check]) == "old")
        // A check task beats a newer brief, and one on an archived thread doesn't count.
        #expect(find(matches, tasks: [check]) == "old")
        var gone = check
        gone.threadId = "archived"
        #expect(find(matches, tasks: [gone]) == "new")
        // Or the updated brief that went out with a later message.
        #expect(find(chat + [match("old", "# Updated brief # Who you are You are Ada…", after: 9000)]) == "old")
    }

    @Test func aConnectedHelperThatRelayedIsSeen() {
        let since = Int64(start.timeIntervalSince1970 * 1000) + 60_000
        let event = message("e1", "user", "Event: “Space 1” finished a turn (t3-thread://v1/t1).", minutes: 1.5, run: nil)
        let old = message("e0", "user", "Event: “Docs” finished a turn (t3-thread://v1/t2).", minutes: 0, run: nil)
        let chat = message("u1", "user", "How's it going?", minutes: 2, run: nil)
        #expect(OrchestratorHandoff.eventArrived([old, event, chat], since: since))
        #expect(!OrchestratorHandoff.eventArrived([old, chat], since: since))
    }

    /// The task's stamp survives decoding from the server's list.
    @Test func scheduledTasksKeepTheirStamp() throws {
        let json = try JSONValue(parsing: Data(#"{"tasks":[{"id":"check","title":"t","prompt":"p","enabled":false,"schedule":{"type":"interval","everyMs":60000},"projectId":"p","updatedAt":"2026-10-24T10:00:05.000Z"}]}"#.utf8))
        #expect(ScheduledTask.list(json).first?.updatedAt == "2026-10-24T10:00:05.000Z")
    }

    /// A connected helper relays (docs/orchestrator-helper.md, section 5): whatever the task says, the Mac stands by, and
    /// once the helper is gone the Mac takes the task back as when it opens.
    @Test func aConnectedHelperMakesTheMacStandBy() {
        var mac = OrchestratorHandoff()
        mac.wrote(updatedAt: "2026-10-24T10:00:05.000Z")
        let macHolds = task(enabled: false, stamp: "2026-10-24T10:00:05.000Z")
        #expect(mac.verdict(task: macHolds, helperConnected: true) == .standBy)
        #expect(mac.verdict(task: nil, helperConnected: true) == .standBy)
        // The helper took the task (a newer stamp) and then dropped off: the Mac takes it back before relaying.
        let helperHeld = task(enabled: false, stamp: "2026-10-24T10:05:00.000Z")
        #expect(mac.verdict(task: helperHeld, helperConnected: false) == .resync)
    }

    @Test func helperSessionsAreBotsWithTheHelperLabel() {
        func session(_ label: String, _ device: String) -> AuthClientSession {
            AuthClientSession(sessionId: label + device, subject: "one-time-token", scopes: [], client: .init(label: label, deviceType: device),
                              issuedAt: T3Timestamp(start), connected: true, current: false)
        }
        let all = [session(HelperInstall.sessionLabel(version: "1.14.0", home: "miniko"), "bot"),
                   session(HelperInstall.sessionLabel(version: "1.14.0", home: "miniko"), "desktop"),
                   session("CandyWrapper", "desktop")]
        #expect(OrchestratorHandoff.helperSessions(all).map(\.client.deviceType) == ["bot"])
    }
}
