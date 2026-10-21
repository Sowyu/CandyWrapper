import Foundation
import T3Protocol
import Testing
@testable import T3Store

private func user(_ entryId: String, _ id: String, at: T3Timestamp, intent: InputIntent? = nil) -> TimelineEntry {
    .message(entryId, ChatMessage(id: MessageId(id), role: .user, text: id, createdAt: at, inputIntent: intent))
}

private func assistant(_ entryId: String, _ id: String, run: RunId?, at: T3Timestamp, updated: T3Timestamp, streaming: Bool = false) -> TimelineEntry {
    .message(entryId, ChatMessage(id: MessageId(id), role: .assistant, text: id, runId: run, streaming: streaming, createdAt: at, updatedAt: updated))
}

private func work(_ entryId: String, _ entry: WorkLogEntry, attempt: TimelineAttempt? = nil) -> TimelineEntry {
    .work(entryId, entry, attempt: attempt)
}

private func rows(_ entries: [TimelineEntry], _ edit: (inout TimelineRowsInput) -> Void = { _ in }) -> [TimelineRow] {
    var input = TimelineRowsInput(entries: entries)
    edit(&input)
    return TimelineRows.derive(input)
}

private func fold(_ rows: [TimelineRow]) -> (runId: RunId, label: String, expanded: Bool)? {
    for row in rows { if case .turnFold(let r, let l, let e) = row.kind { return (r, l, e) } }
    return nil
}

/// Ports of apps/web/src/components/chat/MessagesTimeline.logic.test.ts.
@Suite struct TimelineRowsTests {
    /// The row and entry payloads live in shared boxes (`indirect`). Inline, the largest case made each
    /// row 2 KB, and a long thread copies these arrays on every older page.
    @Test func rowsAndEntriesStaySmall() {
        #expect(MemoryLayout<TimelineRow>.stride <= 128)
        #expect(MemoryLayout<TimelineEntry>.stride <= 192)
    }

    // LT:1300
    @Test func foldsTheFirstAssistantMessageAndSettledWorkBeforeTheTerminalResponse() {
        let entries = [
            user("user-entry", "user-1", at: "2026-01-01T00:00:00Z"),
            assistant("assistant-first-entry", "assistant-first", run: "turn-1", at: "2026-01-01T00:00:05Z", updated: "2026-01-01T00:00:06Z"),
            work("work-entry-1", WorkLogEntry(id: "work-1", createdAt: "2026-01-01T00:00:08Z", runId: "turn-1", label: "Ran command", tone: .tool)),
            assistant("assistant-final-entry", "assistant-final", run: "turn-1", at: "2026-01-01T00:00:20Z", updated: "2026-01-01T00:00:22Z"),
        ]
        let collapsed = rows(entries)
        #expect(fold(collapsed)?.runId == "turn-1" && fold(collapsed)?.expanded == false)
        #expect(fold(collapsed)?.label == "Worked for 22s")
        #expect(collapsed.map(\.id) == ["user-entry", "turn-fold:turn-1", "assistant-final-entry"])
        let expanded = rows(entries) { $0.expandedRunIds = ["turn-1"] }
        #expect(expanded.map(\.id) == ["user-entry", "turn-fold:turn-1", "assistant-first-entry", "work-entry-1", "assistant-final-entry"])
        #expect(fold(expanded)?.expanded == true)
    }

