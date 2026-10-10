import Foundation
import ImageIO
import T3Client

/// Development only (`--fake-t3-connect`): plays Clerk's Frontend API and the T3 Connect relay inside the
/// process, so the sign-in sheet, the account's machines and sign-out can be seen without an account.
/// Nothing leaves the machine: the hosts end in `.invalid` and every request is answered here. The session
/// lives in memory, the DPoP key is a throwaway software key, and the catalog is a temporary file.
///
/// Email code `424242` signs in, `000000` is an expired code, any other code is wrong. Password `candy`
/// signs in. Connecting a listed machine fails with the relay's "no active link" error.
enum FakeT3Connect {
    static let clerkURL = URL(string: "https://clerk.fake.invalid")!
    static let relayURL = URL(string: "https://relay.fake.invalid")!

    @MainActor
    static func makeAccount(identity: ClientIdentity) throws -> T3ConnectAccount {
        let server = Server()
        let clerk = ClerkClient(baseURL: clerkURL, store: MemoryStore(), device: .current, send: server.send)
        let relay = try RelayClient(relayURL: relayURL, key: try SoftwareDPoPKey(), send: server.send)
        return T3ConnectAccount(clerk: clerk, relay: relay, identity: identity, send: server.send)
    }

    /// A catalog in a temporary directory with its own Keychain service, so the fake never writes the
    /// app's saved environments.
    static func catalog() -> EnvironmentCatalog {
        let dir = FileManager.default.temporaryDirectory.appending(path: "candywrapper-fake-t3-connect")
        try? FileManager.default.removeItem(at: dir)
        return EnvironmentCatalog(file: dir.appending(path: "environments.json"),
                                  credentials: CredentialStore(service: "dev.candywrapper.t3.fake-t3-connect"))
    }

