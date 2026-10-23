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
}
