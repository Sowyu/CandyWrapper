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

    /// Whether a thread is an Orchestrator's: its first message is a brief.
    public static func isOrchestratorThread(firstUserMessage text: String?) -> Bool {
        guard let text else { return false }
        return text == OrchestratorBrief.firstHeading || text.hasPrefix(OrchestratorBrief.firstHeading + "\n")
    }
}
