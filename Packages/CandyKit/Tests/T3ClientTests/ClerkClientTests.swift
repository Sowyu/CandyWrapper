import Foundation
import Security
import Testing
@testable import T3Client

// ClerkClient tests. No network: every request goes to `FakeClerk`. Nothing here contacts
// clerk.t3.codes. Tokens, ids and addresses are fakes.
//
// Response shapes follow Clerk's Frontend API OpenAPI spec (github.com/clerk/openapi-specs,
// fapi/2026-05-12.yml): `Client.Environment`, `Client.ClientWrappedSignIn` (`{response, client}`),
// `Client.SignIn`, `Stubs.SignInFactor`, `Stubs.Verification.OTP`, `Client.Client`, `Client.Session`,
// `Client.PublicUserData`, and `createSessionTokenWithTemplate` (`{jwt}`). Error bodies are the
// examples in https://clerk.com/docs/guides/development/errors/frontend-api.

/// Plays Clerk's Frontend API. Records every request; responses can carry headers.
final class FakeClerk: @unchecked Sendable {
    struct Reply { var status: Int; var body: String; var headers: [String: String] }
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private var routes: [String: [Reply]] = [:]
    private var failures: Set<String> = []

    var requests: [URLRequest] { lock.withLock { log } }
    var calls: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }

    /// Queue replies for `METHOD path`; the last one repeats.
    func on(_ method: String, _ path: String, _ body: String, status: Int = 200, headers: [String: String] = [:]) {
        lock.withLock { routes["\(method) \(path)", default: []].append(Reply(status: status, body: body, headers: headers)) }
    }

    func failNetwork(_ method: String, _ path: String) { lock.withLock { _ = failures.insert("\(method) \(path)") } }

    var send: HTTPSend {
        { [self] request in
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            let reply: Reply? = try lock.withLock {
                log.append(request)
                if failures.contains(key) { throw URLError(.notConnectedToInternet) }
                guard var queue = routes[key], let first = queue.first else { return nil }
                if queue.count > 1 { queue.removeFirst(); routes[key] = queue }
                return first
            }
            let r = reply ?? Reply(status: 599, body: "", headers: [:])
            return (Data(r.body.utf8), HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!)
        }
    }
}

final class MemoryClerkStore: ClerkSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ClerkStoredSession?
    private(set) var deletes = 0
    init(_ value: ClerkStoredSession? = nil) { self.value = value }
    var current: ClerkStoredSession? { lock.withLock { value } }
    func load() throws -> ClerkStoredSession? { lock.withLock { value } }
    func save(_ session: ClerkStoredSession) throws { lock.withLock { value = session } }
    func delete() throws { lock.withLock { value = nil; deletes += 1 } }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Double] = []
    var all: [Double] { lock.withLock { waits } }
    func record(_ s: Double) { lock.withLock { waits.append(s) } }
}

// MARK: Fixtures

enum ClerkFixture {
    static let email = "user@example.com"
    static let device = ClerkDeviceInfo(osVersion: "27.0.0", appVersion: "0.6.0", bundleId: "dev.candywrapper.app")

    /// Trimmed `Client.Environment` with the production values M-clerk-native.md section 1 records
    /// (single session, native API on, email code and password).
    static func environment(single: Bool = true, native: Bool = true) -> String {
        """
        {"auth_config":{"object":"auth_config","id":"aac_1","single_session_mode":\(single),"claimed_at":null,"reverification":true,
          "native_settings":{"api_enabled":\(native),"biometric_sign_in_enabled":false}},
         "display_config":{"object":"display_config","id":"display_config_1","instance_environment_type":"production","application_name":"T3 Code"},
         "user_settings":{"attributes":{
            "email_address":{"enabled":true,"required":true,"used_for_first_factor":true,"first_factors":["email_code"],"used_for_second_factor":false,"second_factors":[],"verifications":["email_code"],"verify_at_sign_up":true},
            "password":{"enabled":true,"required":false,"used_for_first_factor":false,"first_factors":[],"used_for_second_factor":false,"second_factors":[],"verifications":[],"verify_at_sign_up":false}},
          "social":{},"sign_up":{"mode":"public"}},
         "organization_settings":{"enabled":false},
         "fraud_settings":{"native":{"device_attestation_mode":"disabled"}}}
        """
    }

