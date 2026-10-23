import Foundation
import T3Protocol
import Testing
@testable import T3Store

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(_ minutes: Double) -> T3Timestamp { T3Timestamp(now.addingTimeInterval(-minutes * 60)) }
private func event(_ id: String, _ kind: OrchestratorEvent.Kind = .finished) -> OrchestratorEvent {
    OrchestratorEvent(threadId: ThreadId(id), title: id, kind: kind, permission: .free)
}

@Suite struct OrchestratorAskFirstTests {
    @Test func yourMessageInsideTheWindowAsksFirst() {
        let t = thread { $0.latestUserAuthoredMessageAt = ago(3.5); $0.latestUserMessageAt = ago(3.5) }
        #expect(OrchestratorPermission.of(t, handsOff: false, windowMinutes: 10, now: now) == .askFirst(minutesAgo: 3))
    }

    @Test func theWindowEndsAtTenMinutes() {
        let edge = thread { $0.latestUserAuthoredMessageAt = ago(10); $0.latestUserMessageAt = ago(10) }
        let inside = thread { $0.latestUserAuthoredMessageAt = ago(9.9); $0.latestUserMessageAt = ago(9.9) }
        #expect(OrchestratorPermission.of(edge, handsOff: false, windowMinutes: 10, now: now) == .free)
        #expect(OrchestratorPermission.of(inside, handsOff: false, windowMinutes: 10, now: now) == .askFirst(minutesAgo: 9))
    }

    @Test func aLaterPromptFromAnotherThreadMeansYouAlreadySaidGo() {
        let t = thread { $0.latestUserAuthoredMessageAt = ago(4); $0.latestUserMessageAt = ago(1) }
        #expect(OrchestratorPermission.of(t, handsOff: false, windowMinutes: 10, now: now) == .free)
    }

    @Test func threadsYouNeverWroteInAreFree() {
        let t = thread { $0.latestUserAuthoredMessageAt = nil; $0.latestUserMessageAt = ago(1) }
        #expect(OrchestratorPermission.of(t, handsOff: false, windowMinutes: 10, now: now) == .free)
    }

    @Test func handsOffWinsAndAZeroWindowNeverAsks() {
        let t = thread { $0.latestUserAuthoredMessageAt = ago(1); $0.latestUserMessageAt = ago(1) }
        #expect(OrchestratorPermission.of(t, handsOff: true, windowMinutes: 10, now: now) == .handsOff)
        #expect(OrchestratorPermission.of(t, handsOff: false, windowMinutes: 0, now: now) == .free)
    }

    @Test func eventLinesCarryTheNote() {
        let e = OrchestratorEvent(threadId: ThreadId("env:abc"), title: "Release notes", kind: .finished, permission: .askFirst(minutesAgo: 3))
        #expect(e.line == "Event: “Release notes” finished a turn (t3-thread://v1/abc). The user wrote there 3 min ago, so ask first.")
        let h = OrchestratorEvent(threadId: ThreadId("abc"), title: "X", kind: .needsYou, permission: .handsOff)
        #expect(h.line.hasSuffix("Hands off: report only, never prompt it."))
    }
}

@Suite struct OrchestratorBatchTests {
    @Test func eventsInsideThirtySecondsGoOutAsOneMessage() {
        var batch = OrchestratorEventBatch()
        let deadline = batch.add([event("a")], now: now)
        #expect(deadline == now.addingTimeInterval(30))
        // Later events join the open window and arm nothing new.
        #expect(batch.add([event("b", .failed)], now: now.addingTimeInterval(12)) == nil)
        #expect(batch.add([event("c", .needsYou)], now: now.addingTimeInterval(29)) == nil)
        #expect(batch.flush(now: now.addingTimeInterval(29.9)) == nil)
        let message = batch.flush(now: now.addingTimeInterval(30))
        #expect(message?.split(separator: "\n").count == 3)
        #expect(message.map(OrchestratorEventBatch.isEventMessage) == true)
        #expect(batch.pending.isEmpty && batch.deadline == nil)
    }

