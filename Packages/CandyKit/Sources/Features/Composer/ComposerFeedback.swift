import DesignSystem
import Foundation
import T3Protocol

/// Where a composer failure shows in T3 Code. Most failures go through `setThreadError`
/// (ChatView.tsx:4538-4572) into the thread error banner over the top of the timeline
/// (`ThreadErrorBanner.tsx`). A blocked model pick and a queued edit that left the queue are
/// toasts. Queue strip commands only log (`useAtomCommand` reports to the console,
/// state/use-atom-command.ts, client-runtime state/runtime.ts:419-435).
public enum ComposerFeedback {
    public enum Failure: Equatable, Sendable {
        /// `onSend` failure (ChatView.tsx:10086-10091).
        case send(String?)
        /// `onRespondToApproval` (ChatView.tsx:10135-10140).
        case approval(String?)
        /// `onRespondToUserInput`.
        case userInput(String?)
        /// `onDismissUserInput`.
        case dismissQuestion(String?)
        /// `onInterrupt` (ChatView.tsx:4588-4595).
        case interrupt(String?)
        /// `onResume` (ChatView.tsx:8710-8716).
        case resume(String?)
        /// `queued-run.cancel`, `reorder`, `promote-to-steer` (QueuedRunsControl.tsx:168-245).
        case queueCommand
        /// Send now on a queued message: `queued-run.start` or promote-to-steer (QueuedRunsControl.tsx at 4928, #31283).
        case queueSendNow(String?)
        /// A failed `queued-run.edit` (ChatView.tsx:9007-9009).
        case queuedEditSave
        /// A command whose failure shows the server's message, else T3's fallback text for it.
        case command(String?, fallback: String)
        /// No usable model at send time. T3 disables the send instead; this is our guard's text.
        case noModel
        /// `getStartedThreadModelChangeBlockReason` refused a pick; the value is its title.
        case modelChangeBlocked(String)
        /// The edited queued run left the queue (ChatView.tsx:4743-4759); true when the edit was kept.
        case queuedEditLeft(kept: Bool)
    }

    public enum Surface: Equatable, Sendable {
        case none
        case banner(String)
        case toast(ToastQueue.Kind, title: String, description: String?)
    }

    public static func surface(for failure: Failure) -> Surface {
        func banner(_ message: String?, _ fallback: String) -> Surface {
            sanitize(message ?? fallback).map(Surface.banner) ?? .none
        }
        switch failure {
        case .send(let m): return banner(m, "Failed to send message.")
        case .approval(let m): return banner(m, "Failed to submit approval decision.")
        case .userInput(let m): return banner(m, "Failed to submit user input.")
        case .dismissQuestion(let m): return banner(m, "Failed to dismiss the question.")
        case .interrupt(let m): return banner(m, "Failed to interrupt the current turn.")
        case .resume(let m): return banner(m, "Could not resume thread.")
        case .queueCommand: return .none
        case .queueSendNow(let m):
            return .toast(.error, title: "Could not send queued message", description: m.flatMap(sanitize).flatMap { $0.isEmpty ? nil : $0 } ?? "An error occurred.")
        case .queuedEditSave: return .banner("Could not save the edited queued message.")
        case .command(let m, let fallback): return banner(m, fallback)
        case .noModel: return .banner("No model is available. Enable a provider in T3 Code's settings.")
        case .modelChangeBlocked(let title):
            // ChatView.tsx:10760-10765, texts from ChatView.logic.ts:1069-1091.
            let description = title == "Start a new chat to switch providers"
                ? "This thread does not support switching providers after it has started."
                : "This provider does not allow switching models after a conversation has started."
            return .toast(.warning, title: title, description: description)
        case .queuedEditLeft(let kept):
            return .toast(kept ? .info : .warning, title: "Queued message is no longer queued",
                          description: kept ? "Your unsaved edit was kept in the composer." : "Your unsaved edit was discarded.")
        }
    }

    // MARK: Transport errors (client-runtime errors/transport.ts)