    static func signIn(_ status: String, firstVerification: String = "null", secondFactors: String = "null",
                       sessionId: String? = nil, sessions: String = "[]") -> String {
        """
        {"response":{"object":"sign_in_attempt","id":"sia_1","status":"\(status)",
            "supported_identifiers":["email_address","passkey"],
            "supported_first_factors":[
              {"strategy":"password"},
              {"strategy":"email_code","safe_identifier":"\(email)","email_address_id":"idn_1","primary":true},
              {"strategy":"passkey"}],
            "supported_second_factors":\(secondFactors),
            "first_factor_verification":\(firstVerification),
            "second_factor_verification":null,
            "identifier":"\(email)",
            "user_data":{"first_name":null,"last_name":null,"has_image":false},
            "created_session_id":\(sessionId.map { "\"\($0)\"" } ?? "null"),
            "abandon_at":1760086400000},
         "client":{"object":"client","id":"client_1","sessions":\(sessions),"sign_in":null,"sign_up":null,
            "last_active_session_id":\(sessionId.map { "\"\($0)\"" } ?? "null"),"last_authentication_strategy":null,
            "cookie_expires_at":null,"captcha_bypass":false,"created_at":1760000000000,"updated_at":1760000000000}}
        """
    }

    static let otpUnverified = #"{"object":"verification_otp","status":"unverified","strategy":"email_code","attempts":0,"expire_at":1760000600000}"#

    static let activeSession = """
        [{"object":"session","id":"sess_1","status":"active","expire_at":1760604800000,"abandon_at":1762592000000,
          "last_active_at":1760000000000,"last_active_token":null,"actor":null,"last_active_organization_id":null,
          "user":{"id":"user_1","object":"user"},
          "public_user_data":{"first_name":null,"last_name":null,"image_url":null,"has_image":false,"identifier":"\(email)","user_id":"user_1"},
          "factor_verification_age":[0,-1],"created_at":1760000000000,"updated_at":1760000000000}]
        """

    static let complete = signIn("complete", sessionId: "sess_1", sessions: activeSession)

    static func error(_ code: String, _ longMessage: String = "x", meta: String = "") -> String {
        #"{"errors":[{"message":"x","long_message":"\#(longMessage)","code":"\#(code)"\#(meta)}],"clerk_trace_id":"trace_1"}"#
    }

