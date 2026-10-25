import Foundation
import T3Protocol

/// `resolveUserMessagePresentation` (packages/client-runtime/src/userMessage.ts): who sent a user
/// message that the user did not type. A scheduled task's message carries its task id; older ones
/// stored the attribution as a prefix in the prompt, which the timeline strips.
public struct UserMessagePresentation: Equatable, Sendable {
    public var text: String
    public var isAutomation: Bool
    public var scheduledTaskId: String?
    /// The guest who wrote it (`attribution: "guest"`, userMessage.ts:42-50); `text` is then the guest's own words.
    public var guestName: String? = nil

    /// `[Triggered by schedule task: …]` and a blank line, at the start of the prompt.
    nonisolated(unsafe) private static let legacyPrefix = /^\[Triggered by schedule task: [^\r\n]+\]\r?\n\r?\n/
    nonisolated(unsafe) private static let legacyMessageId = /^scheduled-task-message:(.+):\d+:(?:scheduled|manual)$/

    public static func resolve(_ message: ChatMessage) -> UserMessagePresentation {
        // The stored text names the guest for the agent; people see the guest's own words.
        if message.role == .user, let guest = GuestMessageAttribution(message.context?["guest"]) {
            return .init(text: guest.text, isAutomation: false, scheduledTaskId: nil, guestName: guest.name)
        }
        return resolve(id: message.id.rawValue, isUser: message.role == .user, text: message.text,
                createdBy: message.createdBy, scheduledTaskId: message.scheduledTaskId)
    }

    /// `resolveUserMessagePresentation(message).attribution === null` (userMessage.ts:10-55): the user
    /// typed it. Automations and other agents (`createdBy: "agent"`) send user-role messages too.
    public static func isTypedByUser(_ message: ChatMessage) -> Bool {
        let p = resolve(message)
        return message.role == .user && !p.isAutomation && p.guestName == nil && message.createdBy != "agent"
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
