import Foundation
import T3Protocol

/// Side chats (4928 #26901): hidden forks of a thread that run in a tab of its right panel. The payloads,
/// the `/side` parser and the rules for when one may start, kept here so the composer, the panel and the
/// tests agree.
public enum SideChats {
    /// `environment.capabilities.sideChats` (contracts environment.ts:101-102). 3824 servers lack it and
    /// would fork an ordinary listed thread.
    public static let capability = "sideChats"
    /// The title the fork gets on the server, shared by every viewer (useSideChat.ts:59-61).
    public static let title = "Side chat"

    /// `forkSideChat` (client-runtime operations/commands.ts:1100-1115): forks the latest stable point,
    /// which works while the parent runs.
    public static func fork(source: ThreadId, target: ThreadId, title: String = SideChats.title,
                            commandId: String = ThreadCommands.newCommandId()) -> JSONValue {
        .object(["type": .string("thread.fork"), "commandId": .string(commandId), "createdBy": .string("user"),
                 "creationSource": .string("web"), "sourceThreadId": .string(source.rawValue),
                 "targetThreadId": .string(target.rawValue), "sourcePoint": .object(["type": .string("latest_stable")]),
                 "sideChat": .bool(true), "title": .string(title)])
    }

    /// `deleteThread` with `onlyIfUnused` (commands.ts:508-517): drops the empty side chat a failed start
    /// leaves; one that got its message stays.
    public static func discard(_ threadId: ThreadId, commandId: String = ThreadCommands.newCommandId()) -> JSONValue {
        .object(["type": .string("thread.delete"), "commandId": .string(commandId), "threadId": .string(threadId.rawValue),
                 "onlyIfUnused": .bool(true)])
    }

    /// `setThreadRuntimeMode` (commands.ts:729-738): the side chat takes the parent composer's mode.
    public static func setRuntimeMode(_ threadId: ThreadId, _ mode: String, commandId: String = ThreadCommands.newCommandId()) -> JSONValue {
        .object(["type": .string("thread.runtime-mode.set"), "commandId": .string(commandId), "threadId": .string(threadId.rawValue),
                 "runtimeMode": .string(mode)])
    }

    /// `parseSideChatCommand` (packages/shared/src/composerTrigger.ts:145-149): `/side [prompt]` or `/btw [prompt]`
    /// as the whole message, any case. Returns the prompt, empty when there is none.
    public static func parseCommand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        for word in ["side", "btw"] {
            guard body.count >= word.count, body.prefix(word.count).lowercased() == word else { continue }
            let rest = body.dropFirst(word.count)
            if rest.isEmpty { return "" }
            guard let first = rest.first, first.isWhitespace else { continue }
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// What the parent thread is, for `disabledReason`.
    public struct Parent: Equatable, Sendable {
        public var isSideChat: Bool
        public var isSubagent: Bool
        /// The server config has arrived.
        public var configLoaded: Bool
        public var capable: Bool
        /// The thread exists on the server (`isServerThread`): a draft has no shell to fork.
        public var isServerThread: Bool
        public var worktreePending: Bool
        public var canOperate: Bool
        public init(isSideChat: Bool = false, isSubagent: Bool = false, configLoaded: Bool = true, capable: Bool = true,
                    isServerThread: Bool = true, worktreePending: Bool = false, canOperate: Bool = true) {
            self.isSideChat = isSideChat; self.isSubagent = isSubagent; self.configLoaded = configLoaded; self.capable = capable
            self.isServerThread = isServerThread; self.worktreePending = worktreePending; self.canOperate = canOperate
        }

        /// `sideChatsOffered` (ChatView.tsx:2847-2852): the + menu lists Side chat at all.
        public var offered: Bool { canOperate && !isSideChat && !isSubagent && capable && configLoaded }
    }

    /// `sideChatDisabledReason` (ChatView.tsx:2868-2885): why `/side` and the + menu's Side chat can't start, or nil.
    public static func disabledReason(_ p: Parent) -> String? {
        if p.isSideChat { return "Side chats cannot start side chats." }
        if p.isSubagent { return "Subagent threads cannot start side chats." }
        if !p.configLoaded { return "Side chats are not ready yet. Try again in a moment." }
        if !p.capable { return "Update this environment's T3 Code server to use side chats." }
        if p.offered, !p.isServerThread { return "Side chats start after the first message." }
        if p.offered, p.worktreePending { return "Available once the thread's worktree is set up." }
        if !p.canOperate { return "This connection cannot change threads." }
        return nil
    }

    /// `sideChatTabState` (RightPanelTabs.tsx:726-737): the dot a side chat's tab wears.
    public enum TabState: String, Sendable { case needsApproval = "needs approval", needsInput = "needs input", running }

    public static func tabState(_ shell: ThreadShell?) -> TabState? {
        guard let shell else { return nil }
        if let request = shell.pendingRuntimeRequest {
            if request.kind == .userInput { return .needsInput }
            if request.kind != .authRefresh { return .needsApproval }
        }
        let active: Set<ThreadStatus> = [.preparing, .queued, .starting, .running, .waiting]
        return active.contains(shell.activityRunStatus ?? shell.status) ? .running : nil
    }

    /// `resolveThreadOpenRoute` (lib/sideChatPane.ts:22-35): a side chat opens as its parent with the side chat's
    /// tab; any other thread opens itself. Returns the thread to open and the side chat to show, in the ids it is given.
    public static func openRoute(_ threadId: ThreadId, shell: ThreadShell?) -> (open: ThreadId, sideChat: ThreadId?) {
        guard let shell, shell.lineage.sideChat == true, let parent = shell.lineage.parentThreadId else { return (threadId, nil) }
        return (parent, threadId)
    }
}