    final class MemoryStore: ClerkSessionStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var value: ClerkStoredSession?
        func load() throws -> ClerkStoredSession? { lock.withLock { value } }
        func save(_ session: ClerkStoredSession) throws { lock.withLock { value = session } }
        func delete() throws { lock.withLock { value = nil } }
    }

    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var email = "you@example.com"
        private var linked: [(id: String, label: String, host: String, online: Bool)] = [
            ("fake-env-studio", "Studio", "studio.fake.invalid", true),
            ("fake-env-buildbox", "Build box", "buildbox.fake.invalid", false),
        ]

        var send: HTTPSend {
            { [self] request in
                try await Task.sleep(for: .milliseconds(350))
                if request.url?.host == "img.fake.invalid" {
                    return (Self.avatarPNG, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!)
                }
                let (status, body, headers) = answer(request)
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
            }
        }

        private func form(_ request: URLRequest) -> [String: String] {
            let text = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            var fields: [String: String] = [:]
            for pair in text.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            return fields
        }

        private func answer(_ request: URLRequest) -> (Int, String, [String: String]) {
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let f = form(request)
            switch (method, path) {
            case ("GET", "/v1/environment"):
                return (200, Self.environment, [:])
            case ("POST", "/v1/client/sign_ins"):
                lock.withLock { email = f["identifier"] ?? email }
                if let password = f["password"] {
                    return password == "candy" ? (200, complete(), ["Authorization": "fake-client-token"])
                        : (422, Self.error("form_password_incorrect"), [:])
                }
                return (200, signIn("needs_first_factor"), ["Authorization": "fake-client-token"])
            case ("POST", "/v1/client/sign_ins/sia_fake/prepare_first_factor"):
                return (200, signIn("needs_first_factor"), [:])
            case ("POST", "/v1/client/sign_ins/sia_fake/attempt_first_factor"):
                switch f["code"] {
                case "424242": return (200, complete(), [:])
                case "000000": return (400, Self.error("verification_expired"), [:])
                default: return (422, Self.error("form_code_incorrect"), [:])
                }
            case ("POST", "/v1/client/sessions/sess_fake/tokens/t3-relay"):
                let exp = Int(Date().timeIntervalSince1970) + 60
                let jwt = Base64URL.encode(Data(#"{"alg":"RS256"}"#.utf8)) + "."
                    + Base64URL.encode(Data(#"{"sub":"user_fake","aud":"t3-code-relay","exp":\#(exp)}"#.utf8)) + ".ZmFrZQ"
                return (200, #"{"jwt":"\#(jwt)"}"#, [:])
            case ("GET", "/v1/client"):
                let email = lock.withLock { self.email }
                return (200, """
                    {"response":{"object":"client","id":"client_fake","last_active_session_id":"sess_fake","sessions":[
                      {"object":"session","id":"sess_fake","status":"active",
                       "user":{"id":"user_fake","first_name":"Candy","last_name":"Wrapper","image_url":"https://img.fake.invalid/avatar.png"},
                       "public_user_data":{"identifier":"\(email)","user_id":"user_fake","image_url":"https://img.fake.invalid/avatar.png"}}]},
                     "client":null}
                    """, [:])
            case ("POST", "/v1/client/sessions/sess_fake/remove"), ("DELETE", "/v1/client/sessions"):
                return (200, "{}", [:])
            case ("GET", "/v1/environments"):
                let list = lock.withLock { linked }.map { m in
                    #"{"environmentId":"\#(m.id)","label":"\#(m.label)","endpoint":\#(Self.endpoint(m.host)),"linkedAt":"2026-09-28T09:30:00.000Z"}"#
                }
                return (200, #"{"environments":[\#(list.joined(separator: ","))]}"#, [:])
            case ("POST", "/v1/client/dpop-token"):
                return (200, #"{"access_token":"fake-relay-token","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"DPoP","expires_in":1800,"scope":"\#(f["scope"] ?? "")"}"#, [:])
            default:
                break
            }
            let parts = path.split(separator: "/").map(String.init)
            if method == "POST", parts.count == 4, parts[0] == "v1", parts[1] == "environments" {
                guard let m = lock.withLock({ linked.first { $0.id == parts[2] } }) else { return (404, "{}", [:]) }
                if parts[3] == "status" {
                    let offline = m.online ? "" : #","error":"No answer","offlineReason":"tunnel_released""#
                    return (200, #"{"environmentId":"\#(m.id)","endpoint":\#(Self.endpoint(m.host)),"status":"\#(m.online ? "online" : "offline")","checkedAt":"2026-10-10T10:00:00.000Z","descriptor":{"environmentId":"\#(m.id)","label":"\#(m.label)","serverVersion":"0.0.46","orchestrationProtocolVersion":2,"platform":{"os":"darwin","arch":"arm64","machine":"mac-studio"},"capabilities":{}}\#(offline)}"#, [:])
                }
                return (403, #"{"_tag":"RelayEnvironmentConnectNotAuthorizedError","code":"environment_connect_not_authorized","reason":"environment_link_not_found","traceId":"fake-trace"}"#, [:])
            }
            if method == "DELETE", parts.count == 4, parts[2] == "environment-links" {
                lock.withLock { linked.removeAll { $0.id == parts[3] } }
                return (200, #"{"ok":true}"#, [:])
            }
            return (404, #"{"errors":[{"message":"not found","code":"resource_not_found"}]}"#, [:])
        }

        /// A 96 px two-tone image for the fake account.
        static let avatarPNG: Data = {
            let size = 96
            guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
            ctx.setFillColor(CGColor(red: 0.95, green: 0.45, blue: 0.62, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.setFillColor(CGColor(red: 0.98, green: 0.85, blue: 0.4, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 24, y: 40, width: 48, height: 48))
            guard let image = ctx.makeImage() else { return Data() }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return Data() }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            return data as Data
        }()

        private static func endpoint(_ host: String) -> String {
            #"{"httpBaseUrl":"https://\#(host)/","wsBaseUrl":"wss://\#(host)/","providerKind":"cloudflare_tunnel"}"#
        }

        private static func error(_ code: String) -> String {
            #"{"errors":[{"message":"x","long_message":"x","code":"\#(code)"}]}"#
        }

        private func signIn(_ status: String, session: Bool = false) -> String {
            let email = lock.withLock { self.email }
            let sessions = session ? """
                [{"object":"session","id":"sess_fake","status":"active","user":{"id":"user_fake"},
                  "public_user_data":{"identifier":"\(email)","user_id":"user_fake","has_image":false}}]
                """ : "[]"
            return """
                {"response":{"object":"sign_in_attempt","id":"sia_fake","status":"\(status)",
                  "supported_first_factors":[{"strategy":"password"},
                    {"strategy":"email_code","safe_identifier":"\(email)","email_address_id":"idn_fake","primary":true}],
                  "supported_second_factors":null,"identifier":"\(email)",
                  "created_session_id":\(session ? "\"sess_fake\"" : "null")},
                 "client":{"object":"client","id":"client_fake","sessions":\(sessions),
                  "last_active_session_id":\(session ? "\"sess_fake\"" : "null")}}
                """
        }

        private func complete() -> String { signIn("complete", session: true) }

        static let environment = """
            {"auth_config":{"single_session_mode":true,"native_settings":{"api_enabled":true}},
             "display_config":{"application_name":"T3 Code"},
             "user_settings":{"attributes":{
               "email_address":{"enabled":true,"used_for_first_factor":true,"first_factors":["email_code"]},
               "password":{"enabled":true}}}}
            """
    }
}
