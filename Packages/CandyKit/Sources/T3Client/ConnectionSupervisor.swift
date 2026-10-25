import Foundation
import T3Protocol

/// T3's reconnect ladder (packages/client-runtime/src/connection/supervisor.ts:35-49, 127-141).
public enum Backoff {
    public static let baseMilliseconds = 1_000
    public static let maxMilliseconds = 300_000
    /// A session that stayed up this long resets the ladder.
    public static let resetAfter: Duration = .seconds(30)

    /// Delay before retry number `failureCount + 1` (`failureCount` is 0 for the first retry).
    /// Equal jitter: uniform in the upper half of the ceiling, `random` in [0, 1).
    public static func delayMilliseconds(failureCount: Int, random: Double) -> Int {
        let exponent = min(max(failureCount, 0) + 1, 20)
        let ceiling = Double(min(maxMilliseconds, baseMilliseconds << exponent))
        return Int((ceiling / 2 + ceiling / 2 * random).rounded())
    }
}

/// Why a connection attempt failed. Mirrors ConnectionTransientError and ConnectionBlockedError.
public enum ConnectionFailure: Error, Sendable, Equatable {
    /// Retry with backoff.
    case transient(String)
    /// Wait for a signal (retry, wake, network change). `unsupported` means a protocol mismatch.
    case blocked(BlockedReason, String)

    public enum BlockedReason: String, Sendable { case authentication, configuration, permission, unsupported }

    public var detail: String {
        switch self {
        case .transient(let d), .blocked(_, let d): d
        }
    }

    /// Maps HTTP and socket errors the way client-runtime/src/connection/errors.ts:115-172 does.
    public static func classify(_ error: Error) -> ConnectionFailure {
        switch error {
        case let f as ConnectionFailure: return f
        case let l as LocatedConnectionFailure: return l.failure
        case let e as EnvironmentHTTPError:
            switch e {
            case .status(let code, let body):
                switch code {
                case 401: return .blocked(.authentication, "The environment credential is invalid.")
                case 403: return .blocked(.permission, "The environment credential does not grant the required access.")
                case 400: return .blocked(.configuration, body == nil ? "The environment rejected the request." : "The environment rejected the authentication request.")
                case 404: return .blocked(.configuration, "The environment endpoint could not be found.")
                // The body's `reason` and `message` are the server's own words and go nowhere: they reach Copy
                // diagnostics, and a server could echo a credential (connection/errors.ts:238-244).
                case 500: return .transient("The environment could not authorize the connection.")
                default: return .transient("The environment returned undeclared status \(code).")
                }
            case .network, .timedOut, .invalidResponse: return .transient(e.description)
            }
        case let e as RPCTransportError:
            switch e {
            case .upgradeRejected(401): return .blocked(.authentication, "The environment credential is invalid.")
            case .upgradeRejected(426): return .blocked(.unsupported, "The server needs a newer orchestration protocol.")
            default: return .transient(e.description)
            }
        case let e as RPCClientError: return .transient(e.description)
        default: return .transient(error.localizedDescription)
        }
    }

    /// The failure with where it happened (`ConnectionFailureInfo`), as client-runtime/src/connection/errors.ts:184-277
    /// maps a direct route's errors. Over T3 Connect the relay already reached the host, so a request that never
    /// arrives was blocked between this device and the tunnel.
    public static func locate(_ error: Error, via: ConnectionFailureInfo.Via = .direct) -> ConnectionFailureInfo {
        if let located = error as? LocatedConnectionFailure { return located.info }
        let failure = classify(error)
        var info: ConnectionFailureInfo
        switch failure {
        case .blocked(let reason, let detail): info = ConnectionFailureInfo(reason: reason.rawValue, blocked: true, detail: detail)
        case .transient(let detail): info = ConnectionFailureInfo(reason: "transport", blocked: false, detail: detail)
        }
        switch error {
        case let e as EnvironmentHTTPError:
            info.via = via
            switch e {
            case .status(_, let body):
                info.hop = .server
                info.traceId = body?.traceId
                if case .transient = failure { info.reason = "remote-unavailable" }
            case .network: info.reason = "network"; info.hop = via == .relay ? .tunnel : .server
            case .timedOut: info.reason = "timeout"; info.hop = via == .relay ? .tunnel : .server
            case .invalidResponse: info.reason = "remote-unavailable"; info.hop = .server
            }
        case let e as RPCTransportError:
            if case .upgradeRejected(401) = e { info.hop = .server; info.via = via }
        default: break
        }
        return info
    }
}

