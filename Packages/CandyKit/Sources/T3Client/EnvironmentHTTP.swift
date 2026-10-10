import Foundation
import T3Protocol

/// How this client names itself to the server (protocol.md 2.2). Attribution only.
public struct ClientIdentity: Sendable, Equatable {
    public var label: String
    public var appVersion: String
    /// `direct`, `ssh` or `relay`.
    public var connectionMethod: String

    public init(label: String = "CandyWrapper", appVersion: String, connectionMethod: String = "direct") {
        self.label = label
        // The server drops values over 64 characters.
        self.appVersion = String(appVersion.prefix(64))
        self.connectionMethod = connectionMethod
    }
}

public enum EnvironmentHTTPError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Non-2xx. `body` is the tagged error when the server sent one (an empty 400 has none).
    case status(Int, EnvironmentHTTPErrorBody?)
    case network(String)
    case timedOut
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .status(let code, let body): "HTTP \(code)" + (body.map { " \($0.tag) \($0.reason ?? $0.message ?? "")" } ?? "")
        case .network(let m): "Network error: \(m)"
        case .timedOut: "The environment did not respond."
        case .invalidResponse(let m): "Invalid response: \(m)"
        }
    }
}

/// Bearer HTTP calls to one environment (protocol.md 4 and 5). Tokens never appear in logs or URLs.
public struct EnvironmentHTTP: Sendable {
    public let baseURL: URL
    private let session: URLSession
    /// T3's auth request timeout (authorization/remote.ts:25).
    public var timeout: TimeInterval = 10
    /// Headers for an authenticated request, used instead of `Bearer <token>` when set. T3 Connect
    /// sets it to `Authorization: DPoP <token>` plus a proof for that method and URL. After a 401,
    /// `send` asks once more with `rejected` set to the refused token, then retries.
    public var authorize: (@Sendable (_ method: String, _ url: URL, _ rejected: String?) async throws -> [String: String])?

