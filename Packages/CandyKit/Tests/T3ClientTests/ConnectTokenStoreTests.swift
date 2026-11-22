import Foundation
import Security
import Testing
@testable import T3Client

// Environment tokens kept between launches (T3: client-runtime authorization/service.ts:458-480). A "relaunch"
// is a second authorizer with a new relay client and an empty memory over the same store. Tokens are fakes and
// the store is in memory; only `keychainListsAndDeletes` touches the login Keychain, under a throwaway service.
struct ConnectTokenStoreTests {
    let clock = FakeClock()
    let cloud = FakeCloud()
    let key = try! SoftwareDPoPKey()
    let store = ConnectTokenStore.inMemory()

    func authorizer(_ http: FakeHTTP, key: (any DPoPSigningKey)? = nil, send: HTTPSend? = nil) throws -> T3ConnectAuthorizer {
        let relay = try RelayClient(key: key ?? self.key, send: http.send, now: { [clock] in clock.now })
        return T3ConnectAuthorizer(relay: relay, tokens: cloud, identity: ClientIdentity(appVersion: "1.2.3"),
                                   send: send ?? http.send, store: store, now: { [clock] in clock.now })
    }

    func serve(_ http: FakeHTTP, tokens: [String] = ["eat-1", "eat-2"], env: String = "env-1") {
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        http.on("POST", "/v1/environments/\(env)/connect", 200, connectJSON(env, credential: "minted-1"))
        http.on("GET", "/.well-known/t3/environment", 200, descriptorJSON(env))
        for t in tokens { http.on("POST", "/oauth/token", 200, envTokenJSON(t)) }
        http.on("POST", "/api/auth/websocket-ticket", 200, ticketJSON)
    }

    /// First launch: the whole chain, and the token lands in the store.
    func firstLaunch(env: String = "env-1") async throws {
        let http = FakeHTTP()
        serve(http, env: env)
        let first = try authorizer(http)
        #expect(try await first.authorizeSocket(environmentId: env).token.accessToken == "eat-1")
        await first.flushStore()
    }

    func calls(_ http: FakeHTTP) -> [String] { http.requests.map { "\($0.httpMethod!) \($0.url!.path)" } }

    static let chain: Set = ["POST /v1/client/dpop-token", "POST /v1/environments/env-1/connect", "POST /oauth/token"]