/// A connection failure that knows where it happened. Connectors throw it; `classify` and `locate` unwrap it.
public struct LocatedConnectionFailure: Error, Sendable, Equatable {
    public var failure: ConnectionFailure
    public var info: ConnectionFailureInfo
    public init(_ failure: ConnectionFailure, _ info: ConnectionFailureInfo) { self.failure = failure; self.info = info }

}

/// Supervisor phases (client-runtime connection/model.ts:130-136) and the presented status
/// (connection/presentation.ts:29-58).
public struct ConnectionState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case available, offline, connecting, backoff, connected
        case blocked(ConnectionFailure.BlockedReason)
    }

    /// What the UI shows: "Connected", "Reconnecting...", "Connection failed" and so on.
    public enum Status: String, Sendable {
        case available, offline, connecting, reconnecting, connected, error, unsupported
    }

    public var phase: Phase = .available
    /// Current or next attempt number.
    public var attempt = 0
    /// Increments for each established session.
    public var generation = 0
    public var lastFailure: String?
    /// Where and why the last attempt failed, for the connection diagnosis.
    public var failure: ConnectionFailureInfo?
    /// When the next attempt runs, while in backoff.
    public var retryAt: ContinuousClock.Instant?

    public var status: Status {
        switch phase {
        case .available: .available
        case .offline: .offline
        case .connected: .connected
        case .connecting: attempt <= 1 && lastFailure == nil ? .connecting : .reconnecting
        case .backoff: .reconnecting
        case .blocked(.unsupported): .unsupported
        case .blocked: .error
        }
    }
}

/// Signals that make the supervisor look at the connection again (client-runtime wakeups.ts).
public enum ConnectionWakeup: Sendable {
    /// App became active. Probe with T3's 15 s timeout.
    case applicationActive
    /// System woke from sleep. The socket is probably dead, so probe with the 3 s quick timeout.
    case systemWake
}

/// How the supervisor checks a quiet socket. See `ConnectionSupervisor` for why `.none` is the default.
public enum KeepalivePolicy: Sendable, Equatable {
    case none
    /// Ping at this interval while the app is active. A missing Pong by the next tick drops the socket.
    case ping(interval: Duration)
}