    /// Cookie-free ephemeral session. A cookie would beat the Authorization header (protocol.md 4.2).
    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    public init(baseURL: URL, session: URLSession = EnvironmentHTTP.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `GET /.well-known/t3/environment`, no auth.
    public func descriptor() async throws -> EnvironmentDescriptor {
        try await send("GET", ".well-known/t3/environment", token: nil, as: EnvironmentDescriptor.self)
    }

    /// `POST /oauth/token`: redeems a pairing code for a bearer token. Form encoded.
    public func exchangeToken(_ request: TokenExchangeRequest) async throws -> AccessTokenResult {
        try await send("POST", "oauth/token", token: nil, body: request.formBody,
                       contentType: "application/x-www-form-urlencoded", as: AccessTokenResult.self)
    }

    /// Pairs with a one-time code: checks the descriptor's protocol version first (protocol.md 1.2).
    public func pair(code: String, identity: ClientIdentity) async throws -> (EnvironmentDescriptor, AccessTokenResult) {
        let descriptor = try await descriptor()
        guard descriptor.isCompatible else {
            throw EnvironmentHTTPError.invalidResponse("orchestration protocol \(descriptor.protocolVersion) is not supported")
        }
        let token = try await exchangeToken(TokenExchangeRequest(subjectToken: code, clientLabel: identity.label))
        return (descriptor, token)
    }

    /// `GET /api/auth/session`. Never 401; unauthenticated callers get `authenticated: false`.
    public func session(token: String?) async throws -> AuthSessionState {
        try await send("GET", "api/auth/session", token: token, as: AuthSessionState.self)
    }

    /// `POST /api/auth/websocket-ticket`. Mint a fresh one for every connection attempt.
    public func webSocketTicket(token: String) async throws -> WebSocketTicket {
        try await send("POST", "api/auth/websocket-ticket", token: token, as: WebSocketTicket.self)
    }

    /// Authenticated GET of a typed route, for example `api/orchestration/shell`.
    public func get<T: Decodable>(_ path: String, token: String, as type: T.Type) async throws -> T {
        try await send("GET", path, token: token, as: T.self)
    }

    /// Authenticated JSON POST of a typed route. A nil body sends none.
    public func post<B: Encodable, T: Decodable>(_ path: String, _ body: B?, token: String, as type: T.Type) async throws -> T {
        let data = try body.map { try JSONEncoder().encode($0) }
        return try await send("POST", path, token: token, body: data, contentType: data == nil ? nil : "application/json", as: T.self)
    }

    // MARK: Host access (Settings > Connections)

    /// `GET /api/connect/link-state` (needs `relay:read`).
    public func cloudLinkState(token: String) async throws -> CloudLinkState {
        try await get("api/connect/link-state", token: token, as: CloudLinkState.self)
    }

    /// `POST /api/connect/preferences` (needs `relay:write`). The server applies it itself.
    public func setCloudPreferences(_ request: CloudPreferencesRequest, token: String) async throws -> CloudLinkState {
        try await post("api/connect/preferences", request, token: token, as: CloudLinkState.self)
    }

    /// `POST /api/auth/pairing-token`: a one-time pairing credential. Only this reply carries the secret.
    public func createPairingCredential(_ request: PairingCredentialRequest, token: String) async throws -> PairingCredentialResult {
        try await post("api/auth/pairing-token", request, token: token, as: PairingCredentialResult.self)
    }

    /// `POST /api/auth/pairing-links/revoke {id}`.
    public func revokePairingLink(id: String, token: String) async throws {
        _ = try await post("api/auth/pairing-links/revoke", ["id": id], token: token, as: JSONValue.self)
    }

    /// `POST /api/auth/clients/revoke {sessionId}`.
    public func revokeClient(sessionId: String, token: String) async throws {
        _ = try await post("api/auth/clients/revoke", ["sessionId": sessionId], token: token, as: JSONValue.self)
    }

    /// `POST /api/auth/clients/revoke-others`, the count of revoked sessions.
    public func revokeOtherClients(token: String) async throws -> Int {
        try await post("api/auth/clients/revoke-others", String?.none, token: token, as: RevokeOthersResult.self).revokedCount
    }

    /// GET of a signed asset URL from `assets.createUrl` (`/api/assets/<token>/<name>`, protocol.md 5).
    /// The signed path is the credential. Bodies over `maxBytes` are refused, like T3's `readBounded`.
    public func asset(_ relativeURL: String, token: String?, maxBytes: Int) async throws -> Data {
        guard let url = URL(string: relativeURL, relativeTo: baseURL)?.absoluteURL else {
            throw EnvironmentHTTPError.invalidResponse("asset URL \(relativeURL)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        if let token { try await setAuthorization(&request, token: token) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as URLError where e.code == .timedOut {
            throw EnvironmentHTTPError.timedOut
        } catch {
            throw EnvironmentHTTPError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw EnvironmentHTTPError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else { throw EnvironmentHTTPError.status(http.statusCode, nil) }
        guard data.count <= maxBytes else { throw EnvironmentHTTPError.invalidResponse("asset larger than \(maxBytes) bytes") }
        return data
    }

    /// `ws(s)://host/ws?wsTicket=...&client...&orchestrationProtocol=2`, in the official order
    /// (authorization/remote.ts:40-84, compatibility.ts:38-42).
    public func webSocketURL(ticket: String, identity: ClientIdentity) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = "/ws"
        c.queryItems = [
            URLQueryItem(name: "wsTicket", value: ticket),
            URLQueryItem(name: "clientSurface", value: "desktop"),
            URLQueryItem(name: "clientAppVersion", value: identity.appVersion),
            URLQueryItem(name: "clientDeviceType", value: "desktop"),
            URLQueryItem(name: "clientOs", value: "macOS"),
            URLQueryItem(name: "connectionMethod", value: identity.connectionMethod),
            URLQueryItem(name: "orchestrationProtocol", value: String(T3Protocol.orchestrationProtocolVersion)),
        ]
        // URLComponents leaves `+` alone in queries; the ticket is base64url so it has none.
        return c.url!
    }

    private func setAuthorization(_ request: inout URLRequest, token: String, rejected: String? = nil) async throws {
        guard let authorize, let url = request.url else {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return
        }
        for (name, value) in try await authorize(request.httpMethod ?? "GET", url, rejected) { request.setValue(value, forHTTPHeaderField: name) }
    }

    private func send<T: Decodable>(_ method: String, _ path: String, token: String?, body: Data? = nil,
                                    contentType: String? = nil, as: T.Type) async throws -> T {
        // `appending(path:)` would escape a query's `?`, so a path like `ThreadHistoryRequest.path` keeps its query apart.
        let parts = path.split(separator: "?", maxSplits: 1)
        var url = baseURL.appending(path: String(parts.first ?? ""))
        if parts.count == 2, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.percentEncodedQuery = String(parts[1])
            url = c.url ?? url
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        // Required on /api/orchestration/*, ignored elsewhere (protocol.md 1.2).
        request.setValue(String(T3Protocol.orchestrationProtocolVersion), forHTTPHeaderField: "x-t3-orchestration-protocol")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { try await setAuthorization(&request, token: token) }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        do {
            return try await perform(request, as: T.self)
        } catch EnvironmentHTTPError.status(401, _) where authorize != nil && token != nil {
            // The DPoP token was refused: once more with a fresh one (environmentHttpAuth.ts:148-207).
            let sent = request.value(forHTTPHeaderField: "Authorization")?.split(separator: " ").last.map(String.init)
            try await setAuthorization(&request, token: token!, rejected: sent)
            return try await perform(request, as: T.self)
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as URLError where e.code == .timedOut {
            throw EnvironmentHTTPError.timedOut
        } catch let e as URLError where e.code == .cancelled {
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
            throw EnvironmentHTTPError.invalidResponse("\(T.self): \(error)")
        }
    }
}
