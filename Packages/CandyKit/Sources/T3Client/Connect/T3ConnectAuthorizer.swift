import Foundation
import T3Protocol

/// An environment DPoP access token from the T3 Connect sequence. One hour; the environment
/// closes the socket when it expires (protocol.md 10.4, C-auth-connect.md 1.8).
public struct T3ConnectToken: Sendable, Equatable {
    public var environmentId: String
    public var label: String
    /// The tunnel endpoint the relay returned.
    public var endpoint: RelayEndpoint
    public var accessToken: String
    public var expiresAt: Date
    public var accountId: String?
    public var thumbprint: String
    public var serverVersion: String? = nil
    public var serverCapabilities: Set<String> = []

    /// DPOP_ACCESS_TOKEN_REFRESH_SKEW_MS (client-runtime/src/connection/model.ts:108).
    public static let refreshSkew: TimeInterval = 60

    /// When to renew: 60 s before expiry (authorization/service.ts:369-385).
    public var renewAt: Date { expiresAt.addingTimeInterval(-Self.refreshSkew) }
    public func needsRenewal(at now: Date) -> Bool { now >= renewAt }
}

/// A socket URL ready to open, plus what later HTTP calls need.
public struct T3ConnectSocket: Sendable, Equatable {
    public var url: URL
    /// The origin in use: the tunnel, or a learned direct route.
    public var httpBaseUrl: String
    public var token: T3ConnectToken
}

