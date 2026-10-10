import AppKit
import Features
import T3Client
import T3Protocol
import T3Store

/// Every environment the window shows (docs/research/L-multi-environment.md): the local one, which
/// `ServerController` manages like T3's platform-managed primary, plus saved remote environments from
/// `EnvironmentCatalog` and development `--server` pairs. Each enabled environment has one
/// `ShellSession` (one socket). Their shells merge, scoped, into the one sidebar.
///
/// Commands never fall back to a current environment: callers pass the environment of the thread or
/// project they act on, from its scoped id, and get that environment's session.
@MainActor
final class Environments {
    struct Entry {
        var label: String
        var machine: String?
        var session: ShellSession?
        /// The newest shell, unscoped.
        var snapshot: ShellSnapshot?
        /// The session's supervisor state, nil while no session runs.
        var state: ConnectionState?
        var watch: Task<Void, Never>?
    }

    private weak var sidebar: SidebarContentView?
    let catalog: EnvironmentCatalog
    let cache: ShellCache
    private(set) var primaryId: String?
    private var entries: [String: Entry] = [:]
    private var shells = MergedShell()
    /// Registration order, the primary first. The merge follows it; sorting doesn't depend on it.
    private var order: [String] = []
    private let iconRoutes = IconRoutes()
    private let identity = ClientIdentity(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")

    /// An environment's session started, was replaced or went away.
    var onSessionChange: ((String) -> Void)?
    /// After each merge.
    var onShell: ((ShellSnapshot) -> Void)?
    /// An environment was removed: drop everything kept for it.
    var onRemove: ((String) -> Void)?
    /// A connection state, the saved list or a label changed (Settings > Connections, the composer banner).
    private var observers: [UUID: () -> Void] = [:]
    /// Every saved environment, enabled or not, in catalog order. Loaded by `restoreSaved`.
    private(set) var saved: [EnvironmentRegistration] = []
    /// Ids being removed (the row menu reads "Removing…").
    private(set) var removing: Set<String> = []

    init(sidebar: SidebarContentView, catalog: EnvironmentCatalog = EnvironmentCatalog(), cache: ShellCache = ShellCache()) {
        self.sidebar = sidebar
        self.catalog = catalog
        self.cache = cache
        let routes = iconRoutes
        ProjectIconStore.shared.loader = { env, cwd, path in
            guard let route = routes.get(env) else { throw CancellationError() }
            return try await ShellSession.projectIconLoader(route.supervisor, http: route.http, token: route.token)(env, cwd, path)
        }
    }

    // MARK: Lookup

    func session(_ environmentId: String?) -> ShellSession? { environmentId.flatMap { entries[$0]?.session } }
    var environmentIds: [String] { order }
    /// Whether the environment's shell has arrived (from the disk cache or the server).
    func hasShell(_ environmentId: String) -> Bool { entries[environmentId]?.snapshot != nil }
    func isRegistered(_ environmentId: String) -> Bool { entries[environmentId] != nil }
    func label(_ environmentId: String) -> String? { entries[environmentId]?.label ?? saved.first { $0.environmentId == environmentId }?.label }
    func machine(_ environmentId: String) -> String? { entries[environmentId]?.machine }
    /// The session's connection state; nil when no session runs.
    func state(_ environmentId: String) -> ConnectionState? { entries[environmentId]?.state }
    /// The route the session uses.
    func routeInUse(_ environmentId: String) -> URL? { entries[environmentId]?.session?.http.baseURL }

    @discardableResult
    func observe(_ change: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = change
        return id
    }

    private func changed() { for o in observers.values { o() } }

    // MARK: The local environment

    /// The local server's shell from the disk cache, before it answers.
    func showCachedPrimary(_ environmentId: String, _ snapshot: ShellSnapshot?) {
        setPrimaryId(environmentId)
        if let snapshot { shellChanged(environmentId, snapshot) }
    }

    /// The local session, or nil when it ended (idle stop). The sidebar keeps the last shell.
    func setPrimary(_ session: ShellSession?, environmentId: String?) {
        if let environmentId { setPrimaryId(environmentId) }
        guard let id = environmentId ?? primaryId else { return }
        attach(session, to: id)
    }

    private func setPrimaryId(_ id: String) {
        guard id != primaryId else { return }
        // Another home answers now: the old local environment leaves the view, its data stays.
        if let old = primaryId { drop(old) }
        primaryId = id
        if entries[id] == nil { entries[id] = Entry(label: "This device") }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        publishEnvironments()
    }

    // MARK: Remote environments

    /// Connects every enabled saved environment, each from its cached shell. Keychain reads run off
    /// the main thread, since one can wait on an access prompt.
    func restoreSaved() {
        let catalog = self.catalog
        Task {
            saved = await Task.detached { catalog.load() }.value
            changed()
            for registration in saved where registration.enabled { connectSaved(registration) }
        }
    }

    /// Connects a saved environment over its first route that answers as that environment (routes.ts:
    /// "the first route in preference order that answers as the expected environment"), else its first.
    /// A saved environment without a token in the Keychain stays listed and "Not connected".
    private func connectSaved(_ registration: EnvironmentRegistration) {
        let id = registration.environmentId
        guard id != primaryId else { return }
        let catalog = self.catalog, cache = self.cache
        Task {
            let (route, token, cached) = await Task.detached { () -> (URL, String?, ShellSnapshot?) in
                let route = await Self.pickRoute(registration)
                return (route, try? catalog.token(environmentId: id, route: route), cache.load(environmentId: id)?.snapshot)
            }.value
            guard let token else {
                NSLog("environment %@ has no token in the Keychain for its route", id)
                return
            }
            // Switched off or removed while the Keychain read ran.
            guard saved.first(where: { $0.environmentId == id })?.enabled == true else { return }
            addRemote(environmentId: id, label: registration.label, machine: registration.machine, baseURL: route, token: token, cached: cached)
        }
    }

    /// The first route whose descriptor answers within T3's 2.5 s route check with the saved id.
    // ponytail: picked once per connect; T3 also rechecks every 60 s for a better route while on a fallback
    nonisolated static func pickRoute(_ registration: EnvironmentRegistration) async -> URL {
        guard registration.routes.count > 1 else { return registration.httpBaseURL }
        for route in registration.routes {
            var http = EnvironmentHTTP(baseURL: route)
            http.timeout = 2.5
            if let d = try? await http.descriptor(), d.environmentId == registration.environmentId { return route }
        }
        return registration.httpBaseURL
    }

    /// Add Environment: pairs over host and code, saves the route and its token, and connects
    /// (onboarding.ts `registerPairingConnection`). Pairing the local environment saves nothing, as
    /// T3's registry ignores platform environments. Returns the environment's label.
    func pair(host: String, code: String, routeTarget: String?) async throws -> String {
        let result = try await Pairing.pair(host: host, code: code, expectedEnvironmentId: routeTarget, identity: identity)
        let d = result.descriptor
        guard d.environmentId != primaryId else { return d.label }
        let registration = EnvironmentRegistration(environmentId: d.environmentId, label: d.label, httpBaseURL: result.baseURL,
                                                   machine: d.platform?.machine)
        let catalog = self.catalog, token = result.token
        let stored = try await Task.detached { try catalog.add(registration, token: token) }.value
        upsertSaved(stored)
        // A new route to a machine that is already connected leaves its session on the route it uses.
        if stored.enabled, entries[stored.environmentId]?.session == nil {
            addRemote(environmentId: stored.environmentId, label: stored.label, machine: stored.machine,
                      baseURL: result.baseURL, token: token, cached: cache.load(environmentId: stored.environmentId)?.snapshot)
        }
        changed()
        return d.label
    }

    private func upsertSaved(_ registration: EnvironmentRegistration) {
        if let i = saved.firstIndex(where: { $0.environmentId == registration.environmentId }) { saved[i] = registration } else { saved.append(registration) }
    }

    /// The row switch (`setEnabled`): off keeps the registration, token and cache and closes the socket;
    /// its projects and threads leave the sidebar. On connects again.
    func setEnabled(_ environmentId: String, _ enabled: Bool) async throws {
        let catalog = self.catalog
        try await Task.detached { try catalog.setEnabled(enabled, environmentId: environmentId) }.value
        guard let i = saved.firstIndex(where: { $0.environmentId == environmentId }) else { return }
        saved[i].enabled = enabled
        if enabled {
            connectSaved(saved[i])
        } else if entries[environmentId] != nil {
            drop(environmentId)
        }
        changed()
    }

    /// The route list's remove button. Reconnects when the session used that route.
    func removeRoute(_ route: URL, environmentId: String) async throws {
        let catalog = self.catalog
        let updated = try await Task.detached { try catalog.removeRoute(route, environmentId: environmentId) }.value
        guard let updated else { return }
        let wasInUse = routeInUse(environmentId).map { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(route) } ?? false
        upsertSaved(updated)
        if wasInUse, updated.enabled {
            drop(environmentId)
            connectSaved(updated)
        }
        changed()
    }

    /// The thread banner's "Reconnect" (`retryEnvironment`).
    func reconnect(_ environmentId: String) {
        guard let supervisor = entries[environmentId]?.session?.supervisor else { return }
        Task { await supervisor.retryNow() }
    }

    /// Development: a server and token from the command line. Not saved. The descriptor gives the
    /// environment's id, label and machine; while the server doesn't answer it retries on T3's ladder.
    func addDevelopment(baseURL: URL, token: String, primary: Bool) {
        let http = EnvironmentHTTP(baseURL: baseURL)
        Task {
            var failures = 0
            while true {
                do {
                    let descriptor = try await http.descriptor()
                    let id = descriptor.environmentId
                    if primary {
                        setPrimaryId(id)
                        if let cached = cache.load(environmentId: id)?.snapshot { shellChanged(id, cached) }
                        entries[id]?.label = descriptor.label
                        entries[id]?.machine = descriptor.platform?.machine
                        attach(ShellSession(environmentId: id, baseURL: baseURL, token: token, cached: entries[id]?.snapshot), to: id)
                    } else {
                        addRemote(environmentId: id, label: descriptor.label, machine: descriptor.platform?.machine,
                                  baseURL: baseURL, token: token, cached: cache.load(environmentId: id)?.snapshot)
                    }
                    return
                } catch {
                    let delay = Backoff.delayMilliseconds(failureCount: failures, random: Double.random(in: 0..<1))
                    failures += 1
                    NSLog("environment at %@ not answering (%@), retrying in %d ms", baseURL.absoluteString,
                          String(describing: error), delay)
                    try? await Task.sleep(for: .milliseconds(delay))
                }
            }
        }
    }

    private func addRemote(environmentId id: String, label: String, machine: String?, baseURL: URL, token: String, cached: ShellSnapshot?) {
        guard id != primaryId else { return }
        if entries[id] == nil { order.append(id) }
        var entry = entries[id] ?? Entry(label: label)
        entry.label = label
        entry.machine = machine
        entries[id] = entry
        publishEnvironments()
        changed()
        if let cached, entry.snapshot == nil { shellChanged(id, cached) }
        attach(ShellSession(environmentId: id, baseURL: baseURL, token: token, cached: entries[id]?.snapshot), to: id)
    }

    /// Removes a saved or development environment: closes its socket, forgets its registration, token,
    /// cached shell and icons, and has every per-environment store drop its entries (`onRemove`).
    /// T3 clears only composer drafts here (L 3.5); this clears the rest too. The local environment
    /// is platform-managed and can't be removed.
    func remove(_ environmentId: String) {
        Task { try? await removeSaved(environmentId) }
    }

    /// "Remove from this device": forgets the registration, every route token and the cache.
    func removeSaved(_ environmentId: String) async throws {
        guard environmentId != primaryId else { return }
        removing.insert(environmentId)
        changed()
        defer { removing.remove(environmentId); changed() }
        if entries[environmentId] != nil {
            drop(environmentId)
            ProjectIconStore.shared.forget(environmentId: environmentId)
            onRemove?(environmentId)
        }
        let catalog = self.catalog, cache = self.cache
        try await Task.detached {
            try catalog.remove(environmentId: environmentId)
            await cache.remove(environmentId: environmentId)
        }.value
        saved.removeAll { $0.environmentId == environmentId }
    }

    /// Stops the session and takes the environment out of the merged shell.
    private func drop(_ id: String) {
        entries[id]?.session?.stop()
        entries[id]?.watch?.cancel()
        entries[id] = nil
        shells.remove(id)
        iconRoutes.set(id, nil)
        order.removeAll { $0 == id }
        publishEnvironments()
        merge()
        onSessionChange?(id)
        changed()
    }

    // MARK: Sessions and shells

    private func attach(_ session: ShellSession?, to id: String) {
        guard entries[id] != nil else { return }
        if let old = entries[id]?.session, old !== session { old.stop() }
        entries[id]?.session = session
        entries[id]?.watch?.cancel()
        entries[id]?.state = nil
        entries[id]?.watch = session.map { session in
            Task { [weak self, weak session] in
                guard let stream = await session?.supervisor.states() else { return }
                for await state in stream {
                    guard let self, let session, self.entries[id]?.session === session else { return }
                    self.entries[id]?.state = state
                    self.changed()
                }
            }
        }
        changed()
        if let session {
            // ServerController may have set `onSnapshot` (cache, activity); chain after it.
            let previous = session.onSnapshot
            session.onSnapshot = { [weak self, weak session] snapshot in
                previous?(snapshot)
                guard let self, let session, self.entries[id]?.session === session else { return }
                self.shellChanged(id, snapshot)
                if id != self.primaryId { Task { await self.cache.noteChanged(snapshot, environmentId: id) } }
            }
            iconRoutes.set(id, IconRoutes.Route(supervisor: session.supervisor, http: session.http, token: session.token))
            ProjectIconStore.shared.forget(environmentId: id)
            session.start()
        }
        onSessionChange?(id)
    }

    private func shellChanged(_ id: String, _ snapshot: ShellSnapshot) {
        guard entries[id] != nil else { return }
        entries[id]?.snapshot = snapshot
        shells.set(snapshot, environmentId: id)
        merge()
    }

    private func merge() {
        let shown = shells.merged(order: order)
        sidebar?.setSnapshot(shown, animated: sidebar?.snapshot != nil)
        if let shown { onShell?(shown) }
    }

    private func publishEnvironments() {
        guard let sidebar else { return }
        var envs = SidebarEnvironments(primaryId: primaryId)
        for (id, entry) in entries {
            envs.labels[id] = entry.label
            if let machine = entry.machine { envs.machines[id] = machine }
        }
        sidebar.state.environments = envs
    }

    /// Ends every session (quit).
    func stopAll() {
        for id in order { entries[id]?.session?.stop() }
    }

    /// Searches every connected environment at once and scopes the matches (`orchestration.searchThreads`).
    func searchThreads(_ query: String) async -> [ThreadSearchMatch]? {
        let sessions = order.compactMap { id in entries[id]?.session.map { (id, $0.supervisor) } }
        guard !sessions.isEmpty else { return nil }
        return await withTaskGroup(of: [ThreadSearchMatch]?.self) { group in
            for (id, supervisor) in sessions {
                group.addTask {
                    guard let json = try? await supervisor.request("orchestration.searchThreads", payload: .object(["query": .string(query)])),
                          let matches = (try? json.decode(as: ThreadSearchResult.self))?.matches else { return nil }
                    return matches.map { EnvironmentScope.scope($0, id) }
                }
            }
            var all: [ThreadSearchMatch]?
            for await part in group { if let part { all = (all ?? []) + part } }
            return all
        }
    }

    /// Project icon routes, read from the icon store's detached loads.
    final class IconRoutes: @unchecked Sendable {
        struct Route { let supervisor: ConnectionSupervisor; let http: EnvironmentHTTP; let token: String }
        private let lock = NSLock()
        private var routes: [String: Route] = [:]
        func set(_ id: String, _ route: Route?) { lock.withLock { routes[id] = route } }
        func get(_ id: String) -> Route? { lock.withLock { routes[id] } }
    }
}
