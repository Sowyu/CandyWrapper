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
        let items = OrchestratorChat.items(messages: messages, turnItems: [], running: true, now: start)
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
        let items = OrchestratorChat.items(messages: messages, turnItems: [], running: false, now: start)
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

