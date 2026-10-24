import Foundation
import Testing
import T3Protocol
@testable import T3Client
@testable import T3Transport

// WP6.4b: the sign-in sheet's state machine, account discovery to catalog entries, and sign-out
// cleanup. No network: Clerk is `FakeClerk`, the relay is `FakeHTTP`. Nothing contacts
// clerk.t3.codes or relay.t3.codes.

private func clerkClient(_ http: FakeClerk, _ store: MemoryClerkStore, clock: FakeClock = FakeClock()) -> ClerkClient {
    ClerkClient(store: store, device: ClerkFixture.device, locale: "en-US", send: http.send, now: { clock.now }, sleep: { _ in })
}

private func tempCatalog() -> (EnvironmentCatalog, URL) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "cw-connect-\(UUID().uuidString)")
    return (EnvironmentCatalog(file: dir.appending(path: "environments.json"),
                               credentials: CredentialStore(service: "dev.candywrapper.t3.test-\(UUID().uuidString)")), dir)
}

/// `RelayClientEnvironmentRecord` (relay.ts:701-706).
private func recordJSON(_ id: String, _ label: String, host: String) -> String {
    #"{"environmentId":"\#(id)","label":"\#(label)","endpoint":{"httpBaseUrl":"https://\#(host)/","wsBaseUrl":"wss://\#(host)/","providerKind":"cloudflare_tunnel"},"linkedAt":"2026-10-01T10:00:00.000Z"}"#
}

