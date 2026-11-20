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
            #expect(draft.scheduleMode == (t.schedule == .once(runAt: "2026-11-20T09:30:00+01:00") ? .once : .kept))
            let input = try ScheduledTaskLogic.upsertInput(draft, projectId: "p1", projectExists: true,
                                                           selection: ("codex", "gpt"), storedSecret: false).get()
            #expect(input["schedule"] == expected)
            #expect(input["threadMode"] == nil)
        }
    }

    /// The Once editor (scheduledTasksSettings.logic.ts:163-181, 244-260): local `datetime-local` values,
    /// the saved instant kept while its clock time is unchanged, and T3's run time errors.
    @Test func onceDraftsEditTheRunTime() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var d = ScheduledTaskDraft()
        d.scheduleMode = .once
        d.savedRunAt = "2026-11-20T09:30:00+01:00"
        d.runAt = "2026-11-20T09:30"
        #expect(ScheduledTaskLogic.onceRunAt(d, calendar: berlin) == "2026-11-20T09:30:00+01:00")
        d.runAt = "2026-11-21T10:15"
        #expect(ScheduledTaskLogic.onceRunAt(d, calendar: berlin) == "2026-11-21T09:15:00.000Z")
        d.runAt = "2026-11-21T"
        #expect(ScheduledTaskLogic.onceError(d, calendar: berlin) == "Pick a date and time.")
        // 02:30 on 29 March 2026 doesn't exist in Berlin.
        d.runAt = "2026-03-29T02:30"
        #expect(ScheduledTaskLogic.onceError(d, calendar: berlin) == "That time does not exist in your time zone.")
        #expect(ScheduledTaskLogic.dateTimeLocal(Date(timeIntervalSince1970: 0), calendar: berlin) == "1970-01-01T01:00")
        #expect(ScheduledTaskLogic.suggestedRunAt(now: Date(timeIntervalSince1970: 3601)).timeIntervalSince1970 == 7200)
        d.runAt = ""
        d.title = "T"; d.prompt = "P"
        if case .failure(let e) = ScheduledTaskLogic.upsertInput(d, projectId: "p", projectExists: true, selection: ("c", "m"), storedSecret: false) {
            #expect(e.copy.title == "Invalid run time")
        } else { Issue.record("an empty run time must not save") }
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

    /// Item 7: `orchestration.forceStopThread` (orchestrationV2.ts:4295-4320) and `unresponsiveAt` (:1842).
    @Test func forceStopWire() throws {
        #expect(ForceStopThread.input(threadId: "t1", runId: "r1") == Self.json(#"{"threadId":"t1","runId":"r1"}"#))
        #expect(ForceStopThread.input(threadId: "t1", runId: nil) == Self.json(#"{"threadId":"t1"}"#))
        let result = try Self.json(#"{"outcome":"shared","sharedWithThreadIds":["t2"]}"#).decode(as: ForceStopThread.Result.self)
        #expect(result.outcome == "shared" && result.sharedWithThreadIds == ["t2"])
        #expect(ForceStopThread.isSuperseded(Self.json(#"{"_tag":"OrchestrationV2ForceStopThreadError","threadId":"t1","reason":"superseded"}"#)))
        let item = try TurnItem(json: Self.json(#"""
            {"id":"i","threadId":"t1","type":"run_interrupt_request","ordinal":1,"status":"waiting",
             "updatedAt":"2026-11-19T00:00:00.000Z","message":"Stop","unresponsiveAt":"2026-11-19T00:00:05.000Z"}
            """#))
        #expect(item.unresponsiveAt?.raw == "2026-11-19T00:00:05.000Z")
    }

    /// Item 8: 4928 turn item fields, decoded only (orchestrationV2.ts:1603-1612, 1729-1853).
    @Test func newTurnItemFieldsDecode() throws {
        func item(_ type: String, _ extra: String) throws -> TurnItem {
            try TurnItem(json: Self.json(#"{"id":"i","threadId":"t1","type":"\#(type)","ordinal":1,"status":"completed","updatedAt":"2026-11-19T00:00:00.000Z",\#(extra)}"#))
        }
        #expect(try item("assistant_message", #""text":"x","phase":"commentary""#).assistantPhase == "commentary")
        let user = try item("user_message", #"""
            "text":"x","freshContext":true,
            "linkedSender":{"environmentId":"e2","threadId":"t9","title":"Other"},
            "modelSwitch":{"from":{"instanceId":"codex","model":"a"},"to":{"instanceId":"codex","model":"b"}}
            """#)
        #expect(user.freshContext && user.linkedSender?.title == "Other" && user.linkedSender?.threadId == "t9")
        #expect(user.modelSwitch?.to.model == "b")
        #expect(try item("system_notice", #""message":"m","level":"warning""#).noticeLevel == "warning")
        #expect(try item("secret_request", #""label":"Key","reason":"r","secretStatus":"pending","url":"https://example.com/keys""#).secretRequestURL == "https://example.com/keys")
        #expect(try item("command_execution", #""completionWake":"always""#).completionWake == "always")
        #expect(try item("assistant_message", #""text":"x""#).assistantPhase == nil)
    }

    /// Item 11: hosted thread links (shared/src/threadLinks.ts:50-68) and link metadata (orchestrationV2.ts:4017-4021).
    @Test func hostedThreadLinksAndMetadata() throws {
        let link = try #require(ThreadLink(href: "https://app.t3.codes/threads/env-1/thread%2E1"))
        #expect(link.environmentId == "env-1" && link.threadId == "thread.1")
        #expect(link.href == "t3-thread://v2/env-1/thread.1")
        #expect(ThreadLink(href: "https://app.t3.codes/threads/env-1") == nil)
        #expect(ThreadLink(href: "https://app.t3.codes/threads/env-1/t/extra") == nil)
        #expect(ThreadLink(href: "https://app.t3.codes/threads/env 1/t") == nil)
        #expect(ThreadLink(href: "t3-thread://v1/abc")?.threadId == "abc")

        #expect(ThreadLinkMetadata.input(threadIds: ["a", "b"]) == Self.json(#"{"threadIds":["a","b"]}"#))
        let meta = ThreadLinkMetadata.decode(Self.json(#"{"a":{"title":"A","projectId":"p"},"b":{"title":"B","projectId":null},"c":{"oops":1}}"#))
        #expect(meta.count == 2 && meta["a"]?.projectId == "p" && meta["b"]?.title == "B" && meta["b"]?.projectId == nil)
    }
}
