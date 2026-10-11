import AppKit
import Testing
import T3Protocol
import T3Store
import DesignSystem
@testable import Features

@MainActor
struct ThreadLeftoversTests {
    @Test func findNavigationWraps() {
        #expect(ThreadFindResult.step(0, count: 3, delta: -1) == 2)
        #expect(ThreadFindResult.step(2, count: 3, delta: 1) == 0)
        #expect(ThreadFindResult.step(0, count: 0, delta: -1) == 0)
    }
    @Test func searchResultDecodesOlderServersAndProgressiveExtras() throws {
        let result = try JSONValue(parsing: Data(#"{"snapshotSequence":10,"totalMatches":7,"activeIndex":2,"match":{"entryId":"item:1","runId":null,"occurrence":2},"complete":true}"#.utf8)).decode(as: ThreadFindResult.self)
        #expect(result.match?.occurrence == 2)
        #expect(result.totalMatches == 7)
    }
    @Test func planSubmissionChangesModeOnlyForImplementation() {
        let implement = ThreadPlanFollowUp.submission(draft: " \n", markdown: " # Plan\nDo it. \n")
        #expect(implement.text == "PLEASE IMPLEMENT THIS PLAN:\n# Plan\nDo it.")
        #expect(implement.mode == .default)
        let refine = ThreadPlanFollowUp.submission(draft: "  Use Swift  ", markdown: "# Plan")
        #expect(refine.text == "Use Swift")
        #expect(refine.mode == .plan)
    }
    @Test func widthsShareSettingAndPreserveSmallColumns() {
        #expect(ThreadChatWidth.maximum("comfortable") == 736)
        #expect(ThreadChatWidth.maximum("wide") == 1152)
        #expect(ThreadChatWidth.maximum("full") > 10000)
        let prior = ClientSettingsStore.shared.current.string("chatWidth")
        defer { ClientSettingsStore.shared.update(["chatWidth": .string(prior)]) }
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1500, height: 700))
        panel.setDraft(projectTitle: "Demo")
        ClientSettingsStore.shared.update(["chatWidth": .string("wide")])
        panel.layoutSubtreeIfNeeded()
        #expect(panel.composer.frame.width == 1152)
        ClientSettingsStore.shared.update(["chatWidth": .string("full")])
        panel.layoutSubtreeIfNeeded()
        #expect(panel.composer.frame.width == 1404)
    }
    @Test func usageFormattingAndClamping() {
        #expect(ThreadContextWindowUsage.tokens(999) == "999")
        #expect(ThreadContextWindowUsage.tokens(1500) == "1.5k")
        #expect(ThreadContextWindowUsage.tokens(12000) == "12k")
        #expect(ThreadContextWindowUsage.tokens(1500000) == "1.5m")
        let usage = ThreadContextWindowUsage(used: 200, maximum: 100, automatically: true)
        #expect(usage.percentage == 100)
        #expect(ThreadContextWindowUsage(used: 20, maximum: 0, automatically: false).percentage == nil)
    }
    @Test func liveUsageWinsOverProviderState() throws {
        var p = try #require(try ThreadPreview.projection(titled: ThreadPreview.commandsThread))
        p.providerTurns = [.object(["tokenUsage": .object(["usedTokens": .number(2100), "maxTokens": .number(10000)])])]
        p.providerThreads = [.object(["contextUsage": .object(["usedTokens": .number(9000)])])]
        let usage = try #require(ThreadContextWindowUsage.derive(p))
        #expect(usage.used == 2100)
        #expect(usage.percentage == 21)
        #expect(usage.total == nil)
    }
    @Test func rewindPreservesDraftAndNeverSelectsCurrentCheckpoint() throws {
        #expect(ThreadPromptRewind.restoredPrompt(draft: "Unsent", message: "Earlier") == "Unsent\n\nEarlier")
        #expect(ThreadPromptRewind.restoredPrompt(draft: "Unsent", message: "") == "Unsent")
        var p = try #require(try ThreadPreview.projection(titled: ThreadPreview.commandsThread))
        var message = try #require(TimelineRowsInput(projection: p).entries.compactMap(\.message).first { $0.role == .user })
        message.runId = RunId("run-two")
        message.inputIntent = .turnStart
        func checkpoint(_ id: String, run: String?, ordinal: Int?, within: Int) throws -> Checkpoint {
            try JSONValue.object([
                "id": .string(id), "threadId": .string(p.thread.id.rawValue), "scopeId": .string("scope"),
                "runId": run.map(JSONValue.string) ?? .null, "appRunOrdinal": ordinal.map { .number(Double($0)) } ?? .null,
                "ordinalWithinScope": .number(Double(within)), "ref": .string("ref"), "status": .string("ready"),
                "files": .array([]), "capturedAt": .string("2026-10-11T12:00:00.000Z")
            ]).decode(as: Checkpoint.self)
        }
        p.checkpoints = [try checkpoint("baseline", run: nil, ordinal: nil, within: 0),
                         try checkpoint("one", run: "run-one", ordinal: 1, within: 1),
                         try checkpoint("two", run: "run-two", ordinal: 2, within: 2)]
        let selected = try #require(ThreadPromptRewind.checkpoint(before: message, in: p))
        #expect(selected.id.rawValue == "one")
        let command = ThreadPromptRewind.command(threadId: p.thread.id, checkpoint: selected, restoreFiles: false, commandId: "test")
        #expect(command["restoreFiles"] == .bool(false))
        #expect(command["scopeId"]?.stringValue == "scope")
        message.runId = RunId("run-one")
        #expect(ThreadPromptRewind.checkpoint(before: message, in: p)?.id.rawValue == "baseline")
        p.checkpoints[0].status = "missing"
        #expect(ThreadPromptRewind.checkpoint(before: message, in: p) == nil)

    }
    @Test func findPaintDoesNotReconfigureRows() throws {
        let p = try #require(try ThreadPreview.projection(titled: ThreadPreview.commandsThread))
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        panel.setProjection(p, projectTitle: "Demo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        let count = panel.timeline.configureCount
        panel.timeline.threadFindQuery = "file"
        panel.timeline.layoutSubtreeIfNeeded()
        #expect(panel.timeline.configureCount == count)
        #expect(panel.timeline.layoutProblems().isEmpty)
    }
}
