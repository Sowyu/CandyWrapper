import Foundation
import Features
import T3Client
import T3Protocol
import T3Store

/// The Orchestrator's reach to every machine (docs/orchestrator.md, "Every machine"). When its turn ends, this reads the
/// turn's replies once, runs their `orchestrator-call` blocks on the machines they name and hands the "Result:" message
/// back. It reacts to shell pushes only: one `getThreadProjection` per finished turn, nothing while idle.
@MainActor
final class OrchestratorRemote {
    private let environments: Environments
    private let threads: ThreadController
    /// The Orchestrator's last seen state per session: a run that ends while CandyWrapper watches has its calls run.
    private var watched: (session: ObjectIdentifier, thread: String, running: Bool)?
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
        defer { watched = (key, id.rawValue, running) }
        guard let was = watched, was.session == key, was.thread == id.rawValue, was.running, !running else { return }
        let run = shell.latestRunId
        Task { [weak self] in await self?.runCalls(env: env, thread: id, run: run) }
    }

    private func runCalls(env: String, thread: ThreadId, run: RunId?) async {
        // As the Android app does: wait, so a "Result:" from it can land, and run only calls nobody answered yet.
        try? await Task.sleep(for: OrchestratorHandoff.callDelay)
        guard await mayRelay() else { return }
        let projection: ThreadProjection
        do {
            let json = try await environments.request(env, "orchestration.getThreadProjection", .object(["threadId": .string(thread.localId.rawValue)]))
            projection = try json.decode(as: ThreadProjection.self)
        } catch { return }
        let mine = projection.messages.filter { $0.role == "assistant" && !$0.streaming && (run == nil || $0.runId == run) }
        let replies = OrchestratorHandoff.unansweredReplies(projection.messages, run: run, handled: handled)
        handled.formUnion(mine.map(\.id.rawValue))
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
            message: { id, text, selection, queue in
                ComposerController.standaloneCommand(threadId: ThreadId(id), messageId: MessageId(UUID().uuidString.lowercased()),
                                                     text: text, selection: selection, queue: queue)
            },
            launch: { id, project, title, text, selection, runtime, workspace in
                var payload = ComposerLogic.launchThreadPayload(commandId: UUID().uuidString.lowercased(), threadId: id, projectId: project, title: title,
                                                                modelSelection: ThreadSession.encode(selection), runtimeMode: runtime,
                                                                interactionMode: "default", messageId: UUID().uuidString.lowercased(), text: text,
                                                                workspaceStrategy: workspace)
                // The Orchestrator names its workers; T3 would retitle them from the prompt.
                if case .object(var o) = payload { o["generateTitle"] = .bool(false); payload = .object(o) }
                return payload
            },
            orchestrator: { [weak self] in self?.orchestrator() })
    }

    struct RelayError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
