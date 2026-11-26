import Foundation

// Agent feedback (5258 packages/contracts/src/agentFeedback.ts, orchestrationV2.ts:1897-1907, rpc.ts:661, 2445;
// T3 commit fe9c98c98f). Off unless `ServerSettings.agentFeedback.mode` is `on-request` or `auto`
// (settings.ts:1172, 1431); gated by the `agentFeedback` capability (environment.ts:226).
//
// The agent's `t3_feedback` tool does not wait for the card: it answers `{status: "awaiting_approval"}` at once and
// tells the agent not to wait (apps/server/src/feedback/FeedbackService.ts:214, FeedbackReport.ts:58-66). So an
// unanswered card never holds a turn. `FeedbackRequestRowView` draws the card.

/// `AgentFeedbackTrace` (agentFeedback.ts:13-33): built by the server from the thread's stored items.
public struct AgentFeedbackTrace: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var turn: Int
        /// `user`, `assistant` or `tool`.
        public var type: String
        public var tool: String?
        /// `ok`, `error` or `unfinished`.
        public var outcome: String?
        public var durationMs: Int?
        /// A message's length in characters.
        public var length: Int?
        public var text: String?
    }
    public var turns: Int
    public var textTurns: Int
    /// A cap dropped an entry or cut a message text.
    public var truncated: Bool
    public var entries: [Entry]
}

/// `AgentFeedbackPreview` (:36-44): exactly what Send sends, already scrubbed. `kind` is `bug`, `confusing`,
/// `missing_capability`, `wrong_docs` or `other`.
public struct AgentFeedbackPreview: Codable, Hashable, Sendable {
    public var kind: String
    public var subject: String
    public var expected: String
    public var actual: String
    public var workaround: String
    public var trace: AgentFeedbackTrace?
}

/// The `feedback_request` turn item's own fields (orchestrationV2.ts:1902-1907), read from the item's JSON.
public struct AgentFeedbackRequest: Decodable, Hashable, Sendable {
    public static let itemType = "feedback_request"
    public var preview: AgentFeedbackPreview
    /// The preview's trace with message text, sent instead when the user includes the conversation.
    public var conversationTrace: AgentFeedbackTrace?
    /// `pending`, `sent`, `declined` or `cancelled`.
    public var feedbackStatus: String
}

public enum AgentFeedbackRPC {
    /// Needs `orchestration:operate` (clientRpcPermissions.ts:107).
    public static let answerRequest = "agentFeedback.answerRequest"
    public static let capability = "agentFeedback"
    public static let errorTag = "AgentFeedbackRequestError"

    /// `AgentFeedbackAnswerInput` (:53-60): `send` or `decline`; `includeConversation` sends the conversation trace
    /// in place of the outline.
    public static func answerInput(threadId: ThreadId, turnItemId: TurnItemId, send: Bool, includeConversation: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["threadId": .string(threadId.rawValue), "turnItemId": .string(turnItemId.rawValue),
                                      "answer": .string(send ? "send" : "decline")]
        if send, includeConversation { o["includeConversation"] = .bool(true) }
        return .object(o)
    }

    /// `AgentFeedbackRequestError` text by `reason` (:62-69); the server sends only the reason.
    public static func failure(_ reason: String?) -> String? {
        switch reason {
        case "load_failed": "Could not load the feedback report."
        case "not_found": "This feedback report no longer exists."
        case "already_answered": "This feedback report was already answered."
        case "feedback_off": "Agent feedback is off, so this report was not sent."
        case "record_failed": "Could not record your answer."
        default: nil
        }
    }
}
