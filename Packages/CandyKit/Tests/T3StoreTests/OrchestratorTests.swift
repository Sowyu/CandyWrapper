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
    @Test func eventsInsideTwoMinutesGoOutAsOneMessage() {
        var batch = OrchestratorEventBatch()
        let deadline = batch.add([event("a")], now: now)
        #expect(deadline == now.addingTimeInterval(120))
        // Later events join the open window and arm nothing new.
        #expect(batch.add([event("b", .failed)], now: now.addingTimeInterval(50)) == nil)
        #expect(batch.add([event("c", .needsYou)], now: now.addingTimeInterval(119)) == nil)
        #expect(batch.flush(now: now.addingTimeInterval(119.9)) == nil)
        let message = batch.flush(now: now.addingTimeInterval(120))
        #expect(message?.split(separator: "\n").count == 3)
        #expect(message.map(OrchestratorEventBatch.isEventMessage) == true)
        #expect(batch.pending.isEmpty && batch.deadline == nil)
    }

    @Test func anEventAfterTheWindowOpensANewOne() {
        var batch = OrchestratorEventBatch()
        _ = batch.add([event("a")], now: now)
        _ = batch.flush(now: now.addingTimeInterval(120))
        let next = batch.add([event("b")], now: now.addingTimeInterval(150))
        #expect(next == now.addingTimeInterval(270))
        #expect(batch.flush(now: now.addingTimeInterval(270)) == event("b").line)
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
        #expect(batch.flush(now: now.addingTimeInterval(120), keep: { $0.threadId.rawValue == "b" }) == event("b").line)
        _ = batch.add([event("a")], now: now.addingTimeInterval(160))
        #expect(batch.flush(now: now.addingTimeInterval(280), keep: { _ in false }) == nil)
        #expect(batch.deadline == nil && batch.pending.isEmpty)
    }

    @Test func nothingArmsWithoutEvents() {
        var batch = OrchestratorEventBatch()
        #expect(batch.add([], now: now) == nil)
        #expect(batch.flush(now: now.addingTimeInterval(300)) == nil)
    }
}

@Suite struct OrchestratorEventDiffTests {
    let orchestrator = ThreadId("orch")

    func diff(_ old: [ThreadShell], _ new: [ThreadShell], handsOff: Set<ThreadId> = [], touched: Set<ThreadId> = []) -> [OrchestratorEvent] {
        OrchestratorEvent.diff(old: Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) }), new: new, orchestrator: orchestrator,
                               handsOff: { handsOff.contains($0) }, windowMinutes: 10, now: now, touched: { touched.contains($0.id) })
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

    /// A thread you wrote in within the window is your own conversation: its events wake nobody, unless the
    /// Orchestrator started it or prompted it.
    @Test func yourOwnRecentConversationsStayQuiet() {
        func yours(_ id: String, minutesAgo: Double, _ edit: (inout ThreadShell) -> Void = { _ in }) -> (ThreadShell, ThreadShell) {
            let before = thread(id) { $0.status = .running; $0.latestUserAuthoredMessageAt = ago(minutesAgo); $0.latestUserMessageAt = ago(minutesAgo); edit(&$0) }
            var after = before
            after.status = .completed
            return (before, after)
        }
        let recent = yours("mine", minutesAgo: 3)
        #expect(diff([recent.0], [recent.1]).isEmpty)
        // It prompted the thread or the relay launched it: still news, with the ask-first note.
        #expect(diff([recent.0], [recent.1], touched: [ThreadId("mine")]).map(\.permission) == [.askFirst(minutesAgo: 3)])
        // T3's tools launched it.
        let launched = yours("worker", minutesAgo: 3) { $0.createdBy = "agent" }
        #expect(diff([launched.0], [launched.1]).map(\.kind) == [.finished])
        // Past the window it's news again.
        let older = yours("old", minutesAgo: 20)
        #expect(diff([older.0], [older.1]).map(\.permission) == [.free])
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
    @Test func noOpRepliesAreKnownAndNewsIsNot() {
        for text in ["—", " — ", "-", "Nothing new.", "Nothing new for you.", "Still running.", "Still running, nothing new.",
                     "Nothing new yet.", "No changes.", "All quiet.", "Both still running.", "nothing to report", "Still working on it."] {
            #expect(OrchestratorReply.isNoop(text), "\(text)")
        }
        for text in ["The build is still running.", "Nothing new, but the release needs your approval.", "Done.",
                     "The fix is in.", "Still running the tests on the Mac mini, about 5 more minutes.", "Waiting on your approval."] {
            #expect(!OrchestratorReply.isNoop(text), "\(text)")
        }
    }

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

    /// The default brief keeps it quiet: the rules once, and none of the chatty ones before them.
    @Test func theDefaultBriefCarriesTheVoiceOnce() {
        let brief = render(OrchestratorBrief.defaultPrompt)
        #expect(brief.components(separatedBy: "# Talking to the user").count == 2)
        #expect(brief.contains("Stay quiet while work runs. No message for routine steps, retries, relays, reads, sends or pickup lines."))
        #expect(brief.contains("Speak only when something the user cares about is done, or when something needs them."))
        #expect(brief.contains("Then use 1 or 2 short sentences, the result first, in normal sentences."))
        #expect(brief.contains("No technical details, versions or ids unless asked. No lists or formatting unless asked. Never recap."))
        #expect(brief.contains("When an event brings nothing new for the user, reply with exactly \"—\" and nothing else besides any call or note. The app hides it."))
        #expect(brief.contains("Choices go through the question tool as tap options."))
        #expect(brief.contains("never write a note's contents into your reply"))
        for old in ["On it.", "pickup line first", "like a friend texting", "Reply in 1 to 3", "one short line or nothing at all", "straight opinion"] {
            #expect(!brief.contains(old), "\(old)")
        }
    }

    @Test func editedAndOlderPromptsGetTheVoiceLast() {
        let edited = render("You are {{name}}. Keep it short.")
        #expect(edited.hasSuffix(OrchestratorBrief.voiceSection))
        let older = render("# Talking to the user\n\n- One line per thread: name, state, next step.")
        #expect(older.hasSuffix(OrchestratorBrief.voiceSection))
        #expect(older.contains("These rules beat any other advice in this brief about how to reply."))
        // A saved prompt carries an older copy of the rules, here the one with the "On it." pickup line: it goes,
        // and what follows it stays.
        let saved = render("# Who you are\n\nYou are {{name}}.\n\n# Talking to the user\n\n- When you take on a task, send a quick pickup line first, like \"On it.\", then do the work.\n\n# Limits\n\nAt most {{crewLimit}} workers.")
        #expect(!older.contains("One line per thread"))
        #expect(!saved.contains("On it."))
        #expect(saved.components(separatedBy: "# Talking to the user").count == 2)
        #expect(saved.contains("You are Ada."))
        #expect(saved.contains("# Limits\n\nAt most 4 workers."))
        #expect(saved.hasSuffix(OrchestratorBrief.voiceSection))
    }
}