/// `RelayEnvironmentStatusResponse` (relay.ts:823-844).
private func statusJSON(_ id: String, host: String, online: Bool, protocolVersion: Int = 2, offlineReason: String? = nil) -> String {
    let reason = offlineReason.map { #","offlineReason":"\#($0)""# } ?? ""
    return #"{"environmentId":"\#(id)","endpoint":{"httpBaseUrl":"https://\#(host)/","wsBaseUrl":"wss://\#(host)/","providerKind":"cloudflare_tunnel"},"status":"\#(online ? "online" : "offline")","checkedAt":"2026-10-10T10:00:00.000Z","descriptor":{"environmentId":"\#(id)","label":"Studio","serverVersion":"0.0.46","orchestrationProtocolVersion":\#(protocolVersion),"platform":{"os":"darwin","arch":"arm64","machine":"mac-studio"},"capabilities":{}}\#(reason)}"#
}

@MainActor
struct T3ConnectSignInFlowTests {
    let http = FakeClerk()
    let store = MemoryClerkStore()

    private func emailCodeRoutes() {
        http.on("GET", "/v1/environment", ClerkFixture.environment())
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("needs_first_factor"), headers: ["Authorization": "client-token-1"])
        http.on("POST", "/v1/client/sign_ins/sia_1/prepare_first_factor",
                ClerkFixture.signIn("needs_first_factor", firstVerification: ClerkFixture.otpUnverified))
    }

    @Test func emailThenWrongCodeThenResendThenRightCode() async {
        emailCodeRoutes()
        http.on("POST", "/v1/client/sign_ins/sia_1/attempt_first_factor", ClerkFixture.error("form_code_incorrect"), status: 422)
        http.on("POST", "/v1/client/sign_ins/sia_1/attempt_first_factor", ClerkFixture.complete)
        let flow = T3ConnectSignInFlow(clerk: clerkClient(http, store))
        var changes = 0
        flow.onChange = { changes += 1 }

        await flow.submitEmail("  user@example.com ")
        #expect(flow.step == .code(sentTo: ClerkFixture.email))
        #expect(flow.error == nil && !flow.isBusy)
        #expect(changes >= 2)

        await flow.submitCode("111111")
        #expect(flow.step == .code(sentTo: ClerkFixture.email))
        #expect(flow.error == "That code is incorrect. Check the email and try again.")

        await flow.resend()
        #expect(flow.notice == "We sent a new code." && flow.error == nil)
        #expect(http.calls.filter { $0.hasSuffix("prepare_first_factor") }.count == 2)

        await flow.submitCode("123 456")
        #expect(flow.step == .signedIn(ClerkAccount(sessionId: "sess_1", userId: "user_1", identifier: ClerkFixture.email)))
        #expect(bodyString(http.requests.last!) == "code=123456&strategy=email_code")
        #expect(store.current?.sessionId == "sess_1")
    }

    @Test func expiredCodeStaysAndTooManyAttemptsStartsOver() async {
        emailCodeRoutes()
        http.on("POST", "/v1/client/sign_ins/sia_1/attempt_first_factor", ClerkFixture.error("verification_expired"), status: 400)
        http.on("POST", "/v1/client/sign_ins/sia_1/attempt_first_factor", ClerkFixture.error("verification_failed"), status: 400)
        let flow = T3ConnectSignInFlow(clerk: clerkClient(http, store))
        await flow.submitEmail(ClerkFixture.email)

        await flow.submitCode("222222")
        #expect(flow.step == .code(sentTo: ClerkFixture.email))
        #expect(flow.error == "That code has expired. Send a new code.")

        await flow.submitCode("333333")
        #expect(flow.step == .email)
        #expect(flow.email == ClerkFixture.email)
        #expect(flow.error == "Too many incorrect codes. Start the sign-in again.")
    }

    @Test func localChecksNeverReachClerk() async {
        let flow = T3ConnectSignInFlow(clerk: clerkClient(http, store))
        await flow.submitEmail("not-an-address")
        #expect(flow.error == "Enter a valid email address." && flow.step == .email)
        await flow.submitCode("123456")  // no challenge yet
        #expect(http.calls.isEmpty)
    }

    @Test func passwordCompletesOrAsksForACode() async {
        let second = #"[{"strategy":"email_code","safe_identifier":"u***@example.com","email_address_id":"idn_1"}]"#
        http.on("GET", "/v1/environment", ClerkFixture.environment())
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.error("form_password_incorrect"), status: 422)
        http.on("POST", "/v1/client/sign_ins", ClerkFixture.signIn("needs_client_trust", secondFactors: second),
                headers: ["Authorization": "client-token-1"])
        http.on("POST", "/v1/client/sign_ins/sia_1/prepare_second_factor", ClerkFixture.signIn("needs_client_trust", secondFactors: second))
        http.on("POST", "/v1/client/sign_ins/sia_1/attempt_second_factor", ClerkFixture.complete)
        let flow = T3ConnectSignInFlow(clerk: clerkClient(http, store))
        await flow.submitEmail("bad")  // keeps the typed email for the password step
        flow.usePassword()
        #expect(flow.step == .password && flow.error == nil)

        await flow.submitPassword("")
        #expect(flow.error == "Enter your password.")
        await flow.submitPassword("wrong")
        #expect(flow.step == .password)
        #expect(flow.error == "That password is incorrect. Try again, or sign in with an email code.")

        await flow.submitPassword("right")
        #expect(flow.step == .code(sentTo: "u***@example.com"))
        await flow.submitCode("654321")
        #expect(http.calls.last == "POST /v1/client/sign_ins/sia_1/attempt_second_factor")
        if case .signedIn = flow.step {} else { Issue.record("expected signed in, got \(flow.step)") }
    }

    @Test func editEmailGoesBackWithoutACall() async {
        emailCodeRoutes()
        let flow = T3ConnectSignInFlow(clerk: clerkClient(http, store))
        await flow.submitEmail(ClerkFixture.email)
        let calls = http.calls.count
        flow.editEmail()
        #expect(flow.step == .email && flow.email == ClerkFixture.email)
        #expect(http.calls.count == calls)
    }
}

struct T3ConnectAccountTests {
    let clerkHTTP = FakeClerk()
    let relayHTTP = FakeHTTP()
    let clock = FakeClock()

