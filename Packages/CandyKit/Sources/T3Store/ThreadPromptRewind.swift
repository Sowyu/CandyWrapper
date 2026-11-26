import Foundation
import T3Protocol

/// session-logic.ts:1104-1185 and operations/commands.ts:1060-1090 at 5258.
public enum ThreadPromptRewind {
    /// A missing or failed snapshot (no git, a side chat, a capture error) still pins a conversation position; only
    /// restoring files needs a ready one (`isRewindableCheckpoint`, session-logic.ts:1158-1162 at 5258, #40745).
    public static func isRewindable(_ checkpoint: Checkpoint) -> Bool { checkpoint.status != "stale" }
    /// "Revert files too" needs the target's snapshot (`rewindFileRestore`, client-runtime threadRepositories.ts:102-121);
    /// the server refuses a file rewind to anything else.
    public static func restoresFiles(_ checkpoint: Checkpoint) -> Bool { checkpoint.status == "ready" }

    public static func checkpoint(before message: ChatMessage, in projection: ThreadProjection) -> Checkpoint? {
        guard message.role == .user, message.inputIntent == .turnStart || message.inputIntent == .queuedTurn,
              let runId = message.runId,
              let current = projection.checkpoints.last(where: { $0.runId == runId && isRewindable($0) }),
              let ordinal = current.appRunOrdinal else { return nil }
        let count = max(0, ordinal - 1)
        return projection.checkpoints.last {
            isRewindable($0) && (count == 0 ? $0.ordinalWithinScope == 0 && $0.appRunOrdinal == nil : $0.appRunOrdinal == count)
        }
    }
    public static func restoredPrompt(draft: String, message: String) -> String {
        message.isEmpty ? draft : draft.isEmpty ? message : draft + "\n\n" + message
    }
    public static func command(threadId: ThreadId, checkpoint: Checkpoint, restoreFiles: Bool, commandId: String = UUID().uuidString.lowercased()) -> JSONValue {
        .object(["type": .string("checkpoint.rollback"), "commandId": .string(commandId), "threadId": .string(threadId.rawValue),
                 "checkpointId": .string(checkpoint.id.rawValue), "scopeId": .string(checkpoint.scopeId.rawValue), "restoreFiles": .bool(restoreFiles)])
    }
}
