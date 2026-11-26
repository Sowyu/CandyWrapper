import Foundation
import T3Protocol

/// 5258 provider-session and turn fields a client reads while a run starts or after it stops
/// (packages/client-runtime/src/state/threadExecution.ts, shared orchestrationV2ManualContinuation.ts).
/// Sessions and provider turns stay raw JSON in `ThreadProjection`, so these read the keys directly.
public enum RunStartup {
    /// `ProviderSession.startupPhase` for this thread (`startupPhaseFor`, threadExecution.ts:165-172): a session that
    /// serves several threads names the one whose start the phase describes in `startupPhaseThreadId`.
    public static func startupPhase(_ session: JSONValue?, threadId: ThreadId) -> String? {
        guard let session, let phase = session["startupPhase"]?.stringValue else { return nil }
        if let owner = session["startupPhaseThreadId"]?.stringValue, owner != threadId.rawValue { return nil }
        return phase
    }

    /// The session `summarizeThreadRun` reads for a run: the newest one on the run's provider instance (:204-206).
    public static func session(for run: Run, in projection: ThreadProjection) -> JSONValue? {
        projection.providerSessions.last { $0["providerInstanceId"]?.stringValue == run.providerInstanceId?.rawValue }
    }

    /// The phase to show for a run that has no provider output yet, or nil (:208-230). A run with no turn yet shows it
    /// while it prepares or starts; one whose turn opened shows it until its first output.
    public static func startupPhase(for run: Run, in projection: ThreadProjection, items: [TurnItem]) -> String? {
        guard let phase = startupPhase(session(for: run, in: projection), threadId: projection.thread.id) else { return nil }
        let attempt = run.activeAttemptId?.rawValue
        let turn = projection.providerTurns.last { $0["runAttemptId"]?.stringValue == attempt && attempt != nil }
        guard let turn else { return [.preparing, .starting, .running].contains(run.status) ? phase : nil }
        let status = turn["status"]?.stringValue
        guard status == "pending" || status == "running" else { return nil }
        let answered = items.contains { $0.runId == run.id && $0.providerTurnId != nil && $0.type != .userMessage }
        return answered ? nil : phase
    }

    /// `providerStartingPhase` (:119-135): the label for a phase; an unknown one keeps the plain label.
    public static func startingLabel(phase: String?, provider: String) -> String {
        switch phase {
        case "plugins": "Loading \(provider) plugins"
        case "mcp": "Starting \(provider) MCP servers"
        case "hooks": "Loading \(provider) hooks"
        case "skills": "Loading \(provider) rules and skills"
        case "resume": "Resuming \(provider) session"
        case "connecting": "Connecting to \(provider)"
        default: "Starting \(provider)"
        }
    }

    /// The session a run executed on (`runProviderSession`, threadExecution.ts:448-460).
    public static func executedSession(for run: Run, in projection: ThreadProjection) -> JSONValue? {
        let sessionId = projection.providerThreads.first { $0["id"]?.stringValue == run.providerThreadId }?["providerSessionId"]?.stringValue
        guard let sessionId else { return session(for: run, in: projection) }
        return projection.providerSessions.first { $0["id"]?.stringValue == sessionId }
    }

    /// The `supportsNativeResume === false` half of `deriveResumableRunId` (:436-444): without native resume the
    /// server can only resend a message the provider never received, so Resume hides unless one is unsent.
    /// An absent flag (4928, or a session recorded before it) keeps Resume.
    public static func resumeUnavailable(_ runId: RunId, in projection: ThreadProjection) -> Bool {
        guard let run = projection.runs.first(where: { $0.id == runId }),
              executedSession(for: run, in: projection)?["capabilities"]?["turns"]?["supportsNativeResume"]?.boolValue == false
        else { return false }
        return unsentContinuationSource(of: runId, in: projection) == nil
    }

    /// `unsentManualContinuationSource` (shared orchestrationV2ManualContinuation.ts:7-41), for a continuation of
    /// `runId`: the run whose message the provider never received, following earlier continuations.
    static func unsentContinuationSource(of runId: RunId, in projection: ThreadProjection) -> Run? {
        let runs = Dictionary(projection.runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // `isDeliveredProviderTurn`: a turn the provider dropped before persisting it doesn't count (orchestrationV2.ts:1382).
        let accepted = Set(projection.providerTurns.filter { $0["promptDropped"]?.boolValue != true }.compactMap { $0["runAttemptId"]?.stringValue })
        func latest(_ id: RunId, _ matches: (RunAttempt) -> Bool) -> Int {
            projection.attempts.filter { $0.runId == id && matches($0) }.map(\.attemptOrdinal).max() ?? 0
        }
        var sourceId: RunId? = runId
        var visited = Set<RunId>()
        while let id = sourceId, !visited.contains(id) {
            visited.insert(id)
            guard let source = runs[id] else { return nil }
            let delivered = latest(id) { accepted.contains($0.id.rawValue) }
            let restarted = latest(id) { $0.reason == "steering_restart" }
            if restarted > delivered { return source }
            if delivered > 0 { return nil }
            guard let next = source.manualContinuationOfRunId else { return source }
            sourceId = next
        }
        return nil
    }
}