/// Owns one environment connection: connects, reconnects with T3's jittered backoff, waits
/// for the network instead of spinning while offline, probes on wake and foreground, and keeps
/// durable subscriptions alive across sessions.
///
/// Liveness: the T3 server never closes a quiet socket. Effect's RpcServer only answers Ping
/// (RpcServer.ts:806) and never pings, apps/server/src/ws.ts sets no idle timeout, and Node's
/// `ws` server has none by default. So a direct connection needs no keepalive traffic, and the
/// supervisor runs no timers while idle. A dead peer shows up through the events that cause
/// one: NWPathMonitor path changes, system wake, app activation (each runs a `server.probe`
/// with T3's timeouts), and the kernel failing the TCP socket. That keeps idle wakeups at zero.
/// Effect's 5 s ping would cost 0.2 wakeups per second for nothing on a direct route.
/// While the owner expects traffic (`setExpectingTraffic`, a running turn) and the app is
/// active, the connection checks a quiet socket as T3 does, so a turn that stops streaming
/// because the network died shows "reconnecting" within 15 to 20 s instead of looking live.
/// Relay routes (T3 Connect via Cloudflare tunnels) can sit behind proxies that drop idle
/// sockets after about 100 s, so pass `.ping(interval: .seconds(80))` there; it pings only
/// while the app is active.
public actor ConnectionSupervisor {
    public struct Dependencies: Sendable {
        /// Opens one session: descriptor check, ticket, socket. One attempt, no retry.
        public var connect: @Sendable () async throws -> RPCConnection
        public var sleep: @Sendable (Duration) async throws -> Void
        public var now: @Sendable () -> ContinuousClock.Instant
        /// Uniform in [0, 1).
        public var random: @Sendable () -> Double

        public init(connect: @escaping @Sendable () async throws -> RPCConnection,
                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                    random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
            self.connect = connect
            self.sleep = sleep
            self.now = now
            self.random = random
        }
    }

    /// T3's CONNECTION_ESTABLISHMENT_TIMEOUT and probe timeouts (supervisor.ts:35-49).
    public static let establishTimeout: Duration = .seconds(15)
    public static let probeTimeout: Duration = .seconds(15)
    public static let quickProbeTimeout: Duration = .seconds(3)

    private let deps: Dependencies
    private let keepalive: KeepalivePolicy
    private(set) public var state = ConnectionState() { didSet { if state != oldValue { publish() } } }
    private var desired = false
    private var online = true
    private var appActive = true
    private var expectingTraffic = false
    /// Orders `applyWatch` calls, which reach the connection through separate tasks.
    private var watchGeneration = 0
    private var failures = 0
    private var skipNextDelay = false
    private var connection: RPCConnection?
    private var connectedAt: ContinuousClock.Instant?
    private var attemptID = 0
    private var attemptTask: Task<Void, Never>?
    private var timerID = 0
    private var timerTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var connectionWaiters: [UUID: (after: Int, continuation: CheckedContinuation<(RPCConnection, Int)?, Never>)] = [:]
    private var platform: PlatformSignals?

    public init(dependencies: Dependencies, keepalive: KeepalivePolicy = .none) {
        deps = dependencies
        self.keepalive = keepalive
    }

    /// The standard bearer connector: descriptor check, fresh ticket, socket (protocol.md 2.1).
    public static func directConnector(http: EnvironmentHTTP, environmentId: String?, identity: ClientIdentity,
                                       token: @escaping @Sendable () async throws -> String)
        -> @Sendable () async throws -> RPCConnection {
        return {
            let descriptor = try await http.descriptor()
            if let message = Pairing.compatibilityError(descriptor) {
                throw ConnectionFailure.blocked(.unsupported, message)
            }
            if let environmentId, descriptor.environmentId != environmentId {
                // errors.ts `environmentMismatchError`.
                throw ConnectionFailure.blocked(.configuration, "Connected environment \(descriptor.environmentId) does not match \(environmentId).")
            }
            let ticket = try await http.webSocketTicket(token: try await token())
            let socket = try await URLSessionRPCSocket.open(url: http.webSocketURL(ticket: ticket.ticket, identity: identity))
            let connection = RPCConnection(socket: socket)
            await connection.start()
            return connection
        }
    }

    // MARK: Signals

    public func connect() {
        desired = true
        evaluate()
    }

    public func disconnect() {
        desired = false
        cancelAttempt()
        dropConnection(reason: "disconnected")
        evaluate()
    }

    /// Connects unless the owner stopped meanwhile. An owner that stops sets its flag at once and sends
    /// `disconnect` in its own task, which can land here before or after this call; checking the flag
    /// on both sides of `connect` leaves a stopped owner disconnected in every order.
    public func connect(unlessStopped isStopped: @Sendable () async -> Bool) async {
        guard await !isStopped() else { return }
        connect()
        if await isStopped() { disconnect() }
    }

    /// The user's "Reconnect" button: resets the ladder and tries now, or quick-probes a live session.
    public func retryNow() {
        failures = 0
        skipNextDelay = false
        if connection != nil { probe(timeout: Self.quickProbeTimeout); return }
        cancelAttempt()
        evaluate()
    }

    public func networkChanged(online isOnline: Bool) {
        guard isOnline != online else { return }
        online = isOnline
        if isOnline {
            failures = 0
            if connection != nil { probe(timeout: Self.quickProbeTimeout) } else { cancelTimer(); evaluate() }
        } else if connection != nil {
            // A loopback session can survive losing the network. Probe before dropping it.
            probe(timeout: Self.quickProbeTimeout)
        } else {
            cancelAttempt()
            evaluate()
        }
    }

    /// NWPathMonitor saw other interfaces or gateways while online: another Wi-Fi, a hotspot, a VPN.
    /// A socket opened on the previous network may now be unroutable. T3's "network-changed"
    /// wakeup: a quick probe of a live session, or a retry now from the first rung
    /// (client-runtime connection/wakeups.ts:10-25, supervisor.ts:582-596).
    public func networkPathChanged() {
        guard online else { return }
        failures = 0
        if connection != nil {
            probe(timeout: Self.quickProbeTimeout)
        } else if attemptTask == nil {
            cancelTimer()
            evaluate()
        }
    }

    /// A turn runs on this environment, so frames should keep coming. See the type's comment.
    public func setExpectingTraffic(_ on: Bool) {
        guard on != expectingTraffic else { return }
        expectingTraffic = on
        applyWatch()
    }

    public func wakeup(_ reason: ConnectionWakeup) {
        if reason == .applicationActive { appActive = true; applyWatch() }
        failures = 0
        if connection != nil {
            probe(timeout: reason == .systemWake ? Self.quickProbeTimeout : Self.probeTimeout)
            startPinging()
        } else if attemptTask == nil {
            cancelTimer()
            evaluate()
        }
    }

    public func applicationResignedActive() {
        appActive = false
        pingTask?.cancel()
        pingTask = nil
        applyWatch()
    }

    /// The user isn't looking while the app is inactive, and activation probes anyway.
    private func applyWatch() {
        guard let connection else { return }
        let on = expectingTraffic && appActive
        watchGeneration += 1
        let generation = watchGeneration
        Task { await connection.setWatched(on, generation: generation) }
    }

    /// Starts NWPathMonitor and wake and activation observers. The app calls this once.
    public func observePlatform() {
        guard platform == nil else { return }
        platform = PlatformSignals(supervisor: self)
    }

    // MARK: Observation and use

    /// Current state first, then every change.
    public func states() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    /// The live session, if connected. Calls are not queued while disconnected, as in T3.
    public var currentConnection: RPCConnection? { connection }

    /// Unary call on the current session. Throws `.transport(.closed)` when not connected.
    public func request(_ tag: String, payload: JSONValue = .object([:])) async throws -> JSONValue {
        guard let connection else { throw RPCClientError.transport(.closed("not connected")) }
        return try await connection.request(tag, payload: payload)
    }

    /// Waits for a session newer than `generation`. Returns nil if the waiting task is cancelled.
    public func waitForConnection(after generation: Int) async -> (RPCConnection, Int)? {
        if let connection, state.generation > generation { return (connection, state.generation) }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if Task.isCancelled { return c.resume(returning: nil) }
                connectionWaiters[id] = (generation, c)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    // MARK: State machine

    private func evaluate() {
        cancelTimer()
        guard desired else {
            setPhase(.available)
            return
        }
        if connection != nil || attemptTask != nil { return }
        guard online else {
            setPhase(.offline)
            return
        }
        startAttempt()
    }

    private func startAttempt() {
        attemptID += 1
        let id = attemptID
        state.attempt = failures + 1
        setPhase(.connecting)
        let connect = deps.connect
        attemptTask = Task {
            let result: Result<RPCConnection, Error>
            do {
                result = .success(try await withTimeout(Self.establishTimeout,
                                                        error: ConnectionFailure.transient("The environment did not respond during connection setup."),
                                                        connect))
            } catch {
                result = .failure(error)
            }
            await self.attemptFinished(id, result)
        }
    }

    private func attemptFinished(_ id: Int, _ result: Result<RPCConnection, Error>) async {
        guard id == attemptID else {
            if case .success(let c) = result { await c.close(reason: "attempt superseded") }
            return
        }
        attemptTask = nil
        switch result {
        case .success(let conn):
            guard desired else {
                await conn.close(reason: "disconnected")
                evaluate()
                return
            }
            connection = conn
            connectedAt = deps.now()
            state.generation += 1
            state.lastFailure = nil
            state.failure = nil
            state.retryAt = nil
            setPhase(.connected)
            let generation = state.generation
            Task {
                let reason = await conn.waitUntilClosed()
                self.connectionClosed(generation, reason)
            }
            resumeWaiters()
            startPinging()
            applyWatch()
        case .failure(let error):
            if error is CancellationError { evaluate(); return }
            let info = ConnectionFailure.locate(error)
            switch ConnectionFailure.classify(error) {
            case .blocked(let reason, let detail):
                state.lastFailure = detail
                state.failure = info
                setPhase(.blocked(reason))
            case .transient(let detail):
                scheduleRetry(detail, info)
            }
        }
    }

    private func connectionClosed(_ generation: Int, _ reason: RPCClientError) {
        guard generation == state.generation, connection != nil else { return }
        connection = nil
        pingTask?.cancel()
        pingTask = nil
        if let connectedAt, deps.now() - connectedAt >= Backoff.resetAfter { failures = 0 }
        if desired && online {
            scheduleRetry(reason.description, ConnectionFailureInfo(reason: "transport", blocked: false, detail: reason.description))
        } else {
            evaluate()
        }
    }

    private func scheduleRetry(_ detail: String, _ info: ConnectionFailureInfo) {
        state.lastFailure = detail
        state.failure = info
        failures += 1
        let delay: Duration = skipNextDelay ? .zero : .milliseconds(Backoff.delayMilliseconds(failureCount: failures - 1, random: deps.random()))
        skipNextDelay = false
        state.attempt = failures + 1
        state.retryAt = deps.now() + delay
        setPhase(.backoff)
        timerID += 1
        let id = timerID
        let sleep = deps.sleep
        timerTask = Task {
            do { try await sleep(delay) } catch { return }
            self.retryTimerFired(id)
        }
    }

    private func retryTimerFired(_ id: Int) {
        guard id == timerID, state.phase == .backoff else { return }
        timerTask = nil
        state.retryAt = nil
        evaluate()
    }

    private func probe(timeout: Duration) {
        guard let connection, probeTask == nil else { return }
        let generation = state.generation
        probeTask = Task {
            // Any answer, even a typed failure or Die from an older server, proves the socket works.
            var alive = true
            do {
                _ = try await withTimeout(timeout, error: RPCTransportError.pingTimedOut) {
                    try await connection.request("server.probe")
                }
            } catch let e as RPCClientError where !e.isTransport {
                alive = true
            } catch {
                alive = false
            }
            await self.probeFinished(generation, alive: alive)
        }
    }

    private func probeFinished(_ generation: Int, alive: Bool) async {
        probeTask = nil
        guard generation == state.generation, let conn = connection, !alive else { return }
        // T3 reconnects at once after a failed probe, then resumes the normal ladder.
        skipNextDelay = true
        await conn.close(reason: "health check failed")
        // connectionClosed runs from the close watcher.
    }

    private func startPinging() {
        guard case .ping(let interval) = keepalive, appActive, pingTask == nil, let connection else { return }
        let generation = state.generation
        pingTask = Task {
            while !Task.isCancelled {
                do {
                    // 10% tolerance lets the system coalesce this with other wakeups.
                    try await Task.sleep(for: interval, tolerance: interval / 10)
                    try await connection.ping(timeout: interval)
                } catch is CancellationError {
                    return
                } catch {
                    await self.probeFinished(generation, alive: false)
                    return
                }
            }
        }
    }

    private func dropConnection(reason: String) {
        guard let conn = connection else { return }
        connection = nil
        pingTask?.cancel()
        pingTask = nil
        Task { await conn.close(reason: reason) }
    }

    private func cancelAttempt() {
        attemptID += 1
        attemptTask?.cancel()
        attemptTask = nil
    }

    private func cancelTimer() {
        timerID += 1
        timerTask?.cancel()
        timerTask = nil
        state.retryAt = nil
    }

    private func setPhase(_ phase: ConnectionState.Phase) {
        state.phase = phase
    }

    private func publish() {
        for c in observers.values { c.yield(state) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func resumeWaiters() {
        guard let connection else { return }
        let ready = connectionWaiters.filter { $0.value.after < state.generation }
        for (id, waiter) in ready {
            connectionWaiters[id] = nil
            waiter.continuation.resume(returning: (connection, state.generation))
        }
    }

    private func cancelWaiter(_ id: UUID) {
        connectionWaiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }
}

// MARK: - Durable subscriptions

/// What a durable subscription reports to its handler.
public enum SubscriptionEvent: Sendable {
    /// A new subscription request went out on session `generation`. Expect a snapshot or a replay.
    case subscribed(generation: Int)
    case value(JSONValue)
    /// The stream broke. Transport losses wait for the next session; server failures retry
    /// on the same session after 250 ms doubling to 30 s (client-runtime rpc/client.ts:105-106).
    case interrupted(RPCClientError)
}

extension ConnectionSupervisor {
    /// A stream that follows the connection: it re-subscribes on every new session and after
    /// recoverable failures. `payload` runs before each subscribe so the caller can supply the
    /// current resume cursor (`afterSequence`). `handler` is awaited before the next value is
    /// pulled, so a slow handler holds back the server through acks.
    /// A handler may clear its cursor and throw to retry with a fresh snapshot after a bad value.
    /// Cancel the returned task to unsubscribe; that sends `Interrupt`.
    /// Ends on a normal stream completion or an `EnvironmentAuthorizationError`.
    public nonisolated func subscribe(
        _ tag: String,
        payload: @escaping @Sendable () async -> JSONValue,
        handler: @escaping @Sendable (SubscriptionEvent) async throws -> Void
    ) -> Task<Void, Never> {
        Task {
            var generation = 0
            var retryDelay: Duration = .milliseconds(250)
            var session: (RPCConnection, Int)?
            while !Task.isCancelled {
                if session == nil {
                    guard let next = await self.waitForConnection(after: generation) else { return }
                    session = next
                    generation = next.1
                }
                guard let (connection, gen) = session else { return }
                do {
                    try await handler(.subscribed(generation: gen))
                    for try await value in await connection.stream(tag, payload: await payload()) {
                        try await handler(.value(value))
                        retryDelay = .milliseconds(250)
                    }
                    if Task.isCancelled { return }
                    // A clean end of a durable stream: the server finished it on purpose.
                    if await connection.isClosed { session = nil; continue }
                    return
                } catch let error as RPCClientError {
                    if Task.isCancelled { return }
                    try? await handler(.interrupted(error))
                    let closed = await connection.isClosed
                    if error.isTransport || closed {
                        session = nil
                        continue
                    }
                    if error.typedError?.tag == "EnvironmentAuthorizationError" { return }
                    do { try await Task.sleep(for: retryDelay) } catch { return }
                    retryDelay = min(retryDelay * 2, .seconds(30))
                } catch {
                    if Task.isCancelled { return }
                    // The consumer rejected a wire value. Rebuild its payload and subscribe
                    // again, so a cleared resume cursor requests an authoritative snapshot.
                    do { try await Task.sleep(for: retryDelay) } catch { return }
                    retryDelay = min(retryDelay * 2, .seconds(30))
                }
            }
        }
    }
}
