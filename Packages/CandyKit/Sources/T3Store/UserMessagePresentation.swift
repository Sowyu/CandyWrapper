import Foundation
import T3Protocol

/// `resolveUserMessagePresentation` (packages/client-runtime/src/userMessage.ts:23-90): who sent a user
/// message that the user did not type. A scheduled task's message carries its task id; older ones
/// stored the attribution as a prefix in the prompt, which the timeline strips.
public struct UserMessagePresentation: Equatable, Sendable {
    /// `"automation" | "agent" | "t3code" | "guest"`; nil when the user typed it.
    public enum Attribution: Equatable, Sendable { case automation, agent, t3code, guest }

    public var text: String
    public var attribution: Attribution?
    public var scheduledTaskId: String?
    /// The guest who wrote it (`attribution: "guest"`, userMessage.ts:42-50); `text` is then the guest's own words.
    public var guestName: String? = nil

    public var isAutomation: Bool { attribution == .automation }

    /// `[Triggered by schedule task: …]` and a blank line, at the start of the prompt.
    nonisolated(unsafe) private static let legacyPrefix = /^\[Triggered by schedule task: [^\r\n]+\]\r?\n\r?\n/
    nonisolated(unsafe) private static let legacyMessageId = /^scheduled-task-message:(.+):\d+:(?:scheduled|manual)$/

    public static func resolve(_ message: ChatMessage) -> UserMessagePresentation {
        // The stored text names the guest for the agent; people see the guest's own words.
        if message.role == .user, let guest = GuestMessageAttribution(message.context?["guest"]) {
            return .init(text: guest.text, attribution: .guest, scheduledTaskId: nil, guestName: guest.name)
        }
        return resolve(id: message.id.rawValue, isUser: message.role == .user, text: message.text,
                       createdBy: message.createdBy, creationSource: message.creationSource, scheduledTaskId: message.scheduledTaskId)
    }

    /// `resolveUserMessagePresentation(message).attribution === null`: the user typed it. Automations,
    /// other agents, T3 Code itself (`createdBy: "agent"`) and guests send user-role messages too.
    public static func isTypedByUser(_ message: ChatMessage) -> Bool {
        message.role == .user && resolve(message).attribution == nil
    }

    public static func resolve(id: String?, isUser: Bool, text: String, createdBy: String?, creationSource: String? = nil,
                               scheduledTaskId: String?) -> UserMessagePresentation {
        guard isUser else { return .init(text: text, attribution: nil, scheduledTaskId: nil) }
        if let scheduledTaskId { return .init(text: text, attribution: .automation, scheduledTaskId: scheduledTaskId) }
        if let prefix = text.firstMatch(of: legacyPrefix) {
            let legacyTaskId = (id ?? "").wholeMatch(of: legacyMessageId).map { String($0.1) }
            if legacyTaskId != nil || createdBy == "agent" {
                return .init(text: String(text[prefix.range.upperBound...]), attribution: .automation, scheduledTaskId: legacyTaskId)
            }
        }
        let attribution: Attribution? = createdBy != "agent" ? nil : creationSource == "server" ? .t3code : .agent
        return .init(text: text, attribution: attribution, scheduledTaskId: nil)
    }
}
