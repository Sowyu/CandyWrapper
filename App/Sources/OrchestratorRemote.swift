import Foundation
import Features
import T3Client
import T3Protocol
import T3Store

/// The Orchestrator's reach to every machine (docs/orchestrator.md, "Every machine"). When a turn ends, this reads the
/// thread's finished replies, runs the `orchestrator-call` blocks nobody ran yet on the machines they name and hands the
/// "Result:" message back. It reacts to shell pushes only: one `getThreadProjection` when a turn ends or the next starts,
/// nothing while idle.
@MainActor
final class OrchestratorRemote {
    private let environments: Environments
    private let threads: ThreadController
    /// The Orchestrator's last seen state per session. `since` and `activeAtStart` are the thread's last update and its
    /// running turn when this session first saw it: replies from before then are history, not calls to run.
    private var watched: (session: ObjectIdentifier, thread: String, running: Bool, run: RunId?, since: Int64, activeAtStart: RunId?)?
    /// Assistant messages whose calls ran this session.
    private var handled: Set<String> = []

    var homeId: () -> String? = { nil }
    var orchestrator: () -> ThreadId? = { nil }
    var rows: (String) -> [OrchestratorModelRow] = { _ in [] }
    /// Sends the results to the Orchestrator.
    var reply: (String) -> Void = { _ in }
    /// Whether this Mac relays now rather than the Android app (`OrchestratorHandoff`).
    var mayRelay: () async -> Bool = { true }

    init(environments: Environments, threads: ThreadController) {
        self.environments = environments
        self.threads = threads
    }

    /// Every machine CandyWrapper knows, its own first.
    func machines() -> [OrchestratorMachineRef] {
        let home = homeId()
        return environments.environmentIds.map { id in
            OrchestratorMachineRef(id: id, label: environments.label(id) ?? (id == home ? "this Mac" : id), isHome: id == home,
                                   connected: environments.session(id) != nil && environments.state(id)?.status == .connected)
        }.sorted { $0.isHome && !$1.isHome }
    }

    func reset() {
        watched = nil
        handled = []
    }

    /// The Orchestrator's shell changed: when its turn just ended, run what it asked for.
    func orchestratorChanged(_ shell: ThreadShell?) {
        guard let env = homeId(), let id = orchestrator(), let session = environments.session(env), let shell else { return }
        let running = OrchestratorEvent.running.contains(shell.status)
        let key = ObjectIdentifier(session)
        guard let was = watched, was.session == key, was.thread == id.rawValue else {
            watched = (key, id.rawValue, running, shell.latestRunId, shell.updatedAt.epochMs ?? 0, running ? shell.latestRunId : nil)
            return
        }
        watched = (key, id.rawValue, running, shell.latestRunId, was.since, was.activeAtStart)
        guard OrchestratorHandoff.turnEnded(wasRunning: was.running, wasRun: was.run, running: running, run: shell.latestRunId) else { return }
        Task { [weak self] in await self?.runCalls(env: env, thread: id, since: was.since, activeAtStart: was.activeAtStart) }
    }

    private func runCalls(env: String, thread: ThreadId, since: Int64, activeAtStart: RunId?) async {
        // As the Android app does: wait, so a "Result:" from it can land, and run only calls nobody answered yet.
        try? await Task.sleep(for: OrchestratorHandoff.callDelay)
        let projection: ThreadProjection
        do {
            let json = try await environments.request(env, "orchestration.getThreadProjection", .object(["threadId": .string(thread.localId.rawValue)]))
            projection = try json.decode(as: ThreadProjection.self)
        } catch { return }
        // Repeats of one scheduled task that piled up behind a busy turn: one runs. Whoever relays or not, since a
        // second cancel of the same run only fails.
        for run in OrchestratorHandoff.redundantScheduledRuns(runs: projection.runs, messages: projection.messages) {
            _ = try? await environments.request(env, "orchestration.dispatchCommand", .object([
                "type": .string("queued-run.cancel"), "commandId": .string(UUID().uuidString.lowercased()),
                "threadId": .string(thread.localId.rawValue), "runId": .string(run.rawValue)]))
        }
        guard await mayRelay() else { return }
        // Marked before the calls run, so a second turn end meanwhile finds nothing left to run.
        let replies = OrchestratorHandoff.callsToRun(projection.messages, runs: projection.runs, since: since,
                                                     activeAtStart: activeAtStart, handled: handled)
        handled.formUnion(replies.map(\.id.rawValue))
        let calls = replies.sorted { ($0.createdAt.epochMs ?? 0) < ($1.createdAt.epochMs ?? 0) }.flatMap { OrchestratorReply.parse($0.text).calls }
        guard !calls.isEmpty, let text = await OrchestratorRelay(host: host()).run(calls) else { return }
        reply(text)
    }

    func host() -> OrchestratorRelayHost {
        OrchestratorRelayHost(
            machines: { [weak self] in self?.machines() ?? [] },
            snapshot: { [weak self] in self?.environments.snapshot($0) },
            request: { [weak self] env, method, payload in
                guard let self else { throw RelayError(message: "CandyWrapper is closing") }
                do { return try await self.environments.request(env, method, payload) } catch let e as RPCClientError {
                    throw RelayError(message: e.typedError?.message ?? e.description)
                }
            },
            config: { OrchestratorStore.shared.config },
            update: { OrchestratorStore.shared.update($0) },
            rows: { [weak self] in self?.rows($0) ?? [] },
            runtimeMode: { [weak self] in self?.threads.composer.config($0)?.settings.defaultRuntimeMode.rawValue ?? "full-access" },
            orchestrator: { [weak self] in self?.orchestrator() })
    }

    struct RelayError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
