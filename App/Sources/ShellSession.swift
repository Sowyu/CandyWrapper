import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// One environment's socket and shell stream: supervisor (one WebSocket, T3's reconnect and backoff),
/// the `orchestration.subscribeShell` subscription (resumes from the store's cursor) and the store
/// (decodes and reduces off the main thread). `Environments` merges every session's shell for the sidebar.
@MainActor
final class ShellSession {
    private var lifecycleSubscription: Task<Void, Never>?
    private(set) var welcome: JSONValue?
    var lifecycleObservers: [UUID: (JSONValue) -> Void] = [:]
    let environmentId: String
    let supervisor: ConnectionSupervisor
    let configFeed: ServerConfigFeed
    let store: ShellStore
    /// The same server and token for HTTP routes, such as thread history pages.
    let http: EnvironmentHTTP
    let token: String
    private var subscription: Task<Void, Never>?
    private var configurationWatch: Task<Void, Never>?
    private var negotiatedServerVersion: String?
    private var negotiatedConfig = false
    private var latestConfiguration: (generation: Int, omissions: ShellOmissions, marker: Bool)?
    private var pulling = false
    private var pullAgain = false
    /// Sidebar changes reach the UI at most once per frame (30 a second when constrained).
    private lazy var pacer = FramePacer { [weak self] in self?.pull() }
    private var started = false
    private var stopped = false
    private var preparedGeneration = 0
    private var preparingGeneration = 0
    private(set) var omissions = ShellOmissions()
    private var completionMarker = false
    private var resumingConnection = false
    private var familyConsumers: [UUID: ThreadId] = [:]
    private var familyReads: [ThreadId: Task<Void, Never>] = [:]
    private var loadedFamilies: [ThreadId: Int] = [:]
    private var familyTokens: [ThreadId: UUID] = [:]
    private var missingThreads: Set<ThreadId> = []
    var isPartial: Bool { omissions.isPartial }
    func confirmsMissing(_ id: ThreadId) -> Bool { missingThreads.contains(id.localId) }
    private var shownGeneration = 0
    private var countRead: Task<Void, Never>?
    private var countReadToken: UUID?
    private var olderRead: Task<Void, Never>?
    private var olderReadToken: UUID?
    private var clearOlderPages = false
    private var olderScope: [ProjectId]?
    private var olderMinimum = 0
    private var olderAttempted = 0
    private var olderCursor: OlderSettledCursor?
    private var olderFinished = false
    var onDisplaySnapshot: ((ShellSnapshot) -> Void)?
    /// After each change window, with the store's whole shell, unscoped (merge, disk cache, activity).
    var onSnapshot: ((ShellSnapshot) -> Void)?

