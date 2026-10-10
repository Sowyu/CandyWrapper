import Foundation
import T3Protocol

// Relay wire types (protocol.md 10.3). Source: packages/contracts/src/relay.ts.

/// Where a linked environment answers: `RelayManagedEndpoint` (relay.ts:158-170).
/// `providerKind` is `manual`, `cloudflare_tunnel` or `t3_relay`.
public struct RelayEndpoint: Codable, Sendable, Equatable {
    public var httpBaseUrl: String
    public var wsBaseUrl: String
    public var providerKind: String

    public init(httpBaseUrl: String, wsBaseUrl: String, providerKind: String) {
        self.httpBaseUrl = httpBaseUrl
        self.wsBaseUrl = wsBaseUrl
        self.providerKind = providerKind
    }
}

/// One entry of `GET /v1/environments`: `RelayClientEnvironmentRecord` (relay.ts:701-706).
public struct RelayEnvironmentRecord: Codable, Sendable, Equatable {
    public var environmentId: String
    public var label: String
    public var endpoint: RelayEndpoint
    public var linkedAt: String
}

/// `RelayListEnvironmentsResponse` (relay.ts:709-711).
struct RelayListEnvironmentsResponse: Codable, Sendable {
    var environments: [RelayEnvironmentRecord]
}

/// `POST /v1/environments/:id/status`: `RelayEnvironmentStatusResponse` (relay.ts:834-843).
public struct RelayEnvironmentStatus: Codable, Sendable, Equatable {
    public var environmentId: String
    public var endpoint: RelayEndpoint
    /// `online` or `offline`.
    public var status: String
    public var checkedAt: String
    public var descriptor: EnvironmentDescriptor?
    public var error: String?
    /// Absent or `tunnel_released`.
    public var offlineReason: String?
    public var traceId: String?

    public var isOnline: Bool { status == "online" }

    /// T3's text for an offline reason (relay/errorPresentation.ts:68-85).
    public var offlineMessage: String? {
        offlineReason == "tunnel_released"
            ? "Offline for a while, so its T3 Connect tunnel was removed. Start T3 Code on that computer and update it to the latest version to reconnect."
            : nil
    }

    /// The listing checks every status against its record (relay/discovery.ts:57-91).
    public func validate(against record: RelayEnvironmentRecord) -> ConnectionFailure? {
        if environmentId != record.environmentId {
            return .blocked(.configuration, "Relay returned status for a different environment.")
        }
        if endpoint != record.endpoint {
            return .blocked(.configuration, "Relay returned status for a different environment endpoint.")
        }
        if let descriptor, descriptor.environmentId != record.environmentId {
            return .blocked(.configuration, "Relay returned a descriptor for a different environment.")
        }
        return nil
    }
}

/// `POST /v1/environments/:id/connect` body: `RelayEnvironmentConnectRequest` (relay.ts:714-731).
/// T3 sends the deprecated alias `clientKeyThumbprint` (managedRelay.ts:823-827).
struct RelayConnectRequest: Codable, Sendable, Equatable {
    var deviceId: String?
    var clientKeyThumbprint: String
}

/// `RelayEnvironmentConnectResponse` (relay.ts:815-820). `credential` is the one-time environment
/// bootstrap credential: two minutes, single use, bound to the proof key.
public struct RelayConnectResponse: Codable, Sendable, Equatable {
    public var environmentId: String
    public var endpoint: RelayEndpoint
    public var credential: String
    public var expiresAt: String
}

/// `RelayDpopAccessTokenResponse` (relay.ts:771-777). The relay grants 30 minutes
/// (infra/relay/src/auth/RelayTokens.ts:29).
public struct RelayAccessTokenResponse: Codable, Sendable, Equatable {
    public var accessToken: String
    public var issuedTokenType: String
    public var tokenType: String
    public var expiresIn: Int
    public var scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", issuedTokenType = "issued_token_type", tokenType = "token_type"
        case expiresIn = "expires_in", scope
    }
}

/// `RelayOkResponse` (relay.ts:955-957).
struct RelayOkResponse: Codable, Sendable {
    var ok: Bool
}

/// Relay DPoP access-token scopes (relay.ts:733-741). `t3-web` may ask for the first two only
/// (infra/relay/src/auth/RelayTokens.ts:63-73).
public enum RelayScope {
    public static let connect = "environment:connect"
    public static let status = "environment:status"
}

/// A `Schema.TaggedError` body from the relay (relay.ts:392-608). One type covers all of them.
public struct RelayErrorBody: Codable, Sendable, Equatable {
    public var tag: String
    public var code: String?
    public var reason: String?
    public var dpopFailureReason: String?
    public var maxTunnels: Double?
    public var traceId: String?

    enum CodingKeys: String, CodingKey {
        case tag = "_tag", code, reason, dpopFailureReason, maxTunnels, traceId
    }

    /// The tags in `RelayProtectedError` (relay.ts:595-608). Any other body is not one T3 decodes.
    static let protectedTags: Set<String> = [
        "RelayAuthInvalidError", "RelayEnvironmentLinkProofExpiredError", "RelayEnvironmentLinkProofInvalidError",
        "RelayEnvironmentConnectNotAuthorizedError", "RelayEnvironmentEndpointUnavailableError",
        "RelayEnvironmentEndpointTimedOutError", "RelayEnvironmentLinkFailedError",
        "RelayEnvironmentLinkUnavailableError", "RelayEnvironmentLinkLimitExceededError",
        "RelayAgentActivityPublishProofExpiredError", "RelayAgentActivityPublishProofInvalidError", "RelayInternalError",
    ]
}
