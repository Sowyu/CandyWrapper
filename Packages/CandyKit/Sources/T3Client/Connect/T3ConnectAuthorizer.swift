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
/// Keeps one environment token per environment in memory, renews it 60 s before expiry and shares
/// one pending renewal between callers.
public actor T3ConnectAuthorizer {
    /// Ticket timeout for a cached token; past it the token is replaced (service.ts:88, 503-520).
    public static let cachedSocketTimeout: TimeInterval = 3
    /// Environment request timeout (authorization/remote.ts:25).
    public static let requestTimeout: TimeInterval = 10

    public nonisolated let relay: RelayClient
    private let tokens: any CloudTokenProvider
    private let identity: ClientIdentity
    private let deviceId: String?
    private let send: HTTPSend
    private let now: @Sendable () -> Date
    private var cache: [String: T3ConnectToken] = [:]
    private var pending: [String: Pending] = [:]
    /// Bumped by `reset()`, so an exchange started before a sign-out can't publish or hand out its token.
    private var generation = 0

    /// One shared exchange, bound to the account and sign-in it started under (service.ts:413-415).
    private struct Pending {
        let id: UUID
        let account: String
        let generation: Int
        let task: Task<T3ConnectToken, Error>
    }

    /// `identity.connectionMethod` is ignored: T3 Connect sockets always say `relay`, even on a
    /// learned direct route (service.ts:217-245).
    public init(relay: RelayClient, tokens: any CloudTokenProvider, identity: ClientIdentity, deviceId: String? = nil,
                send: HTTPSend? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.relay = relay
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
        let account = try await tokens.accountId()
        guard let account else { throw CloudSessionError.signedOut }
        if let cached = cache[environmentId] {
            if cached.accountId == account, cached.thumbprint == relay.key.thumbprint,
               !cached.needsRenewal(at: now()), cached.accessToken != rejected {
                return (cached, true)
            }
            if cached.accountId != account { cache = [:] } else if cached.accessToken == rejected { cache[environmentId] = nil }
        }
        // The relay key never changes for this authorizer, so the account and generation are the whole identity.
        let shared: Pending
        if let p = pending[environmentId], p.account == account, p.generation == generation {
            shared = p
        } else {
            let id = UUID(), started = generation
            shared = Pending(id: id, account: account, generation: started, task: Task {
                try await self.sharedExchange(environmentId: environmentId, account: account, generation: started, id: id)
            })
            pending[environmentId] = shared
        }
        let fresh = try await shared.task.value
        // The user may have switched accounts while this waited (service.ts:409-421).
        guard generation == shared.generation, try await tokens.accountId() == account, generation == shared.generation else {
            throw CloudSessionError.accountChanged
        }
        return (fresh, false)
    }

    /// The exchange every caller for one environment and account shares. It checks the account itself
    /// before caching, so the cache never takes another account's token (service.ts:424-445).
    private func sharedExchange(environmentId: String, account: String, generation started: Int, id: UUID) async throws -> T3ConnectToken {
        defer { if pending[environmentId]?.id == id { pending[environmentId] = nil } }
        let fresh = try await exchange(environmentId: environmentId, account: account)
        guard generation == started, try await tokens.accountId() == account, generation == started else {
            throw CloudSessionError.accountChanged
        }
        cache[environmentId] = fresh
        return fresh
    }

    /// Steps 3 to 6 of protocol.md 10.4.
    // ponytail: no 30 s cap on the whole exchange (service.ts:89), only 10 s per request and the
    // supervisor's 15 s; add a task-group race if a caller outside the supervisor needs it.
    // ponytail: tokens live in memory only, so a relaunch runs the relay connect again; persist to
    // the Keychain if launch latency on T3 Connect matters.
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
        let access = try await perform(request, as: AccessTokenResult.self)
        return T3ConnectToken(environmentId: descriptor.environmentId, label: descriptor.label, endpoint: bootstrap.endpoint,
                              accessToken: access.accessToken,
                              expiresAt: issuedAt.addingTimeInterval(TimeInterval(access.expiresIn)),
                              accountId: account, thumbprint: relay.key.thumbprint)
    }

    /// Drops the token for one environment (removed, or signed out of it).
    public func forget(environmentId: String) { cache[environmentId] = nil }

    /// Drops everything, relay tokens included (sign-out, account switch).
    public func reset() async {
        generation += 1
        cache = [:]
        pending = [:]
        await relay.resetTokenCache()
    }

    // MARK: Socket and HTTP

    /// A socket URL for the environment over its tunnel or `directEndpoint` (a learned route).
    /// A cached token gets 3 s to mint a ticket; if that fails on the tunnel, or the direct route
    /// refuses the token, a fresh token replaces it (service.ts:488-534).
    public func authorizeSocket(environmentId: String, directEndpoint: DirectRoute? = nil) async throws -> T3ConnectSocket {
        if let directEndpoint {
            // A saved LAN address can belong to another machine on another network (service.ts:142-181).
            let descriptor = try await descriptor(httpBaseUrl: directEndpoint.httpBaseUrl)
            guard descriptor.environmentId == environmentId else {
                throw T3ConnectError.environmentMismatch(expected: environmentId, actual: descriptor.environmentId)
            }
        }
        var (token, fromCache) = try await selectToken(environmentId: environmentId, rejected: nil)
        if fromCache {
            do {
                return try await socket(token, direct: directEndpoint, timeout: Self.cachedSocketTimeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DPoPError {
                throw error
            } catch {
                // An unreachable direct address says nothing about the token; keep it for the tunnel.
                if directEndpoint != nil, !Self.isEnvironmentAuthInvalid(error) { throw error }
                token = try await self.token(environmentId: environmentId, rejected: token.accessToken)
            }
        }
        do {
            return try await socket(token, direct: directEndpoint, timeout: Self.requestTimeout)
        } catch {
            // A direct address that refuses the socket says nothing about the token.
            if directEndpoint == nil || error is DPoPError, cache[environmentId]?.accessToken == token.accessToken {
                cache[environmentId] = nil
            }
            throw error
        }
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
                let connection = RPCConnection(socket: try await URLSessionRPCSocket.open(url: socket.url))
                await connection.start()
                return connection
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LocatedConnectionFailure(T3Connect.failure(for: error), T3Connect.locate(error))
            }
        }
    }

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

public enum T3ConnectError: Error, Sendable, Equatable {
    case environmentMismatch(expected: String, actual: String)
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
