import Foundation
import T3Protocol
import Testing
@testable import T3Store

// Helpers shaped like the entry literals in T3's tests.

private func message(
    _ entryId: String, _ id: String? = nil, role: ChatMessage.Role, run: RunId? = nil, at: T3Timestamp, updated: T3Timestamp? = nil,
    streaming: Bool = false, intent: InputIntent? = nil, text: String? = nil
) -> TimelineEntry {
    .message(entryId, ChatMessage(id: MessageId(id ?? entryId), role: role, text: text ?? (id ?? entryId), runId: run, streaming: streaming,
                                  createdAt: at, updatedAt: updated ?? at, inputIntent: intent))
}

private func work(
    _ entryId: String, _ id: String? = nil, run: RunId? = nil, at: T3Timestamp, label: String = "Ran command", tone: WorkLogTone = .tool,
    _ edit: (inout WorkLogEntry) -> Void = { _ in }
) -> TimelineEntry {
    var entry = WorkLogEntry(id: id ?? entryId, createdAt: at, runId: run, label: label, tone: tone)
    edit(&entry)
    return .work(entryId, entry)
}

private func derive(_ entries: [TimelineEntry], _ edit: (inout TimelineRowsInput) -> Void = { _ in }) -> [TimelineRow] {
    var input = TimelineRowsInput(entries: entries)
    edit(&input)
    return TimelineRows.derive(input)
}

private func kind(_ row: TimelineRow) -> String {
    switch row.kind {
    case .message: "message"
    case .assistantMeta: "assistant-meta"
    case .work: "work"
    case .workLive: "work-live"
    case .pendingApproval: "pending-approval"
    case .working: "working"
    case .thinking: "thinking"
    case .workToggle: "work-toggle"
    case .turnFold: "turn-fold"
    case .attemptFold: "attempt-fold"
    case .contextCompaction: "context-compaction"
    case .event: "event"
    case .proposedPlan: "proposed-plan"
    case .htmlRender: "html-render"
    case .mcpApp: "mcp-app"
    }
}

private func live(_ rows: [TimelineRow]) -> [(entry: WorkLogEntry, grouped: [WorkLogEntry], active: Bool, thought: WorkLogEntry?)] {
    rows.compactMap { if case .workLive(let e, let g, _, _, let a, let t) = $0.kind { (e, g, a, t) } else { nil } }
}

private func messageFlags(_ row: TimelineRow?) -> (meta: Bool, copy: Bool, streaming: Bool)? {
    guard let row, case .message(_, _, let meta, let copy, let streaming, _) = row.kind else { return nil }
    return (meta, copy, streaming)
}

/// More ports from the `deriveMessagesTimelineRows` block of
/// apps/web/src/components/chat/MessagesTimeline.logic.test.ts (cited by line), feeding the same
/// entries and run state to the Swift row pass.
@Suite struct TimelineRowsPortTests {
    // LT:668
    @Test func stopsStrandedThinkingAfterASteerAndFollowsTheNextThoughtOrTool() {
        let runId: RunId = "steered-run"
        let at: T3Timestamp = "2026-10-01T06:19:10Z"
        func thought(_ id: String) -> TimelineEntry {
            work(id, run: runId, at: at, label: "Thinking", tone: .thinking) {
                $0.itemType = .reasoning
                $0.detail = id
                $0.toolLifecycleStatus = .inProgress
            }
        }
        let steer = message("steer", role: .user, run: runId, at: at, intent: .steer, text: "Also evaluate speed")
        let first = thought("first-thought"), next = thought("next-thought")
        let tool = work("tool", run: runId, at: at, label: "Running cat") { $0.command = "cat file"; $0.toolLifecycleStatus = .inProgress }
        func rows(_ entries: [TimelineEntry]) -> [TimelineRow] {
            derive(entries) { $0.runningRunId = runId; $0.isWorking = true; $0.activeTurnStartedAt = at }
        }
        #expect(live(rows([first])).first.map { $0.active && $0.entry.id == "first-thought" } == true)
        let afterSteer = rows([first, steer])
        #expect(live(afterSteer).isEmpty)
        #expect(afterSteer.last.map(kind) == "thinking")
        let settled = afterSteer.first { kind($0) == "work" }
        if case .work(let grouped, _, _)? = settled?.kind {
            #expect(grouped.map(\.id) == ["first-thought"] && grouped.first?.toolLifecycleStatus == .completed)
        } else {
            Issue.record("the stranded thought has no work row")
        }
        for entries in [[first, steer, next], [first, next], [first, steer, next, tool]] {
            let active = live(rows(entries)).filter(\.active)
            #expect(active.count == 1)
            #expect(active.first?.entry.id == entries.last?.id)
        }
        // The row pass must not rewrite the entry it was given.
        #expect(first.work?.toolLifecycleStatus == .inProgress)
    }