    private static let networkHint = "Your DNS or firewall may be blocking T3 Connect. Try another network, such as a different Wi-Fi or mobile data."
    private static let transportPatterns: [NSRegularExpression] = {
        let hint = NSRegularExpression.escapedPattern(for: networkHint)
        return [
            #"\bSocketCloseError\b"#, #"\bSocketOpenError\b"#, #"\bSocket is not connected\b"#,
            #"Unable to connect to the T3 server WebSocket\."#,
            #"\b(?:is not connected|disconnected|stopped responding|could not establish a WebSocket connection)\.(?: "# + hint + ")?$",
            #"\bstopped responding for \d+s\. It may be overloaded, asleep, or off the network\.$"#,
            #"\bClientProtocolError\b"#, #"\bRpcClientError\b"#, #"\bping timeout\b"#,
        ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    /// `isTransportConnectionErrorMessage`: connection failures show as connection state, not a banner.
    public static func isTransportError(_ message: String?) -> Bool {
        guard let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return transportPatterns.contains { $0.firstMatch(in: trimmed, range: range) != nil }
    }

    /// `sanitizeThreadErrorMessage`.
    public static func sanitize(_ message: String?) -> String? {
        isTransportError(message) ? nil : message
    }
}

extension ComposerFeedback {
    public enum QueuedEditRecovery: Equatable, Sendable { case kept, discarded, clean }

    /// `recoverQueuedMessageEdit` (chat/queuedMessageEdit.ts:11-27): a changed edit moves to the
    /// thread's prompt when that holds no text, else it is dropped; an unchanged edit just closes.
    public static func recoverQueuedEdit(edited: String, original: String, threadPrompt: String) -> QueuedEditRecovery {
        let dirty = edited != original
        if dirty, threadPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .kept }
        return dirty ? .discarded : .clean
    }
}

/// The thread error banner's state (ChatView.tsx:2058-2199, 2262-2268, ThreadErrorBanner.tsx):
/// a local error per thread key over the shell's `lastError`. Only the server's runtime error gets a session
/// dismissal, keyed `threadKey NUL source NUL error`, so a later run that fails with the same text shows again
/// (5258 ThreadErrorBanner.tsx:54-60, ChatView.logic.ts:1250-1295, #37419). A local error clears on dismiss and
/// masks nothing, so a repeat shows (#40042).
public struct ThreadErrorState: Sendable {
    public enum Variant: Sendable, Equatable { case error, warning }
    public struct Banner: Equatable, Sendable {
        public var message: String
        public var variant: Variant
        /// `AlertTitle` above the message (the provider status banner); nil for thread errors.
        public var title: String? = nil
        /// The provider status banner's info glyph instead of the alert circle.
        public var info = false
        /// "Open provider setup" after the message.
        public var setupLink = false
        /// ThreadErrorBanner's ChatGPT usage limit face (ThreadErrorBanner.tsx:83-123, 6f75bcb374).
        public var chatGptLimit: ChatGptLimit? = nil
    }
    /// A plain ChatGPT limit offers "Manage usage"; a Business workspace cap offers "Copy request for admin".
    public enum ChatGptLimit: Sendable, Equatable { case usage, workspace }

    private var local: [String: String] = [:]
    private var dismissed: Set<String> = []

    public init() {}

    /// `setThreadError`: nil clears; transport errors clear too.
    public mutating func set(_ key: String, _ message: String?) {
        local[key] = ComposerFeedback.sanitize(message)
    }

    /// `getThreadErrorBannerKey`: nil for an error that is not the server's runtime error (`threadErrorIsServerRuntime`).
    /// The source is the latest run and when it ended (`threadErrorSource`, threadExecution.ts at 5258).
    // ponytail: keys on the shell's latest run, not the failure item; read the projection's failure item if two
    // failures in one run must each show again.
    private static func sessionKey(_ key: String, local: String?, shell: ThreadShell?) -> String? {
        guard let shell, let error = shell.lastError, local == nil || local == error else { return nil }
        let source = shell.latestRunId.map { "\($0.rawValue)@\(shell.latestRunCompletedAt.value?.raw ?? "")" } ?? ""
        return "\(key)\u{0}\(source)\u{0}\(error)"
    }

    /// What the banner shows for a thread key. `shell` is nil for a draft.
    public func visible(_ key: String, shell: ThreadShell?) -> Banner? {
        let localError = local[key]
        guard let error = localError ?? shell?.lastError else { return nil }
        if let session = Self.sessionKey(key, local: localError, shell: shell), dismissed.contains(session) { return nil }
        let fromShell = localError == nil && shell != nil
        // A usage limit on a failed run shows the usage-limit recovery banner instead.
        if fromShell, shell?.status == .failed, shell?.lastErrorClass == .usageLimit, shell?.latestRunId != nil { return nil }
        // Only the shell's own error carries its class and code (ChatView.tsx:3257-3262).
        let code = fromShell ? shell?.lastErrorCode : nil
        let limit: ChatGptLimit? = code == UsageLimitsLogic.chatGptWorkspaceUsageLimitCode ? .workspace
            : code == UsageLimitsLogic.chatGptUsageLimitCode ? .usage : nil
        if let limit {
            let message = limit == .workspace
                ? "You've reached your workspace's limit for using your ChatGPT plan in other apps. Copy a request to ask your workspace admin for increased usage limits."
                : "Review your usage settings in ChatGPT."
            return Banner(message: message, variant: .warning, title: "ChatGPT usage limit reached", chatGptLimit: limit)
        }
        let variant: Variant = fromShell && shell?.lastErrorClass == .usageLimit ? .warning : .error
        return Banner(message: error, variant: variant)
    }

    /// The X: clears the local error and masks the server's runtime error for the session.
    public mutating func dismiss(_ key: String, shell: ThreadShell?) {
        if let session = Self.sessionKey(key, local: local[key], shell: shell) { dismissed.insert(session) }
        local[key] = nil
    }
}
