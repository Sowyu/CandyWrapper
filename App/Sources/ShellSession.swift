import AppKit
import Features
import T3Client
import T3Protocol
import T3Store

/// One environment's socket and shell stream: supervisor (one WebSocket, T3's reconnect and backoff),
/// the `orchestration.subscribeShell` subscription (resumes from the store's cursor) and the store
/// (decodes and reduces off the main thread). `Environments` merges every session's shell for the sidebar.
@MainActor
final class ShellSession {
    let environmentId: String
    let supervisor: ConnectionSupervisor
    let store: ShellStore
    /// The same server and token for HTTP routes, such as thread history pages.
    let http: EnvironmentHTTP
    let token: String
    private var subscription: Task<Void, Never>?
    private var pulling = false
    private var pullAgain = false
    private var started = false
    /// After each change window, with the store's whole shell, unscoped (merge, disk cache, activity).
    var onSnapshot: ((ShellSnapshot) -> Void)?

    /// `environmentId` is the descriptor's id. The connector refuses a server that answers with another
    /// id (T3 does the same before it spends a pairing code, onboarding.ts:112-123).
    init(environmentId: String, baseURL: URL, token: String, cached: ShellSnapshot? = nil) {
        self.environmentId = environmentId
        let http = EnvironmentHTTP(baseURL: baseURL)
        self.http = http
        self.token = token
        let identity = ClientIdentity(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        supervisor = ConnectionSupervisor(dependencies: .init(
            connect: ConnectionSupervisor.directConnector(http: http, environmentId: environmentId, identity: identity,
                                                          token: { token })))
        let relay = ChangeRelay()
        store = ShellStore(cached: cached, onChange: { relay.fire() })
        relay.set { [weak self] in Task { @MainActor in self?.pull() } }
    }

    /// Connects and subscribes once; later calls do nothing.
    func start() {
        guard !started else { return }
        started = true
        Task { await supervisor.observePlatform(); await supervisor.connect() }
        let store = self.store
        subscription = supervisor.subscribe("orchestration.subscribeShell", payload: {
            var payload: [String: JSONValue] = ["requestCompletionMarker": .bool(true)]
            if let after = await store.afterSequence { payload["afterSequence"] = .number(Double(after)) }
            return .object(payload)
        }, handler: { event in
            guard case .value(let json) = event, let item = ShellSession.decode(json) else { return }
            await store.apply([item])
        })
    }

    func stop() {
        subscription?.cancel()
        Task { await supervisor.disconnect() }
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
            if let snapshot = await store.takeUpdate()?.snapshot { onSnapshot?(snapshot) }
            pulling = false
            if pullAgain { pullAgain = false; pull() }
        }
    }

    /// Lets the store's Sendable change callback reach a session created after the store.
    final class ChangeRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?
        func set(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }
        func fire() { lock.withLock { action }?() }
    }

    nonisolated static func decode(_ json: JSONValue) -> ShellStreamItem? {
        try? json.decode(as: ShellStreamItem.self)
    }
}