    @Test func validStoredTokenSkipsTheChain() async throws {
        try await firstLaunch()
        clock.advance(3000)
        let http = FakeHTTP()
        serve(http, tokens: ["eat-2"])
        let socket = try await authorizer(http).authorizeSocket(environmentId: "env-1")
        #expect(socket.token.accessToken == "eat-1")
        // The ticket and, beside it, the descriptor a reused token doesn't carry (service.ts:711-724).
        #expect(Set(calls(http)) == ["POST /api/auth/websocket-ticket", "GET /.well-known/t3/environment"])
        #expect(socket.token.serverVersion == "0.0.46" && socket.token.serverCapabilities == ["repositoryIdentity"])
        // Presented exactly as a fresh token: DPoP scheme, a proof bound to it, the cached 3 s ticket timeout.
        let ticket = try #require(http.requests("/api/auth/websocket-ticket").first)
        #expect(header(ticket, "Authorization") == "DPoP eat-1")
        #expect(verifyProof(header(ticket, "DPoP")!, method: "POST", url: "https://prod-abc.tunnel.example/api/auth/websocket-ticket",
                            now: Int(clock.now.timeIntervalSince1970), accessToken: "eat-1") == .ok(thumbprint: key.thumbprint))
        #expect(ticket.timeoutInterval == T3ConnectAuthorizer.cachedSocketTimeout)
    }

    /// The host updated between launches: the reused token's socket reports the version the host serves now.
    @Test func reusedTokenReadsTheCurrentDescriptor() async throws {
        try await firstLaunch()
        let http = FakeHTTP()
        http.on("GET", "/.well-known/t3/environment", 200,
                #"{"environmentId":"env-1","label":"Studio","serverVersion":"0.0.47","orchestrationProtocolVersion":2,"capabilities":{"shellThreadFamilies":true}}"#)
        http.on("POST", "/api/auth/websocket-ticket", 200, ticketJSON)
        let socket = try await authorizer(http).authorizeSocket(environmentId: "env-1")
        #expect(socket.token.serverVersion == "0.0.47" && socket.token.serverCapabilities == ["shellThreadFamilies"])
    }

    @Test(arguments: [3540.0, 3600, 7200])
    func expiredOrNearlyExpiredTokenRunsTheChain(age: TimeInterval) async throws {
        try await firstLaunch()
        clock.advance(age)
        let http = FakeHTTP()
        serve(http, tokens: ["eat-2"])
        let again = try authorizer(http)
        #expect(try await again.authorizeSocket(environmentId: "env-1").token.accessToken == "eat-2")
        #expect(Self.chain.isSubset(of: Set(calls(http))))
        await again.flushStore()
        #expect(await store.load(accountId: "user_1", environmentId: "env-1")?.accessToken == "eat-2")
    }

    @Test func lastSecondBeforeTheSkewStillReuses() async throws {
        try await firstLaunch()
        clock.advance(3539)
        let http = FakeHTTP()
        serve(http, tokens: ["eat-2"])
        #expect(try await authorizer(http).authorizeSocket(environmentId: "env-1").token.accessToken == "eat-1")
        #expect(http.requests("/oauth/token").isEmpty)
    }

    @Test func rejectedStoredTokenIsDeletedAndTheChainRunsOnce() async throws {
        try await firstLaunch()
        let rejecting = FakeHTTP()
        rejecting.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        rejecting.on("POST", "/v1/environments/env-1/connect", 200, connectJSON(credential: "minted-2"))
        rejecting.on("GET", "/.well-known/t3/environment", 200, descriptorJSON())
        rejecting.on("POST", "/oauth/token", 200, envTokenJSON("eat-2"))
        rejecting.on("POST", "/api/auth/websocket-ticket", 401, Self.invalidCredential)
        rejecting.on("POST", "/api/auth/websocket-ticket", 200, ticketJSON)
        let again = try authorizer(rejecting)
        let socket = try await again.authorizeSocket(environmentId: "env-1")
        #expect(socket.token.accessToken == "eat-2")
        #expect(rejecting.requests("/api/auth/websocket-ticket").map { header($0, "Authorization") } == ["DPoP eat-1", "DPoP eat-2"])
        #expect(rejecting.requests("/v1/environments/env-1/connect").count == 1)
        #expect(rejecting.requests("/oauth/token").count == 1)
        await again.flushStore()
        #expect(await store.load(accountId: "user_1", environmentId: "env-1")?.accessToken == "eat-2")
    }

    @Test func rejectedFreshTokenFailsWithoutLooping() async throws {
        try await firstLaunch()
        let refusing = FakeHTTP()
        refusing.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        refusing.on("POST", "/v1/environments/env-1/connect", 200, connectJSON(credential: "minted-2"))
        refusing.on("GET", "/.well-known/t3/environment", 200, descriptorJSON())
        refusing.on("POST", "/oauth/token", 200, envTokenJSON("eat-2"))
        refusing.on("POST", "/oauth/token", 200, envTokenJSON("eat-3"))
        refusing.on("POST", "/api/auth/websocket-ticket", 401, Self.invalidCredential)
        let again = try authorizer(refusing)
        await #expect(throws: EnvironmentHTTPError.self) { try await again.authorizeSocket(environmentId: "env-1") }
        // The stored token, then one fresh one, then a real auth failure.
        #expect(refusing.requests("/api/auth/websocket-ticket").map { header($0, "Authorization") } == ["DPoP eat-1", "DPoP eat-2"])
        #expect(refusing.requests("/oauth/token").count == 1)
        await again.flushStore()
        #expect(await store.load(accountId: "user_1", environmentId: "env-1") == nil)
        // The next attempt (the supervisor's, after its backoff) starts from the chain, once.
        await #expect(throws: EnvironmentHTTPError.self) { try await again.authorizeSocket(environmentId: "env-1") }
        #expect(refusing.requests("/oauth/token").count == 2)
        #expect(refusing.requests("/api/auth/websocket-ticket").count == 3)
    }

    @Test func tokenOfAnotherAccountIsNeverUsed() async throws {
        try await firstLaunch()
        cloud.signIn("user_2", session: "sess_2")
        let http = FakeHTTP()
        serve(http, tokens: ["eat-2"])
        let socket = try await authorizer(http).authorizeSocket(environmentId: "env-1")
        #expect(socket.token.accessToken == "eat-2" && socket.token.accountId == "user_2")
        #expect(http.requests("/api/auth/websocket-ticket").map { header($0, "Authorization") } == ["DPoP eat-2"])
    }

    @Test func tokenOfAnotherEnvironmentIsNeverUsed() async throws {
        try await firstLaunch(env: "env-2")
        let http = FakeHTTP()
        serve(http, tokens: ["eat-9"])
        let socket = try await authorizer(http).authorizeSocket(environmentId: "env-1")
        #expect(socket.token.accessToken == "eat-9")
        #expect(Self.chain.isSubset(of: Set(calls(http))))
    }

    @Test func signOutDuringStoredCredentialLookupEndsAuthorization() async throws {
        actor SigningOut: CloudTokenProvider {
            var signIn: CloudSignIn? = CloudSignIn(accountId: "user_1", session: "sess_1")
            func currentSignIn() -> CloudSignIn? {
                defer { signIn = nil }
                return signIn
            }
            func relaySessionJWT() throws -> String { throw CloudSessionError.signedOut }
        }
        try await firstLaunch()
        let http = FakeHTTP()
        let relay = try RelayClient(key: key, send: http.send, now: { [clock] in clock.now })
        let auth = T3ConnectAuthorizer(relay: relay, tokens: SigningOut(), identity: ClientIdentity(appVersion: "1"),
                                      send: http.send, store: store, now: { [clock] in clock.now })
        await #expect(throws: CloudSessionError.accountChanged) {
            _ = try await auth.token(environmentId: "env-1")
        }
        #expect(calls(http).isEmpty)
    }

    /// Runs `hook` inside the second `currentSignIn`: the authorizer's check after its Keychain read, while that
    /// request is suspended and the authorizer is free.
    actor Hooked: CloudTokenProvider {
        let cloud: FakeCloud
        var hook: (@Sendable () async -> Void)?
        var asked = 0
        init(_ cloud: FakeCloud) { self.cloud = cloud }
        func set(_ hook: @escaping @Sendable () async -> Void) { self.hook = hook }
        func currentSignIn() async throws -> CloudSignIn? {
            asked += 1
            if asked == 2 { await hook?() }
            return try await cloud.currentSignIn()
        }
        func relaySessionJWT() async throws -> String { try await cloud.relaySessionJWT() }
    }

    func hooked(_ http: FakeHTTP, send: HTTPSend? = nil) throws -> (T3ConnectAuthorizer, Hooked) {
        let tokens = Hooked(cloud)
        let relay = try RelayClient(key: key, send: http.send, now: { [clock] in clock.now })
        return (T3ConnectAuthorizer(relay: relay, tokens: tokens, identity: ClientIdentity(appVersion: "1"),
                                    send: send ?? http.send, store: store, now: { [clock] in clock.now }), tokens)
    }

    @Test func accountSwitchDuringStoredCredentialLookupEndsAuthorization() async throws {
        try await firstLaunch()
        let http = FakeHTTP()
        serve(http, tokens: ["eat-2"])
        let (auth, tokens) = try hooked(http)
        await tokens.set { [cloud] in cloud.signIn("user_2", session: "sess_2") }
        await #expect(throws: CloudSessionError.accountChanged) {
            _ = try await auth.authorizeSocket(environmentId: "env-1")
        }
        #expect(calls(http).isEmpty)
    }

    /// The machine was removed while its stored token was read: that token is not used or kept.
    @Test func machineRemovedDuringStoredCredentialLookupDropsTheToken() async throws {
        try await firstLaunch()
        let http = FakeHTTP()
        serve(http, tokens: ["eat-2"])
        let (auth, tokens) = try hooked(http)
        await tokens.set { await auth.forget(environmentId: "env-1") }
        _ = try await auth.authorizeSocket(environmentId: "env-1")
        #expect(http.requests("/api/auth/websocket-ticket").map { header($0, "Authorization") } == ["DPoP eat-2"])
    }

    /// The machine was removed while its token was exchanged: the caller gets the token, nothing keeps it.
    @Test func machineRemovedDuringTheExchangeKeepsNoToken() async throws {
        let http = FakeHTTP()
        serve(http)
        let removing = Box<T3ConnectAuthorizer>()
        let auth = try authorizer(http, send: { [http] request in
            if request.url?.path == "/oauth/token" { await removing.value?.forget(environmentId: "env-1") }
            return try await http.send(request)
        })
        removing.value = auth
        #expect(try await auth.token(environmentId: "env-1").accessToken == "eat-1")
        await auth.flushStore()
        #expect(await store.load(accountId: "user_1", environmentId: "env-1") == nil)
        removing.value = nil
        #expect(try await auth.token(environmentId: "env-1").accessToken == "eat-2")
    }

    /// A sign-out while the ticket is minted, for a stored token and for a fresh one: no socket URL comes back.
    @Test(arguments: [true, false])
    func signOutWhileTheTicketIsMintedEndsAuthorization(stored: Bool) async throws {
        if stored { try await firstLaunch() }
        let http = FakeHTTP()
        serve(http)
        let auth = try authorizer(http, send: { [http, cloud] request in
            let answer = try await http.send(request)
            if request.url?.path == "/api/auth/websocket-ticket" { cloud.signIn(nil) }
            return answer
        })
        await #expect(throws: CloudSessionError.accountChanged) {
            _ = try await auth.authorizeSocket(environmentId: "env-1")
        }
        #expect(http.requests("/api/auth/websocket-ticket").count == 1)
    }

    @Test func itemWhosePayloadNamesAnotherAccountIsDeleted() async throws {
        try await firstLaunch()
        let raw = try #require(try store.credentials.load(environmentId: "user_1/env-1"))
        try store.credentials.save(token: raw, environmentId: "user_2/env-1")
        #expect(await store.load(accountId: "user_2", environmentId: "env-1") == nil)
        #expect(try store.credentials.load(environmentId: "user_2/env-1") == nil)
        #expect(await store.load(accountId: "user_1", environmentId: "env-1")?.accessToken == "eat-1")
    }

    @Test func tokenBoundToAnotherProofKeyRunsTheChain() async throws {
        try await firstLaunch()
        let http = FakeHTTP()
        serve(http, tokens: ["eat-2"])
        let again = try authorizer(http, key: try SoftwareDPoPKey())
        #expect(try await again.authorizeSocket(environmentId: "env-1").token.accessToken == "eat-2")
        await again.flushStore()
        #expect(await store.load(accountId: "user_1", environmentId: "env-1")?.accessToken == "eat-2")
    }

    @Test func renewalWhileConnectedIsStored() async throws {
        let http = FakeHTTP()
        serve(http)
        let first = try authorizer(http)
        _ = try await first.token(environmentId: "env-1")
        clock.advance(3541)
        #expect(try await first.token(environmentId: "env-1").accessToken == "eat-2")
        await first.flushStore()
        #expect(await store.load(accountId: "user_1", environmentId: "env-1")?.accessToken == "eat-2")
    }

    @Test func signOutRemovalAndAccountSwitchDeleteStoredTokens() async throws {
        try await firstLaunch()
        try await firstLaunch(env: "env-2")
        let other = ConnectTokenStore.Stored(environmentId: "env-3", accountId: "user_2", label: "Old", endpoint: RelayEndpoint(
            httpBaseUrl: "https://t/", wsBaseUrl: "wss://t/", providerKind: "x"), accessToken: "old", expiresAtEpochMs: 0, dpopThumbprint: "x")
        try store.credentials.save(token: String(decoding: try JSONEncoder().encode(other), as: UTF8.self), environmentId: "user_2/env-3")
        let a = try authorizer(FakeHTTP())
        await a.keepStoredTokens(forAccount: "user_1")
        await a.flushStore()
        #expect(Set(try store.credentials.accounts()) == ["user_1/env-1", "user_1/env-2"])
        await a.forget(environmentId: "env-2")
        await a.flushStore()
        #expect(try store.credentials.accounts() == ["user_1/env-1"])
        await a.reset()
        await a.flushStore()
        #expect(try store.credentials.accounts().isEmpty)
    }

    @Test func storeQueuesInOrder() async {
        let token = T3ConnectToken(environmentId: "env-1", label: "Studio", endpoint: RelayEndpoint(
            httpBaseUrl: "https://t/", wsBaseUrl: "wss://t/", providerKind: "x"), accessToken: "a", expiresAt: clock.now,
                                   accountId: "user_1", thumbprint: "tp")
        store.save(token)
        store.deleteAll(keepingAccount: nil)
        #expect(await store.load(accountId: "user_1", environmentId: "env-1") == nil)
        store.save(token)
        var newer = token
        newer.accessToken = "b"
        store.save(newer)
        // A late rejection of "a" leaves "b".
        store.delete(accountId: "user_1", environmentId: "env-1", ifToken: "a")
        #expect(await store.load(accountId: "user_1", environmentId: "env-1")?.accessToken == "b")
        let parsed = ConnectTokenStore.parse("user_1/env/with/slash")
        #expect(parsed?.accountId == "user_1" && parsed?.environmentId == "env/with/slash")
        #expect(ConnectTokenStore.parse("nokey") == nil)
    }

    @Test func cancelledLoadReturnsWhileTheKeychainWaits() async {
        let token = T3ConnectToken(environmentId: "env-1", label: "Studio", endpoint: RelayEndpoint(
            httpBaseUrl: "https://t/", wsBaseUrl: "wss://t/", providerKind: "x"), accessToken: "a", expiresAt: clock.now,
                                   accountId: "user_1", thumbprint: "tp")
        store.save(token)
        // Stands in for a read waiting on a Keychain prompt.
        let prompt = DispatchSemaphore(value: 0)
        store.enqueue { prompt.wait() }
        let read = Task { [store] in await store.load(accountId: "user_1", environmentId: "env-1") }
        read.cancel()
        #expect(await read.value == nil)
        prompt.signal()
        #expect(await store.load(accountId: "user_1", environmentId: "env-1")?.accessToken == "a")
    }

    @Test func itemsStayOnThisDeviceUnderTheirOwnService() {
        let credentials = ConnectTokenStore().credentials
        #expect(credentials.service == "dev.candywrapper.t3.connect-environment-token")
        let add = credentials.addQuery("t", environmentId: "user_1/env-1")
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(add[kSecAttrSynchronizable as String] == nil)
        #expect(add[kSecAttrLabel as String] as? String == "T3 Connect environment token")
    }

    /// The real login Keychain under a throwaway service: the attribute listing and the per-account delete.
    @Test(.integration) func keychainListsAndDeletes() async throws {
        let store = ConnectTokenStore(credentials: CredentialStore(service: "dev.candywrapper.t3.test-\(UUID().uuidString)"))
        defer { for k in (try? store.credentials.accounts()) ?? [] { try? store.credentials.delete(environmentId: k) } }
        for (account, env) in [("user_1", "env-1"), ("user_1", "env-2"), ("user_2", "env-1")] {
            store.save(T3ConnectToken(environmentId: env, label: "L", endpoint: RelayEndpoint(httpBaseUrl: "https://t/", wsBaseUrl: "wss://t/",
                                                                                            providerKind: "x"),
                                      accessToken: "tok-\(account)-\(env)", expiresAt: Date(), accountId: account, thumbprint: "tp"))
        }
        await store.flush()
        #expect(Set(try store.credentials.accounts()) == ["user_1/env-1", "user_1/env-2", "user_2/env-1"])
        #expect(await store.load(accountId: "user_1", environmentId: "env-2")?.accessToken == "tok-user_1-env-2")
        store.deleteAll(keepingAccount: "user_1")
        await store.flush()
        #expect(Set(try store.credentials.accounts()) == ["user_1/env-1", "user_1/env-2"])
        store.delete(environmentId: "env-1")
        store.deleteAll(keepingAccount: nil)
        await store.flush()
        #expect(try store.credentials.accounts().isEmpty)
    }

    /// Launch cost over a 40 ms link (scripts/connection-timing/latency-proxy.py's round trip), on the fakes: every
    /// HTTP request takes one round trip, with no TCP or TLS handshakes and no Clerk mint (FakeCloud answers the
    /// relay JWT in memory; the real chain mints one first). Prints `TIMING` lines for the research notes.
    @Test func relaunchRoundTrips() async throws {
        let rtt = Duration.milliseconds(40)
        func slow(_ http: FakeHTTP) -> HTTPSend {
            { request in try await Task.sleep(for: rtt); return try await http.send(request) }
        }
        func launch() async throws -> (ms: Double, requests: Int, token: String) {
            let http = FakeHTTP()
            serve(http, tokens: ["eat-1"])
            let relay = try RelayClient(key: key, send: slow(http), now: { [clock] in clock.now })
            let a = T3ConnectAuthorizer(relay: relay, tokens: cloud, identity: ClientIdentity(appVersion: "1.2.3"),
                                        send: slow(http), store: store, now: { [clock] in clock.now })
            let t0 = ContinuousClock.now
            let socket = try await a.authorizeSocket(environmentId: "env-1")
            let ms = (ContinuousClock.now - t0) / .milliseconds(1)
            await a.flushStore()
            return (ms, http.requests.count, socket.token.accessToken)
        }
        var cold: [Double] = [], warm: [Double] = []
        for _ in 0..<3 {
            await store.flush()
            store.deleteAll(keepingAccount: nil)
            let c = try await launch()
            #expect(c.requests == 5)
            let w = try await launch()
            #expect(w.requests == 2 && w.token == c.token)
            cold.append(c.ms); warm.append(w.ms)
        }
        print("TIMING connect-token cold ms \(cold.map { Int($0) }) relaunch ms \(warm.map { Int($0) }), requests 5 -> 2 (1 round trip)")
        // Five requests in a row against two side by side; generous for a busy machine.
        #expect(warm.min()! < cold.min()! / 2)
    }

    static let invalidCredential = #"{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"invalid_credential","traceId":"t"}"#
}
