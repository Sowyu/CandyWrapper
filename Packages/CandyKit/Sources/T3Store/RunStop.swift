import Foundation
import T3Protocol

/// `presentRunStop` (4928 packages/client-runtime/src/state/threadExecution.ts:534-581): a Stop the provider
/// has not finished. It stays `stopping` while the agent winds down and turns `unresponsive` once the server
/// marks the request with `unresponsiveAt`, which is when Force stop is offered.
public struct RunStop: Equatable, Sendable {
    public enum State: Equatable, Sendable { case stopping, unresponsive }
    public var state: State
    public var runId: RunId
    public var requestedAt: T3Timestamp
    /// The run already ended; the Stop targeted its background work.
    public var background: Bool

    /// `INTERRUPTIBLE_RUN_STATUSES` (threadExecution.ts:56).
    static let interruptible: Set<ThreadStatus> = [.preparing, .starting, .running]

    public static func present(_ projection: ThreadProjection) -> RunStop? {
        present(runs: projection.runs, turnItems: projection.turnItems)
    }

    public static func present(runs: [Run], turnItems: [TurnItem]) -> RunStop? {
        var active: Run?, latest: Run?
        for run in runs {
            // Queued follow-ups never ran, so they hold no Stop of their own.
            if run.status != .queued, run.ordinal > (latest?.ordinal ?? -1) { latest = run }
            if interruptible.contains(run.status), run.ordinal > (active?.ordinal ?? -1) { active = run }
        }
        guard let run = active ?? latest else { return nil }
        var request: TurnItem?
        for item in turnItems where item.runId == run.id {
            if item.type == .runInterruptResult { return nil }
            if item.type == .runInterruptRequest { request = item }
        }
        guard let request, active != nil || request.unresponsiveAt != nil else { return nil }
        return RunStop(state: request.unresponsiveAt == nil ? .stopping : .unresponsive, runId: run.id,
                       requestedAt: request.startedAt ?? request.updatedAt, background: active == nil)
    }
}
