import AppKit
import Features
import T3Client
import T3Protocol
import T3Store

/// Connects one environment's shell stream to the sidebar: supervisor (reconnects), the
/// `orchestration.subscribeShell` subscription (resumes from the store's cursor), the store
/// (decodes and reduces off the main thread) and the sidebar (pulls one merged update per change window).
@MainActor
final class ShellSession {
    let supervisor: ConnectionSupervisor
    let store: ShellStore
    private weak var sidebar: SidebarContentView?
    private var subscription: Task<Void, Never>?
    private var pulling = false
    private var pullAgain = false
    /// After each sidebar pull, with the store's whole shell (for the disk cache and activity).
    var onSnapshot: ((ShellSnapshot) -> Void)?

    init(baseURL: URL, token: String, sidebar: SidebarContentView, cached: ShellSnapshot? = nil) {
        let http = EnvironmentHTTP(baseURL: baseURL)
        let identity = ClientIdentity(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        supervisor = ConnectionSupervisor(dependencies: .init(
            connect: ConnectionSupervisor.directConnector(http: http, environmentId: nil, identity: identity,
                                                          token: { token })))
        self.sidebar = sidebar
        let relay = ChangeRelay()
        store = ShellStore(cached: cached, onChange: { relay.fire() })
        relay.set { [weak self] in Task { @MainActor in self?.pull() } }
        if let cached { sidebar.setSnapshot(cached, animated: false) }
    }

    func start() {
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

    /// One pull at a time; changes that arrive meanwhile trigger exactly one more pull.
    private func pull() {
        guard let sidebar else { return }
        if pulling { pullAgain = true; return }
        pulling = true
        Task { @MainActor in
            await sidebar.pull(from: store)
            if let onSnapshot, let snapshot = await store.snapshot { onSnapshot(snapshot) }
            pulling = false
            if pullAgain { pullAgain = false; pull() }
        }
    }

    /// Lets the store's Sendable change callback reach a session created after the store.
    private final class ChangeRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?
        func set(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }
        func fire() { lock.withLock { action }?() }
    }

    // ponytail: re-encodes the JSONValue to decode the typed item; decode from the frame bytes if profiling shows it
    nonisolated static func decode(_ json: JSONValue) -> ShellStreamItem? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(ShellStreamItem.self, from: data)
    }
}
