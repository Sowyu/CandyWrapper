import Foundation

/// Where and why a connection attempt failed, when the code that saw it knows: the fields of T3's
/// `ConnectionTransientError` and `ConnectionBlockedError` (client-runtime/src/connection/model.ts:60-137).
/// `presentConnectionDiagnosis` reads it. `via` names the route when the hop alone does not: T3 Code on the
/// host can fail behind the tunnel or on a direct route.
public struct ConnectionFailureInfo: Sendable, Equatable {
    /// `ConnectionHop`: this device, T3 Connect, the host's tunnel, or T3 Code on the host.
    public enum Hop: String, Sendable { case device, relay, tunnel, server }
    public enum Via: String, Sendable { case relay, direct }

    /// T3's reason: `network`, `timeout`, `transport`, `endpoint-unavailable`, `relay-unavailable`,
    /// `remote-unavailable` or `session-pending` for a transient failure, `authentication`, `configuration`,
    /// `permission` or `unsupported` for a blocked one.
    public var reason: String
    public var blocked: Bool
    public var detail: String
    public var hop: Hop?
    public var via: Via?
    /// `ConnectionFailureCause`: the relay's endpoint failures (`tunnel_down`, `origin_unreachable`, `dns`,
    /// `tls`, `refused`, `timeout`, `invalid_response`, `unknown`) or `clock_skew`, `not_linked`,
    /// `relay_error`, `tunnel_pending`, `tunnel_not_enabled`.
    public var cause: String?
    public var httpStatus: Int?
    public var traceId: String?
    public var serverUpdateRequired: Bool

    public init(reason: String, blocked: Bool, detail: String, hop: Hop? = nil, via: Via? = nil, cause: String? = nil,
                httpStatus: Int? = nil, traceId: String? = nil, serverUpdateRequired: Bool = false) {
        self.reason = reason; self.blocked = blocked; self.detail = detail; self.hop = hop; self.via = via
        self.cause = cause; self.httpStatus = httpStatus; self.traceId = traceId; self.serverUpdateRequired = serverUpdateRequired
    }
}