    // LT:1026
    @Test func keepsContextCompactionVisibleOutsideFoldedWork() {
        let rows = derive([work("compaction-entry", "compaction", at: "2026-01-01T00:00:00Z", label: "Compacted context 899K → 19K tokens", tone: .info) {
            $0.sourceActivityKind = "context-compaction"
        }])
        #expect(rows.count == 1)
        #expect(rows.first?.id == "compaction-entry")
        if case .contextCompaction(let label, let active, _, _)? = rows.first?.kind {
            #expect(label == "Compacted context 899K → 19K tokens" && !active)
        } else {
            Issue.record("no compaction row: \(rows.map(\.id))")
        }
    }

    // LT:1122
    @Test func onlyEnablesAssistantCopyForTheTerminalAssistantMessageInATurn() {
        let rows = derive([
            message("user-1-entry", "user-1", role: .user, at: "2026-01-01T00:00:00Z", text: "Write a poem"),
            message("assistant-thought-entry", "assistant-thought", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:10Z", updated: "2026-01-01T00:00:11Z"),
            message("assistant-final-entry", "assistant-final", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:20Z", updated: "2026-01-01T00:00:30Z"),
        ]) { $0.expandedRunIds = ["turn-1"] }
        let assistants = rows.filter { $0.message?.role == .assistant && kind($0) == "message" }
        #expect(assistants.count == 2)
        #expect(messageFlags(assistants.first)?.copy == false)
        #expect(messageFlags(assistants.last)?.copy == true)
    }

    // LT:1185
    @Test func marksOnlyTheActiveAssistantTurnAsStreamingForCopyControls() {
        let rows = derive([
            message("assistant-one-entry", "assistant-one", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:10Z", updated: "2026-01-01T00:00:11Z"),
            message("assistant-two-entry", "assistant-two", role: .assistant, run: "turn-2", at: "2026-01-01T00:00:20Z", updated: "2026-01-01T00:00:30Z"),
        ]) { $0.latestRun = TimelineLatestRun(runId: "turn-2", status: .running, startedAt: "2026-01-01T00:00:19Z") }
        let assistants = rows.filter { $0.message?.role == .assistant && kind($0) == "message" }
        #expect(messageFlags(assistants.first)?.streaming == false)
        #expect(messageFlags(assistants.last)?.streaming == true)
    }

    // LT:1706
    @Test func keepsTheWorkingHeaderBelowTheInitiatingPromptAcrossRepeatedSteers() {
        let runId: RunId = "steered-run"
        let startedAt: T3Timestamp = "2026-01-01T00:00:00Z"
        var entries = [message("initial-prompt", role: .user, run: runId, at: startedAt)]
        for index in 0..<3 {
            let rows = derive(entries) {
                $0.latestRun = TimelineLatestRun(runId: runId, status: .running, startedAt: startedAt)
                $0.isWorking = true
                $0.activeTurnStartedAt = startedAt
            }
            #expect(rows.prefix(2).map(\.id) == ["initial-prompt", "working-indicator-row"])
            let working = rows.filter { kind($0) == "working" }
            #expect(working.count == 1 && working.first?.createdAt == startedAt)
            #expect(rows.filter { kind($0) == "message" }.map(\.id) == entries.map(\.id))
            entries.append(message("steer-\(index)", role: .user, run: runId, at: startedAt, intent: .steer))
        }
    }

    // LT:1748
    @Test(arguments: [InputIntent.steer, .promotedQueuedToSteer])
    func keepsTheDurationHeaderAtTheInitiatingPromptWhenASteerArrivesBeforeOutput(_ intent: InputIntent) {
        let runId: RunId = "steered-run"
        func time(_ s: Int) -> T3Timestamp { T3Timestamp(String(format: "2026-01-01T00:00:%02d.000Z", s)) }
        let entries = [
            message("initial-prompt", role: .user, run: runId, at: time(0), intent: .turnStart),
            message("steer", role: .user, run: runId, at: time(5), intent: intent),
            work("work", run: runId, at: time(8)),
            message("final", role: .assistant, run: runId, at: time(20), text: "Done"),
        ]
        for isWorking in [true, false] {
            for expanded in [true, false] {
                let rows = derive(entries) {
                    $0.latestRun = TimelineLatestRun(runId: runId, status: isWorking ? .running : .completed, startedAt: time(0),
                                                     completedAt: isWorking ? nil : time(20))
                    $0.isWorking = isWorking
                    $0.activeTurnStartedAt = time(0)
                    $0.expandedRunIds = expanded ? [runId] : []
                }
                #expect(rows.prefix(3).map(\.id) == ["initial-prompt", isWorking ? "working-indicator-row" : "turn-fold:\(runId.rawValue)", "steer"])
                #expect(rows[1].createdAt == time(0))
                if !isWorking, case .turnFold(_, let label, let open) = rows[1].kind {
                    #expect(label == "Worked for 20s" && open == expanded)
                }
                #expect(rows.contains { $0.id == "final" })
                #expect(rows.contains { $0.id == "work" } == (isWorking || expanded))
            }
        }
    }

    // LT:1825
    @Test func keepsThePreviousTurnFoldedWhileANewlySentMessageAwaitsItsTurn() {
        let rows = derive([
            work("work-entry-1", "work-1", run: "turn-1", at: "2026-01-01T00:00:05Z"),
            message("assistant-final-entry", "assistant-final", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:20Z",
                    updated: "2026-01-01T00:00:22Z", text: "Done"),
            message("user-followup-entry", "user-followup", role: .user, at: "2026-01-01T00:01:00Z", text: "yooo"),
        ]) {
            $0.latestRun = TimelineLatestRun(runId: "turn-1", status: .completed, startedAt: "2026-01-01T00:00:00Z", completedAt: "2026-01-01T00:00:22Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:01:00Z"
        }
        #expect(rows.map(\.id) == ["turn-fold:turn-1", "assistant-final-entry", "user-followup-entry", "working-indicator-row", "live-activity-row"])
        #expect(messageFlags(rows.first { $0.id == "assistant-final-entry" })?.meta == true)
        #expect(rows.last.map(kind) == "thinking")
    }

    // LT:1895
    @Test func doesNotFoldTheActiveInProgressTurn() {
        let rows = derive([
            message("assistant-thought-entry", "assistant-thought", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:05Z",
                    updated: "2026-01-01T00:00:06Z", text: "Working on it."),
            work("work-entry-1", "work-1", run: "turn-1", at: "2026-01-01T00:00:08Z"),
        ]) {
            $0.latestRun = TimelineLatestRun(runId: "turn-1", status: .running, startedAt: "2026-01-01T00:00:00Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:00:00Z"
        }
        #expect(!rows.contains { kind($0) == "turn-fold" })
        #expect(rows.map(\.id) == ["working-indicator-row", "assistant-thought-entry", "live-activity-row"])
    }

    // LT:1945
    @Test func keepsAPromptlessRestartInOneActiveVisualResponse() {
        let rows = derive([
            message("user-entry", "user-1", role: .user, at: "2026-01-01T00:00:00Z", text: "keep going"),
            work("old-work-entry", "old-work", run: "turn-before-restart", at: "2026-01-01T00:00:05Z", label: "Searched files") {
                $0.command = "rg restart"; $0.toolLifecycleStatus = .completed
            },
            work("old-stale-work-entry", "old-stale-work", run: "turn-before-restart", at: "2026-01-01T00:00:06Z", label: "Running stale command") {
                $0.command = "rg stale"; $0.toolLifecycleStatus = .inProgress
            },
            message("old-commentary-entry", "old-commentary", role: .assistant, run: "turn-before-restart", at: "2026-01-01T00:00:08Z",
                    text: "the server restarted, continuing here."),
            work("new-work-entry", "new-work", run: "turn-after-restart", at: "2026-01-01T00:01:05Z", label: "Running tests") {
                $0.command = "vp test run"; $0.toolLifecycleStatus = .inProgress
            },
        ]) {
            $0.latestRun = TimelineLatestRun(runId: "turn-after-restart", status: .running, startedAt: "2026-01-01T00:01:00Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:01:00Z"
        }
        #expect(!rows.contains { kind($0) == "turn-fold" })
        #expect(rows.filter { $0.id == "working-indicator-row" }.count == 1)
        let header = rows.firstIndex { $0.id == "working-indicator-row" }, old = rows.firstIndex { $0.id == "old-work-entry" }
        #expect(header != nil && old != nil && header! < old!)
        #expect(rows.first { $0.id == "working-indicator-row" }?.createdAt == "2026-01-01T00:01:00Z")
        let commentary = messageFlags(rows.first { $0.id == "old-commentary-entry" })
        #expect(commentary?.meta == false && commentary?.copy == false && commentary?.streaming == true)
        #expect(live(rows).filter(\.active).map(\.entry.id) == ["new-work"])
        #expect(!rows.contains { kind($0) == "thinking" })
    }

    // LT:2050
    @Test func carriesTheLatestThoughtOnTheLiveRowWhileALaterToolRuns() {
        func thought(_ id: String, _ at: T3Timestamp, _ detail: String) -> TimelineEntry {
            work("\(id)-entry", id, run: "turn-1", at: at, label: id, tone: .thinking) {
                $0.itemType = .reasoning; $0.detail = detail; $0.toolLifecycleStatus = .completed
            }
        }
        let rows = derive([
            thought("old-thought", "2026-01-01T00:00:01Z", "First idea."),
            thought("new-thought", "2026-01-01T00:00:02Z", "Found the cause."),
            work("running-command-entry", "running-command", run: "turn-1", at: "2026-01-01T00:00:03Z", label: "running-command") {
                $0.command = "rg cause"; $0.requestKind = "command"; $0.toolLifecycleStatus = .inProgress
            },
        ]) {
            $0.latestRun = TimelineLatestRun(runId: "turn-1", status: .running, startedAt: "2026-01-01T00:00:00Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:00:00Z"
        }
        let row = live(rows).first
        #expect(row?.entry.id == "running-command" && row?.thought?.id == "new-thought")
    }

    // LT:2104
    @Test func keepsAnActuallyRunningToolInTheSharedActivityRow() {
        let rows = derive([
            work("running-command-entry", "running-command", run: "turn-1", at: "2026-01-01T00:00:05Z", label: "Running rg") {
                $0.command = "rg toolCall"; $0.requestKind = "command"; $0.toolLifecycleStatus = .inProgress
            },
            work("completed-edit-entry", "completed-edit", run: "turn-1", at: "2026-01-01T00:00:06Z", label: "Edited files") {
                $0.requestKind = "file-change"; $0.changedFiles = ["src/one.ts", "src/two.ts"]; $0.toolLifecycleStatus = .completed
            },
            work("completed-command-entry", "completed-command", run: "turn-1", at: "2026-01-01T00:00:07Z", label: "Ran tests") {
                $0.command = "vp test run"; $0.requestKind = "command"; $0.toolLifecycleStatus = .completed
            },
        ]) {
            $0.latestRun = TimelineLatestRun(runId: "turn-1", status: .running, startedAt: "2026-01-01T00:00:00Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:00:00Z"
        }
        #expect(rows.map(kind) == ["working", "work-live"])
        let row = live(rows).first
        #expect(row?.entry.id == "running-command" && row?.active == true)
        #expect(row?.grouped.map(\.id) == ["running-command", "completed-edit", "completed-command"])
    }

    // LT:2178
    @Test func foldsEachRunOfAProviderNativeSubagentThreadLikeANormalTurn() {
        func at(_ s: Int) -> String { String(format: "2026-09-25T22:%02d:%02d.000Z", 51 + s / 60, s % 60) }
        func base(_ id: String, _ ordinal: Int, _ second: Int, end: Int? = nil, status: String = "completed", completed: Bool = true) -> String {
            """
            "id":"\(id)","threadId":"subagent-child","runId":null,"nodeId":"task-root","ordinal":\(ordinal),"status":"\(status)",
            "startedAt":"\(at(second))","completedAt":\(completed ? "\"\(at(end ?? second))\"" : "null"),"updatedAt":"\(at(end ?? second))"
            """
        }
        func prompt(_ id: String, _ ordinal: Int, _ second: Int) -> TurnItem {
            turnItem("{\(base(id, ordinal, second)),\"type\":\"user_message\",\"messageId\":\"\(id)\",\"text\":\"Prompt \(id)\",\"attachments\":[],\"inputIntent\":\"turn_start\",\"createdBy\":\"agent\",\"creationSource\":\"provider\"}")
        }
        func answer(_ id: String, _ ordinal: Int, _ second: Int) -> TurnItem {
            turnItem("{\(base(id, ordinal, second)),\"type\":\"assistant_message\",\"messageId\":\"\(id)\",\"text\":\"Answer \(id)\",\"streaming\":false}")
        }
        enum Resume { case running, completed, failed }
        func items(_ resume: Resume) -> [ProjectedTurnItem] {
            var list = [
                prompt("launch", 1, 0),
                turnItem("{\(base("launch-ls", 2, 4)),\"type\":\"command_execution\",\"input\":\"ls src\"}"),
                turnItem("{\(base("launch-thinking", 3, 8)),\"type\":\"reasoning\",\"title\":\"Thinking\",\"text\":\"Not there.\",\"streaming\":false}"),
                answer("launch-answer", 4, 8),
                prompt("resume", 5, 72),
                turnItem("{\(base("resume-ls", 6, 77, status: resume == .running ? "running" : "completed", completed: resume != .running)),\"type\":\"command_execution\",\"input\":\"ls src\"}"),
            ]
            if resume == .failed {
                list.append(turnItem("{\(base("resume-error", 7, 80, status: "failed")),\"type\":\"error\",\"failure\":{\"class\":\"provider_error\",\"message\":\"Subagent failed\",\"code\":null,\"retryable\":null}}"))
            }
            if resume != .running { list.append(answer("resume-answer", 8, 80)) }
            return list.enumerated().map { ProjectedTurnItem(local: $1, position: $0) }
        }
        func rows(_ resume: Resume, working: Bool, expanded: Set<RunId> = []) -> [TimelineRow] {
            derive(TimelineEntries.derive(visibleTurnItems: items(resume))) {
                $0.isWorking = working
                $0.runlessWorkActive = working
                $0.expandedRunIds = expanded
                $0.activeTurnStartedAt = working ? T3Timestamp(at(72)) : nil
            }
        }
        func shape(_ rows: [TimelineRow]) -> [String] {
            rows.map { row in
                switch row.kind {
                case .turnFold(_, let label, _): "fold:\(label)"
                case .message(let m, _, _, _, _, _): "\(m.role.rawValue):\(m.id.rawValue)"
                default: kind(row)
                }
            }
        }
        let settled = rows(.completed, working: false)
        #expect(shape(settled) == ["user:launch", "fold:Worked for 8.0s", "assistant:launch-answer", "user:resume", "fold:Worked for 8.0s", "assistant:resume-answer"])
        guard case .turnFold(let launch, _, _)? = settled.first(where: { kind($0) == "turn-fold" })?.kind else {
            Issue.record("no launch fold")
            return
        }
        #expect(shape(rows(.completed, working: false, expanded: [launch])) == [
            "user:launch", "fold:Worked for 8.0s", "work-toggle", "assistant:launch-answer", "user:resume", "fold:Worked for 8.0s", "assistant:resume-answer",
        ])
        #expect(shape(rows(.running, working: true)) == ["user:launch", "fold:Worked for 8.0s", "assistant:launch-answer", "user:resume", "working", "work-live"])
        #expect(shape(rows(.failed, working: false)) == ["user:launch", "fold:Worked for 8.0s", "assistant:launch-answer", "user:resume", "work", "work", "assistant:resume-answer"])
    }

    // LT:2340
    @Test func keepsImportedV1TurnsFoldedOnceTheThreadsFirstV2RunStarts() {
        func at(_ s: Int) -> T3Timestamp { T3Timestamp(String(format: "2026-01-01T00:00:%02dZ", s)) }
        func rows(_ tail: [TimelineEntry]) -> [String] {
            derive([
                message("imported-prompt", role: .user, at: at(0)),
                message("imported-update", role: .assistant, at: at(4)),
                work("imported-command", at: at(5), label: "Ran git") { $0.command = "git status"; $0.requestKind = "command"; $0.toolLifecycleStatus = .completed },
                message("imported-answer", role: .assistant, at: at(8)),
            ] + tail) {
                $0.latestRun = TimelineLatestRun(runId: "run-1", status: .running, startedAt: at(20))
                $0.isWorking = true
                $0.activeTurnStartedAt = at(20)
            }.map { row in
                if case .message(let m, _, _, _, _, _) = row.kind { return "\(m.role.rawValue):\(m.id.rawValue)" }
                return kind(row)
            }
        }
        #expect(Array(rows([message("new-prompt", role: .user, run: "run-1", at: at(20))]).prefix(4)) == [
            "user:imported-prompt", "turn-fold", "assistant:imported-answer", "user:new-prompt",
        ])
        let withoutPrompt = rows([])
        #expect(withoutPrompt.contains("turn-fold"))
        #expect(!withoutPrompt.contains("assistant:imported-update"))
        // The fold row carries the key that opens it.
        let plain = [message("imported-prompt", role: .user, at: at(0)), message("imported-update", role: .assistant, at: at(4)),
                     message("imported-answer", role: .assistant, at: at(8))]
        guard case .turnFold(let key, _, _)? = derive(plain).first(where: { kind($0) == "turn-fold" })?.kind else {
            Issue.record("no fold for the imported turn")
            return
        }
        #expect(derive(plain) { $0.expandedRunIds = [key] }.contains { $0.message?.id == "imported-update" })
    }

    // LT:2437
    @Test func showsAProviderNativeSubagentsRunlessToolsAsLiveWorkWhileItWorks() {
        func rows(_ status: ToolLifecycleStatus, working: Bool) -> [TimelineRow] {
            derive([
                message("task-entry", "task", role: .user, at: "2026-01-01T00:00:00Z", text: "Audit the adapters"),
                work("command-entry", "command", at: "2026-01-01T00:00:05Z", label: "Running git") {
                    $0.command = "git diff --stat"; $0.requestKind = "command"; $0.toolLifecycleStatus = status
                },
            ]) {
                $0.isWorking = working
                $0.runlessWorkActive = working
                $0.activeTurnStartedAt = working ? "2026-01-01T00:00:00Z" : nil
            }
        }
        let running = rows(.inProgress, working: true)
        #expect(running.map(kind) == ["message", "working", "work-live"])
        #expect(live(running).first.map { $0.entry.id == "command" && $0.active } == true)
        #expect(rows(.completed, working: false).map(kind) == ["message", "turn-fold"])
    }

    private static func running(_ input: inout TimelineRowsInput, run: RunId = "turn-1") {
        input.latestRun = TimelineLatestRun(runId: run, status: .running, startedAt: "2026-01-01T00:00:00Z")
        input.isWorking = true
        input.activeTurnStartedAt = "2026-01-01T00:00:00Z"
    }

    // LT:2595
    @Test func keepsSeparatedInProgressToolRunsVisible() {
        let rows = derive([
            work("first-running-entry", "first-running", run: "turn-1", at: "2026-01-01T00:00:05Z", label: "Running first command") {
                $0.command = "rg first"; $0.requestKind = "command"; $0.toolLifecycleStatus = .inProgress
            },
            message("assistant-commentary-entry", "assistant-commentary", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:06Z"),
            work("second-running-entry", "second-running", run: "turn-1", at: "2026-01-01T00:00:07Z", label: "Running second command") {
                $0.command = "rg second"; $0.requestKind = "command"; $0.toolLifecycleStatus = .inProgress
            },
        ]) { Self.running(&$0) }
        #expect(rows.map(kind) == ["working", "work-live", "message", "work-live"])
        #expect(live(rows).map(\.entry.id) == ["first-running", "second-running"])
    }

    // LT:2662
    @Test func doesNotReviveStaleInProgressToolsBeforeAFreshSendHasATurnId() {
        let rows = derive([
            work("stale-running-entry", "stale-running", run: "turn-1", at: "2026-01-01T00:00:05Z", label: "Running stale command") {
                $0.command = "rg stale"; $0.requestKind = "command"; $0.toolLifecycleStatus = .inProgress
            },
            message("user-followup-entry", "user-followup", role: .user, at: "2026-01-01T00:01:00Z", text: "continue"),
        ]) {
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:01:00Z"
        }
        #expect(live(rows).isEmpty)
    }

    // LT:2705
    @Test func doesNotReviveSeparatedHistoricalTaskProgress() {
        let rows = derive([
            work("stale-progress-entry", "stale-progress", run: "turn-1", at: "2026-01-01T00:00:05Z", label: "Old progress", tone: .thinking) {
                $0.sourceActivityKind = "task.progress"
            },
            message("assistant-commentary-entry", "assistant-commentary", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:06Z"),
            work("running-command-entry", "running-command", run: "turn-1", at: "2026-01-01T00:00:07Z", label: "Running command") {
                $0.command = "rg current"; $0.requestKind = "command"; $0.toolLifecycleStatus = .inProgress
            },
        ]) { Self.running(&$0) }
        #expect(live(rows).map(\.entry.id) == ["running-command"])
    }

    // LT:2768
    @Test(arguments: [(ToolLifecycleStatus?.none, Bool?.some(true)), (.inProgress, true), (.completed, false), (.failed, nil), (.declined, false), (.stopped, false)])
    func respectsTheLifecycleOfTrailingTaskProgress(_ status: ToolLifecycleStatus?, _ active: Bool?) {
        let rows = derive([
            work("task-progress-entry", "task-progress", run: "turn-task-progress", at: "2026-01-01T00:00:05Z", label: "Task progress", tone: .thinking) {
                $0.sourceActivityKind = "task.progress"
                $0.toolLifecycleStatus = status
            },
        ]) { Self.running(&$0, run: "turn-task-progress") }
        if let active {
            #expect(live(rows).first?.active == active)
        } else {
            #expect(live(rows).isEmpty)
            #expect(rows.last.map { kind($0) == "thinking" && $0.id == "live-activity-row" } == true)
        }
    }

    // LT:2818
    @Test func reusesOneActivityRowForInitialThinkingAndTheLatestTool() {
        func rows(_ status: ToolLifecycleStatus?, expanded: Set<String> = []) -> [TimelineRow] {
            let entries = status.map { status in
                [work("latest-command-entry", "latest-command", run: "turn-1", at: "2026-01-01T00:00:05Z",
                      label: status == .inProgress ? "Running rg" : "Ran rg") {
                    $0.command = "rg toolCall"; $0.requestKind = "command"; $0.toolLifecycleStatus = status
                    if status == .inProgress { $0.detail = "exit code 1" }
                }]
            } ?? []
            return derive(entries) { Self.running(&$0); $0.expandedWorkGroupIds = expanded }
        }
        let initial = rows(nil), runningRows = rows(.inProgress), completed = rows(.completed), failed = rows(.failed), declined = rows(.declined)
        #expect(initial.first { $0.id == "live-activity-row" }.map(kind) == "thinking")
        for set in [runningRows, completed] {
            let row = set.first { $0.id == "live-activity-row" }
            if case .workLive(_, _, _, _, let active, _)? = row?.kind { #expect(active) } else { Issue.record("no live row: \(set.map(\.id))") }
        }
        #expect(live(failed).isEmpty)
        guard let last = failed.last, case .thinking(let groupId?, _, _) = last.kind, last.id == "live-activity-row" else {
            Issue.record("a failed latest tool hands the row back to thinking with its group: \(failed.map(\.id))")
            return
        }
        let open = rows(.failed, expanded: [groupId])
        if case .thinking(_, let expanded?, _) = open[open.count - 2].kind { #expect(expanded) } else { Issue.record("no open thinking row") }
        if case .work(let grouped, true, _) = open[open.count - 1].kind { #expect(grouped.map(\.id) == ["latest-command"]) } else { Issue.record("no group body") }
        #expect(live(declined).first?.active == false)
        #expect(declined.last.map { kind($0) == "thinking" && $0.id == "live-activity-row" } == true)
        for set in [initial, runningRows, completed, failed, declined] {
            #expect(set.filter { $0.id == "live-activity-row" }.count == 1)
        }
    }

    // LT:2894
    @Test func doesNotFoldTheSessionsRunningTurnWhenLatestRunRegresses() {
        let rows = derive([
            work("previous-work-entry", "previous-work", run: "turn-1", at: "2026-01-01T00:00:05Z", label: "Read files"),
            message("user-followup-entry", "user-followup", role: .user, at: "2026-01-01T00:01:00Z", text: "continue"),
            work("running-work-entry", "running-work", run: "turn-2", at: "2026-01-01T00:01:05Z", label: "Searched files"),
        ]) {
            $0.latestRun = TimelineLatestRun(runId: "turn-1", status: .completed, startedAt: "2026-01-01T00:00:00Z", completedAt: "2026-01-01T00:00:25Z")
            $0.runningRunId = "turn-2"
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:01:00Z"
        }
        #expect(rows.compactMap { if case .turnFold(let run, _, _) = $0.kind { run.rawValue } else { nil } } == ["turn-1"])
        #expect(rows.contains { $0.id == "live-activity-row" })
    }

    // LT:2955
    @Test func onlyShowsAssistantMetadataOnTheTerminalAssistantMessage() {
        let rows = derive([
            message("assistant-thought-entry", "assistant-thought", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:10Z", updated: "2026-01-01T00:00:11Z"),
            message("assistant-final-entry", "assistant-final", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:20Z", updated: "2026-01-01T00:00:30Z"),
        ]) { $0.expandedRunIds = ["turn-1"] }
        #expect(rows.filter { $0.message?.role == .assistant && kind($0) == "message" }.map { messageFlags($0)!.meta } == [false, true])
    }

    // LT:3002
    @Test func withholdsAssistantMetadataWhileTheActiveTurnIsStillInProgress() {
        let rows = derive([
            message("assistant-thought-entry", "assistant-thought", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:10Z", updated: "2026-01-01T00:00:11Z"),
        ]) { Self.running(&$0) }
        let flags = messageFlags(rows.first { $0.message?.role == .assistant })
        #expect(flags?.meta == false && flags?.copy == false)
        #expect(rows.last.map(kind) == "thinking")
    }

    // T3 07d38b8d17: MessagesTimeline.logic.ts:1969, threadExecution.ts:56-71.
    @Test func dropsThinkingOnceTheOpenRunsProviderTurnEnded() {
        let entries = [message("user-entry", "user", role: .user, run: "turn-1", at: "2026-01-01T00:00:00Z")]
        #expect(derive(entries) { Self.running(&$0) }.last.map(kind) == "thinking")
        let ended = derive(entries) { Self.running(&$0); $0.latestRun?.turnEnded = true }
        #expect(!ended.contains { kind($0) == "thinking" })

        let run = try! JSONDecoder().decode(Run.self, from: Data("""
            {"id":"turn-1","threadId":"t","ordinal":1,"status":"running","activeAttemptId":"a","requestedAt":"2026-01-01T00:00:00Z"}
            """.utf8))
        func turn(_ ordinal: Double, _ status: String) -> JSONValue {
            .object(["runAttemptId": .string("a"), "ordinal": .number(ordinal), "status": .string(status)])
        }
        #expect(!TimelineRunState.turnEnded(run, []))
        #expect(!TimelineRunState.turnEnded(run, [turn(1, "failed"), turn(2, "running")]))
        #expect(TimelineRunState.turnEnded(run, [turn(1, "running"), turn(2, "failed")]))
        var settled = run
        settled.status = .failed
        #expect(!TimelineRunState.turnEnded(settled, [turn(1, "failed")]))
    }

    // LT:3046
    @Test(arguments: [(WorkLogTone.tool, "Used 3 tools"), (.info, "Used 2 tools and received 1 update")])
    func expandsActivitiesThroughTheSameGroup(_ middleTone: WorkLogTone, _ summary: String) {
        let icon: JSONValue = .object(["_tag": .string("website"), "pageUrl": .string("https://example.com/checkout")])
        let entries = [
            work("work-entry-1", "work-1", at: "2026-01-01T00:00:01Z", label: "read") { $0.detail = "Reading package.json" },
            work("work-entry-2", "work-2", at: "2026-01-01T00:00:02Z", label: "Status updated", tone: middleTone) {
                $0.detail = "Editing MessagesTimeline.tsx"; $0.toolSurface = "computer"
            },
            work("work-entry-3", "work-3", at: "2026-01-01T00:00:03Z", label: "test") {
                $0.detail = "Running tests"; $0.toolSurface = "browser"; $0.toolIcon = icon
            },
        ]
        let collapsed = derive(entries)
        #expect(collapsed.map(\.id) == ["work-toggle:work-entry-1"])
        if case .workToggle(let t)? = collapsed.first?.kind {
            #expect(t.groupId == "work-group:work-entry-1" && t.hiddenCount == 3 && !t.expanded && t.summary == summary)
            #expect(t.toolSurface == "browser" && t.toolIcon == icon)
        } else {
            Issue.record("no toggle")
        }
        let expanded = derive(entries) { $0.expandedWorkGroupIds = ["work-group:work-entry-1"] }
        #expect(expanded.map(\.id) == ["work-toggle:work-entry-1", "work-group:work-entry-1:details"])
        if case .work(let grouped, true, _)? = expanded.last?.kind { #expect(grouped == entries.map { $0.work! }) } else { Issue.record("no body") }
        if case .workToggle(let t)? = expanded.first?.kind { #expect(t.expanded) }
    }

    private static func event(_ entryId: String, type: String, run: String?, at: T3Timestamp) -> TimelineEntry {
        let item = turnItem("{\"id\":\"\(entryId)-item\",\"type\":\"\(type)\",\"runId\":\(run.map { "\"\($0)\"" } ?? "null"),\"updatedAt\":\"\(at.raw)\"}")
        return TimelineEntry(id: entryId, createdAt: at, kind: .event(ProjectedTurnItem(local: item)))
    }

    // LT:3604
    @Test func foldsSettledTurnCommentaryAndWorkBehindAWorkedForRow() {
        let entries = [
            message("user-entry", "user-1", role: .user, at: "2026-01-01T00:00:00Z", text: "Build it"),
            message("assistant-thought-entry", "assistant-thought", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:05Z", updated: "2026-01-01T00:00:06Z"),
            work("work-entry-1", "work-1", run: "turn-1", at: "2026-01-01T00:00:08Z"),
            work("provider-recovered-entry", "provider-recovered", run: "turn-1", at: "2026-01-01T00:00:09Z",
                 label: "Provider recovered (2/5 retries)", tone: .info) { $0.itemType = .error; $0.toolLifecycleStatus = .completed },
            Self.event("thread-created-entry", type: "thread_created", run: nil, at: "2026-01-01T00:00:10Z"),
            message("assistant-final-entry", "assistant-final", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:20Z", updated: "2026-01-01T00:00:22Z"),
        ]
        let collapsed = derive(entries)
        guard case .turnFold(let run, let label, let open)? = collapsed.first(where: { kind($0) == "turn-fold" })?.kind else {
            Issue.record("no fold: \(collapsed.map(\.id))")
            return
        }
        #expect(run == "turn-1" && !open && label == "Worked for 22s")
        #expect(collapsed.map(\.id) == ["user-entry", "turn-fold:turn-1", "thread-created-entry", "assistant-final-entry"])
        let expanded = derive(entries) { $0.expandedRunIds = ["turn-1"] }
        #expect(expanded.map(\.id) == ["user-entry", "turn-fold:turn-1", "assistant-thought-entry", "work-toggle:work-entry-1",
                                        "thread-created-entry", "assistant-final-entry"])
        let opened = derive(entries) { $0.expandedRunIds = ["turn-1"]; $0.expandedWorkGroupIds = ["work-group:work-entry-1"] }
        if case .work(let grouped, true, _)? = opened.first(where: { kind($0) == "work" })?.kind {
            #expect(grouped.map(\.id) == ["work-1", "provider-recovered"])
        } else {
            Issue.record("no opened activity")
        }
    }

    // LT:3742
    @Test func hidesSubagentsInFoldedTurnsWhenTheyArriveBeforeCommentary() {
        let rows = derive([
            message("user-entry", "user-1", role: .user, at: "2026-01-01T00:00:00Z", text: "Spawn a subagent"),
            Self.event("subagent-card-entry", type: "subagent", run: "turn-1", at: "2026-01-01T00:00:03Z"),
            message("assistant-commentary-entry", "assistant-commentary", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:05Z", updated: "2026-01-01T00:00:06Z"),
            message("assistant-final-entry", "assistant-final", role: .assistant, run: "turn-1", at: "2026-01-01T00:00:20Z", updated: "2026-01-01T00:00:22Z"),
        ])
        #expect(rows.map(\.id) == ["user-entry", "turn-fold:turn-1", "assistant-final-entry"])
    }

    // 3105 9a01524f3 ("subagent continued by a later turn"): the resumed subagent keeps its first turn's place.
    @Test func resumedSubagentFoldsWithTheTurnThatStartedIt() {
        let rows = derive([
            message("prompt-1", role: .user, run: "run-1", at: "2026-10-09T10:00:00Z"),
            message("thought-1", role: .assistant, run: "run-1", at: "2026-10-09T10:00:01Z"),
            Self.event("subagent", type: "subagent", run: "run-2", at: "2026-10-09T10:00:02Z"),
            message("answer-1", role: .assistant, run: "run-1", at: "2026-10-09T10:00:03Z"),
            message("prompt-2", role: .user, run: "run-2", at: "2026-10-09T10:00:30Z"),
            message("answer-2", role: .assistant, run: "run-2", at: "2026-10-09T10:00:32Z"),
            work("send-message", run: "run-2", at: "2026-10-09T10:00:33Z"),
            message("closing-2", role: .assistant, run: "run-2", at: "2026-10-09T10:00:41Z"),
        ])
        #expect(rows.filter { kind($0) != "assistant-meta" }.map(\.id)
                == ["prompt-1", "turn-fold:run-1", "answer-1", "prompt-2", "turn-fold:run-2", "closing-2"])
    }

    // LT:2492
    @Test func doesNotTreatRunlessEntriesAsLiveWorkOnAThreadWithRuns() {
        let rows = derive([
            work("runless-command-entry", "runless-command", at: "2026-01-01T00:00:05Z", label: "Running git") {
                $0.command = "git status"; $0.requestKind = "command"; $0.toolLifecycleStatus = .inProgress
            },
        ]) {
            $0.latestRun = TimelineLatestRun(runId: "turn-1", status: .running, startedAt: "2026-01-01T00:00:00Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:00:00Z"
        }
        #expect(live(rows).isEmpty)
        #expect(rows.last.map(kind) == "thinking")
    }
}
