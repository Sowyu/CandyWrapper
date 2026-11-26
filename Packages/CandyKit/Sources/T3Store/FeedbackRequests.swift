import Foundation
import T3Protocol

/// A `feedback_request` turn item's card (5258 packages/client-runtime/src/feedbackRequest.ts, T3 fe9c98c98f #35871):
/// an agent asks to send a problem report to the T3 team. The agent's turn never waits on it (FeedbackService.ts:214).
public enum FeedbackRequests {
    /// `TITLE` (FeedbackRequestCard.tsx:33).
    public static let title = "Feedback for the T3 team"

    public enum Display: Equatable, Sendable {
        case pending
        /// Inherited by a fork: only the thread that asked can answer it.
        case pendingElsewhere(label: String)
        case answered(sent: Bool, label: String)
    }

    /// `feedbackRequestDisplay` (feedbackRequest.ts:16-37).
    public static func display(status: String, visibility: String) -> Display {
        switch status {
        case "sent": .answered(sent: true, label: "Sent")
        case "declined": .answered(sent: false, label: "Not sent")
        case "cancelled": .answered(sent: false, label: "Closed without sending")
        default: visibility == "local" ? .pending : .pendingElsewhere(label: "Waiting in the original thread")
        }
    }

    /// `feedbackCardPreview` (:40-47): exactly what Send sends, the outline or, with the conversation, its text too.
    public static func preview(_ request: AgentFeedbackRequest, includeConversation: Bool) -> AgentFeedbackPreview {
        guard includeConversation, let trace = request.conversationTrace else { return request.preview }
        var preview = request.preview
        preview.trace = trace
        return preview
    }

    /// `KIND_LABELS` (:49-55).
    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "bug": "Bug"
        case "confusing": "Confusing"
        case "missing_capability": "Missing capability"
        case "wrong_docs": "Wrong docs"
        default: "Other"
        }
    }

    /// `feedbackPreviewFields` (:58-70): the report's fields in reading order, the empty ones left out.
    public static func fields(_ preview: AgentFeedbackPreview) -> [(label: String, value: String)] {
        [("Kind", kindLabel(preview.kind)), ("About", preview.subject), ("Expected", preview.expected),
         ("Happened", preview.actual), ("Did instead", preview.workaround)].filter { !$0.1.isEmpty }
    }

    private static func seconds(_ ms: Int) -> String {
        String(format: ms < 10_000 ? "%.1f s" : "%.0f s", Double(ms) / 1_000)
    }

    /// `feedbackTraceLines` (:75-104): one line per outline entry, plus the message text that goes with it.
    public static func traceLines(_ trace: AgentFeedbackTrace) -> [(line: String, text: String?)] {
        trace.entries.map { entry in
            let what: String
            if entry.type == "tool" {
                what = [entry.tool ?? "tool", entry.outcome, entry.durationMs.map(seconds)].compactMap { $0 }.joined(separator: " · ")
            } else {
                let count = entry.length ?? 0
                what = "\(entry.type == "user" ? "You" : "Agent") · \(count) \(count == 1 ? "character" : "characters")"
            }
            return ("Turn \(entry.turn) · \(what)", entry.text)
        }
    }

    /// `textSpan` (:109-114): counted back to the oldest turn with text.
    static func textSpan(_ trace: AgentFeedbackTrace) -> Int {
        let turns = trace.entries.filter { $0.text != nil }.map(\.turn)
        guard let oldest = turns.min() else { return 0 }
        return trace.turns - oldest + 1
    }

    /// `feedbackTraceSummary` (:117-124): what the outline holds, in one line.
    public static func traceSummary(_ trace: AgentFeedbackTrace) -> String {
        let turns = trace.turns == 1 ? "1 recent turn" : "\(trace.turns) recent turns"
        let span = textSpan(trace)
        let text = span == 0 ? "no message text" : span == 1 ? "message text of the last turn" : "message text of the last \(span) turns"
        return "Outline of \(turns), \(text)\(trace.truncated ? ", shortened to fit" : "")"
    }

    /// `feedbackConversationHint` (:127-134): what the conversation switch adds.
    public static func conversationHint(_ trace: AgentFeedbackTrace) -> String {
        let span = textSpan(trace)
        return "Adds the text of your messages and the agent's replies in the last \(span == 1 ? "turn" : "\(span) turns")."
    }

    /// `feedbackRequestFailureMessage` (:137-148): the server's own message, else a generic one.
    public static let genericFailure = "Could not send your answer. Try again."
}