    private func account(_ store: MemoryClerkStore) throws -> T3ConnectAccount {
        let jwt = ClerkFixture.jwt(exp: clock.now.timeIntervalSince1970 + 60)
        clerkHTTP.on("POST", "/v1/client/sessions/sess_1/tokens/t3-relay", #"{"jwt":"\#(jwt)"}"#)
        clerkHTTP.on("POST", "/v1/client/sessions/sess_1/remove", "{}")
        let relay = try RelayClient(key: try SoftwareDPoPKey(), send: relayHTTP.send, now: { [clock] in clock.now })
        return T3ConnectAccount(clerk: clerkClient(clerkHTTP, store, clock: clock), relay: relay,
                                identity: ClientIdentity(appVersion: "0.6.0"), send: relayHTTP.send)
    }

    @Test func discoveryListsEveryMachineWithItsRelayStatus() async throws {
        relayHTTP.on("GET", "/v1/environments", 200, #"{"environments":[\#(recordJSON("env-1", "Studio", host: "a.tunnel.example")),\#(recordJSON("env-2", "Box", host: "b.tunnel.example")),\#(recordJSON("env-3", "Old", host: "c.tunnel.example"))]}"#)
        relayHTTP.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1", scope: "environment:status environment:connect"))
        relayHTTP.on("POST", "/v1/environments/env-1/status", 200, statusJSON("env-1", host: "a.tunnel.example", online: true))
        relayHTTP.on("POST", "/v1/environments/env-2/status", 200,
                     statusJSON("env-2", host: "b.tunnel.example", online: false, offlineReason: "tunnel_released"))
        relayHTTP.on("POST", "/v1/environments/env-3/status", 200, statusJSON("env-3", host: "c.tunnel.example", online: true, protocolVersion: 3))
        let account = try account(MemoryClerkStore(ClerkFixture.signedIn))

        let machines = try await account.discover()
        #expect(machines.map(\.environmentId) == ["env-1", "env-2", "env-3"])
        #expect(machines[0].availability == .online && machines[0].machine == "mac-studio" && machines[0].unsupportedReason == nil)
        #expect(machines[1].availability == .offline)
        #expect(machines[1].offlineReason?.hasPrefix("Offline for a while, so its T3 Connect tunnel was removed.") == true)
        #expect(machines[2].unsupportedReason == "This client is not supported by this server. Update your app or use a compatible release to connect to Studio.")
        // The list goes out with the t3-relay JWT as a bearer; statuses share one relay token.
        let list = try #require(relayHTTP.requests("/v1/environments").first)
        #expect(header(list, "Authorization")?.hasPrefix("Bearer ey") == true)
        #expect(relayHTTP.requests("/v1/client/dpop-token").count == 1)
    }

    @Test func aFailedStatusMarksOnlyThatMachine() async throws {
        relayHTTP.on("GET", "/v1/environments", 200, #"{"environments":[\#(recordJSON("env-1", "Studio", host: "a.tunnel.example"))]}"#)
        relayHTTP.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1", scope: "environment:status environment:connect"))
        relayHTTP.on("POST", "/v1/environments/env-1/status", 504,
                     #"{"_tag":"RelayEnvironmentEndpointTimedOutError","code":"environment_endpoint_timed_out","traceId":"t1"}"#)
        let machines = try await account(MemoryClerkStore(ClerkFixture.signedIn)).discover()
        guard case .error(let message) = machines.first?.availability else { Issue.record("expected an error"); return }
        #expect(!message.isEmpty && !message.contains("rat-1"))
    }

    @Test func signedOutDiscoveryThrowsWithoutARequest() async throws {
        let account = try account(MemoryClerkStore())
        await #expect(throws: CloudSessionError.signedOut) { _ = try await account.discover() }
        #expect(relayHTTP.requests.isEmpty)
    }

    @Test func addingAMachineSavesARelayRouteWithoutAToken() async throws {
        let (catalog, dir) = tempCatalog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try account(MemoryClerkStore(ClerkFixture.signedIn))
        let record = try JSONDecoder().decode(RelayEnvironmentRecord.self, from: Data(recordJSON("env-1", "Studio", host: "a.tunnel.example").utf8))
        let saved = try await account.add(T3ConnectMachine(record: record, availability: .online), to: catalog)

        #expect(saved.relay == RelayLink(accountId: "user_1", endpoint: record.endpoint))
        #expect(saved.routes == [URL(string: "https://a.tunnel.example/")!])
        #expect(saved.isRelayOnly && saved.enabled)
        #expect(saved.routeLabel(saved.httpBaseURL) == "T3 Connect")
        #expect(catalog.load().map(\.relay) == [saved.relay] && catalog.load().map(\.routes) == [saved.routes])
        let file = String(decoding: try Data(contentsOf: catalog.file), as: UTF8.self)
        #expect(!file.contains("jwt") && !file.contains("token") && !file.contains("client-token"))
    }

    @Test func aPairedMachineGainsTheRelayRouteLast() throws {
        let (catalog, dir) = tempCatalog()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(catalog, [EnvironmentRegistration(environmentId: "env-1", label: "Studio", httpBaseURL: URL(string: "http://10.0.0.2:3773")!)])
        let record = try JSONDecoder().decode(RelayEnvironmentRecord.self, from: Data(recordJSON("env-1", "Studio", host: "a.tunnel.example").utf8))
        let saved = try catalog.addRelay(record, accountId: "user_1")
        #expect(saved.routes.map(\.absoluteString) == ["http://10.0.0.2:3773", "https://a.tunnel.example/"])
        #expect(!saved.isRelayOnly)
        #expect(saved.routeLabel(saved.routes[0]) == "LAN" && saved.routeLabel(saved.routes[1]) == "T3 Connect")
        // Removing the relay route drops the link too.
        let after = try #require(try catalog.removeRoute(saved.routes[1], environmentId: "env-1"))
        #expect(after.relay == nil && after.routes.count == 1)
    }

    @Test func signOutClearsTheSessionTokensAndRelayRoutes() async throws {
        let (catalog, dir) = tempCatalog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryClerkStore(ClerkFixture.signedIn)
        let account = try account(store)
        let a = try JSONDecoder().decode(RelayEnvironmentRecord.self, from: Data(recordJSON("env-1", "Studio", host: "a.tunnel.example").utf8))
        let b = try JSONDecoder().decode(RelayEnvironmentRecord.self, from: Data(recordJSON("env-2", "Box", host: "b.tunnel.example").utf8))
        try write(catalog, [EnvironmentRegistration(environmentId: "env-2", label: "Box", httpBaseURL: URL(string: "http://10.0.0.3:3773")!),
                            EnvironmentRegistration(environmentId: "env-9", label: "Paired", httpBaseURL: URL(string: "http://10.0.0.9:3773")!)])
        try catalog.addRelay(a, accountId: "user_1")
        try catalog.addRelay(b, accountId: "user_1")
        // A relay token in the cache, so sign-out has something to drop.
        relayHTTP.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        relayHTTP.on("POST", "/v1/environments/env-1/connect", 200, connectJSON())
        _ = try await account.relay.connect(environmentId: "env-1", relayJWT: fakeJWT(sub: "user_1"))

        let result = try await account.signOut(catalog: catalog)
        #expect(result.removed == ["env-1"])
        #expect(result.updated.map(\.environmentId) == ["env-2"])
        #expect(catalog.load().map(\.environmentId) == ["env-2", "env-9"])
        #expect(catalog.load().allSatisfy { $0.relay == nil })
        #expect(catalog.load()[0].routes.map(\.absoluteString) == ["http://10.0.0.3:3773"])
        #expect(clerkHTTP.calls.last == "POST /v1/client/sessions/sess_1/remove")
        #expect(store.current == nil)
        #expect(await account.account() == nil)
        // The relay token went with the session: the next connect exchanges again.
        _ = try? await account.relay.connect(environmentId: "env-1", relayJWT: fakeJWT(sub: "user_1"))
        #expect(relayHTTP.requests("/v1/client/dpop-token").count == 2)
    }

    @Test func deregisterSendsTheBearerDelete() async throws {
        relayHTTP.on("DELETE", "/v1/client/environment-links/env-1", 200, #"{"ok":true}"#)
        try await account(MemoryClerkStore(ClerkFixture.signedIn)).deregister(environmentId: "env-1")
        let r = try #require(relayHTTP.requests("/v1/client/environment-links/env-1").first)
        #expect(r.httpMethod == "DELETE" && header(r, "Authorization")?.hasPrefix("Bearer ") == true)
    }

    /// Writes registrations without tokens (the catalog's `add` needs the Keychain).
    private func write(_ catalog: EnvironmentCatalog, _ all: [EnvironmentRegistration]) throws {
        try FileManager.default.createDirectory(at: catalog.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(EnvironmentCatalog.Document(environments: all)).write(to: catalog.file)
    }
}
