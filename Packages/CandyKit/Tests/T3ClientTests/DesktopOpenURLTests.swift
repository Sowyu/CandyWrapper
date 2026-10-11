import Foundation
import Testing
@testable import T3Client

/// Cases from packages/shared/src/codexAuthHandoff.test.ts and providerAuthReturnUrl.test.ts, plus the pairing forms.
struct DesktopOpenURLTests {
    static let state = String(repeating: "a", count: 43)
    static let authorizationUrl: String = {
        var c = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: "dynamic_agent_client"), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: "http://127.0.0.1:54213/auth/callback"), .init(name: "state", value: state),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: String(repeating: "b", count: 43)),
        ]
        return c.string!
    }()
    static let input = CodexAuthHandoff(authorizationUrl: authorizationUrl, returnUrl: "https://app.t3.codes/welcome#agents:remote-environment",
                                        environmentId: "remote-environment", instanceId: "work-codex", flowId: "flow-one")
    static let callbackUrl = "http://127.0.0.1:54213/auth/callback?state=\(state)&code=one-time-code&client_id=oaiapp_test"

    @Test func returnDestinations() {
        for scheme in ["t3code", "t3code-dev"] {
            #expect(ProviderAuthReturn.sanitize("\(scheme)://app/welcome?code=secret#agents:machine-id")?.url == "\(scheme)://app/welcome#agents:machine-id")
            #expect(ProviderAuthReturn.sanitize("\(scheme)://app/settings/providers?instanceId=work&code=secret")?.url
                    == "\(scheme)://app/settings/providers?instanceId=work")
        }
        for bad in ["t3code://attacker/welcome", "t3code://app:123/welcome", "t3code://app/auth/callback", "t3code://user@ app/welcome",
                    "t3code://app/welcome/../evil", "https://attacker.example/welcome", "file:///welcome", "javascript:alert(1)",
                    "t3code://app/settings/../welcome"] {
            #expect(ProviderAuthReturn.sanitize(bad) == nil, "\(bad)")
        }
        #expect(ProviderAuthReturn.sanitize("http://localhost:5173/settings?project=p")?.url == "http://localhost:5173/settings?project=p")
        #expect(ProviderAuthReturn.sanitize("https://app.t3.codes/settings#x")?.url == "https://app.t3.codes/settings")
    }

    @Test func handoffRoundTrip() throws {
        let link = Self.input.handoffURL()
        #expect(CodexAuthHandoff.read(link, scheme: "t3code") == Self.input)
        #expect(DesktopOpenURL.parse(link) == .codexAuthHandoff(Self.input))
        let delivery = try Self.input.deliveryURL(callbackUrl: Self.callbackUrl)
        let c = try #require(URLComponents(string: delivery))
        #expect(c.query == nil)
        #expect(c.host == "app.t3.codes" && c.path == "/welcome")
        let fragment = try #require(c.percentEncodedFragment)
        #expect(fragment.hasPrefix("codex-auth="))
        let json = try #require(String(fragment.dropFirst("codex-auth=".count)).removingPercentEncoding)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object == ["environmentId": "remote-environment", "instanceId": "work-codex", "flowId": "flow-one",
                           "callbackUrl": Self.callbackUrl, "returnHash": "#agents:remote-environment"])
    }

    @Test func handoffRejections() {
        let link = Self.input.handoffURL()
        #expect(CodexAuthHandoff.read(link, scheme: "t3code-dev") == nil)
        #expect(CodexAuthHandoff.read(link.replacingOccurrences(of: "auth/codex", with: "auth/other"), scheme: "t3code") == nil)
        let attackerReturn = CodexAuthHandoff(authorizationUrl: Self.authorizationUrl, returnUrl: "https://attacker.example/welcome",
                                              environmentId: "e", instanceId: "i", flowId: "f")
        #expect(CodexAuthHandoff.read(attackerReturn.handoffURL(), scheme: "t3code") == nil)
        let attackerAuth = CodexAuthHandoff(authorizationUrl: Self.authorizationUrl.replacingOccurrences(of: "auth.openai.com", with: "attacker.example"),
                                            returnUrl: Self.input.returnUrl, environmentId: "e", instanceId: "i", flowId: "f")
        #expect(CodexAuthHandoff.read(attackerAuth.handoffURL(), scheme: "t3code") == nil)
    }

    @Test func authorizationRequestRules() throws {
        let request = try CodexAuthorizationRequest(Self.authorizationUrl)
        #expect(request.port == 54213 && request.state == Self.state)
        #expect(throws: CodexAuthError.self) { try CodexAuthorizationRequest(Self.authorizationUrl + "&redirect_uri=http://localhost:1/auth/callback") }
        #expect(throws: CodexAuthError.self) {
            try CodexAuthorizationRequest(Self.authorizationUrl.replacingOccurrences(of: "127.0.0.1", with: "localhost"))
        }
        #expect(throws: CodexAuthError.self) { try Self.input.deliveryURL(callbackUrl: Self.callbackUrl + "&state=another") }
        #expect(throws: CodexAuthError.self) { try request.validateCallback("http://127.0.0.1:54213/auth/callback?state=\(Self.state)") }
        try request.validateCallback("http://127.0.0.1:54213/auth/callback?state=\(Self.state)&error=access_denied")
    }

    @Test func classifiesEveryForm() {
        #expect(DesktopOpenURL.parse("t3code://app/settings/providers?instanceId=work") == .resume(ProviderAuthReturn.sanitize("t3code://app/settings/providers?instanceId=work")!))
        // Another build's scheme is not ours.
        #expect(DesktopOpenURL.parse("t3code-dev://app/welcome") == nil)
        #expect(DesktopOpenURL.parse("t3code-dev://app/welcome", scheme: "t3code-dev") != nil)
        #expect(DesktopOpenURL.parse("candywrapper-dev://app/settings/providers?code=x", scheme: "candywrapper-dev")
                == .resume(ProviderAuthReturn.sanitize("candywrapper-dev://app/settings/providers", desktopSchemes: ["candywrapper-dev"])!))
        #expect(DesktopOpenURL.parse("https://remote.example.com:3773/pair#token=abc") == .pairing(host: "https://remote.example.com:3773", code: "abc"))
        #expect(DesktopOpenURL.parse("https://app.t3.codes/pair?host=https%3A%2F%2Fbox.example&label=Box#token=xyz")
                == .pairing(host: "https://box.example", code: "xyz"))
        #expect(DesktopOpenURL.parse("http://192.168.1.4:3773/pair?token=q") == .pairing(host: "http://192.168.1.4:3773", code: "q"))
        #expect(DesktopOpenURL.parse("https://example.com/no-token") == nil)
        #expect(DesktopOpenURL.parse("t3code://app/auth/callback") == nil)
    }
}