/// The T3 Connect connect sequence (protocol.md 10.4, client-runtime/src/authorization/service.ts):
/// relay connect, descriptor check, `/oauth/token` with a DPoP proof, then a WebSocket ticket.
/// Keeps one environment token per environment in memory and in `store` between launches, renews it 60 s
/// before expiry and shares one pending renewal between callers.
public actor T3ConnectAuthorizer {
    /// Ticket timeout for a cached token; past it the token is replaced (service.ts:88, 503-520).
    public static let cachedSocketTimeout: TimeInterval = 3
    /// Environment request timeout (authorization/remote.ts:25).
    public static let requestTimeout: TimeInterval = 10
    /// Cap on one shared exchange, whoever waits for it (DPOP_AUTHORIZATION_TIMEOUT_MS, service.ts:90, 447-457).
    static let authorizationTimeout: Duration = .seconds(30)

    public nonisolated let relay: RelayClient
    private let tokens: any CloudTokenProvider
    private let identity: ClientIdentity
    private let deviceId: String?
    private let send: HTTPSend
    private let now: @Sendable () -> Date
    /// Tokens kept between launches; nil keeps them in memory only.
    private let store: ConnectTokenStore?
    /// Each token with the sign-in it was issued under.
    private var cache: [String: (token: T3ConnectToken, signIn: CloudSignIn)] = [:]
    private var pending: [String: Pending] = [:]
    /// Bumped by `reset()`, so an exchange started before a sign-out can't publish or hand out its token.
    private var generation = 0

    /// One shared exchange, bound to the sign-in and reset generation it started under (service.ts:413-415).
    private struct Pending {
        let id: UUID
        let signIn: CloudSignIn
        let generation: Int
        let task: Task<T3ConnectToken, Error>
    }

    /// `identity.connectionMethod` is ignored: T3 Connect sockets always say `relay`, even on a
    /// learned direct route (service.ts:217-245).
    public init(relay: RelayClient, tokens: any CloudTokenProvider, identity: ClientIdentity, deviceId: String? = nil,
                send: HTTPSend? = nil, store: ConnectTokenStore? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.relay = relay
        self.store = store
        self.tokens = tokens
        self.identity = identity
        self.deviceId = deviceId
        self.send = send ?? ConnectHTTP.urlSession
        self.now = now
    }

    // MARK: Tokens

    /// A token that is not due for renewal, from the cache or a fresh connect. `rejected` names a
    /// token the environment refused, so it is replaced even if it looks valid (service.ts:363-393).
    public func token(environmentId: String, rejected: String? = nil) async throws -> T3ConnectToken {
        try await selectToken(environmentId: environmentId, rejected: rejected).token
    }

    private func selectToken(environmentId: String, rejected: String?) async throws -> (token: T3ConnectToken, fromCache: Bool) {
        // Captured once, before any other await: everything below belongs to this sign-in (service.ts:263-268).
        let signIn = try await tokens.currentSignIn()
        guard let signIn else { throw CloudSessionError.signedOut }
        if cache[environmentId] == nil, pending[environmentId] == nil, let store {
            // T3 reads its token store first and reuses a token for the same environment, account and key with
            // more than the 60 s skew left that wasn't just refused (service.ts:458-480).
            let started = generation
            if let stored = await store.load(accountId: signIn.accountId, environmentId: environmentId),
               generation == started, cache[environmentId] == nil {
                if stored.thumbprint == relay.key.thumbprint, !stored.needsRenewal(at: now()), stored.accessToken != rejected {
                    cache[environmentId] = (stored, signIn)
                } else {
                    // Expired, refused or bound to another proof key: it can never be used again.
                    store.delete(accountId: signIn.accountId, environmentId: environmentId, ifToken: stored.accessToken)
                }
            }
        }
        if let cached = cache[environmentId] {
            if cached.signIn == signIn, cached.token.thumbprint == relay.key.thumbprint,
               !cached.token.needsRenewal(at: now()), cached.token.accessToken != rejected {
                return (cached.token, true)
            }
            if cached.signIn != signIn {
                cache = [:]
                if cached.signIn.accountId != signIn.accountId { store?.deleteAll(keepingAccount: signIn.accountId) }
            } else if cached.token.accessToken == rejected {
                drop(environmentId, cached.token)
            }
        }
        // The relay key never changes for this authorizer, so the sign-in and generation are the whole identity.
        let shared: Pending
        if let p = pending[environmentId], p.signIn == signIn, p.generation == generation {
            shared = p
        } else {
            let id = UUID(), started = generation
            shared = Pending(id: id, signIn: signIn, generation: started, task: Task {
                try await self.sharedExchange(environmentId: environmentId, signIn: signIn, generation: started, id: id)
            })
            pending[environmentId] = shared
        }
        // Cancelling this caller, as the supervisor's 15 s timeout does, leaves the exchange running for the others.
        let fresh: T3ConnectToken
        do {
            fresh = try await joinShared(shared.task)
        } catch where generation != shared.generation && !Task.isCancelled {
            // reset() ended the exchange this caller joined.
            throw CloudSessionError.accountChanged
        }
        // The user may have signed in again, to any account, while this waited (service.ts:409-421).
        guard generation == shared.generation, try await tokens.currentSignIn() == signIn, generation == shared.generation else {
            throw CloudSessionError.accountChanged
        }
        return (fresh, false)
    }

    /// The exchange every caller for one environment and sign-in shares. It checks the sign-in itself
    /// before caching, so the cache never takes another sign-in's token (service.ts:424-445).
    private func sharedExchange(environmentId: String, signIn: CloudSignIn, generation started: Int, id: UUID) async throws -> T3ConnectToken {
        defer { if pending[environmentId]?.id == id { pending[environmentId] = nil } }
        let work = Task { try await self.exchange(environmentId: environmentId, account: signIn.accountId) }
        let fresh: T3ConnectToken
        do {
            fresh = try await joinShared(work, timeout: Self.authorizationTimeout,
                                         timeoutError: ConnectionFailure.transient("Timed out renewing the environment credential."))
        } catch {
            work.cancel()
            throw error
        }
        guard generation == started, try await tokens.currentSignIn() == signIn, generation == started else {
            throw CloudSessionError.accountChanged
        }
        cache[environmentId] = (fresh, signIn)
        store?.save(fresh)
        return fresh
    }

    /// Steps 3 to 6 of protocol.md 10.4.
    private func exchange(environmentId: String, account: String) async throws -> T3ConnectToken {
        let jwt = try await tokens.relaySessionJWT()
        guard jwtSubject(jwt).map({ $0 == account }) ?? true else { throw CloudSessionError.accountChanged }
        let bootstrap = try await relay.connect(environmentId: environmentId, deviceId: deviceId, relayJWT: jwt)
        guard bootstrap.environmentId == environmentId else {
            throw T3ConnectError.environmentMismatch(expected: environmentId, actual: bootstrap.environmentId)
        }
        let descriptor = try await descriptor(httpBaseUrl: bootstrap.endpoint.httpBaseUrl)
        guard descriptor.environmentId == environmentId else {
            throw T3ConnectError.environmentMismatch(expected: environmentId, actual: descriptor.environmentId)
        }
        // The minted credential lives two minutes and works once: redeem it now, with the same key.
        let url = try endpointURL(bootstrap.endpoint.httpBaseUrl, "/oauth/token")
        var request = makeRequest("POST", url, timeout: Self.requestTimeout)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(try DPoP.proof(method: "POST", url: url, key: relay.key, now: now()), forHTTPHeaderField: "DPoP")
        request.httpBody = ConnectHTTP.formBody(
            TokenExchangeRequest(subjectToken: bootstrap.credential, clientLabel: identity.label).formFields)
        let issuedAt = now()
        let access: AccessTokenResult
        do {
            access = try await perform(request, as: AccessTokenResult.self)
        } catch EnvironmentHTTPError.status(403, let body?) where body.isConnectApprovalPending {
            // The host requires device approval (4928 client-runtime/src/authorization/service.ts:148-163, 415-418).
            throw T3ConnectError.approvalPending(host: descriptor.label,
                                                 verificationCode: ConnectDeviceApproval.verificationCode(thumbprint: relay.key.thumbprint),
                                                 traceId: body.traceId)
        }
        return T3ConnectToken(environmentId: descriptor.environmentId, label: descriptor.label, endpoint: bootstrap.endpoint,
                              accessToken: access.accessToken,
                              expiresAt: issuedAt.addingTimeInterval(TimeInterval(access.expiresIn)),
                              accountId: account, thumbprint: relay.key.thumbprint, serverVersion: descriptor.serverVersion,
                              serverCapabilities: Self.capabilities(descriptor))
    }

    /// Drops the token for one environment (removed, or signed out of it), stored ones under every account too.
    public func forget(environmentId: String) {
        cache[environmentId] = nil
        store?.delete(environmentId: environmentId)
    }

    /// Deletes stored tokens issued to any other account; nil deletes them all. At launch and after a sign-in.
    public func keepStoredTokens(forAccount accountId: String?) {
        store?.deleteAll(keepingAccount: accountId)
    }

    /// Waits for queued Keychain writes. Tests.
    func flushStore() async { await store?.flush() }

    /// Drops a refused token from memory and the store, unless a newer one replaced it.
    private func drop(_ environmentId: String, _ token: T3ConnectToken) {
        guard cache[environmentId]?.token.accessToken == token.accessToken else { return }
        let accountId = cache[environmentId]?.signIn.accountId
        cache[environmentId] = nil
        if let accountId { store?.delete(accountId: accountId, environmentId: environmentId, ifToken: token.accessToken) }
    }

    /// Drops everything, relay tokens and stored tokens included (sign-out, account switch).
    public func reset() async {
        generation += 1
        cache = [:]
        store?.deleteAll(keepingAccount: nil)
        for p in pending.values { p.task.cancel() }
        pending = [:]
        await relay.resetTokenCache()
    }

    // MARK: Socket and HTTP

    /// A socket URL for the environment over its tunnel or `directEndpoint` (a learned route).
    /// A cached token gets 3 s to mint a ticket; if that fails on the tunnel, or the direct route
    /// refuses the token, a fresh token replaces it once (service.ts:488-534, 705-760). A cached token
    /// carries no descriptor, so it is read beside the ticket and a failed ticket abandons it (service.ts:711-724).
    public func authorizeSocket(environmentId: String, directEndpoint: DirectRoute? = nil) async throws -> T3ConnectSocket {
        var checked: EnvironmentDescriptor?
        if let directEndpoint {
            // A saved LAN address can belong to another machine on another network (service.ts:142-181).
            let descriptor = try await descriptor(httpBaseUrl: directEndpoint.httpBaseUrl)
            guard descriptor.environmentId == environmentId else {
                throw T3ConnectError.environmentMismatch(expected: environmentId, actual: descriptor.environmentId)
            }
            checked = descriptor
        }
        let direct = checked
        var (token, fromCache) = try await selectToken(environmentId: environmentId, rejected: nil)
        if fromCache {
            if let opened = try await reuse(token, directEndpoint: directEndpoint, direct: direct) { return opened }
            token = try await self.token(environmentId: environmentId, rejected: token.accessToken)
        }
        do {
            return try await socket(token, direct: directEndpoint, timeout: Self.requestTimeout)
        } catch {
            // A direct address that refuses the socket says nothing about the token.
            if directEndpoint == nil || error is DPoPError { drop(environmentId, token) }
            throw error
        }
    }

    /// A socket for a cached token, or nil when the route refused it and a fresh token should replace it. Returning
    /// nil cancels the descriptor read before the fresh exchange starts.
    private func reuse(_ token: T3ConnectToken, directEndpoint: DirectRoute?, direct: EnvironmentDescriptor?) async throws -> T3ConnectSocket? {
        async let reading = descriptor(for: token, known: direct)
        var opened: T3ConnectSocket
        do {
            opened = try await socket(token, direct: directEndpoint, timeout: Self.cachedSocketTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DPoPError {
            throw error
        } catch {
            // An unreachable direct address says nothing about the token; keep it for the tunnel.
            if directEndpoint != nil, !Self.isEnvironmentAuthInvalid(error) { throw error }
            return nil
        }
        let descriptor = try await reading
        opened.token.serverVersion = descriptor.serverVersion
        opened.token.serverCapabilities = Self.capabilities(descriptor)
        return opened
    }

    /// The descriptor for a reused token: the direct route's, already read, or the tunnel's.
    private func descriptor(for token: T3ConnectToken, known: EnvironmentDescriptor?) async throws -> EnvironmentDescriptor {
        if let known { return known }
        let descriptor = try await descriptor(httpBaseUrl: token.endpoint.httpBaseUrl)
        guard descriptor.environmentId == token.environmentId else {
            throw T3ConnectError.environmentMismatch(expected: token.environmentId, actual: descriptor.environmentId)
        }
        return descriptor
    }

    static func capabilities(_ descriptor: EnvironmentDescriptor) -> Set<String> {
        Set(descriptor.capabilities.compactMap { $0.value.boolValue == true ? $0.key : nil })
    }

    /// The tunnel origin the environment's current token was issued for: HTTP calls go there, wherever its
    /// route was saved (environmentHttpAuth.ts:155-177, audit TR-1).
    public func httpBaseURL(environmentId: String) async throws -> URL {
        let endpoint = try await token(environmentId: environmentId).endpoint.httpBaseUrl
        guard let url = URL(string: endpoint) else { throw DPoPError.invalidURL(endpoint) }
        return url
    }

    /// `Authorization` and `DPoP` headers for one later HTTP call to the environment
    /// (`Authorization: DPoP <token>` plus a fresh proof for that exact URL, with `ath`).
    /// After a 401, `EnvironmentHTTP` asks again with the refused token as `rejected`, which skips the
    /// cache, and retries once (client-runtime/src/state/environmentHttpAuth.ts:148-207).
    public func authorizationHeaders(environmentId: String, method: String, url: URL, rejected: String? = nil) async throws -> [String: String] {
        let token = try await token(environmentId: environmentId, rejected: rejected)
        return ["Authorization": "DPoP \(token.accessToken)",
                "DPoP": try DPoP.proof(method: method, url: url, accessToken: token.accessToken, key: relay.key, now: now())]
    }

    private func socket(_ token: T3ConnectToken, direct: DirectRoute?, timeout: TimeInterval) async throws -> T3ConnectSocket {
        let httpBase = direct?.httpBaseUrl ?? token.endpoint.httpBaseUrl
        let wsBase = direct?.wsBaseUrl ?? token.endpoint.wsBaseUrl
        let url = try endpointURL(httpBase, "/api/auth/websocket-ticket")
        var request = makeRequest("POST", url, timeout: timeout)
        request.setValue("DPoP \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(try DPoP.proof(method: "POST", url: url, accessToken: token.accessToken, key: relay.key, now: now()),
                         forHTTPHeaderField: "DPoP")
        let ticket = try await perform(request, as: WebSocketTicket.self)
        return T3ConnectSocket(url: try Self.socketURL(wsBaseUrl: wsBase, ticket: ticket.ticket, identity: identity),
                               httpBaseUrl: httpBase, token: token)
    }

    /// `wsBaseUrl` with path `/ws` when it has none, then `wsTicket`, the client parameters,
    /// `connectionMethod=relay` and `orchestrationProtocol=2`, in T3's order
    /// (authorization/remote.ts:42-84, 228-249; connection/compatibility.ts:38-42).
    public static func socketURL(wsBaseUrl: String, ticket: String, identity: ClientIdentity) throws -> URL {
        guard var c = URLComponents(string: wsBaseUrl), c.host != nil else { throw DPoPError.invalidURL(wsBaseUrl) }
        if c.path.isEmpty || c.path == "/" { c.path = "/ws" }
        c.fragment = nil
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "wsTicket" } + [
            URLQueryItem(name: "wsTicket", value: ticket),
            URLQueryItem(name: "clientSurface", value: "desktop"),
            URLQueryItem(name: "clientAppVersion", value: identity.appVersion),
            URLQueryItem(name: "clientDeviceType", value: "desktop"),
            URLQueryItem(name: "clientOs", value: "macOS"),
            URLQueryItem(name: "connectionMethod", value: "relay"),
            URLQueryItem(name: "orchestrationProtocol", value: String(T3Protocol.orchestrationProtocolVersion)),
            // Large frames arrive in parts on 4928 servers; older ones ignore it (rpc/session.ts:250).
            URLQueryItem(name: "frameParts", value: "1"),
        ]
        guard let url = c.url else { throw DPoPError.invalidURL(wsBaseUrl) }
        return url
    }

    /// A connector for `ConnectionSupervisor`: authorize, open the socket, start RPC. Failures come
    /// out as `ConnectionFailure` with T3's text. Pass `.ping(interval: .seconds(80))` as the
    /// supervisor's keepalive on this route (tunnels drop idle sockets).
    public nonisolated func connector(environmentId: String, directEndpoint: DirectRoute? = nil)
        -> @Sendable () async throws -> RPCConnection {
        return { [self] in
            do {
                let socket = try await authorizeSocket(environmentId: environmentId, directEndpoint: directEndpoint)
                let connection = RPCConnection(socket: try await URLSessionRPCSocket.open(url: socket.url),
                                               serverVersion: socket.token.serverVersion, serverCapabilities: socket.token.serverCapabilities)
                await connection.start()
                keepSessionAlive(connection, environmentId: environmentId, expiresAt: socket.token.expiresAt)
                return connection
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LocatedConnectionFailure(T3Connect.failure(for: error), T3Connect.locate(error))
            }
        }
    }

    /// The environment closes a socket when its one-hour session expires, unless the same DPoP key renewed it: a
    /// 4928 server then moves the socket to the newer session (SessionStore.awaitInvalidation, #27998). So T3 renews a
    /// live socket's token in its last minute, retrying a relay blip every 5 s until expiry (connection/driver.ts:250-266,
    /// authorization/service.ts:784-812). Older servers still close the socket at expiry and the supervisor reconnects.
    /// One sleep per connection, about an hour long. It ends with the socket.
    nonisolated func keepSessionAlive(_ connection: RPCConnection, environmentId: String, expiresAt: Date,
                                      sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        let renewal = Task { [self] in
            var expires = expiresAt
            while !Task.isCancelled {
                let now = await self.currentDate()
                guard now < expires else { return }
                do { try await sleep(max(5, expires.timeIntervalSince(now) - T3ConnectToken.refreshSkew)) } catch { return }
                guard !Task.isCancelled, await !connection.isClosed else { return }
                do {
                    let renewed = try await token(environmentId: environmentId)
                    expires = max(expires, renewed.expiresAt)
                } catch is CancellationError {
                    return
                } catch let failure as ConnectionFailure {
                    // A blocked credential ends the loop; a transient one retries after the 5 s floor.
                    if case .blocked = failure { return }
                } catch CloudSessionError.signedOut {
                    return
                } catch {
                    continue
                }
            }
        }
        Task {
            _ = await connection.waitUntilClosed()
            renewal.cancel()
        }
    }

    private func currentDate() -> Date { now() }

    // MARK: Environment HTTP

    private func descriptor(httpBaseUrl: String) async throws -> EnvironmentDescriptor {
        let descriptor = try await perform(makeRequest("GET", try endpointURL(httpBaseUrl, "/.well-known/t3/environment"),
                                                       timeout: Self.requestTimeout), as: EnvironmentDescriptor.self)
        guard descriptor.isCompatible else {
            throw ConnectionFailure.blocked(.unsupported, "The environment speaks orchestration protocol \(descriptor.protocolVersion).")
        }
        return descriptor
    }

    /// `environmentEndpointUrl`: the base URL with its path replaced (environment/endpoint.ts:3-9).
    private func endpointURL(_ httpBaseUrl: String, _ path: String) throws -> URL {
        guard var c = URLComponents(string: httpBaseUrl), c.host != nil else { throw DPoPError.invalidURL(httpBaseUrl) }
        c.path = path
        c.query = nil
        c.fragment = nil
        guard let url = c.url else { throw DPoPError.invalidURL(httpBaseUrl) }
        return url
    }

    private func makeRequest(_ method: String, _ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let e as URLError where e.code == .timedOut {
            throw EnvironmentHTTPError.timedOut
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EnvironmentHTTPError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw EnvironmentHTTPError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            throw EnvironmentHTTPError.status(http.statusCode, try? JSONDecoder().decode(EnvironmentHTTPErrorBody.self, from: data))
        }
        do {
            return try JSONValue(parsing: data).decode(as: T.self)
        } catch {
            throw EnvironmentHTTPError.invalidResponse("\(T.self)")
        }
    }

    static func isEnvironmentAuthInvalid(_ error: Error) -> Bool {
        if case EnvironmentHTTPError.status(401, _) = error { return true }
        return false
    }
}

/// Waits for a task that several callers share. Cancelling this caller throws `CancellationError` at
/// once and leaves `task` running for the others; awaiting `task.value` would ignore the cancel
/// (service.ts:466-469). With `timeout`, throws `timeoutError` once it passes; the owner cancels `task`.
func joinShared<T: Sendable>(_ task: Task<T, Error>, timeout: Duration? = nil,
                             timeoutError: Error = CancellationError()) async throws -> T {
    let waiter = SharedWaiter<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { c in
            waiter.install(c)
            Task { waiter.finish(await task.result) }
            if let timeout {
                waiter.setTimer(Task {
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    waiter.finish(.failure(timeoutError))
                })
            }
        }
    } onCancel: {
        waiter.finish(.failure(CancellationError()))
    }
}

