import Foundation

/// `resolveUserMessagePresentation` (packages/client-runtime/src/userMessage.ts): who sent a user
/// message that the user did not type. A scheduled task's message carries its task id; older ones
/// stored the attribution as a prefix in the prompt, which the timeline strips.
public struct UserMessagePresentation: Equatable, Sendable {
    public var text: String
    public var isAutomation: Bool
    public var scheduledTaskId: String?

    /// `[Triggered by schedule task: …]` and a blank line, at the start of the prompt.
    nonisolated(unsafe) private static let legacyPrefix = /^\[Triggered by schedule task: [^\r\n]+\]\r?\n\r?\n/
    nonisolated(unsafe) private static let legacyMessageId = /^scheduled-task-message:(.+):\d+:(?:scheduled|manual)$/

    public static func resolve(_ message: ChatMessage) -> UserMessagePresentation {
        resolve(id: message.id.rawValue, isUser: message.role == .user, text: message.text,
                createdBy: message.createdBy, scheduledTaskId: message.scheduledTaskId)
    }

    public static func resolve(id: String?, isUser: Bool, text: String, createdBy: String?, scheduledTaskId: String?) -> UserMessagePresentation {
        guard isUser else { return .init(text: text, isAutomation: false, scheduledTaskId: nil) }
        if let scheduledTaskId { return .init(text: text, isAutomation: true, scheduledTaskId: scheduledTaskId) }
        guard let prefix = text.firstMatch(of: legacyPrefix) else { return .init(text: text, isAutomation: false, scheduledTaskId: nil) }
        let legacyTaskId = (id ?? "").wholeMatch(of: legacyMessageId).map { String($0.1) }
        let isAutomation = legacyTaskId != nil || createdBy == "agent"
        return .init(text: isAutomation ? String(text[prefix.range.upperBound...]) : text, isAutomation: isAutomation, scheduledTaskId: legacyTaskId)
    }
}
