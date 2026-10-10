import CryptoKit
import Foundation
import Testing
import T3Protocol
@testable import T3Client

// T3 Connect client tests. No network: every request goes to `FakeHTTP`. Response shapes come
// from packages/contracts/src/relay.ts and auth.ts (cited per fixture). Tokens here are fakes.

/// Plays the relay and the environment. Records every request.
final class FakeHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private var routes: [String: [(status: Int, body: String)]] = [:]
    private var failures: [String: URLError] = [:]

    var requests: [URLRequest] { lock.withLock { log } }
    func requests(_ path: String) -> [URLRequest] { requests.filter { $0.url?.path == path } }

    /// Queue responses for `METHOD path`; the last one repeats.
    func on(_ method: String, _ path: String, _ status: Int = 200, _ body: String) {
        lock.withLock { routes["\(method) \(path)", default: []].append((status, body)) }
    }

    func fail(_ method: String, _ path: String, _ error: URLError) {
        lock.withLock { failures["\(method) \(path)"] = error }
    }

    var send: HTTPSend {
        { [self] request in
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            let result: Result<(Int, String), URLError> = lock.withLock {
                log.append(request)
                if let e = failures[key] { return .failure(e) }
                guard var queue = routes[key], let first = queue.first else { return .success((599, "")) }
                if queue.count > 1 { queue.removeFirst(); routes[key] = queue }
                return .success(first)
            }
            let (status, body) = try result.get()
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_760_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

final class FakeCloud: CloudTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var subject: String? = "user_1"
    func signIn(_ sub: String?) { lock.withLock { subject = sub } }
    func relaySessionJWT() async throws -> String {
        guard let sub = lock.withLock({ subject }) else { throw CloudSessionError.signedOut }
        return fakeJWT(sub: sub)
    }
}

/// An unsigned JWT-shaped string. The relay would reject it; the client only reads `sub`.
func fakeJWT(sub: String) -> String {
    Base64URL.encode(Data(#"{"alg":"RS256"}"#.utf8)) + "." + Base64URL.encode(Data(#"{"sub":"\#(sub)","aud":"t3-code-relay"}"#.utf8)) + ".c2ln"
}

func header(_ r: URLRequest, _ name: String) -> String? { r.value(forHTTPHeaderField: name) }
func bodyString(_ r: URLRequest) -> String { r.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }

// MARK: Independent DPoP verifier, ported from packages/shared/src/dpop.ts:113-199

enum ProofCheck: Equatable { case ok(thumbprint: String), fail(String) }

func verifyProof(_ proof: String, method: String, url: String, now: Int, accessToken: String? = nil) -> ProofCheck {
    let parts = proof.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return .fail("malformed_proof") }
    guard let h = Base64URL.decode(parts[0]), let p = Base64URL.decode(parts[1]), let sig = Base64URL.decode(parts[2]),
          let header = try? JSONSerialization.jsonObject(with: h) as? [String: Any],
          let payload = try? JSONSerialization.jsonObject(with: p) as? [String: Any],
          header["typ"] as? String == "dpop+jwt", header["alg"] as? String == "ES256",
          let jwk = header["jwk"] as? [String: Any], jwk["d"] == nil, jwk["kty"] as? String == "EC",
          jwk["crv"] as? String == "P-256", let x = jwk["x"] as? String, let y = jwk["y"] as? String,
          let htm = payload["htm"] as? String, let htu = payload["htu"] as? String,
          let jti = payload["jti"] as? String, !jti.isEmpty, let iat = payload["iat"] as? Int
    else { return .fail("malformed_proof") }
    // Thumbprint the RFC 7638 way, with Foundation's sorted keys as the independent encoder.
    let canonical = try! JSONSerialization.data(withJSONObject: ["crv": "P-256", "kty": "EC", "x": x, "y": y],
                                                options: [.sortedKeys, .withoutEscapingSlashes])
    let thumbprint = Base64URL.encode(Data(SHA256.hash(data: canonical)))
    guard htm.uppercased() == method.uppercased() else { return .fail("method_mismatch") }
    guard htu == url else { return .fail("url_mismatch") }
    if let accessToken {
        let ath = Base64URL.encode(Data(SHA256.hash(data: Data(accessToken.utf8))))
        guard payload["ath"] as? String == ath else { return .fail("access_token_hash_mismatch") }
    }
    guard let xb = Base64URL.decode(x), let yb = Base64URL.decode(y), xb.count == 32, yb.count == 32,
          let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + xb + yb),
          sig.count == 64, let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig),
          key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
    else { return .fail("invalid_signature") }
    guard iat <= now + 5, now - iat <= 300 else { return .fail("time_window") }
    return .ok(thumbprint: thumbprint)
}

