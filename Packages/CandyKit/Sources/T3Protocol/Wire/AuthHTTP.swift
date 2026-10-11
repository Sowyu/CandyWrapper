import Foundation

// Auth and environment HTTP bodies, docs/protocol.md sections 1.3 and 4.
// Source: packages/contracts/src/{environment.ts,auth.ts,environmentHttp.ts}.

/// `GET /.well-known/t3/environment`, the part a client needs.
public struct EnvironmentDescriptor: Codable, Sendable, Equatable {
    public struct Platform: Codable, Sendable, Equatable {
        public var os: String
        public var arch: String
        public var machine: String?
    }

    public var environmentId: String
    public var label: String
    public var platform: Platform?
    public var serverVersion: String
    /// Absent on old hosts, which means 1.
    public var orchestrationProtocolVersion: Int?
    /// Every key but `repositoryIdentity` is optional; absent means unsupported.
    public var capabilities: [String: JSONValue]

    public var protocolVersion: Int { orchestrationProtocolVersion ?? 1 }
    public var isCompatible: Bool { protocolVersion == T3Protocol.orchestrationProtocolVersion }

    public func capability(_ name: String) -> Bool {
        if case .bool(let b) = capabilities[name] { return b }
        return false
    }
}

/// `POST /oauth/token` form body (section 4.3).
public struct TokenExchangeRequest: Sendable, Equatable {
    public static let grantType = "urn:ietf:params:oauth:grant-type:token-exchange"
    public static let subjectTokenType = "urn:t3:params:oauth:token-type:environment-bootstrap"
    public static let requestedTokenType = "urn:ietf:params:oauth:token-type:access_token"

    public var subjectToken: String
    public var clientLabel: String?
    public var clientDeviceType: String?
    public var clientOS: String?
    /// Space-separated scopes to narrow to. Official clients omit it.
    public var scope: String?

    public init(subjectToken: String, clientLabel: String? = nil, clientDeviceType: String? = "desktop",
                clientOS: String? = "macOS", scope: String? = nil) {
        self.subjectToken = subjectToken
        self.clientLabel = clientLabel
        self.clientDeviceType = clientDeviceType
        self.clientOS = clientOS
        self.scope = scope
    }

    /// Field order matches the recording (`01-basic` t=19).
    public var formFields: [(String, String)] {
        var f: [(String, String)] = [
            ("grant_type", Self.grantType),
            ("subject_token", subjectToken),
            ("subject_token_type", Self.subjectTokenType),
            ("requested_token_type", Self.requestedTokenType),
        ]
        if let scope { f.append(("scope", scope)) }
        if let clientLabel { f.append(("client_label", clientLabel)) }
        if let clientDeviceType { f.append(("client_device_type", clientDeviceType)) }
        if let clientOS { f.append(("client_os", clientOS)) }
        return f
    }

    /// `application/x-www-form-urlencoded` body.
    public var formBody: Data {
        Data(formFields.map { "\(Self.formEscape($0.0))=\(Self.formEscape($0.1))" }.joined(separator: "&").utf8)
    }

    /// Unreserved characters plus `:` stay literal, as URLSearchParams leaves the token types readable.
    private static let formAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:")

    static func formEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }
}

/// `POST /oauth/token` success body.
public struct AccessTokenResult: Codable, Sendable, Equatable {
    public var accessToken: String
    public var expiresIn: Int
    public var issuedTokenType: String?
    public var scope: String?
    public var tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", expiresIn = "expires_in", issuedTokenType = "issued_token_type"
        case scope, tokenType = "token_type"
    }
}

/// `GET /api/auth/session` (section 4.5). Never a 401.
public struct AuthSessionState: Codable, Sendable, Equatable {
    public struct Auth: Codable, Sendable, Equatable {
        public var policy: String
        public var bootstrapMethods: [String]
        public var sessionMethods: [String]
        public var sessionCookieName: String?
        public var serverUpdateScope: String?
    }

    public var authenticated: Bool
    public var auth: Auth
    public var scopes: [String]?
    /// Exact grant. Read this when present, even if empty (section 4.1).
    public var permissions: [String]?
    public var sessionMethod: String?
    public var expiresAt: String?
}

/// `POST /api/auth/websocket-ticket` (section 4.4). Five minute lifetime.
public struct WebSocketTicket: Codable, Sendable, Equatable {
    public var ticket: String
    public var expiresAt: String
}

/// Tagged HTTP error body (section 4.6). Every field but `_tag` is optional so one type covers
/// all six environment errors and the `{_tag, message}` connect errors.
public struct EnvironmentHTTPErrorBody: Codable, Sendable, Equatable {
    public var tag: String
    public var code: String?
    public var reason: String?
    public var message: String?
    public var dpopFailureReason: String?
    public var requiredScope: String?
    public var requiredPermission: String?
    public var traceId: String?

    enum CodingKeys: String, CodingKey {
        case tag = "_tag", code, reason, message, dpopFailureReason, requiredScope, requiredPermission, traceId
    }
}

/// `GET /ws` answers 426 with this when `orchestrationProtocol` is missing or wrong.
public struct ProtocolIncompatibleBody: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var orchestrationProtocolVersion: Int
}

extension AuthSessionState {
    /// auth.ts:130-163,195-202. Omitted permissions are an old server, not an old-only grant.
    public var hasLegacyPermissions: Bool {
        let legacy: Set<String> = ["orchestration:read", "orchestration:operate", "terminal:operate", "review:write", "access:read", "access:write", "relay:read", "relay:write"]
        let parents: Set<String> = ["orchestration:read", "orchestration:operate", "terminal:operate"]
        guard authenticated, let permissions else { return false }
        return permissions.allSatisfy { legacy.contains($0) } && permissions.contains { parents.contains($0) }
    }
}