/// The first of the task's result, the caller's cancel or the timeout resumes the continuation.
private final class SharedWaiter<T: Sendable>: @unchecked Sendable {
    // Guards the fields below.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var timer: Task<Void, Never>?

    func install(_ c: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = lock.withLock {
            if result == nil { continuation = c }
            return result
        }
        if let early { c.resume(with: early) }
    }

    func setTimer(_ t: Task<Void, Never>) {
        let finished: Bool = lock.withLock {
            if result == nil { timer = t }
            return result != nil
        }
        if finished { t.cancel() }
    }

    func finish(_ r: Result<T, Error>) {
        let (c, t): (CheckedContinuation<T, Error>?, Task<Void, Never>?) = lock.withLock {
            guard result == nil else { return (nil, nil) }
            result = r
            defer { continuation = nil; timer = nil }
            return (continuation, timer)
        }
        t?.cancel()
        c?.resume(with: r)
    }
}

public enum T3ConnectError: Error, Sendable, Equatable {
    case environmentMismatch(expected: String, actual: String)
    /// The host has not approved this device yet. The supervisor checks back every few seconds.
    case approvalPending(host: String, verificationCode: String, traceId: String?)
}

public enum T3Connect {
    /// Where a failure on the T3 Connect route happened (connection/errors.ts:37-192, 280-299).
    public static func locate(_ error: Error) -> ConnectionFailureInfo {
        let failure = failure(for: error)
        var blocked = false
        if case .blocked = failure { blocked = true }
        func info(_ reason: String, _ hop: ConnectionFailureInfo.Hop?, cause: String? = nil) -> ConnectionFailureInfo {
            ConnectionFailureInfo(reason: reason, blocked: blocked, detail: failure.detail, hop: hop, via: .relay, cause: cause)
        }
        switch error {
        case let e as LocatedConnectionFailure: return e.info
        case let e as RelayError: return e.located
        case is CloudSessionError: return info("authentication", .relay)
        case T3ConnectError.approvalPending(_, _, let traceId):
            var located = info(ConnectionFailureInfo.approvalPendingReason, .server, cause: "approval_pending")
            located.traceId = traceId
            return located
        case is DPoPError:
            if case .blocked(let reason, _) = failure { return info(reason.rawValue, .device) }
            return info("configuration", .device)
        case let e as EnvironmentHTTPError:
            // mapRemoteDpopEnvironmentError: a refused DPoP credential can name a clock that is off.
            if case .status(401, let body) = e, body?.reason == "invalid_credential" {
                var located = info("authentication", .server, cause: body?.dpopFailureReason == "time_window" ? "clock_skew" : nil)
                located.traceId = body?.traceId
                return located
            }
            var located = ConnectionFailure.locate(e, via: .relay)
            located.detail = failure.detail
            return located
        default:
            var located = ConnectionFailure.locate(error, via: .relay)
            located.via = .relay
            return located
        }
    }

