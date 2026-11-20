import Foundation
import T3Client
import T3Protocol
import T3Store

/// Removes what the Orchestrator, deleted on 2026-11-21, left on this Mac and its servers (`OrchestratorCleanup`,
/// docs/research/orchestrator-removal-2026-11-21.md). It does nothing unless the old `orchestrator.v1` key is there.
/// Each machine is cleaned once, when its shell arrives, at most once per launch; when all are done the keys go.
/// Every step reads fresh state first, so a second run changes nothing.
@MainActor
final class OrchestratorCleanupRunner {
    private let environments: Environments
    private let defaults: UserDefaults
    private var legacy: OrchestratorCleanup.Legacy?
    /// Machines tried this launch, done or not.
    private var tried: Set<String> = []

    init(environments: Environments, defaults: UserDefaults = .standard) {
        self.environments = environments
        self.defaults = defaults
        legacy = OrchestratorCleanup.Legacy.read(defaults.data(forKey: OrchestratorCleanup.configKey))
        guard legacy != nil else { return }
        environments.observeShell { [weak self] in self?.shellChanged() }
        shellChanged()
    }

    private var done: Set<String> {
        get { Set(defaults.stringArray(forKey: OrchestratorCleanup.doneKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: OrchestratorCleanup.doneKey) }
    }

    private func shellChanged() {
        guard let legacy, let pending = legacy.pending(primary: environments.primaryId) else { return }
        let left = pending.subtracting(done)
        guard !left.isEmpty else { return finish() }
        let home = legacy.environmentId ?? environments.primaryId
        // Connected, so the shell is the server's, not the cached one shown at launch.
        for env in left.subtracting(tried) where environments.state(env)?.status == .connected && environments.snapshot(env) != nil {
            tried.insert(env)
            Task { [weak self] in
                guard let self else { return }
                if await self.clean(env, legacy: legacy, isHome: env == home) { self.done.insert(env) }
                self.shellChanged()
            }
        }
    }

    private func finish() {
        for key in [OrchestratorCleanup.configKey, OrchestratorCleanup.syncKey, OrchestratorCleanup.doneKey] { defaults.removeObject(forKey: key) }
        legacy = nil
    }

    /// One machine, in order: the relay helper's own uninstall, its sign-ins, the tasks, then the thread. True when
    /// every step that had something to do succeeded.
    private func clean(_ env: String, legacy: OrchestratorCleanup.Legacy, isHome: Bool) async -> Bool {
        guard let session = environments.session(env) else { return false }
        var ok = true

        // 1 and 2: the helper. Without access:read the sessions can't be listed, and the uninstall still runs on its machine.
        var helpers: [AuthClientSession]?
        if environments.authSession(env)?.permissions?.contains("access:read") ?? true,
           let event = try? await session.supervisor.firstSnapshot("subscribeAuthAccess") {
            var access = AuthAccessSnapshot()
            if (try? access.apply(event)) != nil { helpers = OrchestratorCleanup.helperSessions(access.clientSessions) }
        }
        if isHome, helpers.map({ !$0.isEmpty }) ?? true {
            // Runs the installed 1.14 binary's `uninstall`; "not installed" is fine too. T3 checks nothing about the thread id.
            let lines = await HiddenTerminal.run(environments, session: session, env: env, thread: "candywrapper-cleanup", cwd: "/",
                                                 command: HelperInstall.uninstallCommand(), input: nil)
            let removed: Bool = if case .ok? = lines.last { true } else { false }
            if !removed, helpers?.isEmpty == false { ok = false }
            NSLog("orchestrator cleanup: helper uninstall on %@: %@", env, removed ? "ok" : "no answer")
        }
        for s in helpers ?? [] {
            do { try await session.http.revokeClient(sessionId: s.sessionId, token: session.token) } catch { ok = false }
        }

        // 3: its settings task and check tasks, from a fresh list. A failed read leaves them for the next launch.
        let threads = Set(legacy.machines[env].map { [$0.threadId] } ?? [])
        if let json = try? await session.supervisor.firstSnapshot("scheduledTasks.subscribe", payload: .object([:]), timeout: .seconds(30)) {
            for task in OrchestratorCleanup.tasksToDelete(ScheduledTask.list(json), threads: threads) {
                do { _ = try await session.supervisor.request("scheduledTasks.delete", payload: .object(["id": .string(task.id)]), timeout: .seconds(30)) }
                catch { ok = false }
            }
        } else {
            ok = false
        }

        // 4: its own thread, archived so its history stays and Settings > Archive can bring it back.
        for thread in OrchestratorCleanup.threadsToArchive(legacy, env: env, threads: environments.snapshot(env)?.threads ?? []) {
            let id = thread.id.scoped(to: env)
            do { _ = try await environments.dispatch(id, ThreadCommands.archive(id.localId), optimistic: .archive) } catch { ok = false }
        }
        NSLog("orchestrator cleanup on %@: %@", env, ok ? "done" : "will retry")
        return ok
    }
}
