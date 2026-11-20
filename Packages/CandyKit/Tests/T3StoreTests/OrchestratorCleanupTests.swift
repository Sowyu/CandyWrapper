import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The one-time cleanup after the Orchestrator's removal removes only what it made.
@Suite struct OrchestratorCleanupTests {
    func task(_ id: String, _ title: String, _ prompt: String, thread: String? = nil) -> ScheduledTask {
        var json: [String: JSONValue] = ["id": .string(id), "title": .string(title), "prompt": .string(prompt), "projectId": .string("p"),
                                         "schedule": .object(["type": .string("interval"), "everyMs": .number(1_800_000)])]
        if let thread { json["threadId"] = .string(thread) }
        return ScheduledTask(json: .object(json))!
    }

    @Test func deletesOnlyItsOwnTasks() {
        let tasks = [
            task("settings", "CandyWrapper Orchestrator settings", "{\"format\":\"candywrapper.orchestrator-settings\"}"),
            task("check", "Ada check", "Scheduled check: CandyWrapper is closed. List every thread…", thread: "orch"),
            task("old-check", "Ada check", "Scheduled check: an older wording", thread: "orch"),
            task("phone-check", "Ada check", "Scheduled check: CandyWrapper is closed. List…", thread: "other-orch"),
            task("user-check", "Nightly", "Scheduled check: run the tests", thread: "work"),
            task("bound-settings", "CandyWrapper Orchestrator settings", "mine", thread: "work"),
            task("daily", "Daily summary", "Summarise the day"),
        ]
        let ids = OrchestratorCleanup.tasksToDelete(tasks, threads: ["orch"]).map(\.id)
        #expect(ids == ["settings", "check", "old-check", "phone-check"])
        #expect(OrchestratorCleanup.tasksToDelete(tasks.filter { !ids.contains($0.id) }, threads: ["orch"]).isEmpty)
    }

    @Test func archivesOnlyItsStoredLiveThread() {
        let legacy = OrchestratorCleanup.Legacy(enabled: true, machines: ["env-a": .init(threadId: "orch")])
        let live = [thread("orch"), thread("work")]
        #expect(OrchestratorCleanup.threadsToArchive(legacy, env: "env-a", threads: live).map(\.id.rawValue) == ["orch"])
        #expect(OrchestratorCleanup.threadsToArchive(legacy, env: "env-b", threads: live).isEmpty)
        let archived = [thread("orch") { $0.archivedAt = T3Timestamp(Date()) }]
        #expect(OrchestratorCleanup.threadsToArchive(legacy, env: "env-a", threads: archived).isEmpty)
    }

    @Test func readsOldConfigsAndPicksTheMachines() throws {
        // A 1.14.14 config, trimmed: the keys the cleanup ignores don't matter.
        let data = Data(#"{"enabled":true,"name":"Ada","environmentId":"env-b","machines":{"env-a":{"threadId":"orch","briefDigest":"x"}},"crewLimit":4}"#.utf8)
        let legacy = try #require(OrchestratorCleanup.Legacy.read(data))
        #expect(legacy.pending(primary: "env-a") == ["env-a", "env-b"])
        #expect(OrchestratorCleanup.Legacy.read(nil) == nil)
        // Never switched on and never started: nothing on any server, so nothing waits.
        #expect(OrchestratorCleanup.Legacy.read(Data(#"{"enabled":false}"#.utf8))?.pending(primary: nil) == [])
        // Garbage still clears the keys instead of crashing.
        #expect(OrchestratorCleanup.Legacy.read(Data("not json".utf8))?.pending(primary: nil) == [])
        // On, with no machine picked: waits for the primary.
        #expect(OrchestratorCleanup.Legacy.read(Data(#"{"enabled":true}"#.utf8))?.pending(primary: nil) == nil)
    }

    @Test func findsOnlyTheRelayHelpersSessions() {
        func session(_ label: String, _ device: String) -> AuthClientSession {
            AuthClientSession(sessionId: label + device, subject: "s", scopes: [], client: .init(label: label, deviceType: device),
                              issuedAt: T3Timestamp(Date()), connected: true, current: false)
        }
        let all = [session("CandyWrapper Helper 1.14.0 on miniko", "bot"), session("CandyWrapper Helper 1.14.0 on miniko", "desktop"),
                   session("CandyWrapper on MacBook", "bot")]
        #expect(OrchestratorCleanup.helperSessions(all).map(\.sessionId) == ["CandyWrapper Helper 1.14.0 on minikobot"])
    }
}
