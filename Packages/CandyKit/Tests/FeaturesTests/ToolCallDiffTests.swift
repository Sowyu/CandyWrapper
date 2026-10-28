import AppKit
import Foundation
import Testing
import T3Protocol
import DesignSystem
@testable import Features

struct ToolCallDiffTests {
    func change(_ operation: String, _ path: String = "file with spaces.ts", old: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["operation": .string(operation), "path": .string(path)]
        if let old { fields["oldPath"] = .string(old) }
        return .object(fields)
    }

    @Test func bareHunksAndRenames() {
        for changes in [[], [change("update", "new.ts", old: "old.ts")]] {
            let preview = ToolCallDiff(fileName: "old.ts", diffStr: "@@ -1 +1 @@\n-before\n+after\n", changes: changes)
            let diff = UnifiedDiff(preview.patch ?? "")
            #expect(diff.files.map(\.path) == [changes.isEmpty ? "old.ts" : "new.ts"])
            #expect(diff.lines.map { diff.text($0) } == ["before", "after"])
        }
    }

    @Test func rawAddedAndDeletedContents() {
        let contents = ["first\nsecond", "@@ -0,0 +1 @@\n+content\n", "@@ -1 +0,0 @@\n-content\n",
            "first\nsecond\n", "--- notes\nsecond\n", "diff --git notes\nsecond\n",
            "--- a/embedded.ts\n+++ b/embedded.ts\n@@ -1 +1 @@\n-before\n+after\n",
            "diff --git a/embedded.ts b/embedded.ts\n--- a/embedded.ts\n+++ b/embedded.ts\n@@ -1 +1 @@\n-before\n+after\n"]
        for operation in ["add", "delete"] {
            for text in contents {
                let preview = ToolCallDiff(fileName: "file with spaces.ts", diffStr: text, changes: [change(operation)])
                let diff = UnifiedDiff(preview.patch ?? "")
                #expect(diff.files.map(\.path) == ["file with spaces.ts"])
                let expected = text.hasSuffix("\n") ? String(text.dropLast()) : text
                #expect(diff.lines.map { diff.text($0) }.joined(separator: "\n") == expected)
                #expect(diff.additions == (operation == "add" ? diff.lines.count : 0))
                #expect(diff.deletions == (operation == "delete" ? diff.lines.count : 0))
                #expect(diff.lines.last?.noNewline == !text.hasSuffix("\n"))
            }
        }
    }

    @Test func recordedContentAndEmptyFiles() {
        for operation in ["add", "delete"] {
            let preview = ToolCallDiff(fileName: "empty.ts", diffStr: "", changes: [change(operation, "empty.ts")])
            #expect(preview.content == [.init(label: operation == "add" ? "Recorded content after" : "Recorded content before", text: "")])
        }
        let preview = ToolCallDiff(fileName: "a.ts", oldStr: "before", newStr: "")
        #expect(preview.patch == nil)
        #expect(preview.content == [.init(label: "Recorded content before", text: "before"), .init(label: "Recorded content after", text: "")])
        #expect(!preview.truncated)
        #expect(ToolCallDiff(fileName: "a.ts", newStr: "after").content == [.init(label: "Recorded content after", text: "after")])
    }

    @Test func whitespaceKeepsOriginalTextAndLineNumbers() {
        let patch = ToolCallDiff(fileName: "a.ts", diffStr: "@@ -4,2 +4,2 @@\n-let a = 1\n-old\n+let a=1\n+new\n").patch!
        let diff = ToolCallDiff.render(patch, ignoringWhitespace: true)
        #expect(diff.additions == 1 && diff.deletions == 1)
        #expect(diff.lines.first?.kind == .context)
        #expect(diff.lines.first?.oldNumber == 4 && diff.lines.first?.newNumber == 4)
        #expect(diff.text(diff.lines[0]) == "let a=1")
        #expect(ToolCallDiff.render(patch, ignoringWhitespace: false).additions == 2)
    }

    @Test func truncation() {
        let suffix = "\n… output truncated for transport"
        let preview = ToolCallDiff(fileName: "a.ts", diffStr: "first\nsecond" + suffix, changes: [change("add", "a.ts")])
        #expect(preview.truncated)
        #expect(preview.patch?.contains("output truncated") == false)
        #expect(UnifiedDiff(preview.patch ?? "").additions == 2)
        let content = ToolCallDiff(fileName: "a.ts", newStr: "content" + suffix)
        #expect(content.truncated)
        #expect(content.content == [.init(label: "Recorded content after", text: "content")])
    }

    @Test func completePatchesAndUnsupportedOutput() {
        for operation in ["add", "delete"] {
            let added = operation == "add"
            let patch = "diff --git a/a.ts b/a.ts\n--- \(added ? "/dev/null" : "a/a.ts")\n+++ \(added ? "b/a.ts" : "/dev/null")\n\(added ? "@@ -0,0 +1 @@\n+content" : "@@ -1 +0,0 @@\n-content")\n"
            #expect(ToolCallDiff(fileName: "a.ts", diffStr: patch, changes: [change(operation, "a.ts")]).patch == patch)
        }
        for patch: String? in [nil, "", "provider output", "--- a/a.ts\n+++ b/a.ts\n@@ -1 +1 @@\n-a\n+b\n"] {
            #expect(ToolCallDiff(fileName: "a.ts", diffStr: patch).patch == patch)
        }
    }
}

