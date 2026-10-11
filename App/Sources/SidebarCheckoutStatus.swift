import Foundation
import Features
import T3Protocol

/// The branch each checkout is on, for the sidebar hover card's mismatch line (Sidebar.tsx:1243-1255:
/// `vcsEnvironment.status` with `includeRemote: false`, kept like `useRetainedValue` after the lease ends).
/// A checkout is watched on `subscribeVcsStatus` from the first ask until 10 s after the last
/// (`VCS_STATUS_IDLE_TTL_MS`, client-runtime/src/state/vcs.ts:40); the last branch seen stays cached.
// ponytail: watches only checkouts whose hover card opened; T3 leases a status stream per row near the viewport. Add the row lease if rows ever show live git state
@MainActor
final class SidebarCheckoutStatus {
    private let environments: Environments
    private let changed: () -> Void
    private var branches: [String: String] = [:]
    private var watches: [String: (task: Task<Void, Never>, stop: DispatchWorkItem)] = [:]

    init(environments: Environments, changed: @escaping () -> Void) {
        self.environments = environments
        self.changed = changed
    }

    func branch(environmentId: String, cwd: String) -> String? {
        let key = environmentId + "\u{0}" + cwd
        watch(key, environmentId: environmentId, cwd: cwd)
        return branches[key]
    }

    private func watch(_ key: String, environmentId: String, cwd: String) {
        if let existing = watches[key] {
            existing.stop.cancel()
            watches[key]?.stop = scheduleStop(key)
            return
        }
        guard let shell = environments.session(environmentId) else { return }
        let payload: JSONValue = .object(["cwd": .string(cwd), "includeRemote": .bool(false)])
        let task = shell.supervisor.subscribe(VcsRPC.subscribeStatus, payload: { payload }, handler: { [weak self] event in
            guard case .value(let json) = event else { return }
            await MainActor.run { self?.apply(key, json) }
        })
        watches[key] = (task, scheduleStop(key))
    }

    private func scheduleStop(_ key: String) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.watches.removeValue(forKey: key)?.task.cancel()
                self?.statuses[key] = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        return work
    }

    private var statuses: [String: VcsStatus] = [:]

    private func apply(_ key: String, _ json: JSONValue) {
        guard watches[key] != nil else { return }
        statuses[key] = VcsStatus.apply(json, to: statuses[key])
        let ref = statuses[key]?.refName
        guard branches[key] != ref else { return }
        branches[key] = ref
        changed()
    }

    /// A removed environment's checkouts go with it.
    func environmentRemoved(_ environmentId: String) {
        let prefix = environmentId + "\u{0}"
        for key in watches.keys where key.hasPrefix(prefix) { watches.removeValue(forKey: key)?.task.cancel() }
        branches = branches.filter { !$0.key.hasPrefix(prefix) }
        statuses = statuses.filter { !$0.key.hasPrefix(prefix) }
    }
}
