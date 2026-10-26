import Foundation
import T3Protocol
import T3Store

/// T3's `RunningThreadKeepAlive` (apps/web/src/components/desktop/RunningThreadKeepAlive.tsx,
/// `createRunningThreadKeepAliveAtom` in apps/web/src/state/threads.ts:53-127): on desktop every running
/// thread in every connected environment keeps its detail stream open, so opening one shows live state
/// without a replay. T3 holds no power assertion or App Nap exemption for it, so neither does this.
/// The streams exist only while threads run; with nothing running nothing is subscribed.
@MainActor
final class RunningThreadKeepAlive {
    private struct Kept {
        let store: ThreadStore
        let relay: ShellSession.ChangeRelay
        let subscription: Task<Void, Never>
        /// The supervisor the stream runs on. A re-paired environment gets a new one, and the stream moves to it.
        let supervisor: ObjectIdentifier
    }

    private let environments: Environments
    private var kept: [ThreadId: Kept] = [:]
    /// The thread the panel streams itself (not kept twice).
    var openThread: () -> ThreadId? = { nil }
    /// A closed thread's retained store, reused instead of a cold one.
    var takeRetained: (ThreadId) -> ThreadSession.Retained? = { _ in nil }
    /// A stopped thread's store goes back to the controller's 5-minute retention.
    var retain: (ThreadId, ThreadSession.Retained) -> Void = { _, _ in }

    init(environments: Environments) {
        self.environments = environments
        environments.observeShell { [weak self] in self?.update() }
    }

    /// `isRunning` (threads.ts:53-54).
    static func isRunning(_ status: ThreadStatus) -> Bool { [.preparing, .starting, .running].contains(status) }

    /// Scoped ids of the running threads of every environment with a session.
    private func runningThreads() -> Set<ThreadId> {
        var ids = Set<ThreadId>()
        for env in environments.environmentIds where environments.session(env) != nil {
            for t in environments.snapshot(env)?.threads ?? [] where Self.isRunning(t.status) {
                ids.insert(ThreadId(EnvironmentScope.key(env, t.id.rawValue)))
            }
        }
        return ids
    }

    func update() {
        let running = runningThreads()
        watchRunningEnvironments(running)
        let open = openThread()
        // ponytail: drops a stream when the shell reports the stop, T3 waits for the detail stream to show it too; add the detail check if reopened threads miss their last events
        for (id, entry) in kept where !running.contains(id) || id == open {
            entry.subscription.cancel()
            kept[id] = nil
            if id != open { retain(id, ThreadSession.Retained(store: entry.store, relay: entry.relay)) }
        }
        // A replaced session (re-pairing) leaves the old supervisor disconnected for good, so the stream
        // moves to the new one with the same store, which resumes from its cursor.
        for (id, entry) in kept {
            guard let env = id.environmentId, let session = environments.session(env),
                  ObjectIdentifier(session.supervisor) != entry.supervisor else { continue }
            entry.subscription.cancel()
            kept[id] = subscribe(store: entry.store, relay: entry.relay, session: session)
        }
        for id in running where kept[id] == nil && id != open {
            guard let env = id.environmentId, let session = environments.session(env) else { continue }
            let retained = takeRetained(id)
            let relay = retained?.relay ?? ShellSession.ChangeRelay()
            relay.set {}
            let store = retained?.store ?? ThreadStore(threadId: id.localId, cache: environments.threadCache, environmentId: env,
                                                       onChange: { relay.fire() })
            kept[id] = subscribe(store: store, relay: relay, session: session)
        }
    }

    private func subscribe(store: ThreadStore, relay: ShellSession.ChangeRelay, session: ShellSession) -> Kept {
        let wireSubscription = UUID()
        let subscription = session.supervisor.subscribe("orchestration.subscribeThread", payload: {
            ThreadSession.encode(await store.subscribeInput(subscription: wireSubscription))
        }, handler: { event in
            guard case .value(let json) = event else { return }
            try await ThreadSession.applyWire(json, to: store, subscription: wireSubscription)
        })
        return Kept(store: store, relay: relay, subscription: subscription, supervisor: ObjectIdentifier(session.supervisor))
    }

    /// The supervisor each environment last heard from, and what it heard.
    private var watching: [String: (supervisor: ObjectIdentifier, on: Bool)] = [:]

    /// A running turn should keep streaming, so its environment's socket gets checked when it goes quiet
    /// (`ConnectionSupervisor.setExpectingTraffic`). Idle environments stay at zero wakeups.
    private func watchRunningEnvironments(_ running: Set<ThreadId>) {
        let busy = Set(running.compactMap(\.environmentId))
        for env in environments.environmentIds {
            guard let supervisor = environments.session(env)?.supervisor else { watching[env] = nil; continue }
            let entry = (supervisor: ObjectIdentifier(supervisor), on: busy.contains(env))
            if let old = watching[env], old.supervisor == entry.supervisor, old.on == entry.on { continue }
            watching[env] = entry
            Task { await supervisor.setExpectingTraffic(entry.on) }
        }
    }

    /// Opening a kept thread: its up-to-date store, with the stream handed to the panel's session.
    func take(_ id: ThreadId) -> ThreadSession.Retained? {
        guard let entry = kept.removeValue(forKey: id) else { return nil }
        entry.subscription.cancel()
        return ThreadSession.Retained(store: entry.store, relay: entry.relay)
    }

    /// An environment left: its streams end.
    func drop(environmentId: String) {
        for (id, entry) in kept where id.environmentId == environmentId {
            entry.subscription.cancel()
            kept[id] = nil
        }
    }
}