struct DPoPTests {
    /// RFC 9449 section 4.1 example key and its `jkt` from section 6.1.
    @Test func thumbprintMatchesRFC9449Vector() {
        let jwk = DPoPPublicJWK(x: "l8tFrhx-34tV3hRICRDY9zCkDlpBhF42UQUfWVAWBFs", y: "9VE4jf_Ok_o64zbTTlcuNJajHmt6v9TDVrU0CdvGRDA")
        #expect(jwk.thumbprint == "0ZcOCORZNYy-DWpqq30jZyJGHTN0d2HglBV3uiguA4I")
    }

    /// RFC 9449 section 7.1: the `ath` of the example access token.
    @Test func accessTokenHashMatchesRFC9449Vector() {
        #expect(DPoP.accessTokenHash("Kz~8mXK1EalYznwH-LC-1fBAo.4Ljp~zsPE_NeO.gxU") == "fUHyO2r2Z3DZ53EsNrWBb0xWXoaNy59IiKCAqksmQEo")
    }

    @Test func proofHasT3HeaderAndClaimsAndVerifies() throws {
        let key = try SoftwareDPoPKey()
        let now = Date(timeIntervalSince1970: 1_760_000_000.9)
        let proof = try DPoP.proof(method: "post", url: URL(string: "https://relay.t3.codes/v1/environments/env-1/connect?x=1#y")!,
                                   accessToken: "relay-token", key: key, now: now, jti: "11111111-2222-4333-8444-555555555555")
        let parts = proof.split(separator: ".").map(String.init)
        let jwk = key.publicJWK
        // Exact bytes, in the member order T3's schemas encode (dpop.ts:38-55).
        #expect(String(decoding: Base64URL.decode(parts[0])!, as: UTF8.self)
            == #"{"typ":"dpop+jwt","alg":"ES256","jwk":{"kty":"EC","crv":"P-256","x":"\#(jwk.x)","y":"\#(jwk.y)"}}"#)
        #expect(String(decoding: Base64URL.decode(parts[1])!, as: UTF8.self)
            == #"{"htm":"POST","htu":"https://relay.t3.codes/v1/environments/env-1/connect","jti":"11111111-2222-4333-8444-555555555555","iat":1760000000,"ath":"\#(DPoP.accessTokenHash("relay-token"))"}"#)
        #expect(!proof.contains("="))
        #expect(verifyProof(proof, method: "POST", url: "https://relay.t3.codes/v1/environments/env-1/connect",
                            now: 1_760_000_000, accessToken: "relay-token") == .ok(thumbprint: key.thumbprint))
        // The verifier really checks: a wrong token, URL or clock fails.
        #expect(verifyProof(proof, method: "POST", url: "https://relay.t3.codes/v1/environments/env-1/connect",
                            now: 1_760_000_000, accessToken: "other") == .fail("access_token_hash_mismatch"))
        #expect(verifyProof(proof, method: "GET", url: "https://relay.t3.codes/v1/environments/env-1/connect", now: 1_760_000_000) == .fail("method_mismatch"))
        #expect(verifyProof(proof, method: "POST", url: "https://relay.t3.codes/v1/environments/env-1/connect", now: 1_760_000_301) == .fail("time_window"))
        let tampered = parts[0] + "." + Base64URL.encode(Data(#"{"htm":"POST","htu":"https://relay.t3.codes/v1/environments/env-1/connect","jti":"x","iat":1760000000}"#.utf8)) + "." + parts[2]
        #expect(verifyProof(tampered, method: "POST", url: "https://relay.t3.codes/v1/environments/env-1/connect", now: 1_760_000_000) == .fail("invalid_signature"))
    }

    @Test func proofWithoutTokenOmitsAthAndUsesFreshJti() throws {
        let key = try SoftwareDPoPKey()
        let url = URL(string: "https://tunnel.example/oauth/token")!
        let a = try DPoP.proof(method: "POST", url: url, key: key)
        let b = try DPoP.proof(method: "POST", url: url, key: key)
        let payload = { (p: String) in String(decoding: Base64URL.decode(String(p.split(separator: ".")[1]))!, as: UTF8.self) }
        #expect(!payload(a).contains("ath"))
        #expect(payload(a) != payload(b))
        #expect(verifyProof(a, method: "POST", url: "https://tunnel.example/oauth/token", now: Int(Date().timeIntervalSince1970)) == .ok(thumbprint: key.thumbprint))
    }

    @Test func htuFollowsWHATWGSerialization() throws {
        #expect(try DPoP.htu(URL(string: "HTTPS://Relay.T3.Codes:443/v1/x?y=1#f")!) == "https://relay.t3.codes/v1/x")
        #expect(try DPoP.htu(URL(string: "http://192.168.1.5:3773")!) == "http://192.168.1.5:3773/")
        #expect(try DPoP.htu(URL(string: "http://host.local:80/api/auth/websocket-ticket")!) == "http://host.local/api/auth/websocket-ticket")
        #expect(try DPoP.htu(URL(string: "http://[FD7A:115C:A1E0::1]:3773/oauth/token")!) == "http://[fd7a:115c:a1e0::1]:3773/oauth/token")
    }

    @Test func thumbprintIsRFC7638OverTheEncodedKey() throws {
        let key = try SoftwareDPoPKey()
        let canonical = try JSONSerialization.data(withJSONObject: ["kty": "EC", "crv": "P-256", "x": key.publicJWK.x, "y": key.publicJWK.y],
                                                   options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(key.thumbprint == Base64URL.encode(Data(SHA256.hash(data: canonical))))
        #expect(Base64URL.decode(key.publicJWK.x)?.count == 32)
    }

    /// The installation key survives a reload and signs proofs the verifier accepts.
    @Test func keyStoreRoundTrip() throws {
        let store = DPoPKeyStore(service: "dev.candywrapper.t3.test-dpop-\(UUID().uuidString)")
        let key: any DPoPSigningKey
        do {
            key = try store.loadOrCreate()
        } catch let e as CredentialStore.KeychainError {
            print("keychain unavailable, skipping: \(e)")
            return
        }
        defer { try? store.delete() }
        if SecureEnclave.isAvailable { #expect(key is SecureEnclaveDPoPKey) }
        let again = try store.loadOrCreate()
        #expect(again.publicJWK == key.publicJWK)
        let proof = try DPoP.proof(method: "POST", url: URL(string: "https://relay.t3.codes/v1/client/dpop-token")!, key: again)
        #expect(verifyProof(proof, method: "POST", url: "https://relay.t3.codes/v1/client/dpop-token",
                            now: Int(Date().timeIntervalSince1970)) == .ok(thumbprint: key.thumbprint))
        try store.delete()
        #expect(try store.load() == nil)
    }
}

