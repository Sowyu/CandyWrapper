import Foundation

/// What the app does with a URL macOS hands it (`open-url` and `second-instance` in
/// apps/desktop/src/app/DesktopClerk.ts:139-196). T3 registers `t3code` (development builds `t3code-dev`).
public enum DesktopOpenURL: Equatable, Sendable {
    /// `t3code://auth/codex?request=...`: receive a ChatGPT sign-in on this computer for another client.
    case codexAuthHandoff(CodexAuthHandoff)
    /// `t3code://app/welcome...` or `t3code://app/settings/...`: return to provider setup (`resumeProviderAuth`).
    case resume(ProviderAuthReturn)
    /// A pairing link (`https://host/pair#token=...` or the hosted `?host=...#token=...`), opened with the app.
    case pairing(host: String, code: String)

    /// Classifies `value`; nil for anything T3 would ignore. `scheme` is the app's registered scheme.
    public static func parse(_ value: String, scheme: String = "t3code") -> DesktopOpenURL? {
        if let handoff = CodexAuthHandoff.read(value, scheme: scheme) { return .codexAuthHandoff(handoff) }
        if let destination = ProviderAuthReturn.sanitize(value, desktopSchemes: ProviderAuthReturn.desktopSchemes.union([scheme])),
           destination.scheme == scheme {
            return .resume(destination)
        }
        if let c = URLComponents(string: value), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
           let split = Pairing.splitPairingURL(value) {
            return .pairing(host: split.host, code: split.code)
        }
        return nil
    }
}

/// A sanitized provider-auth return address (packages/shared/src/providerAuthReturnUrl.ts): the desktop app
/// (`t3code://app` or `t3code-dev://app`), a loopback web client, or `https://app.t3.codes`; only Welcome
/// and Settings routes; only a few query keys; a Welcome hash only of the form `#agents:<id>`.
public struct ProviderAuthReturn: Equatable, Sendable {
    public let url: String
    public let scheme: String
    /// `/welcome`, `/settings` or `/settings/...`.
    public let path: String
    /// The kept query items, in order.
    public let query: [(String, String)]
    /// Without `#`; only on Welcome.
    public let fragment: String?

    public static func == (a: Self, b: Self) -> Bool { a.url == b.url }

    static let keptKeys: Set<String> = ["machine", "project", "checkout", "environmentId", "instanceId"]
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// T3's two schemes; the app adds its own (debug builds register `candywrapper-dev`).
    public static let desktopSchemes: Set<String> = ["t3code", "t3code-dev"]

    public static func sanitize(_ value: String?, desktopSchemes: Set<String> = desktopSchemes) -> ProviderAuthReturn? {
        guard let value, var c = URLComponents(string: value), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased()
        else { return nil }
        if c.user != nil || c.password != nil { return nil }
        let desktop = desktopSchemes.contains(scheme) && host == "app" && c.port == nil
        let hostedOrigin = scheme == "https" && host == "app.t3.codes" && (c.port == nil || c.port == 443)
        let web = ["http", "https"].contains(scheme) && (loopbackHosts.contains(host) || hostedOrigin)
        guard desktop || web else { return nil }
        let path = c.percentEncodedPath
        // WHATWG URL resolves dot segments; refuse them instead of resolving.
        if path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." || $0.contains("%2e") || $0.contains("%2E") }) { return nil }
        guard path == "/welcome" || path == "/settings" || path.hasPrefix("/settings/") else { return nil }
        let items = path == "/welcome" ? [] : (c.queryItems ?? []).filter { keptKeys.contains($0.name) }
        c.queryItems = items.isEmpty ? nil : items
        var fragment: String?
        if path == "/welcome", let f = c.fragment, f.range(of: #"^agents:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil { fragment = f }
        c.fragment = fragment
        guard let url = c.string else { return nil }
        return ProviderAuthReturn(url: url, scheme: scheme, path: path, query: items.map { ($0.name, $0.value ?? "") }, fragment: fragment)
    }
}

/// `CodexAuthHandoff` (packages/shared/src/codexAuthHandoff.ts): the hosted web app asks this computer to
/// open ChatGPT's sign-in and catch its loopback callback, then hand the code back to `returnUrl`.
public struct CodexAuthHandoff: Equatable, Sendable, Codable {
    public let authorizationUrl: String
    public let returnUrl: String
    public let environmentId: String
    public let instanceId: String
    public let flowId: String

    public init(authorizationUrl: String, returnUrl: String, environmentId: String, instanceId: String, flowId: String) {
        self.authorizationUrl = authorizationUrl
        self.returnUrl = returnUrl
        self.environmentId = environmentId
        self.instanceId = instanceId
        self.flowId = flowId
    }

