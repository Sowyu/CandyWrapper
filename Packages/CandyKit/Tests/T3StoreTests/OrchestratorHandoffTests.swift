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
        let gathered = batch.flush(now: start.addingTimeInterval(30))
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

    /// A thread is adopted only when its first message is a brief.
    @Test func adoptionReadsTheBriefMarker() {
        #expect(OrchestratorHandoff.isOrchestratorThread(firstUserMessage: OrchestratorBrief.first("You are Ada.")))
        #expect(!OrchestratorHandoff.isOrchestratorThread(firstUserMessage: "Please read # Orchestrator brief later"))
        #expect(!OrchestratorHandoff.isOrchestratorThread(firstUserMessage: OrchestratorBrief.updated("x", message: "y")))
        #expect(!OrchestratorHandoff.isOrchestratorThread(firstUserMessage: nil))
    }

    /// The task's stamp survives decoding from the server's list.
    @Test func scheduledTasksKeepTheirStamp() throws {
        let json = try JSONValue(parsing: Data(#"{"tasks":[{"id":"check","title":"t","prompt":"p","enabled":false,"schedule":{"type":"interval","everyMs":60000},"projectId":"p","updatedAt":"2026-10-24T10:00:05.000Z"}]}"#.utf8))
        #expect(ScheduledTask.list(json).first?.updatedAt == "2026-10-24T10:00:05.000Z")
    }
}