    // 80df91b52b: an answered question keeps its own row outside tool groups and the turn fold.
    @Test func answeredQuestionsStayVisibleAfterTheTurnSettles() {
        let runId: RunId = "turn-1"
        func command(_ id: String, _ second: Int) -> TimelineEntry {
            work("\(id)-entry", WorkLogEntry(id: id, createdAt: T3Timestamp("2026-01-01T00:00:0\(second)Z"), runId: runId, label: "Ran command",
                                          tone: .tool, itemType: .commandExecution, toolLifecycleStatus: .completed))
        }
        let question = work("question-entry", WorkLogEntry(
            id: "question", createdAt: "2026-01-01T00:00:02Z", runId: runId, label: "Answered questions", tone: .info,
            itemType: .userInputRequest, questionAnswer: .object(["requestId": "scope"])))
        let entries = [
            user("user-entry", "user-1", at: "2026-01-01T00:00:00Z"), command("before", 1), question, command("after", 3),
            assistant("answer-entry", "answer", run: runId, at: "2026-01-01T00:00:05Z", updated: "2026-01-01T00:00:05Z"),
        ]
        let latest = TimelineLatestRun(runId: runId, status: .completed, startedAt: "2026-01-01T00:00:00Z", completedAt: "2026-01-01T00:00:06Z")
        #expect(rows(entries) { $0.latestRun = latest }.map(\.id) == ["user-entry", "turn-fold:turn-1", "question-entry", "answer-entry"])
        let expanded = rows(entries) { $0.latestRun = latest; $0.expandedRunIds = [runId] }
        #expect(expanded.contains { $0.id == "question-entry" && { if case .work(let g, _, _) = $0.kind { return g.count == 1 }; return false }($0) })
    }

