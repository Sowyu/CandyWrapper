import Foundation
import T3Protocol
import Testing
@testable import T3Store

private func entry(_ id: String = "tool-1", label: String = "Tool call", tone: WorkLogTone = .tool, _ edit: (inout WorkLogEntry) -> Void = { _ in }) -> WorkLogEntry {
    var e = WorkLogEntry(id: id, createdAt: "2026-09-01T12:00:00Z", label: label, tone: tone)
    edit(&e)
    return e
}

private func dynamicTool(_ name: String, input: String) -> TurnItem {
    turnItem(#"{"id":"d","type":"dynamic_tool","toolName":"\#(name)","input":\#(input)}"#)
}

/// Ports of orchestrationTiming.test.ts, commandLabel.test.ts, toolOutput.test.ts,
/// presentation.test.ts and the "work entry labels" block of MessagesTimeline.logic.test.ts.
@Suite struct WorkLogTests {
    @Test func formatDurationPinnedValues() {
        let pins: [(Double, String)] = [
            (0, "1ms"), (250, "250ms"), (1_500, "1.5s"), (9_950, "10s"), (22_000, "22s"), (60_000, "1m"), (65_000, "1m 5s"),
            (119_500, "2m"), (3_599_499, "59m 59s"), (3_599_500, "1h"), (3_601_000, "1h 1s"), (3_660_000, "1h 1m"),
            (3_661_000, "1h 1m 1s"), (7_199_500, "2h"), (25_190_000, "6h 59m 50s"), (90_061_000, "25h 1m 1s"),
            (-1, "0ms"), (.nan, "0ms"), (.infinity, "0ms"), (-.infinity, "0ms"),
        ]
        for (ms, text) in pins { #expect(formatDuration(ms) == text, "\(ms)") }
    }

    @Test func commandDisplayTextUnwrapsPlainShellWrappers() {
        #expect(commandDisplayText("/bin/zsh -lc 'git diff --stat'") == "git diff --stat")
        #expect(commandDisplayText(#"bash -c "printf \"%s\" hello; git status""#) == #"printf "%s" hello; git status"#)
        #expect(commandDisplayText("/usr/bin/fish --command 'rg TODO src | head -20'") == "rg TODO src | head -20")
        #expect(commandDisplayText("zsh -lc 'pwd\nls'") == "pwd\nls")
        #expect(commandDisplayText(#"/bin/zsh -lc 'curl -H "Authorization: Bearer [REDACTED_SECRET]" https://example.com'"#)
            == #"curl -H "Authorization: Bearer [REDACTED_SECRET]" https://example.com"#)
        for kept in ["git status", "zsh script.sh", "zsh -lc 'echo $1' name value", "zsh -lc 'pwd'; git status", "zsh -lc 'unterminated"] {
            #expect(commandDisplayText(kept) == kept)
        }
        #expect(commandDisplayText("printf '\u{1B}[31m\u{07}\u{7F}'\tok\r\n") == "printf '\u{241B}[31m\u{2407}\u{2421}'\tok")
    }

    @Test func toolOutputFailurePhrases() {
        for text in ["FILE NOT FOUND", "No files found", "ENOENT", "No such file or directory", "CommandNotFoundException",
                     "command not found", "Cannot find path 'a' because it does not exist", "The term 'example' is not recognized",
                     "is not recognized as the name of a cmdlet", "A parameter cannot be found that matches parameter name",
                     "<exited with exit code 2>", "Exited with exit code 1", "exit code: 127"] {
            #expect(toolOutputIndicatesFailure(text), "\(text)")
        }
        for text in ["Done", "exit code: 0", "Exited with exit code 0", "cannot find path", "is not recognized"] {
            #expect(!toolOutputIndicatesFailure(text), "\(text)")
        }
    }

    @Test func smallTextHelpers() {
        #expect(normalizeCompactToolLabel("Ran command complete ") == "Ran command")
        #expect(normalizeCompactToolLabel("Read file Completed") == "Read file")
        #expect(formatTokens(39_602) == "39.6K" && formatTokens(1_000_000) == "1M" && formatTokens(804) == "804" && formatTokens(150_400) == "150K")
        #expect(formatCompactDiffCount(999) == "999" && formatCompactDiffCount(1_200) == "1.2k" && formatCompactDiffCount(1_000) == "1k")
        #expect(formatCompactDiffCount(12_345) == "12k" && formatCompactDiffCount(2_500_000) == "2.5m")
        #expect(liveThoughtLine("**Planning the fix**\nThen more.") == "Planning the fix")
        #expect(liveThoughtLine("Check `ordering` first. Then the rest.") == "Check ordering first.")
        #expect(formatWorkspaceRelativePath("/repo/demo/src/a.ts:12:3", workspaceRoot: "/repo/demo") == "demo/src/a.ts:12:3")
        #expect(formatWorkspaceRelativePath("src/a.ts", workspaceRoot: "/repo/demo/") == "demo/src/a.ts")
        #expect(formatWorkspaceRelativePath("/elsewhere/a.ts", workspaceRoot: "/repo/demo") == "/elsewhere/a.ts")
        #expect(formatWorkspaceRelativePath("/repo/demo", workspaceRoot: "/repo/demo") == "demo")
    }

    // LT:5196
    @Test func collapsesOnlyLongUserMessages() {
        #expect(!shouldCollapseUserMessage("short"))
        #expect(shouldCollapseUserMessage(String(repeating: "a", count: 601)))
        #expect(shouldCollapseUserMessage((1...9).map(String.init).joined(separator: "\n")))
        #expect(!shouldCollapseUserMessage((1...8).map(String.init).joined(separator: "\n")))
        // A long link collapses to its label first.
        #expect(!shouldCollapseUserMessage("[notes](https://example.com/\(String(repeating: "x", count: 700)))"))
        #expect(!shouldCollapseUserMessage("   \n  "))
    }

    // LT:99-352
    @Test func workEntryLabels() {
        let thought = entry(tone: .thinking) {
            $0.itemType = .reasoning
            $0.detail = "Check **ordering** first."
            $0.toolLifecycleStatus = .inProgress
        }
        #expect(WorkLog.liveLabel(thought, workspaceRoot: nil, active: true) == "Check **ordering** first.")
        #expect(WorkLog.liveLabel({ var t = thought; t.detail = "  "; return t }(), workspaceRoot: nil, active: true) == "Thinking")
        #expect(WorkLog.liveLabel({ var t = thought; t.detail = ""; t.toolLifecycleStatus = .completed; return t }(), workspaceRoot: nil, active: false) == "Thought")
        #expect(WorkLog.displayLabel(thought, workspaceRoot: nil) == "Check **ordering** first.")
        #expect(WorkLog.isVisibleInGroup(thought) && !WorkLog.isVisibleInGroup({ var t = thought; t.detail = " "; return t }()))

        let statuses: [(ToolLifecycleStatus, String)] = [
            (.inProgress, "Clicking in the preview browser"), (.completed, "Clicked in the preview browser"),
            (.failed, "Failed to click in the preview browser"), (.declined, "Declined to click in the preview browser"),
            (.stopped, "Stopped clicking in the preview browser"),
        ]
        for (status, label) in statuses {
            let browser = entry { $0.toolTitle = "T3-code.preview_click"; $0.detail = #"{"ok":true}"#; $0.toolLifecycleStatus = status }
            #expect(WorkLog.liveLabel(browser, workspaceRoot: nil, active: status == .inProgress) == label)
            #expect(WorkLog.displayLabel(browser, workspaceRoot: nil) == label)
        }
        let legacy = entry { $0.toolTitle = "T3-code.preview_click" }
        #expect(WorkLog.liveLabel(legacy, workspaceRoot: nil, active: true) == "Clicking in the preview browser")
        #expect(WorkLog.liveLabel(legacy, workspaceRoot: nil, active: false) == "Clicked in the preview browser")

        let read = entry(label: "Read") {
            $0.itemType = .dynamicTool
            $0.toolTitle = "Read"
            $0.detail = "---\nname: env\n---\n cons t x = 1"
            $0.toolData = .object(["input": .object(["file_path": .string("src/env.ts")])])
            $0.structuredPayload = dynamicTool("Read", input: #"{"file_path":"src/env.ts"}"#)
        }
        #expect(WorkLog.displayLabel(read, workspaceRoot: nil) == "Read src/env.ts")
        #expect(WorkLog.readOutput(read, workspaceRoot: nil) == "src/env.ts")
        #expect(WorkLog.readOutput(read, workspaceRoot: "/workspace/ohseearr") == "/workspace/ohseearr/src/env.ts")

        let grep = entry(label: "Grep") {
            $0.itemType = .dynamicTool
            $0.toolTitle = "Grep"
            $0.toolData = .object(["input": .object(["pattern": .string("TODO"), "path": .string("apps/web")])])
            $0.structuredPayload = dynamicTool("Grep", input: #"{"pattern":"TODO","path":"apps/web"}"#)
        }
        #expect(WorkLog.displayLabel(grep, workspaceRoot: nil) == "Searched TODO in web")
        #expect(WorkLog.toolGroupAction(grep) == .codeSearch && WorkLog.toolGroupAction(read) == .read)

        let fileSearch = entry(label: "Searched TODO in web") {
            $0.itemType = .fileSearch
            $0.toolTitle = "Searched TODO in web"
            $0.detail = "TODO"
            $0.toolData = .object(["type": .string("file_search"), "pattern": .string("TODO")])
        }
        #expect(WorkLog.displayLabel(fileSearch, workspaceRoot: nil) == "Searched TODO in web")

        let prompt = "Allow this command?\nrm -rf dist"
        #expect(WorkLog.displayLabel(entry { $0.itemType = .approvalRequest; $0.requestKind = "command"; $0.detail = prompt }, workspaceRoot: nil) == prompt)

        let unknown = entry { $0.toolTitle = "mcp__github__search_issues" }
        #expect(WorkLog.liveLabel(unknown, workspaceRoot: nil, active: true) == "Mcp__github__search_issues")
        #expect(WorkLog.displayLabel({ var u = unknown; u.detail = "Found 3 issues"; return u }(), workspaceRoot: nil) == "Found 3 issues")

        let command = entry { $0.command = "vp test run"; $0.detail = "All tests passed" }
        #expect(WorkLog.liveLabel(command, workspaceRoot: nil, active: true) == "Running vp")
        #expect(WorkLog.liveLabel(command, workspaceRoot: nil, active: false) == "Ran vp")
        #expect(WorkLog.displayLabel(command, workspaceRoot: nil) == "vp test run")
        let wrapped = entry { $0.command = "/bin/zsh -lc 'vp test run apps/web/src/session-logic.test.ts'" }
        #expect(WorkLog.liveLabel(wrapped, workspaceRoot: nil, active: true) == "Running vp")
        #expect(WorkLog.displayLabel(wrapped, workspaceRoot: nil) == "vp test run apps/web/src/session-logic.test.ts")
    }

    @Test func threadReadLabelsUseTheT3Table() {
        let threadRead = entry {
            $0.itemType = .dynamicTool
            $0.toolLifecycleStatus = .completed
            $0.structuredPayload = dynamicTool("t3-code.t3_thread_read", input: #"{"threadId":" thread-child "}"#)
        }
        #expect(WorkLog.displayLabel(threadRead, workspaceRoot: nil) == "Read a T3 thread")
        #expect(T3McpTools.definition("mcp__t3-code__delegate_task")?.summaryAction == "delegate")
        #expect(T3McpTools.definition("mcp__github__delegate_task") == nil)
        #expect(T3McpTools.definition("t3-code-thread_1_t3_thread_send")?.summaryAction == "thread-send")
        #expect(T3McpTools.definition("t3_code:preview_open")?.icon == "browser")
        #expect(T3McpTools.all.count == 84)
    }

    // presentation.test.ts:197-270
    @Test func summarizeToolGroup() {
        let thought = entry("thought", tone: .thinking) { $0.itemType = .reasoning; $0.detail = "Check the source" }
        let command = entry("command") { $0.itemType = .commandExecution; $0.command = "vp test run" }
        let thought2 = { var t = thought; t.id = "thought-2"; return t }()
        #expect(WorkLog.summarizeToolGroup([thought, command, thought2]) == ("Ran 1 command", false))
        #expect(WorkLog.toolGroupSummaryKind([thought, command]) == "command")
        #expect(WorkLog.summarizeToolGroup([thought]).summary == "Thought")
        #expect(WorkLog.summarizeToolGroup([thought, thought2]).summary == "Thought (×2)")
        #expect(WorkLog.toolGroupSummaryKind([thought]) == "reasoning")

        let created = entry("created", label: "Created thread") { $0.itemType = .threadCreated }
        #expect(WorkLog.summarizeToolGroup([command, created]).summary == "Ran 1 command and created 1 thread")

        let chrome = ToolActivitySource(key: "browser-use:chrome", name: "Chrome", kind: "integration")
        let git = entry("command", label: "Ran command") { $0.itemType = .commandExecution; $0.command = "git status" }
        #expect(WorkLog.summarizeToolGroup([
            entry("open", label: "Open page") { $0.toolSource = chrome },
            entry("inspect", label: "Inspect page") { $0.toolSource = chrome }, git,
        ]).summary == "Used Chrome integration and ran 1 command")
        #expect(WorkLog.summarizeToolGroup([
            entry("inspect", label: "Inspect page") { $0.toolSource = ToolActivitySource(key: "browser-use", name: "Browser", kind: "browser") },
            entry("click", label: "Click") { $0.toolSource = ToolActivitySource(key: "computer-use", name: "Computer Use", kind: "computer") },
        ]).summary == "Used Browser and Computer Use")
        #expect(WorkLog.toolGroupAction(entry { $0.itemType = .dynamicTool; $0.viewedImagePath = "/workspace/reference.png" }) == .read)
    }

    @Test func t3SummariesCountEffects() {
        let calls = (1...2).map { i in
            entry("send-\(i)") {
                $0.itemType = .dynamicTool
                $0.toolLifecycleStatus = .completed
                $0.structuredPayload = turnItem(#"""
                    {"id":"s\#(i)","type":"dynamic_tool","toolName":"mcp__t3-code__t3_thread_send","input":{"threadId":"t\#(i)"},
                     "output":{"content":[{"type":"text","text":"{\"messageId\":\"m\#(i)\",\"threadId\":\"t\#(i)\"}"}]}}
                    """#)
            }
        }
        #expect(WorkLog.summarizeToolGroup(calls).summary == "Sent messages to 2 threads")
        var failed = calls[0]
        failed.structuredPayload = turnItem(#"{"id":"f","type":"dynamic_tool","toolName":"t3-code.t3_thread_send","output":{"isError":true}}"#)
        #expect(WorkLog.displayIndicatesFailure(failed))
        #expect(WorkLog.summarizeToolGroup([failed]) == ("Tried to send 1 message", true))
    }

    // session-logic.test.ts "work-log failure policy" :1374
    @Test func failurePolicy() {
        let ok = entry { $0.itemType = .commandExecution; $0.command = "rg 'command not found'"; $0.toolLifecycleStatus = .completed }
        #expect(!WorkLog.displayIndicatesFailure(ok) && WorkLog.indicatesFailure(ok))
        let reported = entry { $0.itemType = .commandExecution; $0.command = "ls"; $0.detail = "ls: x: No such file or directory"; $0.toolLifecycleStatus = .completed }
        #expect(WorkLog.displayIndicatesFailure(reported))
        let exit = entry {
            $0.itemType = .commandExecution
            $0.command = "make"
            $0.toolLifecycleStatus = .completed
            $0.structuredPayload = turnItem(#"{"id":"c","type":"command_execution","input":"make","exitCode":2}"#)
        }
        #expect(WorkLog.displayIndicatesFailure(exit))
        let clean = entry { $0.itemType = .commandExecution; $0.command = "ls"; $0.toolLifecycleStatus = .completed }
        #expect(WorkLog.indicatesSuccess(clean) && !WorkLog.indicatesNeutral(clean))
        // 3315: a reasoning row's prose is not tool output, but an explicit failure still counts.
        let thinking = entry(tone: .thinking) { $0.itemType = .reasoning; $0.detail = "That exit code 2 is expected."; $0.toolLifecycleStatus = .completed }
        #expect(!WorkLog.indicatesFailure(thinking) && WorkLog.indicatesSuccess(thinking))
        #expect(WorkLog.indicatesFailure({ var f = thinking; f.toolLifecycleStatus = .failed; return f }()))
        let idle = entry { $0.toolLifecycleStatus = .idle }
        #expect(WorkLog.indicatesNeutral(idle) && !WorkLog.isVisibleInGroup(idle))
        #expect(WorkLog.isVisibleInGroup({ var s = idle; s.toolLifecycleStatus = .stopped; return s }()))
    }

    // session-logic.test.ts:112 provider retry labels
    @Test func providerErrorLabels() {
        func error(_ status: String, retry: String?) -> TurnItem {
            turnItem(#"""
                {"id":"e","type":"error","status":"\#(status)","title":"Overloaded",
                 "failure":{"class":"provider_error","message":"Overloaded.","code":"x","retryable":true}
                 \#(retry.map { ",\"retry\":\($0)" } ?? "")}
                """#)
        }
        #expect(WorkLog.providerErrorPresentation(error("failed", retry: nil)) == ("Overloaded", "Overloaded."))
        #expect(WorkLog.providerErrorPresentation(error("running", retry: #"{"attempt":2,"maxAttempts":5,"retryDelayMs":1500}"#))
            == ("Retrying provider (2/5)", "Overloaded. Retrying in 1.5s."))
        #expect(WorkLog.providerErrorPresentation(error("completed", retry: #"{"attempt":2,"maxAttempts":null,"retryDelayMs":0}"#)).label
            == "Provider recovered (2 retries)")
        #expect(WorkLog.providerErrorPresentation(error("failed", retry: #"{"attempt":5,"maxAttempts":5,"retryDelayMs":0}"#)).label
            == "Provider error after 5/5 retries")
    }
}

/// `contextCompactionLabel` (client-runtime work-log/presentation.ts:57-79).
@Suite struct ContextCompactionLabelTests {
    @Test func labelFollowsTheStatusAndTheRowSplitsAroundTheArrow() {
        func label(_ status: String, counts: Bool = true) -> String {
            let tokens = counts ? #","beforeTokenCount":12000,"afterTokenCount":5000"# : ""
            return WorkLog.contextCompactionLabel(turnItem(#"{"id":"c","type":"compaction","status":"\#(status)"\#(tokens)}"#))
        }
        #expect(label("failed") == "Context compaction failed")
        #expect(label("interrupted") == "Context compaction stopped")
        #expect(label("waiting") == "Compacting context")
        #expect(label("completed", counts: false) == "Context compacted")
        let done = label("completed")
        #expect(done.hasPrefix("Context compacted ") && done.hasSuffix(" tokens") && done.contains(" → "))
    }
}

/// Nightly 3473 T3 tool summaries (181fbb2b46; client-runtime t3ToolSummary.ts:398-424).
@Suite struct T3ToolSummary3473Tests {
    @Test func reviewGuidesCountTheirOutcomes() {
        func call(_ guides: [String]?) -> T3ToolSummaryCall {
            let output: JSONValue = guides.map { .object(["guides": .array($0.map { .object(["outcome": .string($0)]) })]) } ?? .object([:])
            return T3ToolSummaryCall(input: nil, output: output, outcome: "completed")
        }
        #expect(summarizeT3ToolCalls("write-pr-guides", [call(nil)]).label == "Started writing review guides")
        #expect(summarizeT3ToolCalls("write-pr-guides", [call(["started", "failed"])]) == ("Started 1 review guide, 1 failed", 2 - 1))
        #expect(summarizeT3ToolCalls("write-pr-guides", [call(["failed", "failed"])]).label == "Could not start 2 review guides")
        #expect(T3McpTools.all["unwatch_pull_request"]?.running == "Unwatching")
        #expect(T3McpTools.all["task_cancel"]?.detail == "a delegated task")
    }
}