    @Test func anEventAfterTheWindowOpensANewOne() {
        var batch = OrchestratorEventBatch()
        _ = batch.add([event("a")], now: now)
        _ = batch.flush(now: now.addingTimeInterval(30))
        let next = batch.add([event("b")], now: now.addingTimeInterval(45))
        #expect(next == now.addingTimeInterval(75))
        #expect(batch.flush(now: now.addingTimeInterval(75)) == event("b").line)
    }

    @Test func aRepeatOfTheSameThreadAndKindSendsOneLine() {
        var batch = OrchestratorEventBatch()
        _ = batch.add([event("a"), event("a")], now: now)
        _ = batch.add([event("a"), event("a", .needsYou)], now: now.addingTimeInterval(5))
        #expect(batch.pending.count == 2)
    }

    @Test func eventsOfThreadsArchivedInsideTheWindowAreDropped() {
        var batch = OrchestratorEventBatch()
        _ = batch.add([event("a"), event("b")], now: now)
        #expect(batch.flush(now: now.addingTimeInterval(30), keep: { $0.threadId.rawValue == "b" }) == event("b").line)
        _ = batch.add([event("a")], now: now.addingTimeInterval(40))
        #expect(batch.flush(now: now.addingTimeInterval(70), keep: { _ in false }) == nil)
        #expect(batch.deadline == nil && batch.pending.isEmpty)
    }

    @Test func nothingArmsWithoutEvents() {
        var batch = OrchestratorEventBatch()
        #expect(batch.add([], now: now) == nil)
        #expect(batch.flush(now: now.addingTimeInterval(100)) == nil)
    }
}

@Suite struct OrchestratorEventDiffTests {
    let orchestrator = ThreadId("orch")

    func diff(_ old: [ThreadShell], _ new: [ThreadShell], handsOff: Set<ThreadId> = []) -> [OrchestratorEvent] {
        OrchestratorEvent.diff(old: Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) }), new: new, orchestrator: orchestrator,
                               handsOff: { handsOff.contains($0) }, windowMinutes: 10, now: now)
    }

    @Test func aTurnEndingFailingOrAskingIsAnEvent() {
        let running = thread("t") { $0.status = .running }
        #expect(diff([running], [thread("t") { $0.status = .completed }]).map(\.kind) == [.finished])
        #expect(diff([running], [thread("t") { $0.status = .failed }]).map(\.kind) == [.failed])
        let asking = thread("t") {
            $0.status = .waiting
            $0.pendingRuntimeRequest = PendingRuntimeRequestSummary(id: RuntimeRequestId("r1"), kind: .command, createdAt: ago(0))
        }
        #expect(diff([running], [asking]).map(\.kind) == [.needsYou])
        // The same request again is not new.
        #expect(diff([asking], [asking]).isEmpty)
    }

    @Test func theOrchestratorItsChildrenAndArchivedThreadsAreSkipped() {
        let old = [thread("orch") { $0.status = .running }, thread("child") { $0.status = .running; $0.lineage.parentThreadId = ThreadId("orch") },
                   thread("gone") { $0.status = .running }]
        let new = [thread("orch") { $0.status = .completed }, thread("child") { $0.status = .completed; $0.lineage.parentThreadId = ThreadId("orch") },
                   thread("gone") { $0.status = .completed; $0.archivedAt = ago(0) }]
        #expect(diff(old, new).isEmpty)
    }

    @Test func eventsCarryHandsOff() {
        let e = diff([thread("t") { $0.status = .running }], [thread("t") { $0.status = .completed }], handsOff: [ThreadId("t")])
        #expect(e.first?.permission == .handsOff)
    }
}

