import Foundation
import T3Protocol

/// Sends one HTTP request. Tests pass a fake; the default is the cookie-free ephemeral session.
public typealias HTTPSend = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum ConnectHTTP {
    static let urlSession: HTTPSend = { try await EnvironmentHTTP.defaultSession.data(for: $0) }

    /// `application/x-www-form-urlencoded` as URLSearchParams writes it: alphanumerics and `*-._`
    /// stay, space becomes `+`, everything else is percent-encoded.
    static func formBody(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._ ")
        func escape(_ s: String) -> String {
            (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: " ", with: "+")
        }
        return Data(fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }

    /// One path segment, escaped like `encodeURIComponent`.
    static func pathSegment(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// The T3 Connect relay's client API (protocol.md 10.3, client-runtime/src/relay/managedRelay.ts).
/// Holds the relay DPoP access tokens in memory, keyed like T3 by account, client, relay and key
/// thumbprint, and reuses one for any request whose scopes it covers until 5 s before expiry
/// (managedRelay.ts:364-383). Tokens never reach logs or error text.
public actor RelayClient {
    public static let productionURL = URL(string: "https://relay.t3.codes")!
    /// Web and desktop clients use `t3-web` (apps/web/src/cloud/managedRelayLayer.ts:80).
    public static let clientId = "t3-web"
    /// MANAGED_RELAY_REQUEST_TIMEOUT_MS (managedRelay.ts:225).
    public static let requestTimeout: TimeInterval = 10
    static let cacheSlack: TimeInterval = 5

    /// The relay origin with no trailing slash; also the token exchange `resource`.
    public nonisolated let origin: String
    public nonisolated let key: any DPoPSigningKey
    private let send: HTTPSend
    private let now: @Sendable () -> Date

    struct CachedToken: Sendable {
        var accountId: String
        var scopes: Set<String>
        var accessToken: String
        var expiresAt: Date
    }
    private var tokens: [CachedToken] = []
    private var pending: [String: Task<CachedToken, Error>] = [:]

    /// `relayURL` must be an https origin with no path, query or credentials
    /// (packages/shared/src/relayUrl.ts:1-18).
    public init(relayURL: URL = RelayClient.productionURL, key: any DPoPSigningKey,
                send: HTTPSend? = nil, now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let c = URLComponents(url: relayURL, resolvingAgainstBaseURL: false), c.scheme == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.query == nil,
              c.fragment == nil, c.path.allSatisfy({ $0 == "/" })
        else { throw RelayError(.invalidResponse("Relay URL must be a secure absolute HTTPS origin."), action: .connect) }
        origin = "https://\(host.lowercased())" + (c.port.map { $0 == 443 ? "" : ":\($0)" } ?? "")
        self.key = key
        self.send = send ?? ConnectHTTP.urlSession
        self.now = now
    }

    // MARK: Bearer routes (Clerk JWT or Clerk OAuth token, see CloudTokenProvider)

    /// `GET /v1/environments`.
    public func listEnvironments(bearer: String) async throws -> [RelayEnvironmentRecord] {
        var request = makeRequest("GET", "/v1/environments")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return try await perform(request, .listEnvironments, as: RelayListEnvironmentsResponse.self).environments
    }

    /// `DELETE /v1/client/environment-links/:id`, the account page's "Deregister". It works while
    /// the host is offline (client-runtime/src/relay/managedRelayState.ts:191-209).
    public func deregister(environmentId: String, bearer: String) async throws {
        var request = makeRequest("DELETE", "/v1/client/environment-links/\(ConnectHTTP.pathSegment(environmentId))")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        _ = try await perform(request, .unlink, as: RelayOkResponse.self)
    }

    // MARK: DPoP routes (relay access token from the t3-relay JWT)

    /// `POST /v1/environments/:id/status` with scopes `environment:status environment:connect`
    /// (relay/discovery.ts:152-162).
    public func environmentStatus(environmentId: String, relayJWT: String) async throws -> RelayEnvironmentStatus {
        try await dpopRequest(path: "/v1/environments/\(ConnectHTTP.pathSegment(environmentId))/status",
                              body: nil, scopes: [RelayScope.status, RelayScope.connect],
                              relayJWT: relayJWT, action: .status, as: RelayEnvironmentStatus.self)
    }

    /// `POST /v1/environments/:id/connect` with scope `environment:connect`
    /// (authorization/service.ts:248-276). The returned credential is bound to `key`.
    public func connect(environmentId: String, deviceId: String? = nil, relayJWT: String) async throws -> RelayConnectResponse {
        let body = try JSONEncoder().encode(RelayConnectRequest(deviceId: deviceId, clientKeyThumbprint: key.thumbprint))
        return try await dpopRequest(path: "/v1/environments/\(ConnectHTTP.pathSegment(environmentId))/connect",
                                     body: body, scopes: [RelayScope.connect],
                                     relayJWT: relayJWT, action: .connect, as: RelayConnectResponse.self)
    }

    /// Forgets every relay access token (sign-out, account switch).
    public func resetTokenCache() {
        tokens = []
        pending = [:]
    }

    /// Runs a DPoP request with a cached or fresh relay token. A refused cached token is dropped
    /// and the request tried once more with a new exchange (managedRelay.ts:655-692).
    private func dpopRequest<T: Decodable>(path: String, body: Data?, scopes: [String], relayJWT: String,
                                           action: RelayError.Action, as: T.Type) async throws -> T {
        var retried = false
        while true {
            let token = try await accessToken(relayJWT: relayJWT, scopes: scopes)
            var request = makeRequest("POST", path)
            request.setValue("DPoP \(token.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(try DPoP.proof(method: "POST", url: request.url!, accessToken: token.accessToken,
                                            key: key, now: now()), forHTTPHeaderField: "DPoP")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            do {
                return try await perform(request, action, as: T.self)
            } catch let error as RelayError where error.isRejectedAccessToken && !retried {
                tokens.removeAll { $0.accessToken == token.accessToken }
                retried = true
            }
        }
    }

    func accessToken(relayJWT: String, scopes: [String]) async throws -> CachedToken {
        let wanted = Set(scopes)
        let account = jwtSubject(relayJWT)
        tokens.removeAll { $0.expiresAt.timeIntervalSince(now()) <= Self.cacheSlack }
        guard let account else {
            // No `sub`: T3 bypasses the cache (managedRelay.ts:527-546).
            return try await exchange(relayJWT: relayJWT, scopes: scopes, accountId: "")
        }
        if let hit = tokens.first(where: { $0.accountId == account && wanted.isSubset(of: $0.scopes) }) { return hit }
        let pendingKey = account + " " + scopes.sorted().joined(separator: " ")
        // joinShared, so a cancelled caller (the authorizer's deadline) stops waiting at once.
        if let task = pending[pendingKey] { return try await joinShared(task) }
        let task = Task { try await self.exchange(relayJWT: relayJWT, scopes: scopes, accountId: account) }
        pending[pendingKey] = task
        defer { if pending[pendingKey] == task { pending[pendingKey] = nil } }
        let token = try await joinShared(task)
        tokens.append(token)
        return token
    }

    /// `POST /v1/client/dpop-token`: Clerk `t3-relay` JWT to a 30-minute DPoP relay token
    /// (managedRelay.ts:484-523). The proof carries no `ath`.
    private func exchange(relayJWT: String, scopes: [String], accountId: String) async throws -> CachedToken {
        var request = makeRequest("POST", "/v1/client/dpop-token")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(try DPoP.proof(method: "POST", url: request.url!, key: key, now: now()), forHTTPHeaderField: "DPoP")
        request.httpBody = ConnectHTTP.formBody([
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", relayJWT),
            ("subject_token_type", "urn:ietf:params:oauth:token-type:jwt"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
            ("resource", origin),
            ("scope", scopes.joined(separator: " ")),
            ("client_id", Self.clientId),
        ])
        let issuedAt = now()
        let response = try await perform(request, .exchangeToken, as: RelayAccessTokenResponse.self)
        let granted = response.scope.split(separator: " ").map(String.init)
        guard Set(granted) == Set(scopes), granted.count == Set(granted).count else {
            throw RelayError(.scopesUnexpected(granted: response.scope), action: .exchangeToken)
        }
        return CachedToken(accountId: accountId, scopes: Set(scopes), accessToken: response.accessToken,
                           expiresAt: issuedAt.addingTimeInterval(TimeInterval(response.expiresIn)))
    }

    private func makeRequest(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: origin + path)!, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest, _ action: RelayError.Action, as: T.Type) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let e as URLError where e.code == .timedOut {
            throw RelayError(.timedOut, action: action)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RelayError(.transport(error.localizedDescription), action: action)
        }
        guard let http = response as? HTTPURLResponse else { throw RelayError(.invalidResponse("not HTTP"), action: action) }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(RelayErrorBody.self, from: data)
            throw RelayError(.relay(status: http.statusCode,
                                    body: body.flatMap { RelayErrorBody.protectedTags.contains($0.tag) ? $0 : nil }),
                             action: action)
        }
        do {
            return try JSONValue(parsing: data).decode(as: T.self)
        } catch {
            throw RelayError(.invalidResponse("\(T.self)"), action: action)
        }
    }
}
