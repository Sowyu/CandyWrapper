import Foundation
import T3Protocol

/// Shares one supervised config subscription across shell negotiation and config observers.
/// Replay belongs to one connection generation; callers own any policy cached across connections.
public actor ServerConfigFeed {
    private let supervisor: ConnectionSupervisor
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

    public init(supervisor: ConnectionSupervisor) {
        self.supervisor = supervisor
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
        let task = supervisor.subscribe("subscribeServerConfig", payload: {
            .object([
                "environmentThemes": .bool(true),
                "usageLimitSources": .bool(true),
                "usageLimitsCommand": .bool(true),
            ])
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

    private func cache(_ value: JSONValue) {
        guard let type = value["type"]?.stringValue else { return }
        if type == "snapshot" {
            // A snapshot carries config at the top level (server.ts:693-697), never under payload.
            guard case .object? = value["config"] else { return }
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
