import Foundation

/// T3's network hint for relay and T3 Connect failures (client-runtime/src/errors/network.ts:3-4).
public let t3ConnectNetworkHint = "Your DNS or firewall may be blocking T3 Connect. Try another network, such as a phone hotspot."

/// DPoP hints (client-runtime/src/relay/errorPresentation.ts:4-22).
public enum DPoPHint {
    public static let clock = "Hint: Check that automatic date and time is enabled on both devices, then try again."
    public static let unknown = "Hint: Try again. If it still fails, clock skew may be the cause; check that automatic date and time is enabled on both devices."
    public static let retry = "Hint: Try again. If the problem continues, copy the trace ID."

    public static func message(_ message: String, reason: String?) -> String {
        switch reason {
        case "time_window": "\(message) \(clock)"
        case nil: "\(message) \(unknown)"
        default: "\(message) \(retry)"
        }
    }
}

/// One failed relay request, shaped like T3's `ManagedRelayClientError` (relay/managedRelay.ts:117-200).
public struct RelayError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// Non-2xx. `body` is set only when it decodes as a `RelayProtectedError`.
        case relay(status: Int, body: RelayErrorBody?)
        case transport(String)
        case timedOut
        case invalidResponse(String)
        /// The granted `scope` is not the requested set (managedRelay.ts:517-522).
        case scopesUnexpected(granted: String)
    }

    /// T3's action names, used in messages (managedRelay.ts `ManagedRelayRequestAction`).
    public enum Action: String, Sendable {
        case exchangeToken = "exchange relay DPoP access token"
        case listEnvironments = "list relay-managed environments"
        case unlink = "unlink relay environment"
        case status = "get relay environment status"
        case connect = "connect relay environment"

        /// `ManagedRelayRequestActivity`, used for timeouts (managedRelay.ts:102-115).
        var activity: String {
            switch self {
            case .exchangeToken: "Relay DPoP access token exchange"
            case .listEnvironments: "Relay environment listing"
            case .unlink: "Relay environment unlinking"
            case .status: "Relay environment status request"
            case .connect: "Relay environment connection"
            }
        }
    }

    public var kind: Kind
    public var action: Action

    public init(_ kind: Kind, action: Action) {
        self.kind = kind
        self.action = action
    }

    public var body: RelayErrorBody? {
        if case .relay(_, let body) = kind { return body }
        return nil
    }

    /// The cached relay access token was refused: drop it and exchange once more
    /// (managedRelay.ts:321-327, 655-692).
    var isRejectedAccessToken: Bool {
        body?.tag == "RelayAuthInvalidError" && body?.reason == "invalid_bearer"
    }

    /// User-facing text (relay/errorPresentation.ts:24-66, managedRelay.ts:117-170).
    public var description: String {
        if let body { return Self.message(for: body) }
        switch kind {
        case .relay: return "Could not \(action.rawValue)."
        case .transport: return "Could not \(action.rawValue). \(t3ConnectNetworkHint)"
        case .timedOut: return "\(action.activity) timed out. \(t3ConnectNetworkHint)"
        case .invalidResponse: return "Could not \(action.rawValue)."
        case .scopesUnexpected: return "Relay granted unexpected DPoP access token scopes."
        }
    }

    /// Transient or blocked, as client-runtime/src/connection/errors.ts:37-113 decides.
    public var failure: ConnectionFailure {
        if let body {
            switch body.tag {
            case "RelayAuthInvalidError", "RelayEnvironmentLinkProofExpiredError",
                 "RelayAgentActivityPublishProofExpiredError", "RelayAgentActivityPublishProofInvalidError":
                return .blocked(.authentication, description)
            case "RelayEnvironmentConnectNotAuthorizedError", "RelayEnvironmentLinkProofInvalidError",
                 "RelayEnvironmentLinkLimitExceededError":
                return .blocked(.permission, description)
            default:
                // Endpoint unavailable or timed out, link failed or unavailable, internal error.
                return .transient(description)
            }
        }
        switch kind {
        case .scopesUnexpected: return .blocked(.permission, description)
        default: return .transient(description)
        }
    }

    static func message(for body: RelayErrorBody) -> String {
        let reason = body.reason ?? ""
        switch body.tag {
        case "RelayAuthInvalidError":
            switch reason {
            case "invalid_dpop": return DPoPHint.message("Relay rejected the DPoP proof.", reason: body.dpopFailureReason)
            case "not_authorized": return "Relay rejected the authenticated request."
            default: return "Relay rejected the cloud session token."
            }
        case "RelayEnvironmentLinkProofExpiredError": return "Relay rejected an expired environment link proof."
        case "RelayEnvironmentLinkProofInvalidError": return "Relay rejected the environment link proof (\(reason))."
        case "RelayEnvironmentConnectNotAuthorizedError":
            if reason == "environment_link_not_found" {
                return "Relay has no active link for this environment. The environment server may not have re-established its link yet."
            }
            return body.reason.map { "Relay rejected the environment connection request (\($0))." }
                ?? "Relay rejected the environment connection request."
        case "RelayEnvironmentEndpointUnavailableError": return "Relay could not reach the environment endpoint (\(reason))."
        case "RelayEnvironmentEndpointTimedOutError": return "Relay timed out while contacting the environment endpoint."
        case "RelayEnvironmentLinkFailedError": return "Relay could not link the environment (\(reason))."
        case "RelayEnvironmentLinkUnavailableError": return "Relay cannot provision the managed endpoint (\(reason))."
        case "RelayEnvironmentLinkLimitExceededError":
            let max = body.maxTunnels.map { String(Int($0)) } ?? "?"
            return "Relay refused the link: this account already has its maximum of \(max) managed tunnels. Unlink an environment to free one up."
        case "RelayAgentActivityPublishProofExpiredError": return "Relay rejected an expired agent activity publish proof."
        case "RelayAgentActivityPublishProofInvalidError": return "Relay rejected the agent activity publish proof (\(reason))."
        default: return "Relay encountered an internal error (\(reason))."
        }
    }
}