@Suite struct OrchestratorBriefTests {
    @Test func placeholdersFillAndTheModelsTableLeadsWithTheDefault() {
        var config = OrchestratorConfig()
        config.notebook["rules"] = "Ask before starting more than two threads."
        let brief = OrchestratorBrief.render(config.prompt, .init(
            name: "Orchestrator", machine: "mac-mini", projects: [("CandyWrapper", "p1", "/Users/me/CandyWrapper")], crewLimit: 4,
            models: config.models, notebook: config.notebook, handsOff: ["“Release notes” (t3-thread://v1/abc)"], askFirstMinutes: 10))
        #expect(!brief.contains("{{"))
        #expect(brief.contains("You are Orchestrator"))
        #expect(brief.contains("(mac-mini)"))
        #expect(brief.contains("- CandyWrapper (projectId p1): /Users/me/CandyWrapper"))
        #expect(brief.contains("Run at most 4 workers"))
        #expect(brief.contains("| Everyday work (default) | claudeAgent | claude-opus-5-5 | effort medium |"))
        #expect(brief.contains("| Audits | codex | gpt-6.1-sol | reasoningEffort medium |"))
        #expect(brief.contains("Ask before starting more than two threads."))
        #expect(brief.contains("- “Release notes” (t3-thread://v1/abc)"))
    }

    @Test func briefsSplitBackOut() {
        let first = OrchestratorBrief.first("B")
        #expect(OrchestratorBrief.split(first).brief == "B")
        let updated = OrchestratorBrief.split(OrchestratorBrief.updated("New brief\n\n# Limits\n- x", message: "Ship it"))
        #expect(updated.brief == "New brief\n\n# Limits\n- x")
        #expect(updated.updated && updated.message == "Ship it")
        #expect(OrchestratorBrief.split("hello").brief == nil)
        #expect(OrchestratorBrief.digest("a") != OrchestratorBrief.digest("b"))
    }