// MARK: Fixtures, shaped like packages/contracts/src/relay.ts

/// `RelayDpopAccessTokenResponse` (relay.ts:771-777).
func relayTokenJSON(_ token: String, scope: String = "environment:connect") -> String {
    #"{"access_token":"\#(token)","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"DPoP","expires_in":1800,"scope":"\#(scope)"}"#
}

let tunnel = #"{"httpBaseUrl":"https://prod-abc.tunnel.example/","wsBaseUrl":"wss://prod-abc.tunnel.example/","providerKind":"cloudflare_tunnel"}"#

/// `RelayEnvironmentConnectResponse` (relay.ts:815-820).
func connectJSON(_ env: String = "env-1", credential: String = "minted-1") -> String {
    #"{"environmentId":"\#(env)","endpoint":\#(tunnel),"credential":"\#(credential)","expiresAt":"2025-10-09T08:55:00.000Z"}"#
}

/// `ExecutionEnvironmentDescriptor` subset (contracts/src/environment.ts).
func descriptorJSON(_ env: String = "env-1") -> String {
    #"{"environmentId":"\#(env)","label":"Studio","serverVersion":"0.0.46","orchestrationProtocolVersion":2,"capabilities":{"repositoryIdentity":true}}"#
}

/// `/oauth/token` with a DPoP proof (contracts/src/auth.ts:310-316, EnvironmentAuth.ts:908-918).
func envTokenJSON(_ token: String) -> String {
    #"{"access_token":"\#(token)","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"DPoP","expires_in":3600,"scope":"orchestration:read orchestration:operate"}"#
}

let ticketJSON = #"{"ticket":"dGlja2V0.c2ln","expiresAt":"2025-10-09T09:00:00.000Z"}"#

struct RelayClientTests {
    let http = FakeHTTP()
    let clock = FakeClock()
    let key = try! SoftwareDPoPKey()
    var relay: RelayClient { try! RelayClient(key: key, send: http.send, now: { [clock] in clock.now }) }

