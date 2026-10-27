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
        /// The `environmentIcon` server setting, which overrides the detected machine.
        var iconOverride: String?
        var session: ShellSession?
        /// The newest shell, unscoped.
        var snapshot: ShellSnapshot?
        /// The session's supervisor state, nil while no session runs.
        var state: ConnectionState?
        var watch: Task<Void, Never>?
    }

    private weak var sidebar: SidebarContentView?
    /// Desktop-managed SSH environments; the host runs the T3 release this app speaks (desktop main.ts:117).
    let ssh = SshEnvironmentLauncher(version: ServerVersionSkewLogic.clientVersion)
    /// A toast for an SSH environment that could not connect or lost its tunnel: title and detail.
    var onSshFailure: ((String, String) -> Void)?
    let catalog: EnvironmentCatalog
    let cache: ShellCache
    /// Settled thread snapshots on disk (nil with `CANDY_THREAD_CACHE=off`).
    let threadCache = ThreadCache.forApp()
    private(set) var primaryId: String?
    private var entries: [String: Entry] = [:]
    private var shells = MergedShell()
    /// Sidebar commands not yet reflected in their environment's shell (settle, snooze, pin).
    private var optimistic = OptimisticThreadOverlay()
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
    private(set) var catalogReady = false
    private(set) var saved: [EnvironmentRegistration] = []
    /// Ids being removed (the row menu reads "Removing…").
    private(set) var removing: Set<String> = []
    /// Ids whose `connectSaved` is reading its route and token.
    private var connecting: Set<String> = []
    private var shellSearchGeneration = 0
    /// Connects T3 Connect routes. Nil until the account loads; relay machines wait for it.
    var t3Connect: T3ConnectAuthorizer? {
        didSet {
            guard t3Connect != nil, oldValue == nil else { return }
            for r in saved where r.enabled && r.relay != nil && entries[r.environmentId]?.session == nil { connectSaved(r) }
        }
    }

    init(sidebar: SidebarContentView, catalog: EnvironmentCatalog = EnvironmentCatalog(), cache: ShellCache = ShellCache()) {
        self.sidebar = sidebar
        self.catalog = catalog
        self.cache = cache
        ssh.onTunnelExit = { [weak self] target in
            guard let self, let saved = self.saved.first(where: { $0.sshTarget?.stateKey == target.stateKey }) else { return }
            self.drop(saved.environmentId)
            // ponytail: T3's supervisor prepares the SSH route again on its retry ladder; this drops the session and the
            // row's switch reconnects. Re-run `connectSaved` on the retry ladder if tunnels drop often.
            self.onSshFailure?("SSH connection closed", "The tunnel to \(target.display) closed. Turn the environment off and on in Settings → Connections to reconnect.")
        }
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
    func snapshot(_ environmentId: String) -> ShellSnapshot? { entries[environmentId]?.snapshot }
    func hasPartialShell(_ id: String) -> Bool {
        entries[id]?.session?.isPartial == true || entries[id]?.snapshot?.omissions?.isPartial == true || entries[id]?.snapshot?.olderSettled != nil
    }

    /// A partial sidebar cannot establish whether a worktree is orphaned.
    func worktreeThreadIds(_ environmentId: String, path: String) async throws -> Set<ThreadId>? {
        guard hasPartialShell(environmentId) else { return nil }
        guard let session = session(environmentId), session.omissions.omitIdleSubagents else { throw CommandError.notConnected }
        let json = try await session.supervisor.request("orchestration.getWorktreeThreadIds", payload: .object(["worktreePath": .string(path)]))
        guard case .array(let ids)? = json["threadIds"], ids.allSatisfy({ $0.stringValue != nil }) else { throw CommandError.notConnected }
        return Set(ids.compactMap(\.stringValue).map { ThreadId($0).scoped(to: environmentId) })
    }

    func demandOlderSettled(minimum: Int, projectIds: Set<ProjectId>?) {
        for id in order {
            let local = projectIds.map { $0.filter { $0.environmentId == id }.map(\.localId) }
            let count = local?.isEmpty == true ? 0 : minimum
            entries[id]?.session?.demandOlderSettled(minimum: count, projectIds: local)
        }
    }
    func isRegistered(_ environmentId: String) -> Bool { entries[environmentId] != nil }
    func label(_ environmentId: String) -> String? { entries[environmentId]?.label ?? saved.first { $0.environmentId == environmentId }?.label }
    /// `resolveEnvironmentMachineKind`: the `environmentIcon` setting, else the detected machine.
    func machine(_ environmentId: String) -> String? { entries[environmentId].flatMap { $0.iconOverride ?? $0.machine } }
    func detectedMachine(_ environmentId: String) -> String? { entries[environmentId]?.machine }

    /// The environment's `environmentIcon` setting from its server config.
    func setIconOverride(_ environmentId: String, _ kind: String?) {
        guard entries[environmentId] != nil, entries[environmentId]?.iconOverride != kind else { return }
        entries[environmentId]?.iconOverride = kind
        publishEnvironments()
        changed()
    }

    /// The primary's label and machine from its descriptor: T3 labels the local environment with the
    /// server's label, the host name (environments/primary/context.ts:30, Sidebar.tsx:2503-2509), not "This device".
    func setPrimaryDescriptor(_ descriptor: EnvironmentDescriptor) {
        let id = descriptor.environmentId
        guard entries[id] != nil else { return }
        entries[id]?.label = descriptor.label
        entries[id]?.machine = descriptor.platform?.machine
        publishEnvironments()
        changed()
    }

    /// The primary's detected machine, from its descriptor.
    func setDetectedMachine(_ environmentId: String, _ machine: String?) {
        guard entries[environmentId] != nil, entries[environmentId]?.machine != machine else { return }
        entries[environmentId]?.machine = machine
        publishEnvironments()
        changed()
    }
    /// The session's connection state; nil when no session runs.
    func state(_ environmentId: String) -> ConnectionState? { entries[environmentId]?.state }

    /// This client's session per environment (`GET /api/auth/session`), read once per connected session.
    private var authSessions: [String: AuthSessionState] = [:]
    func setAuthSession(_ session: AuthSessionState?, for environmentId: String) {
        guard authSessions[environmentId] != session else { return }
        authSessions[environmentId] = session
        onAuthSession?(environmentId)
    }
    /// A session's grants changed; the guest share dialog follows them while it shows.
    var onAuthSession: ((String) -> Void)?
    func authSession(_ environmentId: String) -> AuthSessionState? { authSessions[environmentId] }

    /// `readEnvironmentScope(id, orchestration:operate)`: whether this connection may change threads.
    // ponytail: a session not read yet (or a failed read) counts as allowed, where T3 blocks until it reads
    // one; block as T3 does if scoped pairings ever send before the read lands
    func canOperate(_ environmentId: String?) -> Bool {
        guard let environmentId, let session = authSessions[environmentId] else { return true }
        return session.grants(AuthScopes.orchestrationOperate)
    }
    /// `guestShare.create`'s grant, `access:write` (clientRpcPermissions.ts:53-54 at 3669): a guest link hands thread
    /// access to someone outside, like a pairing link. A session not read yet, or a failed read, denies it, as T3's
    /// `permissionAtom` does (commandPermissions.ts:27-33).
    func canCreateGuestShare(_ environmentId: String) -> Bool {
        authSessions[environmentId]?.grants(AuthScopes.accessWrite) ?? false
    }
    /// The route the session uses.
    func routeInUse(_ environmentId: String) -> URL? { entries[environmentId]?.session?.http.baseURL }

    @discardableResult
    func observe(_ change: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = change
        return id
    }

    private func changed() { for o in observers.values { o() } }

    /// After each merge, for views besides the thread view (Settings follows projects and their scripts).
    private var shellObservers: [() -> Void] = []
    /// Each environment's live shell from its server, and nil when the environment leaves or gets a new
    /// session (T3's shell `status` leaving "live"). Cached shells never come through here.
    var onLiveShell: ((String, ShellSnapshot?) -> Void)?
    func observeShell(_ change: @escaping () -> Void) { shellObservers.append(change) }

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
            catalogReady = true
            changed()
            for registration in saved where registration.enabled { connectSaved(registration) }
        }
    }

    /// Connects a saved environment over its first route that answers as that environment (routes.ts:
    /// "the first route in preference order that answers as the expected environment"), else its first.
    /// A saved environment without a token in the Keychain stays listed and "Not connected".
    private func connectSaved(_ registration: EnvironmentRegistration) {
        let id = registration.environmentId
        // One connect per environment at a time (restoreSaved and the t3Connect didSet both call this
        // while the session is nil), and none while the environment is being removed.
        guard id != primaryId, !connecting.contains(id), !removing.contains(id) else { return }
        connecting.insert(id)
        if let target = registration.sshTarget {
            Task {
                defer { connecting.remove(id) }
                do {
                    let bootstrap = try await ssh.ensure(target)
                    guard saved.contains(where: { $0.environmentId == id && $0.enabled }), !removing.contains(id) else { ssh.disconnect(target); return }
                    _ = try await pairSSH(bootstrap, routeTarget: id)
                } catch is CancellationError {
                } catch { onSshFailure?("Could not prepare the SSH environment", String(describing: error)) }
            }
            return
        }
        let catalog = self.catalog, cache = self.cache
        Task {
            let (route, token, cached) = await Task.detached { () -> (URL, String?, ShellSnapshot?) in
                let route = await Self.pickRoute(registration)
                let token = registration.isRelayRoute(route) ? nil : try? catalog.token(environmentId: id, route: route)
                return (route, token, cache.load(environmentId: id)?.snapshot)
            }.value
            connecting.remove(id)
            // Switched off, removed or connected another way while the Keychain read ran.
            guard let current = saved.first(where: { $0.environmentId == id }), current.enabled, !removing.contains(id),
                  entries[id]?.session == nil else { return }
            // Its routes changed meanwhile (a call skipped above carried the new list): start over.
            guard current.routes == registration.routes else { connectSaved(current); return }
            if registration.isRelayRoute(route) {
                guard let authorizer = t3Connect else { return }
                addRemote(environmentId: id, label: registration.label, machine: registration.machine, cached: cached) {
                    ShellSession(environmentId: id, relayBaseURL: route, authorizer: authorizer, cached: $0)
                }
                return
            }
            guard let token else {
                NSLog("environment %@ has no token in the Keychain for its route", id)
                return
            }
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
        // A new route to a machine that is already connected leaves its session on the route it uses. A
        // session keeps its token for life, so re-pairing the route it uses, or a session in error (a
        // revoked token), replaces it with one on the new token.
        let id = stored.environmentId
        let pairedInUse = routeInUse(id).map { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(result.baseURL) } ?? false
        if stored.enabled, entries[id]?.session == nil || pairedInUse || entries[id]?.state?.status == .error {
            addRemote(environmentId: stored.environmentId, label: stored.label, machine: stored.machine,
                      baseURL: result.baseURL, token: token, cached: cache.load(environmentId: stored.environmentId)?.snapshot)
        }
        changed()
        return d.label
    }

    /// `provisionDesktopSshEnvironment` (platform.ts:184-223): pairs over the tunnel with the credential the host
    /// issued, then saves the target and the route like a pairing link. Connection method `ssh` (resolver.ts:250).
    func pairSSH(_ bootstrap: SshEnvironmentLauncher.Bootstrap, routeTarget: String?) async throws -> String {
        let result = try await Pairing.pair(host: bootstrap.baseURL.absoluteString, code: bootstrap.credential, expectedEnvironmentId: routeTarget, identity: ClientIdentity(appVersion: identity.appVersion, connectionMethod: "ssh"))
        let d = result.descriptor
        guard d.environmentId != primaryId else { ssh.disconnect(bootstrap.target); return d.label }
        var registration = EnvironmentRegistration(environmentId: d.environmentId, label: d.label, httpBaseURL: result.baseURL, machine: d.platform?.machine)
        registration.sshTarget = bootstrap.target; registration.sshAlias = bootstrap.target.alias
        let catalog = self.catalog, token = result.token, toSave = registration
        let stored = try await Task.detached { try catalog.add(toSave, token: token) }.value
        upsertSaved(stored)
        addRemote(environmentId: d.environmentId, label: d.label, machine: d.platform?.machine, cached: cache.load(environmentId: d.environmentId)?.snapshot) {
            ShellSession(environmentId: d.environmentId, baseURL: result.baseURL, token: token, cached: $0, connectionMethod: "ssh")
        }
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

    /// A dropped route order from the route list. The session stays on the route it uses.
    func reorderRoutes(_ routes: [URL], environmentId: String) async throws {
        let catalog = self.catalog
        let updated = try await Task.detached { try catalog.reorderRoutes(routes, environmentId: environmentId) }.value
        guard let updated else { return }
        upsertSaved(updated)
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
                        if let cached = cache.load(environmentId: id)?.snapshot {
                            shellChanged(id, cached)
                            LaunchTiming.mark("cached sidebar")
                        }
                        setPrimaryDescriptor(descriptor)
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
        addRemote(environmentId: id, label: label, machine: machine, cached: cached) {
            ShellSession(environmentId: id, baseURL: baseURL, token: token, cached: $0)
        }
    }

    private func addRemote(environmentId id: String, label: String, machine: String?, cached: ShellSnapshot?,
                           session: (ShellSnapshot?) -> ShellSession) {
        guard id != primaryId else { return }
        if entries[id] == nil { order.append(id) }
        var entry = entries[id] ?? Entry(label: label)
        entry.label = label
        entry.machine = machine
        entries[id] = entry
        publishEnvironments()
        changed()
        if let cached, entry.snapshot == nil { shellChanged(id, cached) }
        attach(session(entries[id]?.snapshot), to: id)
    }

    // MARK: T3 Connect

    /// A machine just saved from the T3 Connect account: list it and connect it through the relay.
    func addedRelay(_ registration: EnvironmentRegistration) {
        upsertSaved(registration)
        if registration.enabled, entries[registration.environmentId]?.session == nil { connectSaved(registration) }
        changed()
    }

    /// After sign-out: the catalog already forgot `removed` and dropped the relay route of `updated`.
    /// Their sessions close; cached threads and per-environment state of removed machines go too.
    func appliedRelayRemoval(removed: [String], updated: [EnvironmentRegistration]) async {
        for id in removed {
            if entries[id] != nil {
                drop(id)
                ProjectIconStore.shared.forget(environmentId: id)
                onRemove?(id)
            }
            saved.removeAll { $0.environmentId == id }
            await cache.remove(environmentId: id)
            await threadCache?.removeEnvironment(id)
        }
        for registration in updated {
            let usedRelay = routeInUse(registration.environmentId).map { inUse in
                !registration.routes.contains { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(inUse) } } ?? false
            upsertSaved(registration)
            if usedRelay {
                drop(registration.environmentId)
                if registration.enabled { connectSaved(registration) }
            }
        }
        changed()
    }

    /// A sign-out whose catalog write failed: the relay token is gone, so close every session that uses
    /// a T3 Connect route. Registrations stay as saved.
    func detachRelaySessions() {
        for r in saved where entries[r.environmentId]?.session?.isRelay == true { drop(r.environmentId) }
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
        let catalog = self.catalog, cache = self.cache, threadCache = self.threadCache
        try await Task.detached {
            try catalog.remove(environmentId: environmentId)
            await cache.remove(environmentId: environmentId)
            await threadCache?.removeEnvironment(environmentId)
        }.value
        saved.removeAll { $0.environmentId == environmentId }
    }

    /// Stops the session and takes the environment out of the merged shell.
    private func drop(_ id: String) {
        if let target = saved.first(where: { $0.environmentId == id })?.sshTarget { ssh.disconnect(target) }
        entries[id]?.session?.stop()
        entries[id]?.watch?.cancel()
        entries[id] = nil
        onLiveShell?(id, nil)
        optimistic.remove(environmentId: id)
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
        onLiveShell?(id, nil)
        if let session {
            // ServerController may have set `onSnapshot` (cache, activity); chain after it.
            let previous = session.onSnapshot
            session.onSnapshot = { [weak self, weak session] snapshot in
                previous?(snapshot)
                guard let self, let session, self.entries[id]?.session === session else { return }
                self.onLiveShell?(id, snapshot)
                if id == self.primaryId { LaunchTiming.mark("live sidebar") }
                if id != self.primaryId { Task { await self.cache.noteChanged(snapshot, environmentId: id) } }
            }
            session.onDisplaySnapshot = { [weak self, weak session] snapshot in
                guard let self, let session, self.entries[id]?.session === session else { return }
                self.shellChanged(id, snapshot)
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
        optimistic.reconcile(environmentId: id, snapshotSequence: snapshot.snapshotSequence)
        shells.set(optimistic.apply(snapshot, environmentId: id), environmentId: id)
        merge()
    }

    /// Re-merges an environment's last shell after its optimistic updates changed.
    private func reapplyOptimistic(_ id: String) {
        guard let snapshot = entries[id]?.snapshot else { return }
        shellChanged(id, snapshot)
    }

    // MARK: Commands

    enum CommandError: LocalizedError {
        case notConnected
        var errorDescription: String? { "This environment is not connected." }
    }

    /// One unary call on the environment's own socket.
    func request(_ environmentId: String, _ method: String, _ payload: JSONValue) async throws -> JSONValue {
        guard let session = session(environmentId) else { throw CommandError.notConnected }
        return try await session.supervisor.request(method, payload: payload)
    }

    /// One unary call that gives up after `timeout`, for calls queued behind each other.
    func request(_ environmentId: String, _ method: String, _ payload: JSONValue, timeout: Duration) async throws -> JSONValue {
        guard let session = session(environmentId) else { throw CommandError.notConnected }
        return try await session.supervisor.request(method, payload: payload, timeout: timeout)
    }

    /// `orchestration.dispatchCommand` on the environment of `threadId` (a scoped id). With `update`, the
    /// sidebar shows the change at once; a failure takes it back, a success keeps it until the shell
    /// reaches the command's sequence (`createOptimisticThreadLifecycle`).
    @discardableResult
    func dispatch(_ threadId: ThreadId, _ payload: JSONValue, optimistic update: OptimisticThreadUpdate? = nil) async throws -> JSONValue {
        guard let env = threadId.environmentId else { throw CommandError.notConnected }
        let token = update.map { optimistic.begin($0, threadId: threadId.localId, environmentId: env) }
        if token != nil { reapplyOptimistic(env) }
        do {
            let result = try await request(env, "orchestration.dispatchCommand", payload)
            if let token {
                if let sequence = ThreadCommands.sequence(result) { optimistic.confirm(token, sequence: sequence) } else { optimistic.cancel(token) }
                reapplyOptimistic(env)
            }
            return result
        } catch {
            if let token { optimistic.cancel(token); reapplyOptimistic(env) }
            throw error
        }
    }

    private func merge() {
        let shown = shells.merged(order: order)
        sidebar?.setSnapshot(shown, animated: sidebar?.snapshot != nil, changedThreadIds: shells.lastChangedThreadIds)
        if let shown { onShell?(shown) }
        for o in shellObservers { o() }
    }

    private func publishEnvironments() {
        guard let sidebar else { return }
        var envs = SidebarEnvironments(primaryId: primaryId)
        for (id, entry) in entries {
            envs.labels[id] = entry.label
            if let machine = entry.iconOverride ?? entry.machine { envs.machines[id] = machine }
        }
        sidebar.state.environments = envs
    }

    /// Ends every session (quit).
    func stopAll() {
        ssh.shutdown()
        for id in order { entries[id]?.session?.stop() }
    }

    /// Searches every connected environment at once and scopes the matches (`orchestration.searchThreads`).
    func searchThreads(_ query: String) async -> [ThreadSearchMatch]? {
        let revision = shellSearchGeneration
        let projectIds = sidebar?.resolvedProjectIds
        let sessions = order.compactMap { id in entries[id]?.session.map { (id, $0, entries[id]?.label ?? "") } }
        guard !sessions.isEmpty else { return nil }
        return await withTaskGroup(of: [ThreadSearchMatch]?.self) { group in
            for (id, session, label) in sessions {
                group.addTask {
                    await self.searchThreadMatches(query, id: id, session: session, label: label,
                                                   projectIds: projectIds, revision: revision)
                }
            }
            var all: [ThreadSearchMatch]?
            for await part in group { if let part { all = (all ?? []) + part } }
            return all
        }
    }

    private func searchThreadMatches(_ query: String, id: String, session: ShellSession, label: String,
                                     projectIds: Set<ProjectId>?, revision: Int) async -> [ThreadSearchMatch]? {
        let generation = await session.store.generation
        var payload: [String: JSONValue] = ["query": .string(query)]
        // The server needs a word of three or more letters to match messages; a shorter query still finds the
        // titles of older settled threads the shell leaves out (threadSearch.ts:126-151).
        let searchMessages = !PaletteScoring.messageSearchTokens(query).long.isEmpty
        let cut = session.omissions.omitOlderSettled ? await session.store.snapshot?.olderSettled : nil
        guard searchMessages || cut != nil else { return [] }
        if let cut {
            payload["olderSettledBefore"] = .string(cut.before)
            payload["environmentLabel"] = .string(label)
            if let projectIds {
                payload["projectIds"] = .array(projectIds.filter { $0.environmentId == id }.map { .string($0.localId.rawValue) })
            }
            if !searchMessages { payload["titlesOnly"] = .bool(true) }
        }
        guard let json = try? await session.supervisor.request("orchestration.searchThreads", payload: .object(payload)),
              !Task.isCancelled, self.shellSearchGeneration == revision, generation == (await session.store.generation),
              let result = try? json.decode(as: ThreadSearchResult.self) else { return nil }
        let matches = result.matches
        if let sequence = result.snapshotSequence, let rows = result.threads {
            await session.mountSearch(.init(snapshotSequence: sequence, threads: rows), generation: generation)
        }
        return matches.map { EnvironmentScope.scope($0, id) }
    }

    func clearShellSearch() {
        shellSearchGeneration += 1
        for entry in entries.values {
            guard let session = entry.session else { continue }
            Task { await session.mountSearch(nil, generation: await session.store.generation) }
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