    // LT:1401
    @Test(arguments: [1, 2, 3])
    func foldsCompletedActivitiesAfterTheTerminalResponse(_ count: Int) {
        let runId: RunId = "turn-1"
        let after = (0..<count).map { i in
            work("work-entry-after-text-\(i)", WorkLogEntry(
                id: "work-after-text-\(i)", createdAt: T3Timestamp("2026-01-01T00:00:0\(i + 7)Z"), runId: runId, label: "Ran command",
                tone: .tool, itemType: .commandExecution, toolLifecycleStatus: .completed))
        }
        let entries = [
            work("work-entry-before-text", WorkLogEntry(id: "work-before-text", createdAt: "2026-01-01T00:00:01Z", runId: runId, label: "Status updated", tone: .info)),
            assistant("assistant-final-entry", "assistant-final", run: runId, at: "2026-01-01T00:00:05Z", updated: "2026-01-01T00:00:06Z"),
        ] + after
        let latest = TimelineLatestRun(runId: runId, status: .completed, startedAt: "2026-01-01T00:00:00Z", completedAt: "2026-01-01T00:00:10Z")
        #expect(rows(entries) { $0.latestRun = latest }.map(\.id) == ["turn-fold:turn-1", "assistant-final-entry"])
        let expanded = rows(entries) { $0.latestRun = latest; $0.expandedRunIds = [runId] }
        #expect(expanded.contains { row in
            if row.id == "work-entry-after-text-0" { return true }
            if case .workToggle(let t) = row.kind { return row.id == "work-toggle:work-entry-after-text-0" && t.hiddenCount == count }
            return false
        })

        // A late failure stays visible even though successful work folds.
        var failed = entries
        failed[2].kind = .work({ var e = failed[2].work!; e.toolLifecycleStatus = .failed; return e }())
        #expect(rows(failed) { $0.latestRun = latest }.contains { $0.id == "work-entry-after-text-0" })

        var pending = entries
        pending[2].kind = .work({ var e = pending[2].work!; e.toolLifecycleStatus = .inProgress; return e }())
        let live = rows(pending) {
            $0.latestRun = TimelineLatestRun(runId: runId, status: .running, startedAt: "2026-01-01T00:00:00Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:00:00Z"
        }
        #expect(live.contains { if case .workLive(let e, _, _, _, _, _) = $0.kind { return e.id == "work-after-text-0" }; return false })
    }

    // LT:1502
    @Test func foldsAllAssistantMessagesBeforeTheTerminalMessage() {
        let entries = [
            assistant("assistant-first-entry", "a1", run: "turn-1", at: "2026-01-01T00:00:01Z", updated: "2026-01-01T00:00:02Z"),
            assistant("assistant-middle-entry", "a2", run: "turn-1", at: "2026-01-01T00:00:03Z", updated: "2026-01-01T00:00:04Z"),
            assistant("assistant-final-entry", "a3", run: "turn-1", at: "2026-01-01T00:00:05Z", updated: "2026-01-01T00:00:06Z"),
        ]
        #expect(rows(entries).map(\.id) == ["turn-fold:turn-1", "assistant-final-entry"])
    }

    // LT:1559
    @Test func durationOfASteerSupersededTurnSpansFromItsPrompt() {
        let entries = [
            user("user-entry", "user-1", at: "2026-01-01T00:00:00Z"),
            work("work-entry-before-message", WorkLogEntry(id: "w0", createdAt: "2026-01-01T00:00:07Z", runId: "turn-1", label: "Status updated", tone: .info)),
            assistant("assistant-commentary-entry", "c", run: "turn-1", at: "2026-01-01T00:00:09Z", updated: "2026-01-01T00:00:09Z"),
            work("work-entry-1", WorkLogEntry(id: "w1", createdAt: "2026-01-01T00:00:12Z", runId: "turn-1", label: "Ran command", tone: .tool)),
            user("steer-user-entry", "user-2", at: "2026-01-01T00:00:14Z"),
            assistant("assistant-next-turn-entry", "next", run: "turn-2", at: "2026-01-01T00:00:17Z", updated: "2026-01-01T00:00:17Z", streaming: true),
        ]
        let result = rows(entries) {
            $0.latestRun = TimelineLatestRun(runId: "turn-2", status: .running, startedAt: "2026-01-01T00:00:14Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:00:14Z"
        }
        #expect(fold(result)?.runId == "turn-1" && fold(result)?.label == "Worked for 12s")
    }

    // LT:1668
    @Test func usesLatestTurnTimingsAndTheStoppedLabelForAnInterruptedTurn() {
        let result = rows([work("work-entry-1", WorkLogEntry(id: "work-1", createdAt: "2026-01-01T00:00:05Z", runId: "turn-1", label: "Ran command", tone: .tool))]) {
            $0.latestRun = TimelineLatestRun(runId: "turn-1", status: .interrupted, startedAt: "2026-01-01T00:00:00Z", completedAt: "2026-01-01T00:00:47Z")
        }
        #expect(result.count == 1 && fold(result)?.label == "You stopped after 47s" && fold(result)?.expanded == false)
    }

    // LT:2527
    @Test func rendersASingleCompletedToolCallDirectly() {
        let entries = [
            work("completed-command-entry", WorkLogEntry(
                id: "completed-command", createdAt: "2026-01-01T00:00:05Z", runId: "turn-1", label: "Ran rg", command: "rg toolCall",
                tone: .tool, requestKind: "command", toolLifecycleStatus: .completed)),
            assistant("assistant-commentary-entry", "assistant-commentary", run: "turn-1", at: "2026-01-01T00:00:06Z", updated: "2026-01-01T00:00:06Z"),
            work("running-command-entry", WorkLogEntry(
                id: "running-command", createdAt: "2026-01-01T00:00:07Z", runId: "turn-1", label: "Running tests", command: "vp test run",
                tone: .tool, requestKind: "command", toolLifecycleStatus: .inProgress)),
        ]
        let result = rows(entries) {
            $0.latestRun = TimelineLatestRun(runId: "turn-1", status: .running, startedAt: "2026-01-01T00:00:00Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:00:00Z"
        }
        #expect(result.map(describe) == ["working", "work", "assistant", "work-live"])
        guard case .work(let grouped, false, let label) = result[1].kind else { Issue.record("not a work row"); return }
        #expect(grouped.map(\.id) == ["completed-command"] && label == "rg toolCall")
    }

    // LT:2768
    @Test(arguments: [
        (ToolLifecycleStatus?.none, Bool?.some(true)), (.inProgress, true), (.completed, false),
        (.failed, nil), (.declined, false), (.stopped, false),
    ])
    func respectsTheLifecycleOfTrailingTaskProgress(_ status: ToolLifecycleStatus?, _ active: Bool?) {
        let runId: RunId = "turn-task-progress"
        let result = rows([work("task-progress-entry", WorkLogEntry(
            id: "task-progress", createdAt: "2026-01-01T00:00:05Z", runId: runId, label: "Task progress", tone: .thinking,
            sourceActivityKind: "task.progress", toolLifecycleStatus: status))]) {
            $0.latestRun = TimelineLatestRun(runId: runId, status: .running, startedAt: "2026-01-01T00:00:00Z")
            $0.isWorking = true
            $0.activeTurnStartedAt = "2026-01-01T00:00:00Z"
        }
        let live = result.compactMap { row -> Bool? in if case .workLive(_, _, _, _, let a, _) = row.kind { return a }; return nil }.first
        if let active {
            #expect(live == active)
        } else {
            #expect(live == nil && result.last.map(describe) == "thinking" && result.last?.id == "live-activity-row")
        }
    }

    // LT:333 table: settled legacy T3 calls render directly with their completed label.
    @Test(arguments: [("preview_click", "Clicked in the preview browser"), ("task_status", "Got delegated task status")])
    func rendersASettledLegacyT3CallDirectly(_ tool: String, _ label: String) {
        let entry = WorkLogEntry(
            id: "tool-1", createdAt: "2026-09-01T12:00:00Z", label: "Tool call", tone: .tool,
            toolData: .object(["server": .string("t3-code"), "tool": .string(tool)]), itemType: .dynamicTool)
        let result = rows([work("browser-entry", entry)])
        guard case .work(let grouped, false, let display) = result.first?.kind else { Issue.record("no work row"); return }
        #expect(grouped.map(\.id) == ["tool-1"] && display == label)
    }

    @Test func dropsTheInterruptRequestAndKeepsTheResult() throws {
        let request = turnItem(#"{"id":"req","type":"run_interrupt_request","runId":"r2","message":"Interrupt requested"}"#)
        let result = turnItem(#"{"id":"res","type":"run_interrupt_result","runId":"r2","status":"interrupted","message":"Run interrupted"}"#)
        let entries = TimelineEntries.derive(visibleTurnItems: [request, result].map { ProjectedTurnItem(local: $0) })
        #expect(rows(entries).map(\.id) == ["res"])
    }

    // LT:3812 (only a superseded attempt's output collapses)
    @Test func collapsesOnlyTheSupersededAttempt() {
        let old = TimelineAttempt(id: "attempt-1", runId: "turn-1", rootNodeId: "root-1", status: "superseded")
        let current = TimelineAttempt(id: "attempt-2", runId: "turn-1", attemptOrdinal: 2, rootNodeId: "root-2", status: "running")
        let entries = [
            user("user-entry", "user-1", at: "2026-01-01T00:00:00Z"),
            work("old-work", WorkLogEntry(id: "old", createdAt: "2026-01-01T00:00:01Z", runId: "turn-1", label: "Ran command", tone: .tool, toolLifecycleStatus: .completed), attempt: old),
            user("steer-entry", "user-2", at: "2026-01-01T00:00:02Z", intent: .steer),
            assistant("answer-entry", "answer", run: "turn-1", at: "2026-01-01T00:00:03Z", updated: "2026-01-01T00:00:04Z"),
        ]
        var input = TimelineRowsInput(entries: entries)
        input.entries[3].attempt = current
        input.latestRun = TimelineLatestRun(runId: "turn-1", status: .running, startedAt: "2026-01-01T00:00:00Z")
        input.isWorking = true
        input.runningRunId = "turn-1"
        let result = TimelineRows.derive(input)
        #expect(result.map(\.id) == ["user-entry", "working-indicator-row", "attempt-fold:attempt-1", "steer-entry", "answer-entry", "live-activity-row"])
        input.expandedAttemptIds = ["attempt-1"]
        #expect(TimelineRows.derive(input).map(\.id).contains("old-work"))
    }

    @Test func movesTheFooterBelowToolRowsThatTrailTheAnswer() {
        let entries = [
            user("u", "u", at: "2026-01-01T00:00:00Z"),
            assistant("a", "a", run: "r", at: "2026-01-01T00:00:01Z", updated: "2026-01-01T00:00:02Z"),
            work("w1", WorkLogEntry(id: "w1", createdAt: "2026-01-01T00:00:03Z", runId: "r", label: "x", command: "ls", tone: .tool, toolLifecycleStatus: .failed)),
        ]
        let result = rows(entries) { $0.latestRun = TimelineLatestRun(runId: "r", status: .completed, startedAt: "2026-01-01T00:00:00Z", completedAt: "2026-01-01T00:00:04Z") }
        #expect(result.map(\.id) == ["u", "a", "w1", "assistant-meta:a"])
        guard case .message(_, _, let meta, let copy, _, _) = result[1].kind else { Issue.record("no message"); return }
        #expect(!meta && !copy)
    }

    @Test func marksAdjacentWorkRowsAsOneList() {
        let entries = [
            work("w1", WorkLogEntry(id: "w1", createdAt: "2026-01-01T00:00:01Z", runId: "r1", label: "x", command: "ls", tone: .tool, toolLifecycleStatus: .failed)),
            work("w2", WorkLogEntry(id: "w2", createdAt: "2026-01-01T00:00:02Z", runId: "r1", label: "y", command: "pwd", tone: .tool, toolLifecycleStatus: .failed)),
        ]
        let result = rows(entries) { $0.latestRun = TimelineLatestRun(runId: "r1", status: .failed, completedAt: "2026-01-01T00:00:03Z") }
        #expect(result.map(\.id) == ["w1", "w2"] && result.map(\.continuesWorkLog) == [true, false])
    }

    // LT:596
    /// A page that ends in reasoning without a completion: the old rows after it settle it, so the
    /// spliced front must show it settled, open or folded, settled or running.
    @Test(arguments: [false, true], [false, true])
    func pageEndingInOpenReasoningSettlesIt(_ expanded: Bool, _ working: Bool) {
        let reasoning = WorkLogEntry(id: "reason", createdAt: "2026-01-01T00:00:03Z", runId: "turn-1", label: "Thinking", detail: "Planning",
                                     tone: .thinking, itemType: .reasoning, toolLifecycleStatus: .inProgress)
        let page = [
            user("u1", "u1", at: "2026-01-01T00:00:00Z"),
            work("w1", WorkLogEntry(id: "w1", createdAt: "2026-01-01T00:00:02Z", runId: "turn-1", label: "Ran command", tone: .tool, itemType: .commandExecution, toolLifecycleStatus: .completed)),
            work("reason", reasoning),
        ]
        let old = [
            user("u2", "u2", at: "2026-01-01T00:00:10Z"),
            assistant("a2", "a2", run: "turn-2", at: "2026-01-01T00:00:12Z", updated: "2026-01-01T00:00:13Z"),
        ]
        func input(_ entries: [TimelineEntry]) -> TimelineRowsInput {
            var input = TimelineRowsInput(entries: entries)
            if expanded { input.expandedWorkGroupIds = ["work-group:w1"]; input.expandedRunIds = ["turn-1"] }
            if working {
                input.latestRun = TimelineLatestRun(runId: "turn-2", status: .running, startedAt: "2026-01-01T00:00:11Z")
                input.runningRunId = "turn-2"
                input.isWorking = true
                input.activeTurnStartedAt = "2026-01-01T00:00:11Z"
            }
            return input
        }
        var derived = TimelineRows.Derived(input(old))
        let splice = derived.prepend(input(page + old), count: page.count)
        #expect(splice != nil)
        #expect(derived.rows == TimelineRows.derive(input(page + old)))
    }

    @Test func copyStateNeedsSettledNonEmptyText() {
        #expect(TimelineRows.copyState(text: "Done", showCopyButton: true, streaming: false).visible)
        #expect(!TimelineRows.copyState(text: "Done", showCopyButton: true, streaming: true).visible)
        #expect(TimelineRows.copyState(text: "  ", showCopyButton: true, streaming: false) == (nil, false))
        #expect(!TimelineRows.copyState(text: "Done", showCopyButton: false, streaming: false).visible)
    }
}

/// `isWorkflowScriptMessage` (client-runtime state/subagentRuntime.ts:301-311).
@Suite struct WorkflowOpeningTests {
    @Test func theFlagWinsAndOlderThreadsFallBackToTheMetaExport() {
        #expect(WorkflowOpening.isScript(role: "user", text: "// plan\n/* x */\nexport const meta = {}", workflowScript: nil))
        #expect(!WorkflowOpening.isScript(role: "user", text: "please export const meta", workflowScript: nil))
        #expect(!WorkflowOpening.isScript(role: "user", text: "export const meta = {}", workflowScript: false))
        #expect(WorkflowOpening.isScript(role: "user", text: "prose", workflowScript: true))
        #expect(!WorkflowOpening.isScript(role: "assistant", text: "export const meta = {}", workflowScript: true))
    }
}
