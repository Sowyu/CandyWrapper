import Foundation
import T3Protocol

/// Who relays for the Orchestrator on its machine: this Mac or CandyWrapper on Android. The "while closed" scheduled
/// task is the flag both read. The Mac turns it off while it's open and on when it quits. The phone relays only in the
/// foreground and only while the task says the Mac is closed; it turns the task off while it relays and back on when it
/// goes to the background, if it was the one that turned it off. Before running a call either side waits 2 seconds and
/// skips any call a "Result:" message already answers.
///
/// The Mac remembers the task's `updatedAt` from its own last write (T3 stamps every upsert and setEnabled,
/// ScheduledTaskService.ts:1172, 1212). Another stamp means someone else wrote since, most likely the phone taking over,
/// so the Mac drops what it gathered and takes the task back before it relays again. The phone sees that write and stops.
public struct OrchestratorHandoff: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case relay
        /// Not the Mac's to relay yet: drop what it gathered and write the task back first.
        case resync
    }

    /// The task's `updatedAt` right after this Mac last wrote it off, since it opened or woke. Nil until then.
    public private(set) var ownStamp: String?

    /// How long a side waits before running a call, so a "Result:" from the other side can land first.
    public static let callDelay: Duration = .seconds(2)

    public init() {}

    /// The Mac wrote the task off, holding it; `updatedAt` is what the server answered.
    public mutating func wrote(updatedAt: String?) { ownStamp = updatedAt }

    /// The Mac handed the task off (quit) or can't know who held it meanwhile (it slept): its next relay takes it back first.
    public mutating func forget() { ownStamp = nil }

    /// Before relaying, with the task as the server has it now. Nil when the machine has no such task: nobody else
    /// can be relaying, as the phone reads the Mac's state from it.
    public func verdict(task: ScheduledTask?) -> Verdict {
        guard let task else { return .relay }
        guard let own = ownStamp, task.updatedAt == own, !task.enabled else { return .resync }
        return .relay
    }

    /// The Orchestrator's replies whose calls nobody has run: finished, not handled here yet, and with no "Result:"
    /// message after them (the phone already ran those).
    public static func unansweredReplies(_ messages: [ConversationMessage], run: RunId?, handled: Set<String>) -> [ConversationMessage] {
        let sorted = messages.sorted { ($0.createdAt.epochMs ?? 0, $0.id.rawValue) < ($1.createdAt.epochMs ?? 0, $1.id.rawValue) }
        return sorted.enumerated().compactMap { i, m in
            guard m.role == "assistant", !m.streaming, run == nil || m.runId == run, !handled.contains(m.id.rawValue) else { return nil }
            let answered = sorted[(i + 1)...].contains { $0.role == "user" && OrchestratorRelay.isResultMessage($0.text) }
            return answered ? nil : m
        }
    }

<<<<<<< Updated upstream
    /// The threads whose `orchestration.searchThreads` match for "Orchestrator brief" is a brief: a user message that starts
    /// with the heading. T3 matches each thread's newest such message and starts the snippet at the message when the
    /// phrase is near its start (ThreadSearch.ts:46-60, 100-125), so this holds however long the thread grew. A thread's
    /// projection carries only its newest messages, so its first message can't tell once it passed that window.
    public static func briefThreads(_ matches: [ThreadSearchMatch]) -> Set<String> {
        Set(matches.filter { $0.isUser && ($0.snippet == OrchestratorBrief.firstHeading || $0.snippet.hasPrefix(OrchestratorBrief.firstHeading + " ")) }
            .map(\.threadId.rawValue))
    }

    /// Whether a thread is an Orchestrator's: its first message is a brief.
    public static func isOrchestratorThread(firstUserMessage text: String?) -> Bool {
        guard let text else { return false }
        return text == OrchestratorBrief.firstHeading || text.hasPrefix(OrchestratorBrief.firstHeading + "\n")
=======
    /// The Orchestrator thread to adopt from a search for "Orchestrator brief": the newest live, top-level thread whose
    /// matched message is a brief written with the thread itself, so its first message. T3 matches each thread's newest
    /// user message with the phrase, and the snippet starts at the message's start when the phrase opens it
    /// (ThreadSearch.ts:46-60, 100-127). A thread's projection holds only its last 20 messages, so it can't tell.
    public static func adoptable(_ matches: [ThreadSearchMatch], threads: [ThreadShell]) -> ThreadShell? {
        let live = Dictionary(threads.filter { $0.archivedAt == nil && $0.deletedAt == nil && $0.lineage.parentThreadId == nil }
            .map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        return matches.compactMap { m -> ThreadShell? in
            guard m.isUser, m.snippet.hasPrefix(OrchestratorBrief.firstHeading + " ") || m.snippet == OrchestratorBrief.firstHeading,
                  let t = live[m.threadId.rawValue], let sent = m.messageCreatedAt?.epochMs, let made = t.createdAt.epochMs,
                  abs(sent - made) <= 60_000 else { return nil }
            return t
        }.max { ($0.updatedAt.epochMs ?? 0) < ($1.updatedAt.epochMs ?? 0) }
>>>>>>> Stashed changes
    }
}