    @Test func connectExchangesTheJWTThenConnectsWithAth() async throws {
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        http.on("POST", "/v1/environments/env-1/connect", 200, connectJSON())
        let relay = relay
        let jwt = fakeJWT(sub: "user_1")
        let result = try await relay.connect(environmentId: "env-1", relayJWT: jwt)
        #expect(result.credential == "minted-1")
        #expect(result.endpoint.providerKind == "cloudflare_tunnel")

        let exchange = try #require(http.requests("/v1/client/dpop-token").first)
        #expect(exchange.url?.absoluteString == "https://relay.t3.codes/v1/client/dpop-token")
        #expect(header(exchange, "Content-Type") == "application/x-www-form-urlencoded")
        #expect(header(exchange, "Authorization") == nil)
        #expect(bodyString(exchange) == "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange"
            + "&subject_token=\(jwt)&subject_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Ajwt"
            + "&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token"
            + "&resource=https%3A%2F%2Frelay.t3.codes&scope=environment%3Aconnect&client_id=t3-web")
        #expect(verifyProof(header(exchange, "DPoP")!, method: "POST", url: "https://relay.t3.codes/v1/client/dpop-token",
                            now: Int(clock.now.timeIntervalSince1970)) == .ok(thumbprint: key.thumbprint))
        #expect(!String(decoding: Base64URL.decode(String(header(exchange, "DPoP")!.split(separator: ".")[1]))!, as: UTF8.self).contains("ath"))

        let connect = try #require(http.requests("/v1/environments/env-1/connect").first)
        #expect(header(connect, "Authorization") == "DPoP rat-1")
        #expect(verifyProof(header(connect, "DPoP")!, method: "POST", url: "https://relay.t3.codes/v1/environments/env-1/connect",
                            now: Int(clock.now.timeIntervalSince1970), accessToken: "rat-1") == .ok(thumbprint: key.thumbprint))
        #expect(bodyString(connect) == #"{"clientKeyThumbprint":"\#(key.thumbprint)"}"#)
    }

    @Test func relayTokenIsReusedForCoveredScopesUntilFiveSecondsBeforeExpiry() async throws {
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-2", scope: "environment:status environment:connect"))
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-3"))
        http.on("POST", "/v1/environments/env-1/connect", 200, connectJSON())
        http.on("POST", "/v1/environments/env-1/status", 200,
                #"{"environmentId":"env-1","endpoint":\#(tunnel),"status":"offline","checkedAt":"2025-10-09T08:53:00.000Z","offlineReason":"tunnel_released"}"#)
        let relay = relay
        let jwt = fakeJWT(sub: "user_1")
        _ = try await relay.connect(environmentId: "env-1", relayJWT: jwt)
        _ = try await relay.connect(environmentId: "env-1", relayJWT: jwt)
        #expect(http.requests("/v1/client/dpop-token").count == 1)
        // A connect-only token does not cover status.
        let status = try await relay.environmentStatus(environmentId: "env-1", relayJWT: jwt)
        #expect(!status.isOnline)
        #expect(status.offlineMessage?.hasPrefix("Offline for a while") == true)
        #expect(http.requests("/v1/client/dpop-token").count == 2)
        #expect(bodyString(http.requests("/v1/client/dpop-token")[1]).contains("scope=environment%3Astatus+environment%3Aconnect"))
        clock.advance(1800 - 5)
        _ = try await relay.connect(environmentId: "env-1", relayJWT: jwt)
        #expect(http.requests("/v1/client/dpop-token").count == 3)
        // Another account never sees the first account's token.
        _ = try await relay.connect(environmentId: "env-1", relayJWT: fakeJWT(sub: "user_2"))
        #expect(http.requests("/v1/client/dpop-token").count == 4)
    }

    @Test func refusedRelayTokenIsReplacedOnce() async throws {
        let refused = #"{"_tag":"RelayAuthInvalidError","code":"auth_invalid","reason":"invalid_bearer","traceId":"t1"}"#
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-2"))
        http.on("POST", "/v1/environments/env-1/connect", 401, refused)
        http.on("POST", "/v1/environments/env-1/connect", 200, connectJSON())
        let result = try await relay.connect(environmentId: "env-1", relayJWT: fakeJWT(sub: "user_1"))
        #expect(result.environmentId == "env-1")
        #expect(http.requests("/v1/environments/env-1/connect").map { header($0, "Authorization") } == ["DPoP rat-1", "DPoP rat-2"])

        let http2 = FakeHTTP()
        http2.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        http2.on("POST", "/v1/environments/env-1/connect", 401, refused)
        let relay2 = try RelayClient(key: key, send: http2.send)
        await #expect(throws: RelayError.self) { try await relay2.connect(environmentId: "env-1", relayJWT: fakeJWT(sub: "user_1")) }
        #expect(http2.requests("/v1/environments/env-1/connect").count == 2)
    }

    @Test func unexpectedScopeIsBlocked() async throws {
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1", scope: "environment:connect environment:status"))
        do {
            _ = try await relay.connect(environmentId: "env-1", relayJWT: fakeJWT(sub: "user_1"))
            Issue.record("expected a failure")
        } catch let e as RelayError {
            #expect(e.failure == .blocked(.permission, "Relay granted unexpected DPoP access token scopes."))
        }
        #expect(http.requests("/v1/environments/env-1/connect").isEmpty)
    }

    @Test func listAndDeregisterUseTheBearer() async throws {
        // RelayListEnvironmentsResponse (relay.ts:701-711).
        http.on("GET", "/v1/environments", 200,
                #"{"environments":[{"environmentId":"env-1","label":"Studio","endpoint":\#(tunnel),"linkedAt":"2025-10-01T10:00:00.000Z"}]}"#)
        http.on("DELETE", "/v1/client/environment-links/env 1", 200, #"{"ok":true}"#)
        let relay = relay
        let list = try await relay.listEnvironments(bearer: "oauth-or-jwt")
        #expect(list == [RelayEnvironmentRecord(environmentId: "env-1", label: "Studio",
                                                endpoint: RelayEndpoint(httpBaseUrl: "https://prod-abc.tunnel.example/",
                                                                        wsBaseUrl: "wss://prod-abc.tunnel.example/", providerKind: "cloudflare_tunnel"),
                                                linkedAt: "2025-10-01T10:00:00.000Z")])
        #expect(header(http.requests[0], "Authorization") == "Bearer oauth-or-jwt")
        #expect(header(http.requests[0], "DPoP") == nil)
        try await relay.deregister(environmentId: "env 1", bearer: "oauth-or-jwt")
        let delete = http.requests[1]
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.absoluteString == "https://relay.t3.codes/v1/client/environment-links/env%201")
        #expect(header(delete, "Authorization") == "Bearer oauth-or-jwt")
    }

    @Test func statusIsValidatedAgainstItsRecord() throws {
        let endpoint = RelayEndpoint(httpBaseUrl: "https://a/", wsBaseUrl: "wss://a/", providerKind: "cloudflare_tunnel")
        let record = RelayEnvironmentRecord(environmentId: "env-1", label: "A", endpoint: endpoint, linkedAt: "x")
        var status = RelayEnvironmentStatus(environmentId: "env-1", endpoint: endpoint, status: "online", checkedAt: "x")
        #expect(status.validate(against: record) == nil)
        status.endpoint.wsBaseUrl = "wss://b/"
        #expect(status.validate(against: record) == .blocked(.configuration, "Relay returned status for a different environment endpoint."))
    }

    @Test func relayURLMustBeAnHTTPSOrigin() {
        #expect(throws: RelayError.self) { try RelayClient(relayURL: URL(string: "http://relay.t3.codes")!, key: key) }
        #expect(throws: RelayError.self) { try RelayClient(relayURL: URL(string: "https://relay.t3.codes/v1")!, key: key) }
        #expect((try? RelayClient(relayURL: URL(string: "https://Relay.T3.codes/")!, key: key))?.origin == "https://relay.t3.codes")
    }
}