    @Test func configKeepsDefaultsForMissingKeys() throws {
        let c = try JSONDecoder().decode(OrchestratorConfig.self, from: Data(#"{"enabled":true,"crewLimit":2}"#.utf8))
        #expect(c.enabled && c.crewLimit == 2)
        #expect(c.models == OrchestratorModelRow.defaults)
        #expect(c.closedCheckMinutes == 30 && c.askFirstMinutes == 10)
        let off = try JSONDecoder().decode(OrchestratorConfig.self, from: Data(#"{"closedCheckMinutes":null}"#.utf8))
        #expect(off.closedCheckMinutes == nil)
        let round = try JSONDecoder().decode(OrchestratorConfig.self, from: JSONEncoder().encode(c))
        #expect(round == c)
    }

    @Test func theDefaultRowsMatchTheSpec() {
        let rows = OrchestratorModelRow.defaults
        #expect(rows.map(\.label) == ["Heavy work", "Audits", "Everyday work", "Quick changes"])
        #expect(OrchestratorConfig().defaultRow?.label == "Everyday work")
        #expect(rows[0].selection.optionSelections == [ProviderOptionSelection(id: "effort", value: .string("high"))])
    }
}

@Suite struct OrchestratorReplyTests {
    @Test func planAndMemoryBlocksLeaveTheProse() {
        let reply = OrchestratorReply.parse("""
        Here's the plan.

        ```orchestrator-plan
        1. [x] Write the notes ([Scribe](t3-thread://v1/th-1)), Opus, 10 min
        2. Review them, Sol, 5 min
        ```

        ```orchestrator-memory
        note: rules
        Ask before starting threads.
        ```
        Say go.
        """)
        #expect(reply.text == "Here's the plan.\n\nSay go.")
        #expect(reply.plan?.count == 2)
        #expect(reply.plan?[0].done == true && reply.plan?[0].threadId == "th-1")
        #expect(reply.plan.map { OrchestratorReply.displayText($0[0]) } == "Write the notes (Scribe), Opus, 10 min")
        #expect(reply.plan?[1].done == false && reply.plan?[1].threadId == nil)
        #expect(reply.memories == [.init(note: "rules", text: "Ask before starting threads.")])
    }

    @Test func anUnclosedBlockStaysHiddenAndOtherFencesStay() {
        let streaming = OrchestratorReply.parse("Plan:\n```orchestrator-plan\n1. Half")
        #expect(streaming.text == "Plan:" && streaming.plan == nil)
        let code = OrchestratorReply.parse("```swift\nlet x = 1\n```")
        #expect(code.text == "```swift\nlet x = 1\n```")
    }

    @Test func digestAndUnknownNotes() {
        let r = OrchestratorReply.parse("```orchestrator-digest\nNeeds you: nothing\n```\n```orchestrator-memory\nnote: secrets\nx\n```")
        #expect(r.digest == "Needs you: nothing")
        #expect(r.memories.isEmpty)
    }
}

@Suite struct OrchestratorNameTests {
    @Test func anEmptyNameFallsBackToOrchestrator() {
        var c = OrchestratorConfig()
        #expect(c.displayName == "Orchestrator")
        c.name = "  "
        #expect(c.displayName == "Orchestrator")
        c.name = " Ada "
        #expect(c.displayName == "Ada")
    }

    @Test func aRenameChangesTheBriefSoItGoesOutUpdated() {
        let c = OrchestratorConfig()
        func inputs(_ name: String) -> OrchestratorBrief.Inputs {
            .init(name: name, machine: "m", projects: [], crewLimit: 4, models: c.models, notebook: c.notebook, handsOff: [], askFirstMinutes: 10)
        }
        #expect(OrchestratorBrief.render(c.prompt, inputs("Ada")).contains("You are Ada,"))
        #expect(OrchestratorBrief.fingerprint(c.prompt, inputs("Ada")) != OrchestratorBrief.fingerprint(c.prompt, inputs("Orchestrator")))
    }
}

@Suite struct OrchestratorBriefToolsTests {
    /// Both sections reach every brief, an edited prompt's too.
    @Test func everyBriefRecommendsPagesAndTheQuestionTool() {
        let c = OrchestratorConfig()
        let brief = OrchestratorBrief.render("Custom prompt for {{name}}.", .init(
            name: "Ada", machine: "m", projects: [], crewLimit: 4, models: c.models, notebook: c.notebook, handsOff: [], askFirstMinutes: 10))
        #expect(brief.contains("check it with html_preview, then publish it with html_render before your reply"))
        #expect(brief.contains("AskUserQuestion on Claude, request_user_input on Codex"))
        #expect(brief.contains("Offer 2 to 4 short options"))
    }
}

@Suite struct OrchestratorVoiceTests {
    func render(_ prompt: String) -> String {
        let c = OrchestratorConfig()
        return OrchestratorBrief.render(prompt, .init(name: "Ada", machine: "m", projects: [], crewLimit: 4, models: c.models,
                                                      notebook: c.notebook, handsOff: [], askFirstMinutes: 10))
    }

    /// The default brief talks like a short, casual chat: the rules once, and none of the old report-style ones.
    @Test func theDefaultBriefCarriesTheVoiceOnce() {
        let brief = render(OrchestratorBrief.defaultPrompt)
        #expect(brief.components(separatedBy: "# Talking to the user").count == 2)
        #expect(brief.contains("Reply in 1 to 3 short sentences, in plain, casual words"))
        #expect(brief.contains("No lists, headers, bold, tables or code blocks unless the user asks"))
        #expect(brief.contains("Leave out commit hashes, file names, test counts, run ids and tool names"))
        #expect(brief.contains("When something needs the user, say that first, in one line."))
        #expect(brief.contains("never recap"))
        #expect(brief.contains("reply with one short line or nothing at all"))
        #expect(brief.contains("never write a note's contents into your reply"))
        for old in ["One line per thread", "using the digest format", "Lead with what needs them, then what's new"] {
            #expect(!brief.contains(old), "old reply rule left in: \(old)")
        }
    }

    /// An edited prompt, or an older default saved before this, gets the rules last, where they win.
    @Test func editedAndOlderPromptsGetTheVoiceLast() {
        let edited = render("You are {{name}}. Keep it short.")
        #expect(edited.hasSuffix(OrchestratorBrief.voiceSection))
        let older = render("# Talking to the user\n\n- One line per thread: name, state, next step.")
        #expect(older.hasSuffix(OrchestratorBrief.voiceSection))
        #expect(older.contains("These rules beat any other advice in this brief about how to reply."))
    }
}
