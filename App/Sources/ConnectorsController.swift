import AgentConfig
import DesignSystem
import Features
import Foundation
import T3Client
import T3Store

/// The Connectors tab from the app's side (docs/connectors.md): runs `candywrapper-helper config get|set` in a hidden
/// terminal on each machine and hands the answers to `ConnectorsStore`. The helper's binary for this app's release is
/// fetched and checked on a machine the first time, without installing its service.
@MainActor
final class ConnectorsController {
    private let environments: Environments
    private var store: ConnectorsStore { .shared }
    var toast: (String, String?, ToastQueue.Kind) -> Void = { _, _, _ in }
    /// One run at a time per machine, so two quick changes never edit the same file at once.
    private var queues: [String: Task<Void, Never>] = [:]

    /// Where test builds keep the helper's files and which home folder `config` edits (scripts/connectors-sandbox):
    /// set both and no real config is read or written.
    private static let testHome = ProcessInfo.processInfo.environment["CANDY_HELPER_TEST_HOME"]
    private static let configHome = ProcessInfo.processInfo.environment["CANDY_CONNECTORS_CONFIG_HOME"]
    /// T3 needs a thread id for a terminal but checks nothing about it; `/` exists on every machine.
    private static let thread = "candywrapper-connectors"

    init(environments: Environments) {
        self.environments = environments
        store.actions.load = { [weak self] id in self?.enqueue(id, changes: nil) }
        store.actions.apply = { [weak self] id, changes in self?.enqueue(id, changes: changes) }
        store.actions.unavailable = {
            HelperController.release == nil ? "This build of CandyWrapper doesn't include the helper, which reads and changes each machine's config." : nil
        }
    }

    private func enqueue(_ env: String, changes: [AgentConfigChange]?) {
        let previous = queues[env]
        queues[env] = Task { [weak self] in
            await previous?.value
            await self?.run(env, changes: changes)
        }
    }

    private func run(_ env: String, changes: [AgentConfigChange]?) async {
        let label = environments.label(env) ?? env
        guard let release = HelperController.release, let session = environments.session(env) else {
            store.set(env, .failed("\(label) isn't connected."))
            return
        }
        let command = HelperInstall.configCommand(release, set: changes != nil, testHome: Self.testHome, configHome: Self.configHome)
        let lines = await HiddenTerminal.run(environments, session: session, env: env, thread: Self.thread, cwd: "/", command: command,
                                             input: changes.map(ConfigWire.encodeChanges))
        let snapshot = lines.lazy.compactMap { line -> AgentConfigSnapshot? in
            if case .config(let b64) = line { ConfigWire.decodeSnapshot(b64) } else { nil }
        }.last
        let failure = lines.lazy.compactMap { line -> String? in if case .failed(let why) = line { why } else { nil } }.last
        if let snapshot {
            store.set(env, .loaded(snapshot))
        } else {
            store.set(env, .failed(failure.map { "\(label): \($0)" } ?? "\(label) didn't answer in time."))
        }
        if changes != nil, let failure, snapshot != nil {
            toast("Couldn't change \(label)'s config", failure, .error)
        }
    }
}
