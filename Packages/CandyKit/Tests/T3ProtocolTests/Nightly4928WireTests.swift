import Foundation
import Testing
@testable import T3Protocol

/// Wire changes between nightly 3824 and 4928 (docs/research/nightly-diff-4928-wire.md).
struct Nightly4928WireTests {
    static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// 201 changed files: a 4928 server sends the first 200 and the totals of all 201 (WireProjection.ts:27).
    static func checkpointJSON(truncated: Bool) -> String {
        let count = truncated ? 200 : 3
        let files = (0..<count).map { #"{"path":"src/f\#($0).swift","kind":"modified","additions":2,"deletions":1}"# }
        let total = truncated ? #","filesTotal":{"count":201,"additions":410,"deletions":205}"# : ""
        return #"{"id":"cp1","threadId":"t1","scopeId":"s1","runId":"r1","nodeId":"n1","parentCheckpointId":null,"#
            + #""ordinalWithinScope":0,"appRunOrdinal":1,"ref":"refs/t3/cp1","status":"ready","files":[\#(files.joined(separator: ","))]"#
            + total + #","capturedAt":"2026-11-19T00:00:00.000Z"}"#
    }

    @Test func checkpointFilesTotalDecodes() throws {
        let truncated = try Self.json(Self.checkpointJSON(truncated: true)).decode(as: Checkpoint.self)
        #expect(truncated.files.count == 200)
        #expect(truncated.filesTotal == CheckpointFileTotals(count: 201, additions: 410, deletions: 205))
        #expect(CheckpointFileTotals.of(files: truncated.files, filesTotal: truncated.filesTotal).count == 201)

        let full = try Self.json(Self.checkpointJSON(truncated: false)).decode(as: Checkpoint.self)
        #expect(full.filesTotal == nil)
        #expect(CheckpointFileTotals.of(files: full.files, filesTotal: nil) == CheckpointFileTotals(count: 3, additions: 6, deletions: 3))
    }

    @Test func checkpointTurnItemFilesTotalDecodes() throws {
        let item = try TurnItem(json: Self.json(#"""
            {"id":"i1","threadId":"t1","type":"checkpoint","runId":"r1","ordinal":3,"status":"completed",
             "updatedAt":"2026-11-19T00:00:00.000Z","checkpointId":"cp1","scopeId":"s1",
             "files":[{"path":"a","kind":"added","additions":1,"deletions":0}],
             "filesTotal":{"count":250,"additions":900,"deletions":12}}
            """#))
        #expect(item.filesTotal == CheckpointFileTotals(count: 250, additions: 900, deletions: 12))
        // Round trip keeps it, since the item encodes its raw object.
        let again = try TurnItem(json: JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item)))
        #expect(again.filesTotal?.count == 250)
    }

    @Test func sideChatLineageIsNotListed() throws {
        func lineage(_ text: String) throws -> ThreadLineage { try Self.json(text).decode(as: ThreadLineage.self) }
        #expect(try lineage(#"{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"t"}"#).isListed)
        #expect(try lineage(#"{"parentThreadId":"p","relationshipToParent":"fork","rootThreadId":"p"}"#).isListed)
        #expect(try !lineage(#"{"parentThreadId":"p","relationshipToParent":"subagent","rootThreadId":"p"}"#).isListed)
        let side = try lineage(#"{"parentThreadId":"p","relationshipToParent":"fork","rootThreadId":"p","sideChat":true}"#)
        #expect(side.sideChat == true && !side.isListed)
    }

    /// 4928 one-shot schedules and thread modes (scheduledTask.ts:67-74, 231-239, 275).
    @Test func onceAndUnknownSchedulesKeepTheirTask() throws {
        func task(_ schedule: String, extra: String = "") -> String {
            #"{"id":"st1","title":"T","prompt":"P","enabled":true,"schedule":\#(schedule),"projectId":"p1","threadId":null\#(extra)}"#
        }
        let list = Self.json(#"{"timeZone":"Europe/Berlin","tasks":["#
            + task(#"{"type":"once","runAt":"2026-11-20T09:30:00+01:00"}"#, extra: #","threadMode":"fresh_session""#) + ","
            + task(#"{"type":"lunar","phase":"full"}"#) + ","
            + task(#"{"type":"interval","everyMs":60000}"#) + "]}")
        let tasks = ScheduledTask.list(list)
        #expect(tasks.count == 3)
        #expect(ScheduledTask.timeZone(list) == "Europe/Berlin")
        #expect(tasks[0].schedule == .once(runAt: "2026-11-20T09:30:00+01:00"))
        #expect(tasks[0].threadMode == "fresh_session" && tasks[0].effectiveThreadMode == "fresh_session")
        #expect(tasks[2].threadMode == nil && tasks[2].effectiveThreadMode == "new_thread")
        #expect(ScheduledTaskLogic.scheduleLabel(tasks[0].schedule).hasPrefix("Once, "))
        #expect(ScheduledTaskLogic.scheduleLabel(tasks[1].schedule) == "Custom schedule")

        // Editing either sends the schedule back as it came.
        let sent = [Self.json(#"{"type":"once","runAt":"2026-11-20T09:30:00+01:00"}"#), Self.json(#"{"type":"lunar","phase":"full"}"#)]
        for (t, expected) in zip(tasks, sent) {
            let draft = ScheduledTaskLogic.draft(t)
            #expect(draft.scheduleMode == .kept)
            let input = try ScheduledTaskLogic.upsertInput(draft, projectId: "p1", projectExists: true,
                                                           selection: ("codex", "gpt"), storedSecret: false).get()
            #expect(input["schedule"] == expected)
            #expect(input["threadMode"] == nil)
        }
    }

    /// Section 5: closed enums now keep values a newer server sends.
    @Test func closedEnumsAcceptUnknownValues() throws {
        func dec<T: Decodable>(_ t: T.Type, _ s: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(s.utf8)) }
        #expect(try dec(TerminalSessionStatus.self, #""paused""#).rawValue == "paused")
        #expect(try dec(TerminalSessionStatus.self, #""running""#) == .running)
        #expect(try dec(GitStackedAction.self, #""commit_push_pr""#) == .commitPushPr)
        #expect(try dec(GitStackedAction.self, #""rebase""#).rawValue == "rebase")
        #expect(GitStackedAction.allCases.count == 5)
        let stage = try dec(RelayClientInstallStage.self, #""unpacking""#)
        #expect(stage.label == "Installing relay client" && stage.step == 5)
        #expect(RelayClientInstallStage.activating.step == 7 && RelayClientInstallStage.waitingForLock.rawValue == "waiting_for_lock")
        #expect(try dec(PreviewEvent.Kind.self, #""zoomed""#).rawValue == "zoomed")
        #expect(try dec(PeerLinkSummary.Status.self, #""paused""#).rawValue == "paused")
        #expect(try dec(PeerLinkSummary.Status.self, #""expired""#) == .expired)
    }
}
