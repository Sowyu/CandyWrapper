import Foundation
import T3Protocol

/// A pairing failure with T3's text, shown inline and in the "Could not add backend" toast.
public struct PairingError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public let traceId: String?
    public init(_ message: String, traceId: String? = nil) {
        self.message = message
        self.traceId = traceId
    }
    public var description: String { message }
}

/// Direct pairing with a host and a one-time code (client-runtime connection/onboarding.ts
/// `preparePairingRegistration`, docs/research/C-auth-connect.md 2.2 and 2.3).
public enum Pairing {
    /// ConnectionsSettings.tsx `parsePairingUrlFields`: a pasted pairing URL (direct or hosted) splits
    /// into host and code. Anything without a token gives nil, so the field keeps what was typed.
    public static func splitPairingURL(_ input: String) -> (host: String, code: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasScheme = trimmed.range(of: #"^[a-zA-Z][a-zA-Z\d+.-]*://"#, options: .regularExpression) != nil || trimmed.hasPrefix("//")
        let text = hasScheme ? (trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed) : "https://" + trimmed
        guard let c = URLComponents(string: text), let host = c.host, !host.isEmpty else { return nil }
        // `readHostedPairingRequest`: `?host=` plus a token.
        if let hosted = c.queryItems?.first(where: { $0.name == "host" })?.value?.trimmingCharacters(in: .whitespaces), !hosted.isEmpty,
           let token = token(in: c) {
            return (hosted, token)
        }
        guard let token = token(in: c), let scheme = c.scheme else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme.lowercased()
        origin.host = host
        origin.port = c.port
        return (origin.string ?? text, token)
    }

    /// `getPairingTokenFromUrl`: the fragment's `token` first, then the query's.
    static func token(in c: URLComponents) -> String? {
        if let fragment = c.fragment {
            var f = URLComponents()
            f.percentEncodedQuery = fragment
            if let t = f.queryItems?.first(where: { $0.name == "token" })?.value?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        }
        if let t = c.queryItems?.first(where: { $0.name == "token" })?.value?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        return nil
    }

    /// `parseRemotePairingFields`: a URL in the host field wins; else both fields must be filled.
    public static func fields(host: String, code: String) throws -> (host: String, code: String) {
        if let split = splitPairingURL(host) { return split }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { throw PairingError("Enter a backend host.") }
        if code.isEmpty { throw PairingError("Enter a pairing code.") }
        return (host, code)
    }

    /// shared/remote.ts `normalizeRemoteBaseUrl` and `toHttpBaseUrl`: `https://` when there is no
    /// scheme, `ws:`/`wss:` become `http:`/`https:`, the path, query and fragment go.
    public static func baseURL(host: String) throws -> URL {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw PairingError("Enter a backend URL.") }
        let bare = String(trimmed.drop { $0 == "/" })
        let text = bare.range(of: #"^[a-zA-Z][a-zA-Z\d+-]*://"#, options: .regularExpression) != nil ? bare : "https://" + bare
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme), let h = c.host, !h.isEmpty else {
            throw PairingError("Backend URL is invalid.")
        }
        c.scheme = scheme == "ws" ? "http" : scheme == "wss" ? "https" : scheme
        c.path = "/"
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        guard let url = c.url else { throw PairingError("Backend URL is invalid.") }
        return url
    }

    /// compatibility.ts `orchestrationProtocolCompatibilityError`.
    public static func compatibilityError(_ descriptor: EnvironmentDescriptor) -> String? {
        let version = descriptor.protocolVersion
        if version == T3Protocol.orchestrationProtocolVersion { return nil }
        return version > T3Protocol.orchestrationProtocolVersion
            ? "This client is not supported by this server. Update your app or use a compatible release to connect to \(descriptor.label)."
            : "This client requires a newer server. Update T3 Code on \(descriptor.label) to connect."
    }

    /// compatibility.ts `serverUpdateRequired`: the host speaks an older protocol and this client can drive
    /// its update (`canSelfUpdate`).
    public static func serverUpdateRequired(_ descriptor: EnvironmentDescriptor) -> Bool {
        descriptor.protocolVersion < T3Protocol.orchestrationProtocolVersion && ServerUpdateCapabilities(descriptor.capabilities).canUpdateRemotely
    }

    public struct Result: Sendable {
        public let descriptor: EnvironmentDescriptor
        public let baseURL: URL
        public let token: String
    }

    /// Checks the descriptor before it spends the one-time code: a route must reach
    /// `expectedEnvironmentId`, and the protocol must match. Then redeems the code at `/oauth/token`.
    public static func pair(host: String, code: String, expectedEnvironmentId: String? = nil, identity: ClientIdentity,
                            knownEnvironments: [EnvironmentRegistration] = [],
                            session: URLSession = EnvironmentHTTP.defaultSession) async throws -> Result {
        let fields = try fields(host: host, code: code)
        let base = try baseURL(host: fields.host)
        let http = EnvironmentHTTP(baseURL: base, session: session)
        let descriptor: EnvironmentDescriptor
        do { descriptor = try await http.descriptor() } catch { throw presented(error, url: base.appending(path: ".well-known/t3/environment")) }
        if let expected = expectedEnvironmentId, descriptor.environmentId != expected {
            throw PairingError("That address reaches \(descriptor.label), a different machine. Add it as its own environment instead.")
        }
        if expectedEnvironmentId == nil {
            try assertKnownAddress(environmentId: descriptor.environmentId, route: base, saved: knownEnvironments)
        }
        // An outdated server that can update itself is still saved, so it can be updated from here (onboarding.ts:126-130).
        if let message = compatibilityError(descriptor), !serverUpdateRequired(descriptor) { throw PairingError(message) }
        let token: AccessTokenResult
        do {
            token = try await http.exchangeToken(TokenExchangeRequest(subjectToken: fields.code, clientLabel: identity.label))
        } catch {
            throw presented(error, url: base.appending(path: "oauth/token"))
        }
        return Result(descriptor: descriptor, baseURL: base, token: token.accessToken)
    }

    /// Check before redeeming a code, then again under the catalog lock (registry.ts:544-577, 3814).
    public static func assertKnownAddress(environmentId: String, route: URL, saved: [EnvironmentRegistration]) throws {
        guard let known = saved.first(where: { $0.environmentId == environmentId }),
              !known.routes.contains(where: { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(route) }) else { return }
        throw PairingError("That address claims to be \(known.label), which is already saved. Add it as a route from that environment's settings instead.")
    }

    /// errors.ts `mapRemoteEnvironmentError` and rpc/http.ts's request errors.
    static func presented(_ error: Error, url: URL) -> Error {
        guard let e = error as? EnvironmentHTTPError else { return error }
        let u = url.absoluteString
        switch e {
        case .status(let status, let body?):
            let message = switch status {
            case 401: "The environment credential is invalid."
            case 403: "The environment credential does not grant the required access."
            case 400: "The environment rejected the authentication request."
            case 404: "The environment endpoint could not be found."
            case 500...: "The environment could not authorize the connection."
            default: "Remote environment endpoint \(u) returned undeclared status \(status)."
            }
            return PairingError(message, traceId: body.traceId.flatMap { $0 == "unavailable" ? nil : $0 })
        case .status(let status, nil): return PairingError("Remote environment endpoint \(u) returned undeclared status \(status).")
        case .timedOut: return PairingError("Remote environment endpoint \(u) timed out after 10000ms.")
        case .network(let cause): return PairingError("Failed to fetch remote environment endpoint \(u) (\(cause)).")
        case .invalidResponse: return PairingError("Remote environment endpoint returned an invalid response from \(u).")
        }
    }
}