@MainActor
struct ToolCallDiffPanelTests {
    func item(_ fields: [String: JSONValue] = [:]) throws -> TurnItem {
        var raw: [String: JSONValue] = ["id": .string("source-item"), "threadId": .string("source-thread"), "type": .string("file_change"),
            "ordinal": .number(1), "status": .string("completed"), "updatedAt": .string("2026-10-28T00:00:00Z"), "runId": .string("run"), "fileName": .string("a.ts")]
        raw.merge(fields) { _, new in new }
        return try TurnItem(json: .object(raw))
    }
    let target = ToolCallDiffTarget(threadId: "source-thread", itemId: "source-item", revision: "live", runId: "run", filePath: "a.ts")

    @Test func patchUsesSourceIdentityAndClearsOnClose() async throws {
        let detail = try item(["diffStr": .string("@@ -1 +1 @@\n-before\n+after\n")])
        let panel = DiffPanelView()
        panel.threadId = "viewing-thread"
        panel.toolCallLoader = { input in
            #expect(input.threadId == "source-thread" && input.itemId == "source-item" && input.revision == "live")
            return .init(item: detail)
        }
        panel.openToolCall(target)
        #expect(panel.message.text == "Loading tool call diff...")
        #expect(await eventually { panel.list.diff.files.count == 1 })
        #expect(panel.list.diff.additions == 1)
        panel.closeToolCall()
        #expect(panel.toolCallTarget == nil)
        #expect(panel.list.diff.files.isEmpty)
    }

    @Test func oldServerFallsBackButEmptyRecordedContentDoesNot() async throws {
        for fields: [String: JSONValue] in [[:], ["newStr": .string("")]] {
            let detail = try item(fields)
            let panel = DiffPanelView()
            panel.threadId = "viewing-thread"
            panel.setSummaries([.init(checkpointId: "c", scopeId: "s", runId: "run", checkpointTurnCount: 1,
                checkpointRef: "ref", status: "ready", files: [], assistantMessageId: nil, completedAt: "2026-10-28T00:00:00Z")])
            panel.toolCallLoader = { _ in .init(item: detail) }
            panel.loader = { _ in
                #expect(fields.isEmpty)
                return try JSONValue.object(["threadId": .string("viewing-thread"), "fromTurnCount": .number(0), "toTurnCount": .number(1),
                    "diff": .string("diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1 +1 @@\n-old\n+turn diff\n")]).decode(as: ThreadTurnDiff.self)
            }
            panel.openToolCall(target)
            #expect(await eventually { panel.message.text != "Loading tool call diff..." })
            if fields.isEmpty {
                #expect(await eventually { panel.list.diff.files.count == 1 })
                #expect(panel.toolCallTarget == nil)
                #expect(panel.list.diff.lines.map { panel.list.diff.text($0) }.contains("turn diff"))
            } else {
                #expect(panel.toolCallTarget != nil)
                #expect(panel.list.diff.files.isEmpty)
                let recorded = panel.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }.first
                #expect(recorded?.string.contains("Recorded content after\nEmpty content.") == true)
                panel.closeToolCall()
                #expect(recorded?.string.isEmpty == true)
            }
            panel.closeToolCall()
        }
    }

    @Test func truncatedPatchReportsOmittedFiles() async throws {
        let detail = try item(["diffStr": .string("@@ -1 +1 @@\n-a\n+b\n… output truncated for transport"),
            "changes": .array([.object(["operation": .string("update"), "path": .string("a.ts")]), .object(["operation": .string("update"), "path": .string("b.ts")])])])
        let panel = DiffPanelView()
        panel.toolCallLoader = { _ in .init(item: detail) }
        panel.openToolCall(target)
        #expect(await eventually { panel.list.diff.files.count == 1 })
        // Two bars, as DiffPanel.tsx:1043-1054 stacks them.
        let labels = panel.subviews.compactMap { $0 as? LabelView }.filter { !$0.isHidden }
        #expect(labels.contains { $0.text == "This preview exceeds the size limit. Changes shown are incomplete." })
        #expect(labels.contains { $0.text == "This tool call changed 2 files. The recorded patch omits 1 of them." })
        panel.closeToolCall()
    }

    @Test func failureAndLateReply() async throws {
        struct Failed: LocalizedError { var errorDescription: String? { "Detail failed" } }
        let panel = DiffPanelView()
        panel.toolCallLoader = { _ in throw Failed() }
        panel.openToolCall(target)
        #expect(await eventually { panel.errorLine.text == "Detail failed" })
        #expect(panel.message.text == "No patch available for this selection.")
        let detail = try item(["diffStr": .string("@@ -1 +1 @@\n-a\n+b\n")])
        actor Started {
            var value = false
            func mark() { value = true }
        }
        let started = Started()
        panel.toolCallLoader = { _ in
            await started.mark()
            try? await Task.sleep(for: .milliseconds(20))
            return .init(item: detail)
        }
        panel.openToolCall(target)
        #expect(await eventually { await started.value })
        panel.closeToolCall()
        try await Task.sleep(for: .milliseconds(40))
        #expect(panel.list.diff.files.isEmpty)
    }

    @Test func inheritedTargetRefreshesRevision() async throws {
        let detail = try item(["diffStr": .string("@@ -1 +1 @@\n-a\n+b\n")])
        let panel = DiffPanelView()
        panel.toolCallLoader = { _ in .init(item: detail) }
        panel.openToolCall(target)
        let row = ProjectedTurnItem(position: 0, visibility: "inherited", sourceThreadId: "source-thread", sourceItemId: "source-item", item: detail)
        panel.refreshToolCall([row])
        #expect(panel.toolCallTarget?.revision == detail.updatedAt.raw)
        #expect(await eventually { panel.list.diff.files.count == 1 })
        panel.closeToolCall()
    }
}
