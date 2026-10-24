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

    /// A thread is adopted only when its brief came with the thread, so it's the first message, and the newest such
    /// thread wins. The search alone tells: a projection holds only a thread's last 20 messages.
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
        #expect(OrchestratorHandoff.adoptable(matches, threads: threads)?.id == ThreadId("new"))
        #expect(OrchestratorHandoff.adoptable([match("new", brief, source: "assistant")], threads: threads) == nil)
        #expect(OrchestratorHandoff.adoptable([match("later", brief, after: 3600)], threads: threads) == nil)
        #expect(OrchestratorHandoff.adoptable([], threads: threads) == nil)
    }

    func run(_ id: String, _ status: String) -> Run {
        try! JSONDecoder().decode(Run.self, from: Data("""
            {"id":"\(id)","threadId":"orch","ordinal":1,"status":"\(status)","requestedAt":"2026-10-24T10:00:00Z","startedAt":null,"completedAt":null}
            """.utf8))
    }

    /// The race behind launches that never ran: a turn ends on an orchestrator-call block just as an Event arrives. The
    /// Event queued behind the turn and starts the next one at once, so the shell goes from turn to turn without
    /// showing it idle, and the newest turn is the Event's. The call still counts as ended and still runs, once.
    @Test func callsFromATurnThatRacedAnEventStillRun() {
        let since = Int64(start.timeIntervalSince1970 * 1000)
        let launch = "Starting it.\n\n```orchestrator-call\n{\"tool\":\"launch\",\"machine\":\"miniko\",\"projectId\":\"p\",\"title\":\"Fix\",\"text\":\"Fix it\"}\n```"
        let messages = [message("m0", "user", "Ship the fix", minutes: 1, run: "run-a"),
                        message("m1", "assistant", launch, minutes: 2, run: "run-a"),
                        message("m2", "user", "Event: “Docs” finished a turn (t3-thread://v1/d1).", minutes: 2.01, run: "run-b")]
        // The shell went straight from turn A to the Event's turn B.
        #expect(OrchestratorHandoff.turnEnded(wasRunning: true, wasRun: RunId("run-a"), running: true, run: RunId("run-b")))
        let due = OrchestratorHandoff.callsToRun(messages, runs: [run("run-a", "completed"), run("run-b", "running")],
                                                 since: since, activeAtStart: nil, handled: [])
        #expect(due.map(\.id.rawValue) == ["m1"])
        #expect(due.flatMap { OrchestratorReply.parse($0.text).calls }.map(\.tool) == [.launch])
        // Once it ran here it doesn't run again, and a "Result:" from the phone answers it too.
        #expect(OrchestratorHandoff.callsToRun(messages, runs: [run("run-a", "completed")], since: since, activeAtStart: nil, handled: ["m1"]).isEmpty)
        let answered = messages + [message("m3", "user", "Result: launched “Fix” on miniko", minutes: 3, run: "run-c")]
        #expect(OrchestratorHandoff.callsToRun(answered, runs: [run("run-a", "completed")], since: since, activeAtStart: nil, handled: []).isEmpty)
        // A turn still running waits for its end.
        #expect(OrchestratorHandoff.callsToRun(messages, runs: [run("run-a", "running")], since: since, activeAtStart: nil, handled: []).isEmpty)
        // Replies from before CandyWrapper saw the thread are history, unless their turn was the one running then.
        let later = since + 10 * 60_000
        #expect(OrchestratorHandoff.callsToRun(messages, runs: [run("run-a", "completed")], since: later, activeAtStart: nil, handled: []).isEmpty)
        #expect(OrchestratorHandoff.callsToRun(messages, runs: [run("run-a", "completed")], since: later, activeAtStart: RunId("run-a"),
                                               handled: []).map(\.id.rawValue) == ["m1"])
    }

    @Test func aTurnEndsWhenItGoesIdleOrTheNextStarts() {
        #expect(OrchestratorHandoff.turnEnded(wasRunning: true, wasRun: RunId("a"), running: false, run: RunId("a")))
        #expect(OrchestratorHandoff.turnEnded(wasRunning: false, wasRun: RunId("a"), running: true, run: RunId("b")))
        #expect(!OrchestratorHandoff.turnEnded(wasRunning: true, wasRun: RunId("a"), running: true, run: RunId("a")))
        #expect(!OrchestratorHandoff.turnEnded(wasRunning: false, wasRun: RunId("a"), running: false, run: RunId("a")))
    }

    func check(_ id: String, thread: String = "orch", minutes: Double = 30, enabled: Bool = false, updated: String? = nil,
               prompt: String = OrchestratorBrief.scheduledCheckPrompt) -> ScheduledTask {
        ScheduledTask(id: id, title: "Conductor check", prompt: prompt, enabled: enabled, schedule: .interval(everyMs: minutes * 60_000),
                      projectId: "p", threadId: thread, updatedAt: updated)
    }

    /// miniko on 2026-10-24: six check tasks on one Orchestrator thread, the user's at 60 minutes and five extras that
    /// clients made after losing their own id. Every client now picks the same one, the smallest id, and deletes the rest.
    @Test func everyClientUsesTheSameCheckTaskAndDropsTheRest() {
        let tasks = [check("scheduled-task:f538bf49"), check("scheduled-task:2bcc7c0d", minutes: 60), check("scheduled-task:8a16a8d2"),
                     check("scheduled-task:8afd9f14"), check("scheduled-task:993eb57e"), check("scheduled-task:55ec6126", enabled: true),
                     check("scheduled-task:000other", thread: "other"),
                     ScheduledTask(id: "scheduled-task:00settings", title: OrchestratorSettingsSync.title, prompt: "{}", enabled: false,
                                   schedule: .interval(everyMs: 86_400_000), projectId: "p"),
                     check("scheduled-task:0000mine", prompt: "My own reminder")]
        #expect(OrchestratorCheckTask.canonical(tasks, thread: "orch")?.id == "scheduled-task:2bcc7c0d")
        #expect(OrchestratorCheckTask.duplicates(tasks, thread: "orch").map(\.id).sorted()
                == ["scheduled-task:55ec6126", "scheduled-task:8a16a8d2", "scheduled-task:8afd9f14", "scheduled-task:993eb57e", "scheduled-task:f538bf49"])
        // Whatever order the list comes in.
        #expect(OrchestratorCheckTask.canonical(tasks.reversed(), thread: "orch")?.id == "scheduled-task:2bcc7c0d")
        #expect(OrchestratorCheckTask.canonical([], thread: "orch") == nil)
        #expect(OrchestratorCheckTask.duplicates([check("scheduled-task:only")], thread: "orch").isEmpty)
        // With the helper running nothing stays on: it deletes the extras, and an enabled canonical task reads as
        // someone else's write, so it turns that off too.
        let on = tasks.map { t -> ScheduledTask in var c = t; c.enabled = true; c.updatedAt = "2026-10-24T09:00:00.000Z"; return c }
        var helper = OrchestratorHandoff()
        helper.wrote(updatedAt: "2026-10-24T08:00:00.000Z")
        #expect(helper.verdict(task: OrchestratorCheckTask.canonical(on, thread: "orch")) == .resync)
        #expect(OrchestratorCheckTask.duplicates(on, thread: "orch").count == 5)
        // Two clients that create at once make the same task.
        #expect(OrchestratorCheckTask.commandId(thread: "orch") == OrchestratorCheckTask.commandId(thread: "orch"))
        #expect(OrchestratorCheckTask.commandId(thread: "orch") != OrchestratorCheckTask.commandId(thread: "other"))
    }

    /// The interval the user set on the task in T3 stays: it becomes the "While closed" setting unless the user changed
    /// that setting since.
    @Test func theUsersIntervalOnTheTaskStays() {
        let set = check("scheduled-task:2bcc7c0d", minutes: 60, updated: "2026-10-24T08:00:00.000Z")
        let edited = T3Timestamp("2026-10-24T08:00:00.000Z").epochMs!
        // The setting was never changed in CandyWrapper: the task's 60 minutes win.
        #expect(OrchestratorCheckTask.intervalSetOnTask(set, settingMinutes: 30, settingChangedAt: nil) == 60)
        // Changed before the task was edited: the task wins. Changed after: the setting does.
        #expect(OrchestratorCheckTask.intervalSetOnTask(set, settingMinutes: 30, settingChangedAt: edited - 60_000) == 60)
        #expect(OrchestratorCheckTask.intervalSetOnTask(set, settingMinutes: 15, settingChangedAt: edited + 60_000) == nil)
        // Already the same, or not an interval task: nothing to take.
        #expect(OrchestratorCheckTask.intervalSetOnTask(set, settingMinutes: 60, settingChangedAt: nil) == nil)
        let fixed = ScheduledTask(id: "x", title: "t", prompt: OrchestratorBrief.scheduledCheckPrompt, schedule: .fixedTime(timeOfDay: "09:00", weekdays: nil),
                                  projectId: "p", threadId: "orch")
        #expect(OrchestratorCheckTask.intervalSetOnTask(fixed, settingMinutes: 30, settingChangedAt: nil) == nil)
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