struct RelayErrorMappingTests {
    func error(_ status: Int, _ json: String, _ action: RelayError.Action = .connect) -> RelayError {
        let body = try! JSONDecoder().decode(RelayErrorBody.self, from: Data(json.utf8))
        return RelayError(.relay(status: status, body: body), action: action)
    }

    /// Bodies as `Schema.TaggedError` encodes them (relay.ts:410-593); classes per connection/errors.ts:37-77.
    @Test func protectedErrorsMapLikeT3() {
        let cases: [(RelayError, ConnectionFailure)] = [
            (error(401, #"{"_tag":"RelayAuthInvalidError","code":"auth_invalid","reason":"invalid_bearer","traceId":"t"}"#),
             .blocked(.authentication, "Relay rejected the cloud session token.")),
            (error(401, #"{"_tag":"RelayAuthInvalidError","code":"auth_invalid","reason":"invalid_dpop","dpopFailureReason":"time_window","traceId":"t"}"#),
             .blocked(.authentication, "Relay rejected the DPoP proof. Hint: Check that automatic date and time is enabled on both devices, then try again.")),
            (error(401, #"{"_tag":"RelayAuthInvalidError","code":"auth_invalid","reason":"invalid_dpop","traceId":"t"}"#),
             .blocked(.authentication, "Relay rejected the DPoP proof. \(DPoPHint.unknown)")),
            (error(403, #"{"_tag":"RelayEnvironmentConnectNotAuthorizedError","code":"environment_connect_not_authorized","reason":"environment_link_not_found","traceId":"t"}"#),
             .blocked(.permission, "Relay has no active link for this environment. The environment server may not have re-established its link yet.")),
            (error(403, #"{"_tag":"RelayEnvironmentConnectNotAuthorizedError","code":"environment_connect_not_authorized","traceId":"t"}"#),
             .blocked(.permission, "Relay rejected the environment connection request.")),
            (error(502, #"{"_tag":"RelayEnvironmentEndpointUnavailableError","code":"environment_endpoint_unavailable","reason":"endpoint_request_failed","traceId":"t"}"#),
             .transient("Relay could not reach the environment endpoint (endpoint_request_failed).")),
            (error(504, #"{"_tag":"RelayEnvironmentEndpointTimedOutError","code":"environment_endpoint_timed_out","traceId":"t"}"#),
             .transient("Relay timed out while contacting the environment endpoint.")),
            (error(403, #"{"_tag":"RelayEnvironmentLinkLimitExceededError","code":"environment_link_limit_exceeded","maxTunnels":3,"traceId":"t"}"#),
             .blocked(.permission, "Relay refused the link: this account already has its maximum of 3 managed tunnels. Unlink an environment to free one up.")),
            (error(500, #"{"_tag":"RelayInternalError","code":"internal_error","reason":"database_unavailable","traceId":"t"}"#),
             .transient("Relay encountered an internal error (database_unavailable).")),
        ]
        for (e, expected) in cases { #expect(e.failure == expected) }
    }

    @Test func transportFailuresAreTransientWithTheNetworkHint() async throws {
        let http = FakeHTTP()
        http.fail("GET", "/v1/environments", URLError(.timedOut))
        let relay = try RelayClient(key: SoftwareDPoPKey(), send: http.send)
        do {
            _ = try await relay.listEnvironments(bearer: "b")
            Issue.record("expected a failure")
        } catch let e as RelayError {
            #expect(e.failure == .transient("Relay environment listing timed out. \(t3ConnectNetworkHint)"))
        }
        // A 401 with no tagged body (the relay's bare Unauthorized) is not a RelayProtectedError.
        let bare = RelayError(.relay(status: 401, body: nil), action: .exchangeToken)
        #expect(bare.failure == .transient("Could not exchange relay DPoP access token."))
    }

    @Test func environmentDPoPFailuresCarryTheHint() {
        // EnvironmentAuthInvalidError with a DPoP category (apps/server/src/auth/http.ts:366-376).
        let body = try! JSONDecoder().decode(EnvironmentHTTPErrorBody.self, from: Data(
            #"{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"invalid_credential","dpopFailureReason":"time_window","traceId":"t"}"#.utf8))
        #expect(T3Connect.failure(for: EnvironmentHTTPError.status(401, body))
            == .blocked(.authentication, "The environment credential is invalid. \(DPoPHint.clock)"))
        #expect(T3Connect.failure(for: CloudSessionError.signedOut) == .blocked(.authentication, "Sign in to T3 Connect."))
        #expect(T3Connect.failure(for: T3ConnectError.environmentMismatch(expected: "a", actual: "b"))
            == .blocked(.configuration, "Connected environment b does not match a."))
    }
}

struct T3ConnectAuthorizerTests {
    let http = FakeHTTP()
    let clock = FakeClock()
    let cloud = FakeCloud()
    let key = try! SoftwareDPoPKey()

    func makeAuthorizer() throws -> T3ConnectAuthorizer {
        let relay = try RelayClient(key: key, send: http.send, now: { [clock] in clock.now })
        return T3ConnectAuthorizer(relay: relay, tokens: cloud, identity: ClientIdentity(appVersion: "1.2.3"),
                                   send: http.send, now: { [clock] in clock.now })
    }

    func serveHappyPath() {
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        http.on("POST", "/v1/environments/env-1/connect", 200, connectJSON(credential: "minted-1"))
        http.on("POST", "/v1/environments/env-1/connect", 200, connectJSON(credential: "minted-2"))
        http.on("GET", "/.well-known/t3/environment", 200, descriptorJSON())
        http.on("POST", "/oauth/token", 200, envTokenJSON("eat-1"))
        http.on("POST", "/oauth/token", 200, envTokenJSON("eat-2"))
        http.on("POST", "/api/auth/websocket-ticket", 200, ticketJSON)
    }

    @Test func fullSequenceBuildsTheRelaySocketURL() async throws {
        serveHappyPath()
        let socket = try await makeAuthorizer().authorizeSocket(environmentId: "env-1")
        #expect(socket.url.absoluteString == "wss://prod-abc.tunnel.example/ws?wsTicket=dGlja2V0.c2ln&clientSurface=desktop"
            + "&clientAppVersion=1.2.3&clientDeviceType=desktop&clientOs=macOS&connectionMethod=relay&orchestrationProtocol=2")
        #expect(socket.token.accessToken == "eat-1")
        #expect(socket.token.label == "Studio")
        #expect(http.requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "POST /v1/client/dpop-token", "POST /v1/environments/env-1/connect", "GET /.well-known/t3/environment",
            "POST /oauth/token", "POST /api/auth/websocket-ticket",
        ])
        let now = Int(clock.now.timeIntervalSince1970)
        let exchange = try #require(http.requests("/oauth/token").first)
        #expect(exchange.url?.absoluteString == "https://prod-abc.tunnel.example/oauth/token")
        #expect(header(exchange, "Authorization") == nil)
        #expect(verifyProof(header(exchange, "DPoP")!, method: "POST", url: "https://prod-abc.tunnel.example/oauth/token", now: now)
            == .ok(thumbprint: key.thumbprint))
        #expect(bodyString(exchange) == "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange&subject_token=minted-1"
            + "&subject_token_type=urn%3At3%3Aparams%3Aoauth%3Atoken-type%3Aenvironment-bootstrap"
            + "&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token"
            + "&client_label=CandyWrapper&client_device_type=desktop&client_os=macOS")
        let ticket = try #require(http.requests("/api/auth/websocket-ticket").first)
        #expect(header(ticket, "Authorization") == "DPoP eat-1")
        #expect(verifyProof(header(ticket, "DPoP")!, method: "POST", url: "https://prod-abc.tunnel.example/api/auth/websocket-ticket",
                            now: now, accessToken: "eat-1") == .ok(thumbprint: key.thumbprint))
    }

    @Test func tokenRenewsSixtySecondsBeforeExpiry() async throws {
        serveHappyPath()
        let authorizer = try makeAuthorizer()
        let first = try await authorizer.token(environmentId: "env-1")
        #expect(first.expiresAt == clock.now.addingTimeInterval(3600))
        #expect(first.renewAt == clock.now.addingTimeInterval(3540))
        clock.advance(3539)
        #expect(try await authorizer.token(environmentId: "env-1").accessToken == "eat-1")
        clock.advance(1)
        #expect(try await authorizer.token(environmentId: "env-1").accessToken == "eat-2")
        // The relay token (30 min) had expired too, so the relay saw a second exchange.
        #expect(http.requests("/v1/environments/env-1/connect").count == 2)
        #expect(http.requests("/v1/client/dpop-token").count == 2)
    }

    @Test func concurrentCallersShareOneRenewal() async throws {
        serveHappyPath()
        let authorizer = try makeAuthorizer()
        async let a = authorizer.token(environmentId: "env-1")
        async let b = authorizer.token(environmentId: "env-1")
        let (ta, tb) = try await (a, b)
        #expect(ta.accessToken == tb.accessToken)
        #expect(http.requests("/v1/environments/env-1/connect").count == 1)
    }

    @Test func refusedCachedTokenIsReplaced() async throws {
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        http.on("POST", "/v1/environments/env-1/connect", 200, connectJSON(credential: "minted-1"))
        http.on("POST", "/v1/environments/env-1/connect", 200, connectJSON(credential: "minted-2"))
        http.on("GET", "/.well-known/t3/environment", 200, descriptorJSON())
        http.on("POST", "/oauth/token", 200, envTokenJSON("eat-1"))
        http.on("POST", "/oauth/token", 200, envTokenJSON("eat-2"))
        http.on("POST", "/api/auth/websocket-ticket", 401,
                #"{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"invalid_credential","traceId":"t"}"#)
        http.on("POST", "/api/auth/websocket-ticket", 200, ticketJSON)
        let authorizer = try makeAuthorizer()
        _ = try await authorizer.token(environmentId: "env-1")
        let socket = try await authorizer.authorizeSocket(environmentId: "env-1")
        #expect(socket.token.accessToken == "eat-2")
        #expect(http.requests("/api/auth/websocket-ticket").map { header($0, "Authorization") } == ["DPoP eat-1", "DPoP eat-2"])
        #expect(http.requests("/api/auth/websocket-ticket")[0].timeoutInterval == 3)
    }

    @Test func headersForLaterCallsSignThatURL() async throws {
        serveHappyPath()
        let authorizer = try makeAuthorizer()
        let url = URL(string: "https://prod-abc.tunnel.example/api/orchestration/shell")!
        let headers = try await authorizer.authorizationHeaders(environmentId: "env-1", method: "GET", url: url)
        #expect(headers["Authorization"] == "DPoP eat-1")
        #expect(verifyProof(headers["DPoP"]!, method: "GET", url: url.absoluteString, now: Int(clock.now.timeIntervalSince1970),
                            accessToken: "eat-1") == .ok(thumbprint: key.thumbprint))
    }

    @Test func accountSwitchDropsCachedTokens() async throws {
        serveHappyPath()
        let authorizer = try makeAuthorizer()
        #expect(try await authorizer.token(environmentId: "env-1").accountId == "user_1")
        cloud.signIn("user_2")
        let second = try await authorizer.token(environmentId: "env-1")
        #expect(second.accountId == "user_2")
        #expect(http.requests("/v1/environments/env-1/connect").count == 2)
        cloud.signIn(nil)
        await #expect(throws: CloudSessionError.signedOut) { try await authorizer.token(environmentId: "env-1") }
    }

    @Test func relayEndpointForAnotherEnvironmentIsRefused() async throws {
        http.on("POST", "/v1/client/dpop-token", 200, relayTokenJSON("rat-1"))
        http.on("POST", "/v1/environments/env-1/connect", 200, connectJSON("env-2"))
        let authorizer = try makeAuthorizer()
        await #expect(throws: T3ConnectError.environmentMismatch(expected: "env-1", actual: "env-2")) {
            try await authorizer.token(environmentId: "env-1")
        }
        #expect(http.requests("/oauth/token").isEmpty)
    }

    @Test func learnedRouteChecksItsDescriptorAndSignsItsOwnURL() async throws {
        serveHappyPath()
        let authorizer = try makeAuthorizer()
        let lan = ConnectRoutes.learned(from: ["http://192.168.1.20:3773"])[0]
        let socket = try await authorizer.authorizeSocket(environmentId: "env-1", directEndpoint: lan)
        #expect(socket.url.absoluteString.hasPrefix("ws://192.168.1.20:3773/ws?wsTicket="))
        #expect(socket.url.absoluteString.contains("connectionMethod=relay"))
        let ticket = try #require(http.requests("/api/auth/websocket-ticket").first)
        #expect(ticket.url?.absoluteString == "http://192.168.1.20:3773/api/auth/websocket-ticket")
        #expect(verifyProof(header(ticket, "DPoP")!, method: "POST", url: "http://192.168.1.20:3773/api/auth/websocket-ticket",
                            now: Int(clock.now.timeIntervalSince1970), accessToken: "eat-1") == .ok(thumbprint: key.thumbprint))
        // The descriptor at the LAN address was checked before any credential went there.
        #expect(http.requests.first?.url?.absoluteString == "http://192.168.1.20:3773/.well-known/t3/environment")
    }
}

