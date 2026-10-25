import Foundation
import T3Protocol

/// Compactions T3 Code starts on its own (0345e852ed): a bare `/compact` it sends before the prompt cache
/// expires or when the user comes back, and the one a resumed Claude session asks for.
public enum IdleCompaction {
    /// `IDLE_COMPACTING_LABELS` (packages/client-runtime/src/userMessage.ts:10-13): the working row or live divider.
    public static let compactingLabels = [
        "beforeCacheExpires": "Compacting before the cache expires…",
        "onReturn": "Compacting after being idle…",
    ]
    /// `IDLE_COMPACTION_TITLES` (userMessage.ts:16-19): leads the finished divider in place of "Context compacted".
    public static let titles = [
        "beforeCacheExpires": "Context automatically compacted before cache expiry",
        "onReturn": "Context compacted after being idle",
    ]

    /// `isCompactionCommandMessage` (packages/contracts/src/orchestrationV2.ts:492-498).
    public static func isCommand(_ message: ChatMessage) -> Bool {
        message.role == .user && message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/compact"
            && message.attachments.isEmpty
    }

    /// `idleCompactionOf` (orchestrationV2.ts:501-510): why T3 Code sent this `/compact`, nil when someone asked.
    /// Servers before `idleCompaction` marked their own as agent-created.
    public static func reason(_ message: ChatMessage) -> String? {
        guard isCommand(message) else { return nil }
        if let r = message.idleCompaction, compactingLabels[r] != nil { return r }
        return message.createdBy == "agent" && message.creationSource == "server" ? "beforeCacheExpires" : nil
    }

    /// `claudeResumeCompactionAge` (packages/shared/src/claudeCompaction.ts:27-39): the session age from an
    /// answered "compact before continuing?" question whose answer was to compact.
    public static func resumeAge(_ questionAnswer: JSONValue) -> String? {
        guard case .object(let answers)? = questionAnswer["answers"] else { return nil }
        for (id, answer) in answers {
            let question = questionAnswer["questionTextById"]?[id]?.stringValue ?? id
            guard let match = question.wholeMatch(of: resumeQuestion) else { continue }
            let chosen = answer.arrayValue?.compactMap(\.stringValue) ?? answer.stringValue.map { [$0] } ?? []
            if chosen.contains("Compact and continue") { return String(match.1) }
        }
        return nil
    }

    nonisolated(unsafe) private static let resumeQuestion =
        /This session is (\d+h \d+m|\d+m) old and uses \d{1,3}(?:,\d{3})* tokens\. Compact it before continuing\?/
}