    /// `environmentId` is the descriptor's id. The connector refuses a server that answers with another
    /// id (T3 does the same before it spends a pairing code, onboarding.ts:112-123).
    convenience init(environmentId: String, baseURL: URL, token: String, cached: ShellSnapshot? = nil, connectionMethod: String = "direct") {
        let http = EnvironmentHTTP(baseURL: baseURL)
        let identity = ClientIdentity(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0", connectionMethod: connectionMethod)
        self.init(environmentId: environmentId, http: http, token: token, cached: cached,
                  supervisor: ConnectionSupervisor(dependencies: .init(
                    connect: ConnectionSupervisor.directConnector(http: http, environmentId: environmentId, identity: identity,
                                                                  token: { token }))))
    }

    /// A T3 Connect session: the socket comes from `authorizer` over the tunnel at `baseURL`, and every
    /// HTTP call carries `Authorization: DPoP` with a fresh proof. Tunnels drop idle sockets, so it pings
    /// every 80 s (T3ConnectAuthorizer.connector).
    convenience init(environmentId: String, relayBaseURL baseURL: URL, authorizer: T3ConnectAuthorizer, cached: ShellSnapshot? = nil) {
        var http = EnvironmentHTTP(baseURL: baseURL)
        http.authorize = { method, url, rejected in
            try await authorizer.authorizationHeaders(environmentId: environmentId, method: method, url: url, rejected: rejected)
        }
        self.init(environmentId: environmentId, http: http, token: "", cached: cached,
                  supervisor: ConnectionSupervisor(dependencies: .init(connect: authorizer.connector(environmentId: environmentId)),
                                                   keepalive: .ping(interval: .seconds(80))))
    }

    private init(environmentId: String, http: EnvironmentHTTP, token: String, cached: ShellSnapshot?, supervisor: ConnectionSupervisor) {
        self.environmentId = environmentId
        self.http = http
        self.token = token
        self.supervisor = supervisor
        configFeed = ServerConfigFeed(supervisor: supervisor)
        let relay = ChangeRelay()
        store = ShellStore(cached: cached, onChange: { relay.fire() })
        relay.set { [weak self] in Task { @MainActor in self?.pacer.request() } }
    }

    /// Connects and subscribes once; later calls do nothing.
    func start() {
        guard !started, !stopped else { return }
        started = true
        let feed = configFeed
        configurationWatch = Task { [weak self] in
            await feed.start()
            var generation = 0
            for await event in await feed.events() {
                if Task.isCancelled { return }
                switch event {
                case .subscribed(let next): generation = next
                case .value(let json) where json["type"]?.stringValue == "snapshot":
                    if let config = json["config"] { await self?.configurationChanged(config, generation: generation) }
                default: break
                }
            }
        }
        lifecycleSubscription = supervisor.subscribe("subscribeServerLifecycle", payload: { .object([:]) }) { [weak self] event in
            guard case .value(let json) = event else { return }
            await MainActor.run {
                guard let self else { return }
                if json["type"]?.stringValue == "welcome" { self.welcome = json["payload"] }
                for observer in self.lifecycleObservers.values { observer(json) }
            }
        }
        // `stop` can run before this task reaches the supervisor; its disconnect must win.
        Task { [supervisor] in
            await supervisor.observePlatform()
            await supervisor.connect(unlessStopped: { @MainActor [weak self] in self?.stopped ?? true })
        }
        subscribeShell()
    }

    private func subscribeShell() {
        subscription = supervisor.subscribe("orchestration.subscribeShell", payload: { [weak self] in
            await self?.subscribeInput() ?? .object([:])
        }, handler: { [weak self] event in
            guard let self else { return }
            switch event {
            case .subscribed(let generation): await self.prepareShell(generation)
            case .value(let json): await self.receive(json)
            case .interrupted: break
            }
        })
    }

    private func configurationChanged(_ config: JSONValue, generation: Int) async {
        let policy = ShellOmissions(config: config)
        let marker = config["shellResumeCompletionMarker"]?.boolValue == true
        latestConfiguration = (generation, policy, marker)
        guard !stopped, preparedGeneration == generation,
              await supervisor.state.generation == generation,
              policy != omissions || marker != completionMarker else { return }
        // Recheck even when a development server changes flags without changing its version.
        subscription?.cancel()
        preparedGeneration = 0
        resumePrepared = false
        subscribeShell()
    }

    private func configurationStillMatches(_ generation: Int) -> Bool {
        guard let latestConfiguration, latestConfiguration.generation == generation else { return true }
        return latestConfiguration.omissions == omissions && latestConfiguration.marker == completionMarker
    }

    /// A disk shell is paint-only. Warm in-memory shells resume when omissions match, retaining
    /// CandyWrapper's delta reconnect; policy changes and cold caches get authoritative HTTP.
    private func prepareShell(_ generation: Int) async {
        guard preparedGeneration != generation, !stopped, !Task.isCancelled else { return }
        preparingGeneration = generation
        let version = await supervisor.serverVersion
        if negotiatedConfig, let version, version == negotiatedServerVersion,
           await store.canResume(omissions: omissions), configurationStillMatches(generation), !stopped, !Task.isCancelled {
            resumePrepared = true
            resumingConnection = true
            preparedGeneration = generation
            if !completionMarker { await store.resumed(); resumingConnection = false }
            return
        }
        let config = await configFeed.initialConfig(generation: generation)
        guard !stopped, !Task.isCancelled, preparingGeneration == generation, await supervisor.state.generation == generation else { return }
        omissions = ShellOmissions(config: config ?? .null)
        completionMarker = config?["shellResumeCompletionMarker"]?.boolValue == true
        negotiatedConfig = config != nil
        negotiatedServerVersion = version
        if await store.canResume(omissions: omissions) {
            resumePrepared = true
            resumingConnection = true
            preparedGeneration = generation
            if !completionMarker { await store.resumed(); resumingConnection = false }
            return
        }
        resumingConnection = false
        var transport = http
        transport.timeout = 20
        let policy = omissions
        let snapshot = try? await transport.get(policy.snapshotPath, token: token, as: ShellSnapshot.self)
        guard !Task.isCancelled, !stopped, preparingGeneration == generation, await supervisor.state.generation == generation else { return }
        if var snapshot {
            missingThreads = []
            snapshot.omissions = policy
            await store.apply([.snapshot(snapshot, resolvedRepositoryIdentityRoots: nil)])
        }
        // HTTP failure requests a socket snapshot, never a resume from the old cache.
        preparedGeneration = generation
        resumePrepared = snapshot != nil
    }

    private var resumePrepared = false
    private func subscribeInput() async -> JSONValue {
        var payload = omissions.payload
        if completionMarker { payload["requestCompletionMarker"] = .bool(true) }
        if resumePrepared, let sequence = await store.afterSequence { payload["afterSequence"] = .number(Double(sequence)) }
        return .object(payload)
    }

    private func receive(_ json: JSONValue) async {
        guard var item = Self.decode(json), !stopped else { return }
        let previousSequence = await store.afterSequence ?? -1
        if case .snapshot(var snapshot, let roots) = item, roots == nil {
            resumingConnection = false
            missingThreads = []
            snapshot.omissions = omissions
            item = .snapshot(snapshot, resolvedRepositoryIdentityRoots: nil)
        }
        await store.apply([item])
        if case .synchronized = item, resumingConnection {
            resumingConnection = false
            await store.resumed()
            refreshCounts()
        }
        if case .snapshot(_, nil) = item { resumePrepared = true }
        switch item {
        case .threadUpdated(let sequence, _, let thread) where sequence > previousSequence:
            missingThreads.remove(thread.id)
            if await store.needsCountRefresh {
                if olderRead == nil { olderAttempted = 0 }
                refreshCounts()
            }
        case .threadRemoved(let sequence, _, let id) where sequence > previousSequence:
            missingThreads.insert(id)
            if olderRead == nil { olderAttempted = 0 }
            if await store.needsCountRefresh { refreshCounts() }
        default: break
        }
    }

    @discardableResult
    func retainFamily(_ threadId: ThreadId) -> UUID {
        let lease = UUID()
        familyConsumers[lease] = threadId
        loadFamily(threadId)
        return lease
    }

    func releaseFamily(_ lease: UUID) {
        guard let id = familyConsumers.removeValue(forKey: lease), !familyConsumers.values.contains(id) else { return }
        familyReads.removeValue(forKey: id)?.cancel()
        familyTokens[id] = nil
        loadedFamilies[id] = nil
        Task { await store.mount(nil, key: "family:\(id.rawValue)", generation: await store.generation) }
    }

    private func loadFamily(_ id: ThreadId) {
        guard omissions.omitIdleSubagents, familyReads[id] == nil, !stopped else { return }
        let token = UUID()
        familyTokens[id] = token
        familyReads[id] = Task { [weak self] in
            guard let self else { return }
            let generation = await store.generation
            defer { if familyTokens[id] == token { familyReads[id] = nil; familyTokens[id] = nil } }
            guard generation > 0, loadedFamilies[id] != generation else { return }
            do {
                let json = try await supervisor.request("orchestration.getThreadFamily", payload: .object(["threadId": .string(id.rawValue)]))
                let family = try json.decode(as: ShellThreadRead.self)
                guard !Task.isCancelled, generation == (await store.generation) else { return }
                loadedFamilies[id] = generation
                await store.mount(family, key: "family:\(id.rawValue)", generation: generation)
            } catch { /* Keep the route and allow an explicit reopen to retry. */ }
        }
    }

    /// Search rows share the same generation/tombstone protection as family reads.
    func mountSearch(_ read: ShellThreadRead?, generation: Int) async {
        await store.mount(read, key: "search", generation: generation)
    }

    /// Demand is bounded by the visible shelf, with no reads while it is collapsed.
    func demandOlderSettled(minimum: Int, projectIds: [ProjectId]?) {
        let scope = projectIds?.sorted { $0.rawValue < $1.rawValue }
        if scope != olderScope || minimum == 0 {
            olderRead?.cancel(); olderRead = nil
            olderReadToken = nil
            olderScope = scope
            resetOlderPages()
            clearOlderPages = true
            if minimum == 0 {
                Task { [weak self] in
                    guard let self, olderMinimum == 0 else { return }
                    await store.unmount(prefix: "older:", generation: await store.generation)
                }
            }
        }
        olderMinimum = minimum
        loadOlderSettled()
    }

    private func resetOlderPages() {
        olderAttempted = 0; olderCursor = nil; olderFinished = false
    }

    private func loadOlderSettled() {
        guard omissions.omitOlderSettled, olderMinimum > olderAttempted, !olderFinished, olderRead == nil, !stopped else { return }
        let token = UUID()
        olderReadToken = token
        olderRead = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            defer {
                if olderReadToken == token {
                    olderRead = nil; olderReadToken = nil
                    if succeeded { loadOlderSettled() }
                }
            }
            let generation = await store.generation
            guard generation > 0, let snapshot = await store.snapshot, let cut = snapshot.olderSettled else { return }
            let scope = olderScope
            if clearOlderPages {
                clearOlderPages = false
                await store.unmount(prefix: "older:", generation: generation)
            }
            let requested = olderMinimum
            olderAttempted = requested
            var cursor = olderCursor ?? OlderSettledCursor(settledAt: cut.before)
            do {
                // One environment reads only enough candidates for the requested merged prefix.
                while !olderFinished {
                    guard !Task.isCancelled, olderReadToken == token, generation == (await store.generation) else { return }
                    let rendered = await store.displaySnapshot
                    let count = SidebarModel.buildShelves((rendered?.threads ?? []).map { SidebarThread($0) },
                        scopedProjectIds: scope.map(Set.init), capabilities: .init(threadSettlement: true, threadSnooze: true),
                        nowMs: Int64(Date().timeIntervalSince1970 * 1000)).settled.count
                    if count >= requested { break }
                    var payload: [String: JSONValue] = ["before": Self.json(cursor), "limit": .number(50)]
                    if let scope { payload["projectIds"] = .array(scope.map { .string($0.rawValue) }) }
                    let json = try await supervisor.request("orchestration.getOlderSettledThreads", payload: .object(payload))
                    let page = try json.decode(as: OlderSettledPage.self)
                    guard !Task.isCancelled, olderReadToken == token, generation == (await store.generation), scope == olderScope else { return }
                    olderFinished = page.threads.count < 50
                    if let last = page.threads.last, let settledAt = last.settledAt {
                        let next = OlderSettledCursor(settledAt: settledAt.raw, threadId: last.id)
                        if next == cursor { olderFinished = true }
                        cursor = next; olderCursor = next
                    } else { olderFinished = true }
                    await store.mount(.init(snapshotSequence: page.snapshotSequence, threads: page.threads),
                                      key: "older:\(cursor.settledAt):\(cursor.threadId?.rawValue ?? "")", generation: generation)
                }
                succeeded = true
            } catch {
                if olderReadToken == token { olderAttempted = 0 }
            }
        }
    }

