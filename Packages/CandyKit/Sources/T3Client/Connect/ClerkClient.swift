import Foundation

/// The signed-in T3 Connect account.
public struct ClerkAccount: Sendable, Equatable {
    public var sessionId: String
    /// The Clerk user id, the relay JWT `sub`.
    public var userId: String?
    /// The email the user signed in with.
    public var identifier: String?
}

/// A code Clerk emailed. Pass it back to `verifyCode(_:for:)` or `resendCode(_:)`.
public struct ClerkCodeChallenge: Sendable, Equatable {
    public enum Factor: Sendable, Equatable {
        /// Email code sign-in (`attempt_first_factor`).
        case first
        /// Client trust or second factor after a password (`attempt_second_factor`).
        case second
    }
    public var signInId: String
    public var factor: Factor
    /// `email_address_id` from the sign-in's factor list, sent back to `prepare_*_factor`.
    public var emailAddressId: String?
    /// Clerk's masked address, for "We sent a code to ...".
    public var sentTo: String?
}

public enum ClerkSignInStep: Sendable, Equatable {
    case complete(ClerkAccount)
    case needsCode(ClerkCodeChallenge)
}

/// A native Clerk Frontend API client for T3 Connect, signing in the way Clerk's Swift SDK does
/// (docs/research/M-clerk-native.md section 2). Native mode: every URL carries `_is_native=true`, the
/// client token travels raw in `Authorization`, and no cookie is read or sent. The client token and
/// session id live in the Keychain (`ClerkSessionStorage`); session JWTs stay in memory.
///
/// Email code: `POST /v1/client/sign_ins {identifier, locale}`, then
/// `POST .../{id}/prepare_first_factor {email_address_id, strategy=email_code}`, then
/// `POST .../{id}/attempt_first_factor {code, strategy=email_code}`.
/// Password: `POST /v1/client/sign_ins {identifier, locale, password}` (clerk-ios `Auth.signInWithPassword`);
/// a `needs_client_trust` or `needs_second_factor` answer continues with an emailed code through
/// `prepare_second_factor` and `attempt_second_factor` (`SignIn.sendMfaEmailCode`, `verifyMfaCode`).
public actor ClerkClient: CloudTokenProvider {
    /// T3's production Frontend API, from `pk_live_Y2xlcmsudDMuY29kZXMk` (C-auth-connect.md 0.4).
    public static let productionURL = URL(string: "https://clerk.t3.codes")!
    /// T3's relay template (C-auth-connect.md 0.4, docs/operations/connect-setup.md:50-61).
    public static let relayTemplate = "t3-relay"
    /// clerk-ios `Utils/Version.swift:8-9`, sent as `x-ios-sdk-version` and `clerk-api-version`
    /// (`Dependencies/DependencyContainer.swift:102-108`).
    public static let sdkVersion = "1.6.1"
    public static let apiVersion = "2026-08-20"
    /// Reuse a minted JWT until this many seconds before its `exp`, Clerk's default
    /// `GetTokenOptions.expirationBuffer` (clerk-ios `Session.swift`).
    static let jwtMargin: TimeInterval = 10
    /// clerk-ios retries 408, 425 and 429 once when `Retry-After` is at most 5 s
    /// (`ClerkRateLimitRetryMiddleware.swift`).
    static let maxRetryWait: Double = 5
    static let requestTimeout: TimeInterval = 15

    public nonisolated let baseURL: URL
    public nonisolated let template: String
    private let store: any ClerkSessionStorage
    private let device: ClerkDeviceInfo
    private let locale: String
    private let send: HTTPSend
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Double) async -> Void

    private var stored: ClerkStoredSession?
    private var loaded = false
    private var cachedEnvironment: ClerkEnvironment?
    private var cachedJWT: (sessionId: String, jwt: String, expiresAt: Date)?
    private var pendingMint: (sessionId: String, task: Task<String, Error>)?
    /// Bumped on sign-in and sign-out so an in-flight mint can't cache or clear a newer session.
    private var generation = 0

    public init(baseURL: URL = ClerkClient.productionURL, template: String = ClerkClient.relayTemplate,
                store: any ClerkSessionStorage = ClerkKeychainStore(), device: ClerkDeviceInfo = .current,
                locale: String = ClerkClient.userLocale(), send: HTTPSend? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.baseURL = baseURL
        self.template = template
        self.store = store
        self.device = device
        self.locale = locale
        self.send = send ?? ConnectHTTP.urlSession
        self.now = now
        self.sleep = sleep
    }

    /// clerk-ios `LocaleUtils.userLocale()`.
    public static func userLocale() -> String {
        if let first = Locale.preferredLanguages.first, !first.isEmpty { return first }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        if let region = Locale.current.region?.identifier, !region.isEmpty { return "\(language)-\(region)" }
        return language
    }

    // MARK: State

    /// The signed-in account, or nil.
    public func account() -> ClerkAccount? {
        guard let s = session(), let sid = s.sessionId else { return nil }
        return ClerkAccount(sessionId: sid, userId: s.userId, identifier: s.identifier)
    }

    /// `GET /v1/environment`, kept for this launch.
    // ponytail: fetched once per launch, refetch on each sign-in if T3 changes its Clerk settings live.
    public func environment() async throws -> ClerkEnvironment {
        if let cachedEnvironment { return cachedEnvironment }
        let env = try decode(ClerkEnvironment.self, try await call("GET", "/v1/environment"))
        cachedEnvironment = env
        return env
    }

    // MARK: Sign-in

    /// Creates a sign-in and emails a code. Then call `verifyCode(_:for:)`.
    public func startEmailCode(email: String) async throws -> ClerkCodeChallenge {
        try await beginSignIn(\.emailCodeEnabled)
        let signIn = try await createSignIn(["identifier": email.trimmingCharacters(in: .whitespacesAndNewlines),
                                             "locale": locale])
        guard let factor = signIn.emailFactor("email_code", in: signIn.supportedFirstFactors, fallbackToFirst: true) else {
            throw ClerkAuthError(.unavailable)
        }
        let challenge = ClerkCodeChallenge(signInId: signIn.id, factor: .first,
                                           emailAddressId: factor.emailAddressId, sentTo: factor.safeIdentifier)
        try await resendCode(challenge)
        return challenge
    }

    /// Sends the code again (`prepare_first_factor` or `prepare_second_factor`).
    public func resendCode(_ challenge: ClerkCodeChallenge) async throws {
        var fields = ["strategy": "email_code"]
        fields["email_address_id"] = challenge.emailAddressId
        let step = challenge.factor == .first ? "prepare_first_factor" : "prepare_second_factor"
        _ = try await signInCall(challenge.signInId, step, fields)
    }

    /// Checks the emailed code and finishes the sign-in.
    public func verifyCode(_ code: String, for challenge: ClerkCodeChallenge) async throws -> ClerkAccount {
        let step = challenge.factor == .first ? "attempt_first_factor" : "attempt_second_factor"
        let fields = ["code": code.trimmingCharacters(in: .whitespacesAndNewlines), "strategy": "email_code"]
        let (signIn, client) = try await signInCall(challenge.signInId, step, fields)
        guard case .complete(let account) = try await advance(signIn, client) else {
            throw ClerkAuthError(.unavailable, message: "This account needs a sign-in step CandyWrapper does not support yet.")
        }
        return account
    }

    /// Signs in with email and password. Clerk may still ask for an emailed code on a new device.
    public func signIn(email: String, password: String) async throws -> ClerkSignInStep {
        try await beginSignIn(\.passwordEnabled)
        let identifier = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let (signIn, client) = try await createSignInWithClient(["identifier": identifier, "locale": locale, "password": password])
        if signIn.status == "needs_first_factor" {
            let (next, nextClient) = try await signInCall(signIn.id, "attempt_first_factor",
                                                          ["password": password, "strategy": "password"])
            return try await advance(next, nextClient)
        }
        return try await advance(signIn, client)
    }

    /// Removes the session on Clerk (`POST /v1/client/sessions/{id}/remove`, clerk-ios `Auth.signOut`)
    /// and deletes the Keychain item. Local state is cleared even when Clerk can't be reached.
    public func signOut() async {
        generation += 1
        let sessionId = session()?.sessionId
        if let sessionId {
            _ = try? await call("POST", "/v1/client/sessions/\(ConnectHTTP.pathSegment(sessionId))/remove")
        }
        clearLocal()
    }

    // MARK: CloudTokenProvider

    /// A `t3-relay` JWT, minted with `POST /v1/client/sessions/{id}/tokens/t3-relay` and reused only
    /// until 10 s before its `exp`. Never stored. T3's clients mint per call (`skipCache: true`,
    /// packages/shared/src/relayAuth.ts:84-89); RelayClient caches the relay token it buys for 30 min,
    /// so this cache only saves the duplicate mints inside one authorization.
    public func relaySessionJWT() async throws -> String {
        guard let sessionId = session()?.sessionId else { throw CloudSessionError.signedOut }
        if let c = cachedJWT, c.sessionId == sessionId, c.expiresAt.timeIntervalSince(now()) > Self.jwtMargin {
            return c.jwt
        }
        if let pending = pendingMint, pending.sessionId == sessionId { return try await pending.task.value }
        let started = generation
        let task = Task { try await self.mint(sessionId: sessionId, generation: started) }
        pendingMint = (sessionId, task)
        defer { if pendingMint?.sessionId == sessionId { pendingMint = nil } }
        return try await task.value
    }

    public func accountId() async throws -> String? {
        guard let s = session(), s.sessionId != nil else { return nil }
        if let userId = s.userId { return userId }
        return jwtSubject(try await relaySessionJWT())
    }

    private func mint(sessionId: String, generation started: Int) async throws -> String {
        let path = "/v1/client/sessions/\(ConnectHTTP.pathSegment(sessionId))/tokens/\(ConnectHTTP.pathSegment(template))"
        let data: Data
        do {
            data = try await call("POST", path)
        } catch let e as ClerkAuthError where e.kind == .signedOut || e.kind == .clerk(status: 404, code: "resource_not_found") {
            if generation == started { clearLocal() }
            throw CloudSessionError.signedOut
        }
        let token: ClerkTokenObject?
        do { token = try ClerkWire.decoder.decode(ClerkTokenObject?.self, from: data) } catch { throw ClerkAuthError(.invalidResponse) }
        guard let jwt = token?.jwt, !jwt.isEmpty else {
            if generation == started { clearLocal() }
            throw CloudSessionError.signedOut
        }
        if generation == started, let exp = jwtExpiry(jwt) {
            cachedJWT = (sessionId, jwt, exp)
        }
        return jwt
    }

    // MARK: Sign-in steps

    private func beginSignIn(_ strategy: KeyPath<ClerkEnvironment, Bool>) async throws {
        let env = try await environment()
        guard env.nativeAPIEnabled, env[keyPath: strategy] else { throw ClerkAuthError(.unavailable) }
        // single_session_mode: Clerk refuses a second sign-in on a client that has a session
        // (`session_exists`, 400). Drop ours first; a new client starts with the next request.
        if env.singleSessionMode, session()?.sessionId != nil { await signOut() }
    }

    private func createSignIn(_ fields: [String: String]) async throws -> ClerkSignInObject {
        try await createSignInWithClient(fields).0
    }

    /// `POST /v1/client/sign_ins`. If Clerk says this client is already signed in (`session_exists`,
    /// `identifier_already_signed_in`), end all its sessions (`DELETE /v1/client/sessions`, clerk-ios
    /// `Auth.signOut()` with no id) and try once more.
    private func createSignInWithClient(_ fields: [String: String]) async throws -> (ClerkSignInObject, ClerkClientObject?) {
        do {
            return try decodeSignIn(try await call("POST", "/v1/client/sign_ins", fields))
        } catch let e as ClerkAuthError where e.kind == .clerk(status: 400, code: "session_exists")
            || e.kind == .clerk(status: 400, code: "identifier_already_signed_in") {
            _ = try await call("DELETE", "/v1/client/sessions")
            dropSession()
            return try decodeSignIn(try await call("POST", "/v1/client/sign_ins", fields))
        }
    }

    private func signInCall(_ id: String, _ step: String, _ fields: [String: String]) async throws -> (ClerkSignInObject, ClerkClientObject?) {
        try decodeSignIn(try await call("POST", "/v1/client/sign_ins/\(ConnectHTTP.pathSegment(id))/\(step)", fields))
    }

    private func advance(_ signIn: ClerkSignInObject, _ client: ClerkClientObject?) async throws -> ClerkSignInStep {
        switch signIn.status {
        case "complete":
            return .complete(try finish(signIn, client))
        case "needs_second_factor", "needs_client_trust":
            guard signIn.supportedSecondFactors?.contains(where: { $0.strategy == "email_code" }) == true else { break }
            let factor = signIn.emailFactor("email_code", in: signIn.supportedSecondFactors, fallbackToFirst: false)
            let challenge = ClerkCodeChallenge(signInId: signIn.id, factor: .second, emailAddressId: factor?.emailAddressId,
                                               sentTo: factor?.safeIdentifier ?? signIn.supportedSecondFactors?
                                                .first { $0.strategy == "email_code" }?.safeIdentifier)
            try await resendCode(challenge)
            return .needsCode(challenge)
        default:
            break
        }
        throw ClerkAuthError(.unavailable, message: "This account needs a sign-in step CandyWrapper does not support yet.")
    }

    private func finish(_ signIn: ClerkSignInObject, _ client: ClerkClientObject?) throws -> ClerkAccount {
        guard let sessionId = signIn.createdSessionId, var s = session() else { throw ClerkAuthError(.invalidResponse) }
        let clerkSession = client?.sessions.first { $0.id == sessionId }
        s.sessionId = sessionId
        s.userId = clerkSession?.userId
        s.identifier = clerkSession?.publicUserData?.identifier ?? signIn.identifier
        generation += 1
        cachedJWT = nil
        try persist(s)
        return ClerkAccount(sessionId: sessionId, userId: s.userId, identifier: s.identifier)
    }

    // MARK: HTTP

    /// One Frontend API request with the SDK's query item and headers. Applies the response
    /// `Authorization` header to the stored client token, retries once on 408, 425 and 429 like
    /// clerk-ios, and maps errors. Returns the body of a 2xx.
    @discardableResult
    private func call(_ method: String, _ path: String, _ fields: [String: String]? = nil) async throws -> Data {
        var attempt = 1
        while true {
            let request = makeRequest(method, path, fields)
            let data: Data, response: URLResponse
            do {
                (data, response) = try await send(request)
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ClerkAuthError(.network)
            }
            guard let http = response as? HTTPURLResponse else { throw ClerkAuthError(.invalidResponse) }
            try applyDeviceToken(http, body: data)
            if (200..<300).contains(http.statusCode) { return data }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            if attempt == 1, [408, 425, 429].contains(http.statusCode) {
                let wait = retryAfter.flatMap(ClerkAuthError.retrySeconds).map(Double.init) ?? 0.5
                if wait <= Self.maxRetryWait {
                    attempt += 1
                    await sleep(min(max(wait, 0.1), Self.maxRetryWait))
                    continue
                }
            }
            throw ClerkAuthError.from(status: http.statusCode, body: data, retryAfter: retryAfter)
        }
    }

    private func makeRequest(_ method: String, _ path: String, _ fields: [String: String]?) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = [URLQueryItem(name: "_is_native", value: "true")]
        var request = URLRequest(url: components.url!, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "clerk-api-version")
        request.setValue(Self.sdkVersion, forHTTPHeaderField: "x-ios-sdk-version")
        request.setValue("0", forHTTPHeaderField: "x-mobile")
        let s = session()
        if let token = s?.clientToken { request.setValue(token, forHTTPHeaderField: "Authorization") }
        if let clientId = s?.clientId { request.setValue(clientId, forHTTPHeaderField: "x-clerk-client-id") }
        request.setValue(device.deviceType, forHTTPHeaderField: "x-device-type")
        request.setValue(device.deviceModel, forHTTPHeaderField: "x-device-model")
        request.setValue(device.osVersion, forHTTPHeaderField: "x-os-version")
        request.setValue(device.appVersion, forHTTPHeaderField: "x-app-version")
        request.setValue(device.bundleId, forHTTPHeaderField: "x-bundle-id")
        request.setValue(device.isSandbox, forHTTPHeaderField: "x-is-sandbox")
        if let fields { request.httpBody = ClerkWire.formBody(fields) }
        return request
    }

    /// clerk-ios `ClerkDeviceTokenResponseUpdate`: a value sets the token, an empty or bare `Bearer`
    /// value clears it, no header keeps it. Also records the client id from the body.
    private func applyDeviceToken(_ response: HTTPURLResponse, body: Data) throws {
        let clientId = (try? ClerkWire.decoder.decode(ClientIdProbe.self, from: body))?.client?.id
        if let header = response.value(forHTTPHeaderField: "Authorization") {
            let token = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty || token.caseInsensitiveCompare("Bearer") == .orderedSame {
                clearLocal()
                return
            }
            var s = session() ?? ClerkStoredSession(clientToken: token)
            s.clientToken = token
            if let clientId { s.clientId = clientId }
            if s != stored { try persist(s) }
        } else if let clientId, var s = session(), s.clientId != clientId {
            s.clientId = clientId
            try persist(s)
        }
    }

    private struct ClientIdProbe: Decodable {
        struct Client: Decodable { var id: String }
        var client: Client?
    }

    private func decodeSignIn(_ data: Data) throws -> (ClerkSignInObject, ClerkClientObject?) {
        let wrapped = try decode(ClerkClientResponse<ClerkSignInObject>.self, data)
        return (wrapped.response, wrapped.client)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try ClerkWire.decoder.decode(T.self, from: data) } catch { throw ClerkAuthError(.invalidResponse) }
    }

    // MARK: Storage

    private func session() -> ClerkStoredSession? {
        if !loaded {
            loaded = true
            // A locked or unreadable Keychain reads as signed out; nothing is deleted.
            stored = try? store.load()
        }
        return stored
    }

    private func persist(_ s: ClerkStoredSession) throws {
        stored = s
        loaded = true
        do { try store.save(s) } catch { throw ClerkAuthError(.keychain) }
    }

    /// Forgets the session but keeps the client token, after Clerk ended every session on this client.
    private func dropSession() {
        guard var s = session() else { return }
        s.sessionId = nil
        s.userId = nil
        s.identifier = nil
        generation += 1
        cachedJWT = nil
        try? persist(s)
    }

    private func clearLocal() {
        generation += 1
        stored = nil
        loaded = true
        cachedJWT = nil
        pendingMint = nil
        try? store.delete()
    }
}

/// The unverified `exp` of a JWT, only to decide how long to reuse it.
func jwtExpiry(_ token: String) -> Date? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let data = Base64URL.decode(String(parts[1])),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = object["exp"] as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: exp.doubleValue)
}