struct ConnectRoutesTests {
    @Test func learnedRoutesDropLoopbackAndRankLikeT3() {
        let routes = ConnectRoutes.learned(from: [
            "https://studio.example.com", "http://100.101.102.103:3773/", "http://127.0.0.1:3773",
            "http://192.168.1.20:3773", "http://192.168.1.20:3773/again", "http://[fe80::1]:3773", "not a url",
        ])
        #expect(routes.map(\.httpBaseUrl) == ["http://192.168.1.20:3773/", "http://[fe80::1]:3773/",
                                              "http://100.101.102.103:3773/", "https://studio.example.com/"])
        #expect(routes.map(\.kind) == [.lan, .lan, .tailnet, .public])
        #expect(routes[3].wsBaseUrl == "wss://studio.example.com/")
    }

    @Test func hostKinds() {
        #expect(ConnectRoutes.kind(host: "localhost") == .loopback)
        #expect(ConnectRoutes.kind(host: "mac.tail1234.ts.net") == .tailnet)
        #expect(ConnectRoutes.kind(host: "fd7a:115c:a1e0::5") == .tailnet)
        #expect(ConnectRoutes.kind(host: "10.0.0.2") == .lan)
        #expect(ConnectRoutes.kind(host: "172.20.1.1") == .lan)
        #expect(ConnectRoutes.kind(host: "studio.local") == .lan)
        #expect(ConnectRoutes.kind(host: "studio") == .lan)
        #expect(ConnectRoutes.kind(host: "::ffff:192.168.0.1") == .lan)
        #expect(ConnectRoutes.kind(host: "8.8.8.8") == .public)
        #expect(ConnectRoutes.kind(host: "2001:db8::1") == .public)
    }
}