    private func refreshCounts() {
        guard omissions.omitOlderSettled, countRead == nil, !stopped else { return }
        let token = UUID()
        countReadToken = token
        countRead = Task { [weak self] in
            guard let self else { return }
            defer { if countReadToken == token { countRead = nil; countReadToken = nil } }
            try? await Task.sleep(for: .milliseconds(150))
            let generation = await store.generation
            var previousSequence: Int?
            do {
                // A removal can land while the first read is in flight. Retry only when that
                // response's sequence predates a later relevant event, never while idle.
                while !Task.isCancelled, generation == (await store.generation), let cut = await store.snapshot?.olderSettled {
                    let json = try await supervisor.request("orchestration.getOlderSettledThreads", payload: .object([
                        "before": Self.json(OlderSettledCursor(settledAt: cut.before)), "limit": .number(0)]))
                    guard !Task.isCancelled else { return }
                    let page = try json.decode(as: OlderSettledPage.self)
                    await store.updateCounts(page, generation: generation)
                    if !(await store.needsCountRefresh) { break }
                    if let previousSequence, page.snapshotSequence <= previousSequence { break }
                    previousSequence = page.snapshotSequence
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch { }
        }
    }

    nonisolated private static func json<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .null
    }

    /// Final: a stopped session never connects again.
    func stop() {
        stopped = true
        subscription?.cancel()
        configurationWatch?.cancel()
        lifecycleSubscription?.cancel()
        countRead?.cancel(); olderRead?.cancel()
        for task in familyReads.values { task.cancel() }
        let feed = configFeed
        Task { await feed.stop(); await supervisor.disconnect() }
    }

    /// A project's icon file: `assets.createUrl` with a `project-favicon` resource, then the signed URL
    /// (client-runtime state/assets.ts, projectFaviconCache.ts). Waits for the socket when it is down,
    /// so icons asked for while the cached sidebar shows still arrive. Runs off the main thread.
    nonisolated static func projectIconLoader(_ supervisor: ConnectionSupervisor, http: EnvironmentHTTP, token: String) -> ProjectIconStore.Loader {
        { _, cwd, faviconPath in
            var resource: [String: JSONValue] = ["_tag": .string("project-favicon"), "cwd": .string(cwd)]
            if let faviconPath { resource["path"] = .string(faviconPath) }
            let payload = JSONValue.object(["resource": .object(resource)])
            let result: JSONValue
            do {
                result = try await supervisor.request("assets.createUrl", payload: payload)
            } catch RPCClientError.transport {
                guard let (connection, _) = await supervisor.waitForConnection(after: 0) else { throw CancellationError() }
                result = try await connection.request("assets.createUrl", payload: payload)
            }
            guard case .string(let relativeURL)? = result.objectValue?["relativeUrl"] else { return nil }
            // `isProjectFaviconFallbackUrl`: the server found no icon file.
            if relativeURL.split(separator: "?").first?.split(separator: "/").last == "project-favicon-missing" { return nil }
            // PROJECT_FAVICON_MAX_SOURCE_BYTES: larger files are not worth decoding for an icon.
            return try await http.asset(relativeURL, token: token, maxBytes: 4 * 1024 * 1024)
        }
    }

    /// One pull at a time; changes that arrive meanwhile trigger exactly one more pull.
    private func pull() {
        if pulling { pullAgain = true; return }
        pulling = true
        Task { @MainActor in
            if let update = await store.takeUpdate() {
                if update.authoritativeChanged, let snapshot = update.snapshot { onSnapshot?(snapshot) }
                if let snapshot = update.displaySnapshot { onDisplaySnapshot?(snapshot) }
                let generation = await store.generation
                if shownGeneration != generation {
                    shownGeneration = generation
                    for task in familyReads.values { task.cancel() }
                    familyReads = [:]; familyTokens = [:]; loadedFamilies = [:]
                    countRead?.cancel(); countRead = nil; countReadToken = nil
                    olderRead?.cancel(); olderRead = nil; olderReadToken = nil; resetOlderPages()
                    for id in Set(familyConsumers.values) { loadFamily(id) }
                    loadOlderSettled()
                    if await store.needsCountRefresh { refreshCounts() }
                }
            }
            pulling = false
            if pullAgain { pullAgain = false; pull() }
        }
    }

    /// Lets the store's Sendable change callback reach a session created after the store.
    final class ChangeRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable (Bool) -> Void)?
        func set(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = { _ in action() } } }
        /// The action gets whether the change only grew a streaming text.
        func setStreaming(_ action: @escaping @Sendable (Bool) -> Void) { lock.withLock { self.action = action } }
        func fire(streaming: Bool = false) { lock.withLock { action }?(streaming) }
    }

    nonisolated static func decode(_ json: JSONValue) -> ShellStreamItem? {
        try? json.decode(as: ShellStreamItem.self)
    }
}
