import AppKit
import Foundation
import T3Protocol
import T3Store
import Testing
@testable import Features

@Suite struct OrchestratorChatTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func message(_ id: String, _ role: String, _ text: String, minutes: Double, run: String? = nil) -> ConversationMessage {
        var json: [String: Any] = [
            "id": id, "threadId": "orch", "role": role, "text": text, "streaming": false,
            "createdAt": T3Timestamp(start.addingTimeInterval(minutes * 60)).raw,
            "updatedAt": T3Timestamp(start.addingTimeInterval(minutes * 60)).raw,
        ]
        if let run { json["runId"] = run }
        return try! JSONDecoder().decode(ConversationMessage.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func stacksTimesReadAndTyping() {
        let messages = [
            message("m0", "user", OrchestratorBrief.first("You are the Orchestrator."), minutes: 0),
            message("m1", "user", "Ship the notes", minutes: 1),
            message("m2", "user", "Then review them", minutes: 1.5),
            message("m3", "assistant", "On it.", minutes: 2),
            message("m4", "assistant", "```orchestrator-plan\n1. Write ([Scribe](t3-thread://v1/w1))\n```", minutes: 2.1),
            message("m5", "user", "Event: “Scribe” finished a turn (t3-thread://v1/w1).", minutes: 40),
        ]
        let items = OrchestratorChat.items(messages: messages, turnItems: [], running: true, activity: true, now: start)
        let kinds = items.map { item -> String in
            switch item {
            case .time: "time"
            case .brief: "brief"
            case .line(_, let text, let thread): "line:\(text):\(thread ?? "")"
            case .bubble(_, let user, _, let first, let last): "\(user ? "me" : "bot")\(first ? "^" : "")\(last ? "$" : "")"
            case .plan(_, let steps): "plan:\(steps.first?.threadId ?? "")"
            case .memory: "memory"
            case .read: "read"
            case .typing: "typing"
            case .image: "image"
            case .html: "html"
            }
        }
        #expect(kinds == ["time", "brief", "me^", "me$", "read", "bot^$", "plan:w1", "time", "line:“Scribe” finished a turn:w1", "typing"])
    }

    @Test func noReadBeforeTheTurnStarts() {
        let items = OrchestratorChat.items(messages: [message("m1", "user", "Hi", minutes: 0)], turnItems: [], running: false, now: start)
        #expect(!items.contains(.read(id: "read")))
        #expect(!items.contains(.typing))
    }

    @Test func updatedBriefsSplitIntoACardAndYourBubble() {
        let text = OrchestratorBrief.updated("New brief", message: "Go")
        let items = OrchestratorChat.items(messages: [message("m1", "user", text, minutes: 0)], turnItems: [], running: false, now: start)
        #expect(items.contains(.brief(id: "brief-m1", text: "New brief", updated: true)))
        #expect(items.contains(.bubble(id: "m1", fromUser: true, text: "Go", first: true, last: true)))
    }

    /// Threads T3's tools launch have ids like `mcp:<uuid>`; the line still drops its link and names the thread.
    @Test func eventLinesNameThreadsWithColonIds() {
        let e = OrchestratorChat.eventLine("Event: “Counter” finished a turn (t3-thread://v1/mcp:32a7b575-7401). Hands off: report only, never prompt it.")
        #expect(e.text == "“Counter” finished a turn")
        #expect(e.threadId == "mcp:32a7b575-7401")
        let plan = OrchestratorReply.parse("```orchestrator-plan\n1. Count ([Counter](t3-thread://v1/mcp:32a7))\n```").plan
        #expect(plan?.first?.threadId == "mcp:32a7")
        #expect(plan.map { OrchestratorReply.displayText($0[0]) } == "Count (Counter)")
    }

    /// By default the chat shows only what you and it said: no event, result or tool lines, no time label left over
    /// from them, and no reply that only says nothing is new.
    @Test func activityAndNoOpRepliesStayOutByDefault() throws {
        let tool = try JSONDecoder().decode(TurnItem.self, from: JSONSerialization.data(withJSONObject: [
            "id": "ti-1", "threadId": "orch", "type": "dynamic_tool", "ordinal": 1, "status": "completed", "runId": "run-2",
            "updatedAt": T3Timestamp(start).raw, "toolName": "mcp__t3-code__t3_thread_read",
        ] as [String: Any]))
        let messages = [
            message("m1", "user", "Ship the notes", minutes: 0),
            message("m2", "assistant", "On it.", minutes: 0.5),
            message("m3", "user", "Event: “Scribe” finished a turn (t3-thread://v1/w1).", minutes: 40),
            message("m4", "assistant", "Nothing new.", minutes: 40.5, run: "run-2"),
            message("m5", "user", "Event: “Scribe” finished a turn (t3-thread://v1/w1).", minutes: 60),
            message("m6", "assistant", "—", minutes: 60.5),
            message("m7", "assistant", "The notes are out.", minutes: 80),
        ]
        let items = OrchestratorChat.items(messages: messages, turnItems: [tool], running: false, now: start)
        let kinds = items.map { item -> String in
            switch item {
            case .time: "time"
            case .bubble(_, let user, let text, _, _): "\(user ? "me" : "bot"):\(text)"
            case .line(_, let text, _): "line:\(text)"
            case .read: "read"
            default: "other"
            }
        }
        #expect(kinds == ["time", "me:Ship the notes", "read", "bot:On it.", "time", "bot:The notes are out."])
        let shown = OrchestratorChat.items(messages: messages, turnItems: [tool], running: false, activity: true, now: start)
        #expect(shown.contains { if case .line(_, let text, _) = $0 { text == "“Scribe” finished a turn" } else { false } })
        #expect(shown.contains { if case .line(_, let text, _) = $0 { text.hasPrefix("Used 1 tool") } else { false } })
        #expect(!shown.contains { if case .bubble(_, _, let text, _, _) = $0 { text == "Nothing new." || text == "—" } else { false } })
    }

    /// T3 delivers a delegated task's result into the thread as a user message. It's activity, never your bubble.
    @Test func delegatedTaskDeliveriesAreActivityNotYourMessages() throws {
        // The user's screenshot: the bare delivery, as T3 3473 writes it (Orchestrator.ts:614-633).
        let delivered = message("m2", "user", "Delegated task node:delegated-task:command%3Amcp%3Af59f4d6c-948c-4cb0-b656-0bcae36f7f6d%3Adelegate-task%3Adc63307c [completed]:\nYour message only says \"placeholder\", so I don't have a task to work on yet. What should I do?", minutes: 1)
        // With a title and T3's own marker, failed.
        var marked = message("m3", "user", "Delegated task t-9 (Fixer) [failed]:\nTests still fail.\n\nDelegated task t-10 (Docs) [completed]. Use task_status with taskId t-10 to read the result.", minutes: 2)
        marked.delegatedCompletion = .object(["parentRunId": .string("run-1"), "generation": .number(1), "taskIds": .array([.string("t-9"), .string("t-10")])])
        var question = message("m4", "user", "Delegated task t-11 asked a question and is still working. Read it with t3_pending_request_read.", minutes: 3)
        question.notification = .object(["summary": .string("Delegated task \"Scout\" has a question")])
        let messages = [message("m1", "user", "ok but it doesnt seem like their making anything rn whats going on", minutes: 0), delivered, marked, question,
                        message("m5", "user", "Please read the Delegated task notes later", minutes: 4)]
        func bubbles(_ items: [OrchestratorChatItem]) -> [String] {
            items.compactMap { if case .bubble(_, let user, let text, _, _) = $0 { "\(user ? "me" : "bot"):\(text)" } else { nil } }
        }
        let hidden = OrchestratorChat.items(messages: messages, turnItems: [], running: false, now: start)
        #expect(bubbles(hidden) == ["me:ok but it doesnt seem like their making anything rn whats going on", "me:Please read the Delegated task notes later"])
        #expect(!hidden.contains { if case .line = $0 { true } else { false } })
        let shown = OrchestratorChat.items(messages: messages, turnItems: [], running: false, activity: true, now: start)
        let lines = shown.compactMap { if case .line(_, let text, _) = $0 { text } else { nil } }
        #expect(lines == ["A delegated task finished", "“Fixer” failed", "“Docs” finished", "A delegated task has a question"])
        #expect(bubbles(shown) == bubbles(hidden))
    }

    /// A scheduled task bound to its thread sends prompts as user messages; they're the schedule's, not yours.
    @Test func scheduledPromptsAreActivity() {
        var check = message("m2", "user", "Space build check: list the CandyWrapper threads that aren't settled, read only what changed.", minutes: 30)
        check.scheduledTaskId = "scheduled-task:space"
        var again = message("m3", "user", check.text, minutes: 60)
        again.scheduledTaskId = "scheduled-task:space"
        let messages = [message("m1", "user", "Build Space", minutes: 0), check, again]
        let hidden = OrchestratorChat.items(messages: messages, turnItems: [], running: false, now: start)
        let bubbles = hidden.compactMap { if case .bubble(_, _, let text, _, _) = $0 { text } else { nil } }
        #expect(bubbles == ["Build Space"])
        let shown = OrchestratorChat.items(messages: messages, turnItems: [], running: false, activity: true, now: start)
        let lines = shown.compactMap { if case .line(_, let text, _) = $0 { text } else { nil } }
        #expect(lines == ["Scheduled: Space build check", "Scheduled: Space build check"])
        #expect(OrchestratorChat.scheduledLine("Remind me to stretch every hour and also drink some water and check the build status") == "Scheduled: Remind me to stretch every hour and also drink some water an…")
    }

    /// Images ride on the user-message turn item; a message of images only hides T3's stand-in text.
    @Test func sentImagesShowBeforeTheBubble() throws {
        let item = try JSONDecoder().decode(TurnItem.self, from: JSONSerialization.data(withJSONObject: [
            "id": "ti-1", "threadId": "orch", "type": "user_message", "ordinal": 1, "status": "completed", "messageId": "m1",
            "updatedAt": T3Timestamp(start).raw,
            "attachments": [["type": "image", "id": "att-1", "name": "shot.png", "mimeType": "image/png", "sizeBytes": 10]],
        ] as [String: Any]))
        let alone = OrchestratorChat.items(messages: [message("m1", "user", ComposerAttachmentRules.attachmentOnlyPrompt, minutes: 0)],
                                           turnItems: [item], running: false, now: start)
        #expect(alone.contains(.image(id: "image-m1-0", attachmentId: "att-1", name: "shot.png")))
        #expect(!alone.contains { if case .bubble = $0 { true } else { false } })
        let withText = OrchestratorChat.items(messages: [message("m1", "user", "What's in this?", minutes: 0)], turnItems: [item],
                                              running: false, now: start)
        let kinds = withText.compactMap { i -> String? in
            switch i { case .image: "image"; case .bubble: "bubble"; default: nil }
        }
        #expect(kinds == ["image", "bubble"])
    }

    /// A page it published with html_render shows above that turn's reply.
    @Test func publishedPagesSitAboveTheReply() throws {
        let tool = try JSONDecoder().decode(TurnItem.self, from: JSONSerialization.data(withJSONObject: [
            "id": "ti-2", "threadId": "orch", "type": "dynamic_tool", "ordinal": 2, "status": "completed", "runId": "run-1",
            "updatedAt": T3Timestamp(start).raw, "toolName": "mcp__t3-code__html_render",
            "output": ["htmlRender": ["attachmentId": "page-1", "title": "Plan", "height": 400]],
        ] as [String: Any]))
        let items = OrchestratorChat.items(messages: [message("m2", "assistant", "Here it is.", minutes: 0, run: "run-1")],
                                           turnItems: [tool], running: false, now: start)
        let kinds = items.compactMap { i -> String? in
            switch i { case .html(_, let page): "html:\(page.attachmentId)"; case .bubble: "bubble"; default: nil }
        }
        #expect(kinds == ["html:page-1", "bubble"])
    }

    /// The Overview's groups: work under way, work done, and work that stopped short.
    @Test func overviewGroups() {
        #expect(OrchestratorCrewCard.group(.working, completedTurn: true) == .running)
        #expect(OrchestratorCrewCard.group(.approval, completedTurn: false) == .running)
        #expect(OrchestratorCrewCard.group(.ready, completedTurn: true) == .finished)
        #expect(OrchestratorCrewCard.group(.ready, completedTurn: false) == .stopped)
        #expect(OrchestratorCrewCard.group(.failed, completedTurn: true) == .stopped)
        #expect(OrchestratorCrewCard.group(.limited, completedTurn: true) == .stopped)
    }

    @Test func relayResultsAndCallsDrawAsLinesNotBubbles() {
        let messages = [
            message("m1", "assistant", "Looking.\n\n```orchestrator-call\n{\"tool\":\"list\"}\n```", minutes: 0),
            message("m2", "user", "Result: listed 3 threads on 2 machines\n## miniko\n- x\n\nResult: sent to “Fixer” on MacBook", minutes: 1),
        ]
        let items = OrchestratorChat.items(messages: messages, turnItems: [], running: false, activity: true, now: start)
        let lines = items.compactMap { item -> String? in if case .line(_, let text, _) = item { text } else { nil } }
        #expect(lines == ["Listed 3 threads on 2 machines", "Sent to “Fixer” on MacBook"])
        let bubbles = items.compactMap { item -> String? in if case .bubble(_, _, let text, _, _) = item { text } else { nil } }
        #expect(bubbles == ["Looking."])
    }
}

/// The Orchestrator's draft lives in the thread composer's store (`ComposerController.setDraftText`, saved to
/// `composer.prompts.v1`). The app makes a fresh pane each time you come back; here a dictionary stands in for
/// the store, and the pane must report every edit, show the stored draft again, and clear it on send.
@MainActor @Suite struct OrchestratorDraftTests {
    final class Store { var drafts: [String: String] = [:] }