    static func jwt(sub: String = "user_1", exp: Double) -> String {
        Base64URL.encode(Data(#"{"alg":"RS256","kid":"ins_1"}"#.utf8)) + "."
            + Base64URL.encode(Data(#"{"sub":"\#(sub)","aud":"t3-code-relay","exp":\#(Int(exp))}"#.utf8)) + ".c2ln"
    }

    static let signedIn = ClerkStoredSession(clientToken: "client-token-1", clientId: "client_1", sessionId: "sess_1",
                                             userId: "user_1", identifier: email)
}

private func makeClient(_ http: FakeClerk, _ store: MemoryClerkStore, clock: FakeClock = FakeClock(),
                        sleeps: SleepLog = SleepLog()) -> ClerkClient {
    ClerkClient(store: store, device: ClerkFixture.device, locale: "en-US", send: http.send,
                now: { clock.now }, sleep: { sleeps.record($0) })
}

private func query(_ r: URLRequest) -> [URLQueryItem] {
    URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
}

/// The headers clerk-ios sets on every request from an AppKit app
/// (`ClerkHeaderRequestMiddleware.swift`, `DependencyContainer.swift:102-108`, `DeviceHelper.swift`).
private func expectSDKHeaders(_ r: URLRequest, token: String?, clientId: String?) {
    #expect(r.url!.host == "clerk.t3.codes")
    #expect(query(r) == [URLQueryItem(name: "_is_native", value: "true")])
    #expect(header(r, "Content-Type") == "application/x-www-form-urlencoded")
    #expect(header(r, "clerk-api-version") == "2026-08-20")
    #expect(header(r, "x-ios-sdk-version") == "1.6.1")
    #expect(header(r, "x-mobile") == "0")
    #expect(header(r, "x-device-type") == "unspecified")
    #expect(header(r, "x-device-model") == "")
    #expect(header(r, "x-os-version") == "27.0.0")
    #expect(header(r, "x-app-version") == "0.6.0")
    #expect(header(r, "x-bundle-id") == "dev.candywrapper.app")
    #expect(header(r, "x-is-sandbox") == "false")
    #expect(header(r, "x-native-device-id") == nil)
    #expect(header(r, "Authorization") == token)
    #expect(header(r, "x-clerk-client-id") == clientId)
    #expect(header(r, "Cookie") == nil)
    #expect(r.httpShouldHandleCookies == false)
}

// MARK: Sign-in

struct ClerkSignInTests {
    @Test func emailCodeRunsCreatePrepareAttemptLikeTheSDK() async throws {
        let http = FakeClerk(), store = MemoryClerkStore()
        http.on("GET", "/v1/environment", ClerkFixture.environment())
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("needs_first_factor"), headers: ["Authorization": "client-token-1"])
        http.on("POST", "/v1/client/sign_ins/sia_1/prepare_first_factor",
                ClerkFixture.signIn("needs_first_factor", firstVerification: ClerkFixture.otpUnverified))
        http.on("POST", "/v1/client/sign_ins/sia_1/attempt_first_factor", ClerkFixture.complete)
        let clerk = makeClient(http, store)

        let challenge = try await clerk.startEmailCode(email: " user@example.com ")
        #expect(challenge == ClerkCodeChallenge(signInId: "sia_1", factor: .first, emailAddressId: "idn_1", sentTo: ClerkFixture.email,
                                                attempt: 1))
        let account = try await clerk.verifyCode("123456", for: challenge)
        #expect(account == ClerkAccount(sessionId: "sess_1", userId: "user_1", identifier: ClerkFixture.email))

        #expect(http.calls == ["GET /v1/environment", "POST /v1/client/sign_ins",
                               "POST /v1/client/sign_ins/sia_1/prepare_first_factor",
                               "POST /v1/client/sign_ins/sia_1/attempt_first_factor"])
        let r = http.requests
        expectSDKHeaders(r[0], token: nil, clientId: nil)
        expectSDKHeaders(r[1], token: nil, clientId: nil)
        expectSDKHeaders(r[2], token: "client-token-1", clientId: "client_1")
        expectSDKHeaders(r[3], token: "client-token-1", clientId: "client_1")
        #expect(r[0].httpMethod == "GET" && r[0].httpBody == nil)
        // SignIn.CreateParams, PrepareFirstFactorParams, AttemptFirstFactorParams: sorted keys,
        // `@` escaped, nil fields dropped.
        #expect(bodyString(r[1]) == "identifier=user%40example.com&locale=en-US")
        #expect(bodyString(r[2]) == "email_address_id=idn_1&strategy=email_code")
        #expect(bodyString(r[3]) == "code=123456&strategy=email_code")
        #expect(store.current == ClerkFixture.signedIn)
        #expect(await clerk.account() == account)
        #expect(try await clerk.accountId() == "user_1")
    }

    @Test func passwordSignInIsOneCreate() async throws {
        let http = FakeClerk(), store = MemoryClerkStore()
        http.on("GET", "/v1/environment", ClerkFixture.environment())
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.complete, headers: ["Authorization": "client-token-1"])
        let clerk = makeClient(http, store)

        let step = try await clerk.signIn(email: ClerkFixture.email, password: "p@ss word+1")
        #expect(step == .complete(ClerkAccount(sessionId: "sess_1", userId: "user_1", identifier: ClerkFixture.email)))
        #expect(http.calls == ["GET /v1/environment", "POST /v1/client/sign_ins"])
        #expect(bodyString(http.requests[1]) == "identifier=user%40example.com&locale=en-US&password=p%40ss%20word%2B1")
        #expect(store.current?.sessionId == "sess_1")
    }

    @Test func passwordOnANewDeviceAsksForAnEmailedCode() async throws {
        let http = FakeClerk(), store = MemoryClerkStore()
        let second = #"[{"strategy":"email_code","safe_identifier":"user@example.com","email_address_id":"idn_1"}]"#
        http.on("GET", "/v1/environment", ClerkFixture.environment())
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("needs_client_trust", secondFactors: second),
                headers: ["Authorization": "client-token-1"])
        http.on("POST", "/v1/client/sign_ins/sia_1/prepare_second_factor", ClerkFixture.signIn("needs_client_trust", secondFactors: second))
        http.on("POST", "/v1/client/sign_ins/sia_1/attempt_second_factor", ClerkFixture.complete)
        let clerk = makeClient(http, store)

        let step = try await clerk.signIn(email: ClerkFixture.email, password: "secret")
        guard case .needsCode(let challenge) = step else { Issue.record("expected a code step"); return }
        #expect(challenge.factor == .second)
        #expect(bodyString(http.requests[2]) == "email_address_id=idn_1&strategy=email_code")
        _ = try await clerk.verifyCode("654321", for: challenge)
        #expect(http.calls.last == "POST /v1/client/sign_ins/sia_1/attempt_second_factor")
        #expect(bodyString(http.requests.last!) == "code=654321&strategy=email_code")
        #expect(store.current?.sessionId == "sess_1")
    }

    @Test func obsoleteSignInAnswerLeavesTheNewerSignInAlone() async throws {
        let http = FakeClerk(), store = MemoryClerkStore(ClerkStoredSession(clientToken: "client-token-1")),
            held = HeldResponse("/v1/client/sign_ins")
        http.on("GET", "/v1/environment", ClerkFixture.environment(single: false))
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("complete", sessionId: "sess_old"),
                headers: ["Authorization": "client-token-old"])
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("complete", sessionId: "sess_2"),
                headers: ["Authorization": "client-token-2"])
        let clerk = ClerkClient(store: store, device: ClerkFixture.device, locale: "en-US", send: held.wrap(http.send),
                                sleep: { _ in })
        let old = Task { try await clerk.signIn(email: "a@example.com", password: "p") }
        #expect(await eventually { held.isHolding })
        _ = try await clerk.signIn(email: ClerkFixture.email, password: "p")
        held.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(store.current?.sessionId == "sess_2")
        #expect(store.current?.clientToken == "client-token-2")

        // A sheet closed mid-request ends its attempt the same way.
        let http2 = FakeClerk(), held2 = HeldResponse("/v1/client/sign_ins")
        http2.on("GET", "/v1/environment", ClerkFixture.environment(single: false))
        http2.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("complete", sessionId: "sess_3"),
                 headers: ["Authorization": "client-token-3"])
        let clerk2 = ClerkClient(store: store, device: ClerkFixture.device, locale: "en-US", send: held2.wrap(http2.send),
                                 sleep: { _ in })
        let dismissed = Task { try await clerk2.signIn(email: "a@example.com", password: "p") }
        #expect(await eventually { held2.isHolding })
        await clerk2.cancelSignIn()
        held2.release()
        await #expect(throws: CancellationError.self) { try await dismissed.value }
        #expect(store.current?.sessionId == "sess_2")
        #expect(store.current?.clientToken == "client-token-2")
    }

    @Test func singleSessionModeEndsTheOldSessionFirst() async throws {
        let http = FakeClerk(), store = MemoryClerkStore(ClerkFixture.signedIn)
        http.on("GET", "/v1/environment", ClerkFixture.environment(single: true))
        http.on("POST", "/v1/client/sessions/sess_1/remove", "{}")
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("needs_first_factor"), headers: ["Authorization": "client-token-2"])
        http.on("POST", "/v1/client/sign_ins/sia_1/prepare_first_factor", ClerkFixture.signIn("needs_first_factor"))
        let clerk = makeClient(http, store)

        _ = try await clerk.startEmailCode(email: ClerkFixture.email)
        #expect(http.calls == ["GET /v1/environment", "POST /v1/client/sessions/sess_1/remove",
                               "POST /v1/client/sign_ins", "POST /v1/client/sign_ins/sia_1/prepare_first_factor"])
        #expect(header(http.requests[1], "Authorization") == "client-token-1")
        #expect(header(http.requests[2], "Authorization") == nil)
        #expect(store.current == ClerkStoredSession(clientToken: "client-token-2", clientId: "client_1"))
    }

    @Test func alreadySignedInEndsTheClientSessionsAndRetriesOnce() async throws {
        let http = FakeClerk(), store = MemoryClerkStore(ClerkFixture.signedIn)
        http.on("GET", "/v1/environment", ClerkFixture.environment(single: false))
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.error("identifier_already_signed_in"), status: 400)
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.complete)
        http.on("DELETE", "/v1/client/sessions", "{}")
        let clerk = makeClient(http, store)

        _ = try await clerk.signIn(email: ClerkFixture.email, password: "secret")
        #expect(http.calls == ["GET /v1/environment", "POST /v1/client/sign_ins", "DELETE /v1/client/sessions", "POST /v1/client/sign_ins"])
        #expect(store.current?.sessionId == "sess_1")
    }

    @Test func disabledNativeAPIStopsBeforeCreate() async throws {
        let http = FakeClerk()
        http.on("GET", "/v1/environment", ClerkFixture.environment(native: false))
        let clerk = makeClient(http, MemoryClerkStore())
        await #expect(throws: ClerkAuthError(.unavailable)) { _ = try await clerk.startEmailCode(email: ClerkFixture.email) }
        #expect(http.calls == ["GET /v1/environment"])
    }

    @Test func environmentDecodesTheFieldsSignInNeeds() throws {
        let env = try ClerkWire.decoder.decode(ClerkEnvironment.self, from: Data(ClerkFixture.environment().utf8))
        #expect(env == ClerkEnvironment(singleSessionMode: true, nativeAPIEnabled: true, emailCodeEnabled: true, passwordEnabled: true))
        let bare = try ClerkWire.decoder.decode(ClerkEnvironment.self, from: Data(#"{"auth_config":{"single_session_mode":false}}"#.utf8))
        #expect(bare == ClerkEnvironment(singleSessionMode: false, nativeAPIEnabled: false, emailCodeEnabled: false, passwordEnabled: false))
    }

    @Test func bearerOnlyAuthorizationClearsTheStoredClient() async throws {
        let http = FakeClerk(), store = MemoryClerkStore(ClerkFixture.signedIn)
        http.on("GET", "/v1/environment", ClerkFixture.environment(), headers: ["Authorization": "Bearer"])
        let clerk = makeClient(http, store)
        _ = try await clerk.environment()
        #expect(store.current == nil)
        #expect(await clerk.account() == nil)
    }
}

// MARK: Relay JWT

struct ClerkTokenTests {
    @Test func mintsTheTemplateAndReusesItUntilTenSecondsBeforeExpiry() async throws {
        let http = FakeClerk(), clock = FakeClock()
        let first = ClerkFixture.jwt(exp: clock.now.timeIntervalSince1970 + 60)
        let second = ClerkFixture.jwt(exp: clock.now.timeIntervalSince1970 + 120)
        http.on("POST", "/v1/client/sessions/sess_1/tokens/t3-relay", #"{"jwt":"\#(first)"}"#)
        http.on("POST", "/v1/client/sessions/sess_1/tokens/t3-relay", #"{"jwt":"\#(second)"}"#)
        let clerk = makeClient(http, MemoryClerkStore(ClerkFixture.signedIn), clock: clock)

        #expect(try await clerk.relaySessionJWT() == first)
        let r = http.requests[0]
        expectSDKHeaders(r, token: "client-token-1", clientId: "client_1")
        #expect(r.httpMethod == "POST" && r.httpBody == nil)
        clock.advance(49)
        #expect(try await clerk.relaySessionJWT() == first)
        #expect(http.requests.count == 1)
        clock.advance(2)
        #expect(try await clerk.relaySessionJWT() == second)
        #expect(http.requests.count == 2)
        #expect(try await clerk.clientBearer() == second)
    }

    @Test func concurrentCallersShareOneMint() async throws {
        let http = FakeClerk(), clock = FakeClock()
        http.on("POST", "/v1/client/sessions/sess_1/tokens/t3-relay", #"{"jwt":"\#(ClerkFixture.jwt(exp: clock.now.timeIntervalSince1970 + 60))"}"#)
        let clerk = makeClient(http, MemoryClerkStore(ClerkFixture.signedIn), clock: clock)
        async let a = clerk.relaySessionJWT()
        async let b = clerk.relaySessionJWT()
        _ = try await (a, b)
        #expect(http.requests.count == 1)
    }

    @Test func cancelledCreatorLeavesTheMintToTheOthers() async throws {
        let http = FakeClerk(), path = "/v1/client/sessions/sess_1/tokens/t3-relay"
        // No `exp`, so nothing is cached: a second mint would show as a second request.
        http.on("POST", path, #"{"jwt":"\#(fakeJWT(sub: "user_1"))"}"#)
        let held = HeldResponse(path)
        let clerk = ClerkClient(store: MemoryClerkStore(ClerkFixture.signedIn), device: ClerkFixture.device, locale: "en-US",
                                send: held.wrap(http.send), sleep: { _ in })
        let a = Task { try await clerk.relaySessionJWT() }
        #expect(await eventually { held.isHolding })
        let b = Task { try await clerk.relaySessionJWT() }
        await settle()
        a.cancel()
        await #expect(throws: CancellationError.self) { try await a.value }
        let c = Task { try await clerk.relaySessionJWT() }
        await settle()
        held.release()
        #expect(try await b.value == fakeJWT(sub: "user_1"))
        #expect(try await c.value == fakeJWT(sub: "user_1"))
        #expect(http.requests.count == 1)
    }

    @Test func noSessionIsSignedOutWithoutARequest() async throws {
        let http = FakeClerk()
        let clerk = makeClient(http, MemoryClerkStore(ClerkStoredSession(clientToken: "client-token-1")))
        await #expect(throws: CloudSessionError.signedOut) { _ = try await clerk.relaySessionJWT() }
        #expect(try await clerk.accountId() == nil)
        #expect(http.requests.isEmpty)
    }

    @Test func endedSessionSignsOutLocally() async throws {
        for (status, body) in [(401, ClerkFixture.error("authentication_invalid")), (404, ClerkFixture.error("resource_not_found")),
                               (200, "null")] {
            let http = FakeClerk(), store = MemoryClerkStore(ClerkFixture.signedIn)
            http.on("POST", "/v1/client/sessions/sess_1/tokens/t3-relay", body, status: status)
            let clerk = makeClient(http, store)
            await #expect(throws: CloudSessionError.signedOut) { _ = try await clerk.relaySessionJWT() }
            #expect(store.current == nil)
            #expect(try await clerk.accountId() == nil)
        }
    }

    @Test func tokenWithoutExpiryIsNotCached() async throws {
        let http = FakeClerk()
        http.on("POST", "/v1/client/sessions/sess_1/tokens/t3-relay", #"{"jwt":"\#(fakeJWT(sub: "user_1"))"}"#)
        let clerk = makeClient(http, MemoryClerkStore(ClerkFixture.signedIn))
        _ = try await clerk.relaySessionJWT()
        _ = try await clerk.relaySessionJWT()
        #expect(http.requests.count == 2)
    }
}

// MARK: Sign-out

struct ClerkSignOutTests {
    @Test func removesTheSessionAndClearsTheStore() async throws {
        let http = FakeClerk(), clock = FakeClock(), store = MemoryClerkStore(ClerkFixture.signedIn)
        http.on("POST", "/v1/client/sessions/sess_1/tokens/t3-relay", #"{"jwt":"\#(ClerkFixture.jwt(exp: clock.now.timeIntervalSince1970 + 60))"}"#)
        http.on("POST", "/v1/client/sessions/sess_1/remove", "{}")
        let clerk = makeClient(http, store, clock: clock)
        _ = try await clerk.relaySessionJWT()

        await clerk.signOut()
        #expect(http.calls.last == "POST /v1/client/sessions/sess_1/remove")
        expectSDKHeaders(http.requests.last!, token: "client-token-1", clientId: "client_1")
        #expect(store.current == nil && store.deletes == 1)
        await #expect(throws: CloudSessionError.signedOut) { _ = try await clerk.relaySessionJWT() }
        #expect(await clerk.account() == nil)
    }

    @Test func offlineSignOutStillClearsLocally() async throws {
        let http = FakeClerk(), store = MemoryClerkStore(ClerkFixture.signedIn)
        http.failNetwork("POST", "/v1/client/sessions/sess_1/remove")
        let clerk = makeClient(http, store)
        await clerk.signOut()
        #expect(store.current == nil)
    }

    @Test func obsoleteSignOutLeavesTheNewerSessionAlone() async throws {
        let http = FakeClerk(), store = MemoryClerkStore(ClerkFixture.signedIn),
            held = HeldResponse("/v1/client/sessions/sess_1/remove")
        http.on("POST", "/v1/client/sessions/sess_1/remove", "{}")
        http.on("GET", "/v1/environment", ClerkFixture.environment(single: false))
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("complete", sessionId: "sess_2"),
                headers: ["Authorization": "client-token-2"])
        let clerk = ClerkClient(store: store, device: ClerkFixture.device, locale: "en-US", send: held.wrap(http.send),
                                sleep: { _ in })
        let signOut = Task { await clerk.signOut() }
        #expect(await eventually { held.isHolding })
        _ = try await clerk.signIn(email: ClerkFixture.email, password: "p")
        held.release()
        await signOut.value
        #expect(store.current?.sessionId == "sess_2")
        #expect(await clerk.account()?.sessionId == "sess_2")
    }

    @Test func staleResponseLeavesTheNextSignInAlone() async throws {
        for staleToken in ["client-token-old", "Bearer"] {
            let http = FakeClerk(), store = MemoryClerkStore(ClerkFixture.signedIn), held = HeldResponse("/v1/client")
            http.on("GET", "/v1/client", #"{"response":{"id":"client_1","sessions":[]},"client":null}"#,
                    headers: ["Authorization": staleToken])
            http.on("GET", "/v1/environment", ClerkFixture.environment())
            http.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("complete", sessionId: "sess_2"),
                    headers: ["Authorization": "client-token-2"])
            let clerk = ClerkClient(store: store, device: ClerkFixture.device, locale: "en-US", send: held.wrap(http.send),
                                    sleep: { _ in })
            let profile = Task { try await clerk.profile() }
            #expect(await eventually { held.isHolding })
            await clerk.signOut()
            _ = try await clerk.signIn(email: ClerkFixture.email, password: "p")
            held.release()
            #expect(try await profile.value == nil)
            #expect(store.current?.clientToken == "client-token-2")
            #expect(store.current?.sessionId == "sess_2")
        }
    }
}

// MARK: Errors

struct ClerkErrorTests {
    @Test func clerkCodesMapToPlainMessages() {
        let cases: [(Int, String, ClerkAuthError.Kind)] = [
            (422, ClerkFixture.error("form_code_incorrect"), .wrongCode),
            (400, ClerkFixture.error("verification_expired"), .codeExpired),
            (400, ClerkFixture.error("verification_failed"), .tooManyAttempts),
            (422, ClerkFixture.error("form_identifier_not_found"), .unknownEmail),
            (422, ClerkFixture.error("form_password_incorrect"), .wrongPassword),
            (422, ClerkFixture.error("form_password_compromised"), .passwordCompromised),
            (403, ClerkFixture.error("user_locked", meta: #","meta":{"lockout_expires_in_seconds":1800}"#), .accountLocked(seconds: 1800)),
            (401, ClerkFixture.error("signed_out"), .signedOut),
            (429, ClerkFixture.error("too_many_requests"), .rateLimited(retryAfter: 12)),
            (429, ClerkFixture.error("verification_code_too_many_requests"), .rateLimited(retryAfter: 12)),
            (429, "", .rateLimited(retryAfter: 12)),
            (400, ClerkFixture.error("form_param_format_invalid", "Enter a valid email address."), .clerk(status: 400, code: "form_param_format_invalid")),
        ]
        for (status, body, kind) in cases {
            #expect(ClerkAuthError.from(status: status, body: Data(body.utf8), retryAfter: "12").kind == kind)
        }
        #expect(ClerkAuthError(.wrongCode).message == "That code is incorrect. Check the email and try again.")
        #expect(ClerkAuthError(.rateLimited(retryAfter: 12)).message == "Too many attempts. Try again in 12 seconds.")
        #expect(ClerkAuthError(.accountLocked(seconds: 1800)).message == "Your account is locked. Try again in 30 min.")
        #expect(ClerkAuthError.from(status: 400, body: Data(ClerkFixture.error("form_param_format_invalid", "Enter a valid email address.").utf8),
                                    retryAfter: nil).message == "Sign-in failed: Enter a valid email address.")
    }

    @Test func shortRetryAfterIsRetriedOnceLikeTheSDK() async throws {
        let http = FakeClerk(), sleeps = SleepLog()
        http.on("GET", "/v1/environment", ClerkFixture.error("too_many_requests"), status: 429, headers: ["Retry-After": "1"])
        http.on("GET", "/v1/environment", ClerkFixture.environment())
        let clerk = makeClient(http, MemoryClerkStore(), sleeps: sleeps)
        _ = try await clerk.environment()
        #expect(http.requests.count == 2)
        #expect(sleeps.all == [1])
    }

    @Test func longRetryAfterFailsWithTheWait() async throws {
        let http = FakeClerk(), sleeps = SleepLog()
        http.on("POST", "/v1/client/sign_ins/sia_1/attempt_first_factor", ClerkFixture.error("too_many_requests"), status: 429, headers: ["Retry-After": "30"])
        let clerk = makeClient(http, MemoryClerkStore(ClerkStoredSession(clientToken: "client-token-1")), sleeps: sleeps)
        let challenge = ClerkCodeChallenge(signInId: "sia_1", factor: .first, emailAddressId: "idn_1", sentTo: nil)
        await #expect(throws: ClerkAuthError(.rateLimited(retryAfter: 30))) { _ = try await clerk.verifyCode("1", for: challenge) }
        #expect(http.requests.count == 1)
        #expect(sleeps.all.isEmpty)
    }

    @Test func noAnswerIsANetworkError() async throws {
        let http = FakeClerk()
        http.failNetwork("GET", "/v1/environment")
        let clerk = makeClient(http, MemoryClerkStore())
        await #expect(throws: ClerkAuthError(.network)) { _ = try await clerk.environment() }
    }

    @Test func messagesNeverCarrySecrets() async throws {
        let http = FakeClerk()
        http.on("POST", "/v1/client/sign_ins/sia_1/attempt_first_factor", ClerkFixture.error("form_code_incorrect"), status: 422)
        let clerk = makeClient(http, MemoryClerkStore(ClerkFixture.signedIn))
        let challenge = ClerkCodeChallenge(signInId: "sia_1", factor: .first, emailAddressId: "idn_1", sentTo: nil)
        do {
            _ = try await clerk.verifyCode("987654", for: challenge)
            Issue.record("expected an error")
        } catch {
            let text = "\(error)"
            #expect(!text.contains("987654") && !text.contains("client-token-1"))
        }
    }
}

// MARK: Keychain

struct ClerkKeychainStoreTests {
    @Test func roundTripReplacesAndDeletes() throws {
        let store = ClerkKeychainStore(service: "dev.candywrapper.t3.test-clerk-\(UUID().uuidString)")
        do {
            try store.save(ClerkStoredSession(clientToken: "test-token-a"))
        } catch let e as CredentialStore.KeychainError {
            // A locked keychain with no GUI login can't be written. Not a code failure.
            print("keychain unavailable, skipping: \(e.status)")
            return
        }
        defer { try? store.delete() }
        #expect(try store.load() == ClerkStoredSession(clientToken: "test-token-a"))
        try store.save(ClerkFixture.signedIn)
        #expect(try store.load() == ClerkFixture.signedIn)
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }

    @Test func newItemsAreThisDeviceOnlyAndNotSynced() {
        let add = ClerkKeychainStore(service: "s", account: "a").addQuery(Data())
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(add[kSecAttrSynchronizable as String] == nil)
    }

    @Test func profileReadsTheSessionUserImage() async throws {
        let http = FakeClerk(), store = MemoryClerkStore()
        try store.save(ClerkFixture.signedIn)
        http.on("GET", "/v1/client", #"{"response":{"id":"client_1","sessions":[{"id":"sess_1","status":"active","user":{"id":"user_1","first_name":"Ada","last_name":null,"image_url":"https://img.clerk.com/abc"},"public_user_data":{"identifier":"ada@example.com","user_id":"user_1"}}]},"client":null}"#)
        let profile = try #require(try await makeClient(http, store).profile())
        #expect(profile.initials == "A")
        #expect(profile.fetchURL?.absoluteString == "https://img.clerk.com/abc?width=80")
        #expect(ClerkProfile(imageURL: URL(string: "https://example.com/a.png"), identifier: "bo@x.io").fetchURL?.absoluteString == "https://example.com/a.png")
        #expect(ClerkProfile(imageURL: nil, identifier: "bo@x.io").initials == "B")
    }

    @Test func formBodyMatchesClerksEncoder() {
        let body = ClerkWire.formBody(["strategy": "password", "identifier": "a+b@x.io", "password": "a b&c=d/?é"])
        #expect(String(decoding: body, as: UTF8.self) == "identifier=a%2Bb%40x.io&password=a%20b%26c%3Dd/?%C3%A9&strategy=password")
    }
}