    /// `readCodexAuthHandoff`.
    public static func read(_ value: String, scheme: String) -> CodexAuthHandoff? {
        guard value.utf8.count <= 32_768, let c = URLComponents(string: value), c.scheme?.lowercased() == scheme,
              c.host == "auth", c.port == nil, c.percentEncodedPath == "/codex", c.user == nil, c.password == nil, c.fragment == nil
        else { return nil }
        let requests = (c.queryItems ?? []).filter { $0.name == "request" }
        guard requests.count == 1, let json = requests[0].value, let data = json.data(using: .utf8),
              let input = try? JSONDecoder().decode(CodexAuthHandoff.self, from: data),
              input.authorizationUrl.utf8.count <= 16_384, input.returnUrl.utf8.count <= 4_096,
              !input.environmentId.isEmpty, !input.instanceId.isEmpty, !input.flowId.isEmpty, input.flowId.count <= 128,
              (try? CodexAuthorizationRequest(input.authorizationUrl)) != nil,
              ProviderAuthReturn.sanitize(input.returnUrl) != nil
        else { return nil }
        return input
    }

    /// `codexAuthHandoffUrl`, for tests.
    public func handoffURL(scheme: String = "t3code") -> String {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "auth"
        c.path = "/codex"
        let json = (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        c.queryItems = [URLQueryItem(name: "request", value: json)]
        // `+` and `&` inside the JSON must not read as form separators.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.string ?? ""
    }

    /// `codexAuthDeliveryUrl`: the return address with the callback in a `#codex-auth=` fragment, never the query.
    public func deliveryURL(callbackUrl: String) throws -> String {
        let request = try CodexAuthorizationRequest(authorizationUrl)
        try request.validateCallback(callbackUrl)
        guard let destination = ProviderAuthReturn.sanitize(returnUrl), var c = URLComponents(string: destination.url) else {
            throw CodexAuthError("Invalid T3 Code return address.")
        }
        struct Delivery: Encodable {
            let environmentId, instanceId, flowId, callbackUrl, returnHash: String
        }
        let delivery = Delivery(environmentId: environmentId, instanceId: instanceId, flowId: flowId, callbackUrl: callbackUrl,
                                returnHash: destination.fragment.map { "#" + $0 } ?? "")
        let json = String(data: try JSONEncoder().encode(delivery), encoding: .utf8) ?? "{}"
        // `encodeURIComponent`.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        c.percentEncodedFragment = "codex-auth=" + (json.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        return c.string ?? destination.url
    }
}

public struct CodexAuthError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// `codexAuthorizationRequest`: only OpenAI's authorize endpoint with a loopback `redirect_uri`, one value per key.
public struct CodexAuthorizationRequest: Equatable, Sendable {
    public let authorizationUrl: String
    public let redirectUri: String
    public let state: String
    public let port: UInt16

    public init(_ value: String) throws {
        let invalid = CodexAuthError("Invalid ChatGPT sign-in request.")
        guard value.utf8.count <= 16_384, let c = URLComponents(string: value), c.scheme == "https", c.host == "auth.openai.com",
              c.port == nil, c.path == "/api/accounts/authorize", c.user == nil, c.password == nil, c.fragment == nil
        else { throw invalid }
        let items = c.queryItems ?? []
        func single(_ key: String) throws -> String {
            let values = items.filter { $0.name == key }.compactMap(\.value)
            guard values.count == 1, items.filter({ $0.name == key }).count == 1, let v = values.first, !v.isEmpty else { throw invalid }
            return v
        }
        let redirectUri = try single("redirect_uri")
        let state = try single("state")
        guard redirectUri.range(of: #"^http://127\.0\.0\.1:[1-9]\d{0,4}/auth/callback$"#, options: .regularExpression) != nil,
              let port = URLComponents(string: redirectUri)?.port, port <= 65_535,
              state.range(of: #"^[A-Za-z0-9_-]{16,128}$"#, options: .regularExpression) != nil,
              try single("response_type") == "code",
              try single("code_challenge_method") == "S256",
              try single("code_challenge").range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              try single("client_id").range(of: #"^(dynamic_agent_client|oaiapp_[A-Za-z0-9_-]+)$"#, options: .regularExpression) != nil
        else { throw invalid }
        authorizationUrl = value
        self.redirectUri = redirectUri
        self.state = state
        self.port = UInt16(port)
    }

    /// `codexCallbackUrl`: same origin and path as the redirect, one matching state, a code or an error.
    public func validateCallback(_ value: String) throws {
        let mismatch = CodexAuthError("This redirect URL does not belong to the current sign-in.")
        guard value.utf8.count <= 16_384, let c = URLComponents(string: value), let expected = URLComponents(string: redirectUri),
              c.scheme == expected.scheme, c.host == expected.host, c.port == expected.port, c.path == expected.path,
              c.user == nil, c.password == nil, c.fragment == nil
        else { throw mismatch }
        let items = c.queryItems ?? []
        func all(_ key: String) -> [String] { items.filter { $0.name == key }.map { $0.value ?? "" } }
        let states = all("state"), codes = all("code"), errors = all("error"), clients = all("client_id")
        guard states == [state], clients.count <= 1,
              clients.allSatisfy({ $0.range(of: #"^oaiapp_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }),
              (codes.count == 1 && !codes[0].isEmpty && errors.isEmpty) || (errors.count == 1 && !errors[0].isEmpty && codes.isEmpty)
        else { throw mismatch }
    }
}