    func pane(_ store: Store) -> OrchestratorPaneView {
        let p = OrchestratorPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        var s = OrchestratorPaneState()
        s.started = true
        s.connected = true
        p.set(s)
        p.onDraftChange = { store.drafts["orch"] = $0.isEmpty ? nil : $0 }
        p.setDraft(store.drafts["orch"] ?? "")
        return p
    }

    /// The stash key sends the draft to the stash; the list shows the entries as the thread composer's rows.
    @Test func theStashKeyStashesTheDraft() {
        let p = pane(Store())
        var stashed: String?
        p.onStash = { stashed = $0 }
        p.setDraft("Plan the launch")
        p.stashDraft()
        #expect(stashed == "Plan the launch")
        // Stashing clears the field even while you type in it, which a stored draft never does.
        p.window?.makeFirstResponder(nil)
        p.replaceDraft("")
        #expect(p.draft.isEmpty)
        let rows = OrchestratorPaneView.menuEntries([OrchestratorStashEntry(id: "s1", prompt: "Plan the launch", createdAt: "2026-10-24T10:00:00.000Z")])
        #expect(rows.map(\.id) == ["s1"])
        #expect(rows.first?.snippet == "Plan the launch")
        #expect(rows.first?.attachments.isEmpty == true)
    }

    @Test func aDraftSurvivesLeavingAndComingBack() {
        let store = Store()
        var first: OrchestratorPaneView? = pane(store)
        first?.setDraft("Plan the release notes")
        #expect(store.drafts["orch"] == "Plan the release notes")
        first = nil
        let back = pane(store)
        #expect(back.draft == "Plan the release notes")
        var sent: String?
        back.onSend = { sent = $0 }
        back.composer.submit()
        #expect(sent == "Plan the release notes")
        #expect(store.drafts["orch"] == nil)
        #expect(pane(store).draft.isEmpty)
    }
}

