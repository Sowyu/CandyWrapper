import Foundation
import T3Protocol

/// session-logic.ts:1045-1068 and operations/commands.ts:887-916.
public enum ThreadPromptRewind {
    public static func checkpoint(before message: ChatMessage, in projection: ThreadProjection) -> Checkpoint? {
        guard message.role == .user, message.inputIntent == .turnStart || message.inputIntent == .queuedTurn,
              let runId = message.runId,
              let current = projection.checkpoints.last(where: { $0.runId == runId && $0.status == "ready" }),
              let ordinal = current.appRunOrdinal else { return nil }
        let count = max(0, ordinal - 1)
        return projection.checkpoints.last {
            $0.status == "ready" && (count == 0 ? $0.ordinalWithinScope == 0 && $0.appRunOrdinal == nil : $0.appRunOrdinal == count)
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