    /// Maps any error from the sequence to T3's connection error (connection/errors.ts:37-192).
    public static func failure(for error: Error) -> ConnectionFailure {
        switch error {
        case let f as ConnectionFailure: return f
        case let e as RelayError: return e.failure
        case let e as CloudSessionError: return .blocked(.authentication, e.description)
        case let e as DPoPError:
            return .blocked(e == .invalidKey ? .authentication : .configuration, "Could not create the environment authorization proof.")
        case T3ConnectError.environmentMismatch(let expected, let actual):
            return .blocked(.configuration, "Connected environment \(actual) does not match \(expected).")
        case T3ConnectError.approvalPending(let host, let code, _):
            return .transient("Approve this device on \(host). It shows code \(code).")
        case let e as EnvironmentHTTPError:
            switch e {
            // mapRemoteDpopEnvironmentError: a refused DPoP credential carries the clock or retry hint.
            case .status(401, let body) where body?.reason == "invalid_credential":
                return .blocked(.authentication, DPoPHint.message("The environment credential is invalid.", reason: body?.dpopFailureReason))
            case .network(let m): return .transient("\(m) \(t3ConnectNetworkHint)")
            case .timedOut: return .transient("\(e.description) \(t3ConnectNetworkHint)")
            default: return ConnectionFailure.classify(e)
            }
        default: return ConnectionFailure.classify(error)
        }
    }
}
