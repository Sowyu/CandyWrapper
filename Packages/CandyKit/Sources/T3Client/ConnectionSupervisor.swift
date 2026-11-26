import Foundation
import T3Protocol

/// T3's reconnect ladder (packages/client-runtime/src/connection/supervisor.ts:35-49, 127-141).
public enum Backoff {
    public static let baseMilliseconds = 1_000
    public static let maxMilliseconds = 300_000
    /// The first retry after a live session drops (SESSION_LOSS_RETRY_DELAY_MS, supervisor.ts:48), jittered to 125-250 ms.
    public static let sessionLossMilliseconds = 250
    /// A session that stayed up this long resets the ladder.
    public static let resetAfter: Duration = .seconds(30)
    /// Someone is approving this device on the host, so check back soon (4928 supervisor.ts:49-52).
    public static let approvalPendingMilliseconds = 4_000
    /// A request lives 10 minutes; past that nobody is approving, so the device backs off.
    public static let approvalPendingFastRetries = 150

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

    /// Waiting for the host to approve this T3 Connect device (4928 connection/presentation.ts:58-68).
    public var awaitingApproval: Bool {
        guard failure?.reason == ConnectionFailureInfo.approvalPendingReason else { return false }
        return phase == .connecting || phase == .backoff
    }

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
/// (RpcServer.ts:806), apps/server/src/ws.ts sets no idle timeout, and Node's `ws` server has
/// none by default. So a direct connection needs no keepalive traffic from the client, and the
/// supervisor runs no timers while idle. A dead peer shows up through the events that cause
/// one: NWPathMonitor path changes, system wake, app activation (each runs a `server.probe`
/// with T3's timeouts), and the kernel failing the TCP socket. Servers from Nightly 5258 on write
/// `{"_tag":"Pong"}` every 20 s on every socket (apps/server/src/socketHeartbeat.ts:7-10,
/// ws.ts:3952), which the client cannot turn off. Each one wakes only the socket read task, which
/// decodes it and stamps the connection's last-frame time: no timer, no store, no view. So idle cost
/// is zero on older servers and one socket read per 20 s on 5258. Effect's 5 s ping would cost
/// 0.2 wakeups per second for nothing on a direct route.
/// While the owner expects traffic (`setExpectingTraffic`, a running turn) and the app is
/// active, the connection checks a quiet socket as T3 does, so a turn that stops streaming
/// because the network died shows "reconnecting" within 15 to 20 s instead of looking live.
/// Relay routes (T3 Connect via Cloudflare tunnels) can sit behind proxies that drop idle
/// sockets after about 100 s, so pass `.ping(interval: .seconds(80))` there; it pings only
/// while the app is active, and skips a ping when a frame arrived within the interval, so a
/// 5258 server's heartbeat keeps the route open with no ping from the client.
public actor ConnectionSupervisor {
    public struct Dependencies: Sendable {
        /// Opens one session: descriptor check, ticket, socket. One attempt, no retry.
        public var connect: @Sendable () async throws -> RPCConnection
        public var sleep: @Sendable (Duration) async throws -> Void
        public var now: @Sendable () -> ContinuousClock.Instant
        /// Uniform in [0, 1).
        public var random: @Sendable () -> Double
        /// Asks the host for its public descriptor over a fresh request: true when it answered as this environment.
        /// A probe still unanswered after 500 ms uses it to tell a dead socket from a slow one (supervisor.ts:745-790).
        /// Nil skips that check, and the probe deadline decides.
        public var checkHost: (@Sendable () async -> Bool)?
        /// Loopback or LAN, where a live socket answers within 3 s and a silent one is replaced at once
        /// (supervisor.ts:707-708, 730-737).
        public var answersQuickly: Bool
        /// Runs before the reconnect that follows a socket which died without a close: drop pooled HTTP
        /// connections, which usually died with it.
        public var transportLost: @Sendable () async -> Void
        /// A host on this device: the device reporting offline, often wrongly, never parks it. The report still
        /// probes a live session (supervisor.ts:323-327).
        public var ignoresOffline: Bool
        /// The wait before a durable subscription retries on the same session. Tests make it instant.
        public var retrySleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        public init(connect: @escaping @Sendable () async throws -> RPCConnection,
                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                    random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                    checkHost: (@Sendable () async -> Bool)? = nil,
                    answersQuickly: Bool = false,
                    transportLost: @escaping @Sendable () async -> Void = {},
                    ignoresOffline: Bool = false) {
            self.connect = connect
            self.sleep = sleep
            self.now = now
            self.random = random
            self.checkHost = checkHost
            self.answersQuickly = answersQuickly
            self.transportLost = transportLost
            self.ignoresOffline = ignoresOffline
        }

        /// A direct route's dependencies: `checkHost` reads the descriptor with T3's 2.5 s route check timeout
        /// (driver.ts:61, 186-207), `answersQuickly` follows the host, and a dead socket resets `http`'s pool.
        public static func direct(http: EnvironmentHTTP, environmentId: String?, identity: ClientIdentity,
                                  token: @escaping @Sendable () async throws -> String) -> Dependencies {
            return Dependencies(
                connect: ConnectionSupervisor.directConnector(http: http, environmentId: environmentId, identity: identity, token: token),
                checkHost: { await hostAnswers(at: http.baseURL, environmentId: environmentId) },
                answersQuickly: RouteKind.answersQuickly(http.baseURL),
                transportLost: { http.resetConnections() },
                ignoresOffline: RouteKind.isLoopback(http.baseURL))
        }

        /// A T3 Connect route's dependencies: `checkHost` reads the public descriptor through the tunnel, as T3's
        /// `checkHost` does for every prepared route (driver.ts:219-228), so a silent relay socket is found in about
        /// 2.5 s instead of at the 15 s probe deadline. `baseURL` follows the tunnel the relay currently names.
        public static func relay(connect: @escaping @Sendable () async throws -> RPCConnection, environmentId: String?,
                                 baseURL: @escaping @Sendable () async throws -> URL,
                                 transportLost: @escaping @Sendable () async -> Void = {}) -> Dependencies {
            Dependencies(connect: connect,
                         checkHost: {
                             guard let url = try? await baseURL() else { return false }
                             return await hostAnswers(at: url, environmentId: environmentId)
                         },
                         transportLost: transportLost)
        }

        /// The descriptor at `baseURL` within T3's 2.5 s route check timeout (driver.ts:61, 186-207), on its own
        /// session each time: a pooled connection to a host whose socket went silent is likely dead too, and the
        /// check would wait out its timeout on it. The descriptor is public, so no credential goes out.
        static func hostAnswers(at baseURL: URL, environmentId: String?) async -> Bool {
            let session = URLSession(configuration: EnvironmentHTTP.defaultSession.configuration)
            defer { session.finishTasksAndInvalidate() }
            var check = EnvironmentHTTP(baseURL: baseURL, session: session)
            check.timeout = 2.5
            guard let descriptor = try? await check.descriptor() else { return false }
            return environmentId == nil || descriptor.environmentId == environmentId
        }
    }

    /// T3's route kinds for probe timing (connection/routes.ts `connectionRouteKind`).
    public enum RouteKind {
        /// This device: `localhost`, 127/8 and ::1.
        public static func isLoopback(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
        }

        /// Loopback and private LAN addresses, and `.local` names.
        public static func answersQuickly(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
            let octets = host.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4, host.split(separator: ".").count == 4 else { return host.hasPrefix("fe80:") || host.hasPrefix("fd") }
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
    }

    /// T3's CONNECTION_ESTABLISHMENT_TIMEOUT and probe timeouts (supervisor.ts:35-49).
    public static let establishTimeout: Duration = .seconds(15)
    public static let probeTimeout: Duration = .seconds(15)
    public static let quickProbeTimeout: Duration = .seconds(3)
    /// Input after the socket said nothing this long probes it: T3 drops a socket after 15 s without a frame
    /// (client-runtime rpc/protocol.ts:10-12), and this finds the same socket on the user's next input, without a timer.
    public static let inputQuietThreshold: Duration = .seconds(15)

    private let deps: Dependencies
    private let keepalive: KeepalivePolicy
    private(set) public var state = ConnectionState() { didSet { if state != oldValue { publish() } } }
    private var desired = false
    private var online = true
    /// The last NWPathMonitor update applied. Updates reach the actor through separate tasks, so an older one can
    /// arrive after a newer one; it must not undo it.
    private var pathSequence = 0
    /// The next attempt runs even while the device reports offline: a Reconnect press, or replacing a socket a
    /// probe found dead. The platform's report can stay wrong after the network is back (supervisor.ts:1213-1221).
    private var ignoreOfflineOnce = false
    nonisolated var retrySleep: @Sendable (Duration) async throws -> Void { deps.retrySleep }
    /// Bumped on app activation; durable subscriptions that opt in subscribe again on the same session.
    private var resubscribeEpoch = 0
    private var resubscribeWaiters: [UUID: (after: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var appActive = true
    private var expectingTraffic = false
    /// Orders `applyWatch` calls, which reach the connection through separate tasks.
    private var watchGeneration = 0
    private var failures = 0
    /// The failures that climb the ladder: approval waits count as attempts but not here.
    private var backoffFailures = 0
    private var approvalWaits = 0
    private var skipNextDelay = false
    private var connection: RPCConnection?
    private var connectedAt: ContinuousClock.Instant?
    private var attemptID = 0
    private var attemptTask: Task<Void, Never>?
    private var timerID = 0
    private var timerTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    /// The last socket died without a close, so the next attempt resets pooled HTTP connections first.
    private var transportSuspect = false
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
            let connection = RPCConnection(socket: socket, serverVersion: descriptor.serverVersion,
                                           serverCapabilities: Set(descriptor.capabilities.compactMap { $0.value.boolValue == true ? $0.key : nil }))
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
        failures = 0; backoffFailures = 0; approvalWaits = 0
        skipNextDelay = false
        if connection != nil { probe(.retry); return }
        ignoreOfflineOnce = true
        cancelAttempt()
        evaluate()
    }

    /// One NWPathMonitor update, numbered in the order the monitor delivered it. A late older update is dropped.
    public func pathUpdated(online isOnline: Bool, moved: Bool, sequence: Int) {
        guard sequence > pathSequence else { return }
        pathSequence = sequence
        networkChanged(online: isOnline)
        if moved { networkPathChanged() }
    }

    public func networkChanged(online isOnline: Bool) {
        guard isOnline != online else { return }
        online = isOnline
        if isOnline {
            failures = 0; backoffFailures = 0; approvalWaits = 0
            if connection != nil { probe(.retry) } else { cancelTimer(); evaluate() }
        } else if connection != nil {
            // A loopback session can survive losing the network. Probe before dropping it.
            probe(.retry)
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
        failures = 0; backoffFailures = 0; approvalWaits = 0
        if connection != nil {
            probe(.networkChanged)
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
        failures = 0; backoffFailures = 0; approvalWaits = 0
        if connection != nil {
            probe(reason == .systemWake ? .retry : .foreground)
            // Shell and thread subscribe again on the same session, so one that died while the app was in the
            // background is live again (wakeups.ts:25-27, state/shell.ts:629, state/threads.ts:984).
            if reason == .applicationActive { resubscribe() }
            startPinging()
        } else if attemptTask == nil {
            cancelTimer()
            evaluate()
        }
    }

    /// The user acted (a key, click, scroll or the pointer entering the window). A socket silent for
    /// `threshold` gets a probe with the silent socket check, which is how an idle socket that died without a
    /// close is found without a timer. Returns how long until the socket would be silent for `threshold`, so
    /// the caller can skip the next inputs until then, and whether it probed; nil while there is no session.
    public func inputAfterQuiet(threshold: Duration = inputQuietThreshold) async -> (recheckIn: Duration, probed: Bool)? {
        guard let connection else { return nil }
        let quiet = await connection.quietFor
        guard self.connection === connection else { return nil }
        if quiet < threshold { return (threshold - quiet, false) }
        if probeTask == nil { probe(.input) }
        return (threshold, true)
    }

    /// Subscriptions made with `resubscribesOnActivation` interrupt their stream and subscribe again from their cursor.
    public func resubscribe() {
        resubscribeEpoch += 1
        let ready = resubscribeWaiters
        resubscribeWaiters = [:]
        for waiter in ready.values { waiter.continuation.resume() }
    }

    var currentResubscribeEpoch: Int { resubscribeEpoch }

    /// Returns once `resubscribe` runs after `epoch`, or when the waiting task is cancelled.
    func waitForResubscribe(after epoch: Int) async {
        if resubscribeEpoch > epoch { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if Task.isCancelled || resubscribeEpoch > epoch { return c.resume() }
                resubscribeWaiters[id] = (epoch, c)
            }
        } onCancel: {
            Task { await self.cancelResubscribeWaiter(id) }
        }
    }

    private func cancelResubscribeWaiter(_ id: UUID) {
        resubscribeWaiters.removeValue(forKey: id)?.continuation.resume()
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

    /// A unary call that gives up after `timeout` and throws `CancellationError`. Giving up sends `Interrupt`, so a
    /// handler that never answers can't hold back the calls queued behind it (audit OH-2).
    public func request(_ tag: String, payload: JSONValue = .object([:]), timeout: Duration) async throws -> JSONValue {
        try await withTimeout(timeout) { try await self.request(tag, payload: payload) }
    }

    /// A live socket can still carry a message the host never answers, and the liveness checks alone would leave the
    /// send pending forever, so a message send fails after 60 s (#35076, client-runtime operations/commands.ts
    /// MESSAGE_DISPATCH_TIMEOUT). Giving up sends `Interrupt`.
    public static let messageDispatchTimeout: Duration = .seconds(60)

    /// `orchestration.dispatchCommand` for a user message, failing with T3's text after `messageDispatchTimeout`.
    public func dispatchMessage(_ payload: JSONValue, hostLabel: String, timeout: Duration = messageDispatchTimeout) async throws -> JSONValue {
        let unconfirmed = RPCClientError.failure([.fail(RPCTypedError(tag: "EnvironmentRpcUnavailableError", fields: [
            "message": .string("\(hostLabel) did not confirm the message within \(timeout.components.seconds) seconds."),
        ]))])
        return try await withTimeout(timeout, error: unconfirmed) {
            try await self.request("orchestration.dispatchCommand", payload: payload)
        }
    }

    /// Reads one snapshot, then interrupts the stream. `scheduledTasks.list` was removed in 3814;
    /// its subscription works on older servers too (packages/contracts/src/rpc.ts:1828-1833).
    public func firstSnapshot(_ tag: String, payload: JSONValue = .object([:]), timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard let connection else { throw RPCClientError.transport(.closed("not connected")) }
        return try await withTimeout(timeout) {
            for try await value in await connection.stream(tag, payload: payload, snapshotFirst: true) {
                return value
            }
            throw RPCClientError.transport(.closed("subscription ended before its snapshot"))
        }
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

    /// Fresh descriptor metadata from this socket's connector. Unknown routes negotiate anew.
    public var serverVersion: String? { connection?.serverVersion }
    public var serverCapabilities: Set<String> { connection?.serverCapabilities ?? [] }

    // MARK: State machine

    private func evaluate() {
        cancelTimer()
        guard desired else {
            setPhase(.available)
            return
        }
        if connection != nil || attemptTask != nil { return }
        guard online || deps.ignoresOffline || ignoreOfflineOnce else {
            setPhase(.offline)
            return
        }
        ignoreOfflineOnce = false
        startAttempt()
    }

    private func startAttempt() {
        attemptID += 1
        let id = attemptID
        state.attempt = failures + 1
        setPhase(.connecting)
        let connect = deps.connect
        let resetTransport = transportSuspect
        transportSuspect = false
        let transportLost = deps.transportLost
        attemptTask = Task {
            if resetTransport { await transportLost() }
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
        if let connectedAt, deps.now() - connectedAt >= Backoff.resetAfter { failures = 0; backoffFailures = 0; approvalWaits = 0 }
        if case .transport(.pingTimedOut) = reason { transportSuspect = true }
        if desired && (online || deps.ignoresOffline || ignoreOfflineOnce) {
            // The first loss of a live session retries almost at once; the ladder still counts it (supervisor.ts:1286-1298).
            scheduleRetry(reason.description, ConnectionFailureInfo(reason: "transport", blocked: false, detail: reason.description),
                          firstLoss: failures == 0)
        } else {
            evaluate()
        }
    }

    private func scheduleRetry(_ detail: String, _ info: ConnectionFailureInfo, firstLoss: Bool = false) {
        state.lastFailure = detail
        state.failure = info
        // Approval waits count as attempts but not toward backoff, so a later outage starts low (4928 supervisor.ts:1185-1305).
        let pending = info.reason == ConnectionFailureInfo.approvalPendingReason
        if pending { approvalWaits += 1 }
        let awaitingApproval = pending && approvalWaits <= Backoff.approvalPendingFastRetries
        // The quick retry after a lost session doesn't climb the ladder either, so a server that is still restarting
        // gets its next try on the first rung (1-2 s) instead of the second (2-4 s). T3 counts it (supervisor.ts:1286-1294);
        // a host that keeps dropping sessions still climbs, since only the first loss after 30 s up is quick.
        if !awaitingApproval && !firstLoss { backoffFailures += 1 }
        failures += 1
        let ladder = awaitingApproval ? 0 : Backoff.delayMilliseconds(failureCount: backoffFailures - 1, random: deps.random())
        let milliseconds = pending ? max(Backoff.approvalPendingMilliseconds, ladder)
            : firstLoss ? Int((Double(Backoff.sessionLossMilliseconds) * (0.5 + deps.random() / 2)).rounded()) : ladder
        let delay: Duration = skipNextDelay ? .zero : .milliseconds(milliseconds)
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

    /// What asked for a probe; each gets T3's deadline (supervisor.ts:710-743).
    enum ProbeKind {
        /// Returning to the app: 15 s, and one missed probe is asked again, since a busy host can miss one
        /// (#24309, supervisor.ts:819-822, 885-892).
        case foreground
        /// Retry, wake, the network going offline: 3 s.
        case retry
        /// Another network path: 3 s on loopback and LAN, 15 s elsewhere, where a tailnet or VPN can be slower.
        case networkChanged
        /// Input after a silent stretch (`inputAfterQuiet`): the network change's deadlines.
        case input
    }

    private func probe(_ kind: ProbeKind) {
        guard let connection, probeTask == nil else { return }
        let generation = state.generation
        let quick = deps.answersQuickly
        let timeout: Duration = switch kind {
        case .foreground: Self.probeTimeout
        case .retry: Self.quickProbeTimeout
        case .networkChanged, .input: quick ? Self.quickProbeTimeout : Self.probeTimeout
        }
        let checkHost = deps.checkHost
        probeTask = Task {
            let alive = await Self.runProbe(connection, timeout: timeout, toleratesMiss: kind == .foreground,
                                            checkHost: checkHost, replaceAtOnce: quick && kind != .foreground)
            await self.probeFinished(generation, alive: alive)
        }
    }

    /// `server.probe` against its deadline, raced with the silent socket check. Any answer, even a typed failure or
    /// Die from an older server, proves the socket works.
    ///
    /// The silent socket check (supervisor.ts:745-790): a probe still unanswered after 500 ms asks the host for its
    /// descriptor over a fresh request, again each second until it answers. If the host answers while the socket
    /// delivered no frame, the socket is dead: replaced at once on loopback and LAN, and 2.5 s after the check
    /// started elsewhere, where one lost packet can stall a live socket. T3's foreground probe skips this check
    /// because its 5 s pings already watch an idle socket; CandyWrapper sends none, so the foreground probe runs it
    /// with the 2.5 s wait on every route. Frame parts keep a big frame from looking silent.
    static func runProbe(_ connection: RPCConnection, timeout: Duration, toleratesMiss: Bool,
                         checkHost: (@Sendable () async -> Bool)?, replaceAtOnce: Bool) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                for attempt in 0..<(toleratesMiss ? 2 : 1) {
                    do {
                        _ = try await withTimeout(timeout, error: RPCTransportError.pingTimedOut) {
                            try await connection.request("server.probe")
                        }
                        return true
                    } catch let e as RPCClientError where !e.isTransport {
                        return true
                    } catch RPCTransportError.pingTimedOut where attempt == 0 && toleratesMiss {
                        continue
                    } catch {
                        return false
                    }
                }
                return false
            }
            if let checkHost {
                group.addTask {
                    let started = ContinuousClock.now
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return nil }
                    let before = await connection.inboundFrames
                    while await !checkHost() {
                        if await connection.inboundFrames != before { return nil }
                        do { try await Task.sleep(for: .seconds(1)) } catch { return nil }
                    }
                    if !replaceAtOnce {
                        let remaining = .milliseconds(2500) - (ContinuousClock.now - started)
                        if remaining > .zero { do { try await Task.sleep(for: remaining) } catch { return nil } }
                    }
                    // nil leaves the decision to the probe: the socket delivered something.
                    return await connection.inboundFrames == before ? false : nil
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return true
        }
    }

    private func probeFinished(_ generation: Int, alive: Bool) async {
        probeTask = nil
        guard generation == state.generation, let conn = connection, !alive else { return }
        // T3 reconnects at once after a failed probe, then resumes the normal ladder.
        skipNextDelay = true
        transportSuspect = true
        ignoreOfflineOnce = true
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
                    // Any frame proves the socket and keeps the proxy's idle clock reset, as a Pong would.
                    if await connection.quietFor < interval { continue }
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
    /// on the same session after 250 ms doubling to 30 s (client-runtime rpc/client.ts:105-106), a few times unless
    /// the subscription keeps retrying them (`serverFailureRetries`).
    case interrupted(RPCClientError)
}

extension ConnectionSupervisor {
    /// Server failures in a row, with no value between them, that a subscription retries on one session before it
    /// waits for the next session. T3 retries a failing stream only where the caller asks, the shell and threads
    /// (client-runtime rpc/client.ts:436-452, state/shell.ts:719-720, state/threads.ts:1145-1149), and ends the rest
    /// on the first failure. Retrying forever sent `subscribeVcsStatus` every 30 s while the app sat idle, for every
    /// folder on a host whose git cannot start (a server left running in a deleted working directory fails each one
    /// with `GitManagerError`). A folder without git is not a failure: the host answers `isRepo: false` and keeps the
    /// stream open. Five retries span about 8 s.
    public static let serverFailureRetries = 5

    /// A stream that follows the connection: it re-subscribes on every new session and after
    /// recoverable failures. `payload` runs before each subscribe so the caller can supply the
    /// current resume cursor (`afterSequence`). `handler` is awaited before the next value is
    /// pulled, so a slow handler holds back the server through acks.
    /// A handler may clear its cursor and throw to retry with a fresh snapshot after a bad value.
    /// Cancel the returned task to unsubscribe; that sends `Interrupt`.
    /// Ends on a normal stream completion or an `EnvironmentAuthorizationError`.
    /// `snapshotFirst`: see `RPCConnection.stream`.
    /// `resubscribesOnActivation`: app activation (`resubscribe`) interrupts the stream and subscribes again on the same
    /// session, as T3 does for the shell and threads (client-runtime rpc/client.ts:284-330, state/shell.ts:629,
    /// state/threads.ts:984). One small round trip, and a subscription that died without an error is live again.
    /// `keepsRetryingServerFailures`: retry server failures on the same session for as long as they last, as T3 does
    /// for the shell and threads. Without it a subscription stops after `serverFailureRetries` and subscribes again on
    /// the next session.
    public nonisolated func subscribe(
        _ tag: String,
        snapshotFirst: Bool = false,
        resubscribesOnActivation: Bool = false,
        keepsRetryingServerFailures: Bool = false,
        payload: @escaping @Sendable () async -> JSONValue,
        handler: @escaping @Sendable (SubscriptionEvent) async throws -> Void
    ) -> Task<Void, Never> {
        let retrySleep = self.retrySleep
        return Task {
            var generation = 0
            var retryDelay: Duration = .milliseconds(250)
            var serverFailures = 0
            var session: (RPCConnection, Int)?
            while !Task.isCancelled {
                if session == nil {
                    guard let next = await self.waitForConnection(after: generation) else { return }
                    session = next
                    generation = next.1
                }
                guard let (connection, gen) = session else { return }
                let progress = SubscriptionProgress()
                do {
                    let epoch = await self.currentResubscribeEpoch
                    try await handler(.subscribed(generation: gen))
                    let input = await payload()
                    // Cancelled while the payload waited, as when the user leaves a thread during its cold open.
                    if Task.isCancelled { return }
                    let stream = await connection.stream(tag, payload: input, snapshotFirst: snapshotFirst)
                    // True when activation asked for a new subscription; false when the stream ended.
                    let resubscribe = try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            for try await value in stream {
                                try await handler(.value(value))
                                progress.sawValue = true
                            }
                            return false
                        }
                        if resubscribesOnActivation {
                            group.addTask {
                                await self.waitForResubscribe(after: epoch)
                                return !Task.isCancelled
                            }
                        }
                        defer { group.cancelAll() }
                        return try await group.next() ?? false
                    }
                    retryDelay = .milliseconds(250)
                    serverFailures = 0
                    if Task.isCancelled { return }
                    if resubscribe { continue }
                    // A clean end of a durable stream: the server finished it on purpose.
                    if await connection.isClosed { session = nil; continue }
                    return
                } catch let error as RPCClientError {
                    if Task.isCancelled { return }
                    if progress.sawValue { retryDelay = .milliseconds(250) }
                    try? await handler(.interrupted(error))
                    let closed = await connection.isClosed
                    if error.isTransport || closed {
                        session = nil
                        continue
                    }
                    if error.typedError?.tag == "EnvironmentAuthorizationError" { return }
                    serverFailures = progress.sawValue ? 1 : serverFailures + 1
                    if !keepsRetryingServerFailures, serverFailures > Self.serverFailureRetries {
                        // Parked until the next session, which subscribes again from a fresh payload.
                        serverFailures = 0
                        retryDelay = .milliseconds(250)
                        session = nil
                        continue
                    }
                    do { try await retrySleep(retryDelay) } catch { return }
                    retryDelay = min(retryDelay * 2, .seconds(30))
                } catch {
                    if Task.isCancelled { return }
                    if progress.sawValue { retryDelay = .milliseconds(250) }
                    // The consumer rejected a wire value. Rebuild its payload and subscribe
                    // again, so a cleared resume cursor requests an authoritative snapshot.
                    do { try await retrySleep(retryDelay) } catch { return }
                    retryDelay = min(retryDelay * 2, .seconds(30))
                }
            }
        }
    }
}

/// Set by a subscription's stream task, read by its loop once that task has finished.
private final class SubscriptionProgress: @unchecked Sendable {
    var sawValue = false
}
