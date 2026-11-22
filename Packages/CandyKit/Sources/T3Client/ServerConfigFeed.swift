import Foundation
import T3Protocol

/// Shares one supervised config subscription across shell negotiation and config observers.
/// Replay belongs to one connection generation; callers own any policy cached across connections.
public actor ServerConfigFeed {
    private let supervisor: ConnectionSupervisor
    /// Names the host whose clock the first snapshot of each subscription reads (`ServerClock`, #36420).
    private let environmentId: String?
    /// When this generation's subscription went out, until its snapshot records the host's clock.
    private var clockRequestedAtMs: Int64?
    private var subscription: Task<Void, Never>?
    private var completion: Task<Void, Never>?
    private var run: UUID?
    private var stopped = false
    private var generation: Int?
    private var snapshot: JSONValue?
    private var initialFailed = false
    private var updates: [String: JSONValue] = [:]
    private var listeners: [UUID: AsyncStream<SubscriptionEvent>.Continuation] = [:]
    private var waiters: [UUID: (generation: Int, continuation: CheckedContinuation<JSONValue?, Never>)] = [:]

    // Each known update replaces whole fields (server.ts:674-759; ws.ts:351-359, 3100-3164,
    // t3code-fast-load-5b35402623). Unknown events pass through without growing the replay cache.
    private static let updateTypes = [
        "keybindingsUpdated", "providerStatuses", "settingsUpdated",
        "environmentThemesUpdated", "usageLimitSourcesUpdated",
    ]

    /// The deadlines in `initialConfig(generation:within:)` sleep with this; tests step it by hand.
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(supervisor: ConnectionSupervisor, environmentId: String? = nil,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.supervisor = supervisor
        self.environmentId = environmentId
        self.sleep = sleep
    }

    deinit {
        subscription?.cancel()
        completion?.cancel()
        for waiter in waiters.values { waiter.continuation.resume(returning: nil) }
        for listener in listeners.values { listener.finish() }
    }

    /// Idempotent. Starts the only owned RPC stream; never calls `server.getConfig`.
    public func start() {
        guard run == nil, !Task.isCancelled else { return }
        let token = UUID()
        run = token
        stopped = false
        // rpc.ts:1787-1797; matches the composer's existing capability opt-ins.
        let supervisor = self.supervisor
        let task = supervisor.subscribe("subscribeServerConfig", snapshotFirst: true, payload: {
            var fields: [String: JSONValue] = [
                "environmentThemes": .bool(true),
                "usageLimitSources": .bool(true),
                "usageLimitsCommand": .bool(true),
            ]
            // Opt out only when the descriptor promises on-demand refresh replies (environment.ts:106).
            if await supervisor.serverCapabilities.contains("providerWorkspaceSnapshotsOnDemand") {
                fields["workspaceSnapshotsOnDemand"] = .bool(true)
            }
            return .object(fields)
        }, handler: { [weak self] event in
            await self?.receive(event, run: token)
        })
        subscription = task
        completion = Task { [weak self] in
            await task.value
            await self?.finished(run: token)
        }
    }

    /// Cancels the owned stream, finishes every listener and resolves pending initial reads with nil.
    /// Call `start` and register new listeners to use the feed again.
    public func stop() {
        subscription?.cancel()
        completion?.cancel()
        finish()
    }

    /// Waits for this generation's snapshot and returns its raw config with current field updates.
    /// Start the feed first. Cancellation, stop, terminal completion and superseded generations return nil.
    /// A waiter may register before the subscription announces its requested generation.
    public func initialConfig(generation requested: Int) async -> JSONValue? {
        guard run != nil, !Task.isCancelled else { return nil }
        if let generation {
            if requested < generation { return nil }
            if requested == generation, let config = snapshot?["config"] { return config }
            if requested == generation, initialFailed { return nil }
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                waiters[id] = (requested, continuation)
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelWaiter(id) }
        }
    }

    /// How long a cold thread open waits for its session's config before it opens without it. T3 waits with no
    /// deadline (client-runtime state/threads.ts:1035, rpc/session.ts:382-397), so a config stream that hangs
    /// without an error holds the thread. The snapshot arrives 9 ms after the socket opens on loopback and 54 ms at
    /// 40 ms RTT (docs/research/connection-vs-t3-desktop-4928.md), so 1 s leaves room for a slow relay, and opening
    /// without config costs only the HTTP round trip that the socket path saves.
    public static let threadOpenConfigDeadline: Duration = .seconds(1)

    /// How long the shell waits for its session's config before it loads everything with no flags (`ShellNegotiation`).
    /// T3 waits with no deadline (client-runtime state/shell.ts:638-641). Measured, the config snapshot lands about 10 ms
    /// after the socket opens on loopback and 54 ms after at 40 ms RTT (docs/research/connection-vs-t3-desktop-4928.md).
    /// By arithmetic, its 98 KB, about 30 KB after the socket's compression, takes under 1 s at 1 Mbit/s and 300 ms RTT.
    /// 5 s leaves room for a busy host behind a slow relay. Running out costs a larger first shell, so the bound sits well
    /// above the thread open's 1 s.
    public static let shellConfigDeadline: Duration = .seconds(5)

    /// `initialConfig(generation:)` that gives up after `deadline` and returns nil. A config already known returns
    /// at once with no wait. The waiter and the deadline both end when either finishes or the caller is cancelled.
    public func initialConfig(generation requested: Int, within deadline: Duration) async -> JSONValue? {
        if requested == generation, let config = snapshot?["config"] { return config }
        return await withTaskGroup(of: JSONValue?.self) { group in
            group.addTask { await self.initialConfig(generation: requested) }
            let sleep = self.sleep
            group.addTask { try? await sleep(deadline); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Each consumer gets a separate stream. Late consumers receive subscribed, the current snapshot,
    /// then at most one of each known update. Registration before `start` is supported.
    public func events() -> AsyncStream<SubscriptionEvent> {
        let (stream, continuation) = AsyncStream<SubscriptionEvent>.makeStream()
        guard !stopped else { continuation.finish(); return stream }
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        if let generation { continuation.yield(.subscribed(generation: generation)) }
        if let snapshot { continuation.yield(.value(snapshot)) }
        for type in Self.updateTypes {
            if let update = updates[type] { continuation.yield(.value(update)) }
        }
        return stream
    }

    private func receive(_ event: SubscriptionEvent, run token: UUID) {
        guard run == token else { return }
        switch event {
        case .subscribed(let next):
            if generation != next {
                clockRequestedAtMs = Self.nowMs()
                generation = next
                snapshot = nil
                initialFailed = false
                updates.removeAll(keepingCapacity: true)
                for (id, waiter) in waiters where waiter.generation < next {
                    waiters[id] = nil
                    waiter.continuation.resume(returning: nil)
                }
            }
        case .value(let value):
            cache(value)
        case .interrupted:
            if snapshot == nil {
                initialFailed = true
                for (id, waiter) in waiters where waiter.generation == generation {
                    waiters[id] = nil
                    waiter.continuation.resume(returning: nil)
                }
            }
        }
        for listener in listeners.values { listener.yield(event) }
    }

    private static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    private func cache(_ value: JSONValue) {
        guard let type = value["type"]?.stringValue else { return }
        if type == "snapshot" {
            // A snapshot carries config at the top level (server.ts:693-697), never under payload.
            guard case .object? = value["config"] else { return }
            // Only a subscription's first snapshot is fresh; later ones may repeat its serverTime
            // (client-runtime rpc/session.ts at 4928, #36420).
            if let requested = clockRequestedAtMs, let environmentId {
                clockRequestedAtMs = nil
                let serverTime = value["config"]?["serverTime"]?.stringValue.flatMap(T3Timestamp.parseEpochMs)
                ServerClock.record(environmentId: environmentId, serverTimeMs: serverTime, requestedAtMs: requested, receivedAtMs: Self.nowMs())
            }
            snapshot = value
            initialFailed = false
            // A later editor-discovery snapshot is authoritative for config fields. The two hubs
            // never ride in snapshots and must survive them (ws.ts:313-359, 3178-3180).
            for type in ["keybindingsUpdated", "providerStatuses", "settingsUpdated"] {
                updates[type] = nil
            }
            if let generation {
                for (id, waiter) in waiters where waiter.generation == generation {
                    waiters[id] = nil
                    waiter.continuation.resume(returning: value["config"])
                }
            }
        } else if Self.updateTypes.contains(type), case .object(let payload)? = value["payload"] {
            updates[type] = value
            let fields: [String]
            switch type {
            case "keybindingsUpdated": fields = ["keybindings", "issues"]
            case "providerStatuses": fields = ["providers"]
            case "settingsUpdated": fields = ["settings"]
            default: return // The hubs have their own events, not fields in ServerConfig.
            }
            guard case .object(var event)? = snapshot, case .object(var config)? = event["config"] else { return }
            for field in fields {
                if let replacement = payload[field] { config[field] = replacement }
            }
            event["config"] = .object(config)
            snapshot = .object(event)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    private func finished(run token: UUID) {
        guard run == token else { return }
        finish()
    }

    private func finish() {
        run = nil
        subscription = nil
        completion = nil
        stopped = true
        generation = nil
        snapshot = nil
        initialFailed = false
        updates.removeAll()
        for waiter in waiters.values { waiter.continuation.resume(returning: nil) }
        waiters.removeAll()
        for listener in listeners.values { listener.finish() }
        listeners.removeAll()
    }
}
