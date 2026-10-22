import Foundation
import T3Protocol

/// What failed on the way to an environment, in order, and what to try (`ConnectionDiagnosis`,
/// client-runtime/src/connection/diagnosis.ts:16-31). The Connections row and the composer's offline banner read it.
public struct ConnectionDiagnosis: Sendable, Equatable {
    public enum HopResult: String, Sendable { case ok, failed, unchecked }
    public struct Hop: Sendable, Equatable {
        public var hop: ConnectionFailureInfo.Hop
        public var label: String
        public var result: HopResult
    }

    /// Names the part that failed, e.g. "Mac mini's tunnel is offline".
    public var headline: String
    public var hops: [Hop]
    public var steps: [String]
    public var facts: [(label: String, value: String)]
    /// The troubleshooting guide section for this failure. Nil for direct routes.
    public var moreInfoURL: String?

    public static func == (l: Self, r: Self) -> Bool {
        l.headline == r.headline && l.hops == r.hops && l.steps == r.steps && l.moreInfoURL == r.moreInfoURL
            && l.facts.map(\.label) == r.facts.map(\.label) && l.facts.map(\.value) == r.facts.map(\.value)
    }

    /// The relay's last health check for the environment (`RelayEnvironmentStatusResponse`, relay.ts:834-855).
    public struct RelayStatus: Sendable, Equatable {
        public var status: String
        public var endpointFailure: String?
        public var endpointStatus: Int?
        public var offlineReason: String?
        public init(status: String, endpointFailure: String? = nil, endpointStatus: Int? = nil, offlineReason: String? = nil) {
            self.status = status; self.endpointFailure = endpointFailure; self.endpointStatus = endpointStatus; self.offlineReason = offlineReason
        }
    }

    /// `ConnectionDiagnosisInput` (diagnosis.ts:33-46) with the supervisor state's fields it reads.
    public struct Input: Sendable {
        public var hostLabel: String
        /// The network or the supervisor is offline.
        public var offline: Bool
        public var failure: ConnectionFailureInfo?
        /// The environment's usual route, used when the failure does not name one.
        public var via: ConnectionFailureInfo.Via
        /// Can name a cause before any connect attempt.
        public var relayStatus: RelayStatus?
        public var attempt: Int
        public var retryAt: Date?
        public var clientVersion: String?
        public var serverVersion: String?
        public init(hostLabel: String, offline: Bool, failure: ConnectionFailureInfo?, via: ConnectionFailureInfo.Via, relayStatus: RelayStatus? = nil,
                    attempt: Int = 0, retryAt: Date? = nil, clientVersion: String? = nil, serverVersion: String? = nil) {
            self.hostLabel = hostLabel; self.offline = offline; self.failure = failure; self.via = via; self.relayStatus = relayStatus
            self.attempt = attempt; self.retryAt = retryAt; self.clientVersion = clientVersion; self.serverVersion = serverVersion
        }
    }

    private struct Located {
        var hop: ConnectionFailureInfo.Hop
        /// A `ConnectionFailureCause`, or `offline`, `outdated`, `released`.
        var cause: String?
    }

    private static let notAnswering: Set<String> = ["origin_unreachable", "invalid_response"]

    /// `locate` (diagnosis.ts:56-80).
    private static func locate(_ input: Input) -> Located? {
        let failure = input.failure
        if input.offline { return Located(hop: .device, cause: "offline") }
        if let failure, failure.blocked, failure.serverUpdateRequired { return Located(hop: .server, cause: "outdated") }
        if let hop = failure?.hop { return Located(hop: hop, cause: failure?.cause) }
        if let failure {
            let unreachable = ["network", "timeout", "transport"].contains(failure.reason)
            let via = failure.via ?? input.via
            return Located(hop: unreachable && via == .relay ? .tunnel : .server, cause: nil)
        }
        guard let status = input.relayStatus, status.status == "offline" else { return nil }
        if status.offlineReason == "tunnel_released" { return Located(hop: .tunnel, cause: "released") }
        let cause = status.endpointFailure
        return Located(hop: cause.map(notAnswering.contains) == true ? .server : .tunnel, cause: cause)
    }

    private static func failedOnThisDevice(_ failure: ConnectionFailureInfo?) -> Bool {
        ["network", "transport", "timeout"].contains(failure?.reason ?? "")
    }

    /// `headline` (diagnosis.ts:82-139).
    private static func headline(_ host: String, _ located: Located, _ failure: ConnectionFailureInfo?) -> String {
        switch located.cause {
        case "offline": return "This device is offline"
        case "outdated": return "\(host) runs an older T3 Code"
        case "clock_skew": return "This device's clock is off"
        case "not_linked": return "\(host) is not linked to your T3 Connect account"
        case "relay_error": return "T3 Connect returned an error"
        case "tunnel_pending": return "\(host)'s tunnel is still being set up"
        case "tunnel_not_enabled": return "T3 Connect is not turned on for \(host)"
        case "released", "tunnel_down": return "\(host)'s tunnel is offline"
        case "origin_unreachable": return "Tunnel works, but T3 Code on \(host) did not answer"
        case "invalid_response": return "T3 Code on \(host) sent an unexpected answer"
        case "dns": return "\(host)'s tunnel address did not resolve"
        case "tls": return "Secure connection to \(host)'s tunnel failed"
        case "refused": return "\(host)'s tunnel refused the connection"
        case "timeout": return "\(host) did not answer in time"
        default: break
        }
        switch located.hop {
        case .device: return "This device could not prepare the connection"
        case .relay:
            return failure?.reason == "authentication" ? "T3 Connect did not accept this device's sign-in" : "This device can't reach T3 Connect"
        case .tunnel:
            // The relay already reached the host when this device fails on its own (#17629).
            return failedOnThisDevice(failure) ? "This device can't reach \(host)'s tunnel" : "T3 Connect could not reach \(host)'s tunnel"
        case .server:
            return failure?.reason == "authentication" || failure?.reason == "permission"
                ? "T3 Code on \(host) did not accept this device" : "T3 Code on \(host) did not answer"
        }
    }

    /// `steps` (diagnosis.ts:141-209).
    private static func steps(_ host: String, _ located: Located, _ failure: ConnectionFailureInfo?) -> [String] {
        let checkHost = "On \(host), check Settings > Connections or run `t3 connect status`."
        switch located.cause {
        case "offline": return ["Connect this device to the internet. T3 Code reconnects on its own."]
        case "outdated": return ["Update T3 Code on \(host)."]
        case "clock_skew": return ["Turn on automatic date and time on this device and on \(host), then retry."]
        case "not_linked":
            return ["Check that this device is signed in to the same T3 Connect account as the host.",
                    "On \(host), open Settings > Connections and turn T3 Connect on."]
        case "tunnel_pending": return ["Wait a minute. T3 Code retries on its own.", checkHost]
        case "relay_error": return ["Wait a few minutes. T3 Code retries on its own.", "If it keeps failing, copy the diagnostics and report it."]
        case "tunnel_not_enabled": return ["On \(host), open Settings > Connections and turn T3 Connect on."]
        case "released", "tunnel_down":
            return ["Make sure \(host) is awake and T3 Code is running on it.", checkHost,
                    "A VPN or Tailscale exit node on \(host) can block the tunnel (port 7844). Turn it off or allow the tunnel."]
        case "origin_unreachable", "invalid_response": return ["Open or restart T3 Code on \(host).", checkHost]
        // The relay saw these on its way to the host, so the fix is on the host.
        case "dns", "tls", "refused", "timeout", "unknown": return ["Make sure \(host) is awake and online.", checkHost]
        default: break
        }
        switch located.hop {
        case .device: return ["Restart T3 Code on this device.", "If it keeps failing, remove \(host) from this device and add it again."]
        case .relay:
            return failure?.reason == "authentication" ? ["Sign out of T3 Connect and sign in again."]
                : ["Check this device's internet connection.", "A VPN, firewall, or ad blocker on this device can block T3 Connect."]
        case .tunnel:
            return failedOnThisDevice(failure)
                ? ["A VPN, firewall, or DNS filter on this device can block the tunnel.",
                   "Try another network, or add a direct route such as a Tailscale address."]
                : ["Make sure \(host) is awake and online.", checkHost]
        case .server: return ["Make sure T3 Code is running on \(host).", "Retry. If it keeps failing, copy the diagnostics."]
        }
    }

    /// `helpSection` (diagnosis.ts:211-259): a section of docs/user/t3-connect-troubleshooting.md.
    private static func helpSection(_ located: Located, _ failure: ConnectionFailureInfo?) -> String {
        switch located.cause {
        case "offline": return "this-device-cant-reach-t3-connect"
        case "outdated": return "the-host-runs-an-older-t3-code"
        case "clock_skew": return "the-clock-is-off"
        case "not_linked", "tunnel_not_enabled": return "sign-in-account-or-link-problems"
        case "relay_error": return "t3-connect-returned-an-error"
        case "released", "tunnel_down", "tunnel_pending": return "the-hosts-tunnel-is-offline"
        case "origin_unreachable", "invalid_response": return "the-tunnel-works-but-t3-code-does-not-answer"
        case "dns", "tls", "refused", "timeout", "unknown": return "the-t3-connect-address-does-not-resolve-or-answer"
        default: break
        }
        switch located.hop {
        case .device: return "this-device-cant-reach-t3-connect"
        case .relay: return failure?.reason == "authentication" ? "sign-in-account-or-link-problems" : "this-device-cant-reach-t3-connect"
        case .tunnel: return failedOnThisDevice(failure) ? "this-device-cant-reach-t3-connect" : "the-hosts-tunnel-is-offline"
        case .server:
            return failure?.reason == "authentication" || failure?.reason == "permission"
                ? "sign-in-account-or-link-problems" : "the-tunnel-works-but-t3-code-does-not-answer"
        }
    }

    private static func hopLabel(_ hop: ConnectionFailureInfo.Hop, _ host: String) -> String {
        switch hop {
        case .device: "This device"
        case .relay: "T3 Connect"
        case .tunnel: "\(host) tunnel"
        case .server: "T3 Code on \(host)"
        }
    }

    /// `presentConnectionDiagnosis` (diagnosis.ts:281-333): nil when nothing has failed.
    public static func present(_ input: Input) -> ConnectionDiagnosis? {
        guard let located = locate(input) else { return nil }
        let host = input.hostLabel
        let failure = input.failure
        let relayPath = located.hop == .relay || located.hop == .tunnel
            || (failure == nil && input.relayStatus?.status == "offline") || (failure?.via ?? input.via) == .relay
        let order: [ConnectionFailureInfo.Hop] = relayPath ? [.device, .relay, .tunnel, .server] : [.device, .server]
        let failedIndex = order.firstIndex(of: located.hop) ?? -1
        let hops = order.enumerated().map { index, hop in
            Hop(hop: hop, label: hopLabel(hop, host), result: index < failedIndex ? .ok : index == failedIndex ? .failed : .unchecked)
        }
        // The relay health check only explains the state when no attempt has failed yet.
        let httpStatus = failure != nil ? failure?.httpStatus : input.relayStatus?.endpointStatus
        var facts: [(label: String, value: String)] = []
        func add(_ label: String, _ value: String?) { if let value, !value.isEmpty { facts.append((label, value)) } }
        add("Cause", located.cause ?? failure?.reason)
        add("HTTP status", httpStatus.map(String.init))
        add("Attempts", input.attempt > 0 ? String(input.attempt) : nil)
        add("Next retry", input.retryAt.map(isoString))
        add("Route", relayPath ? "T3 Connect" : "Direct")
        add("App version", input.clientVersion)
        add("Host version", input.serverVersion)
        add("Error", failure.map { Self.redacted($0.detail) })
        add("Trace ID", failure?.traceId)
        return ConnectionDiagnosis(headline: headline(host, located, failure), hops: hops, steps: steps(host, located, failure), facts: facts,
                                   moreInfoURL: relayPath ? t3ConnectTroubleshootingURL(helpSection(located, failure)) : nil)
    }

    /// Error text can quote a server or a URL, and Copy diagnostics puts it on the clipboard: credentials in an
    /// auth header, a URL's user info or a token parameter or fragment go.
    static func redacted(_ text: String) -> String {
        var out = text
        for (pattern, template) in [(#"(?i)\b(Bearer|DPoP|Basic)\s+[^\s,;"']+"#, "$1 [redacted]"),
                                    (#"(://)[^/\s@]+@"#, "$1[redacted]@"),
                                    (#"(?i)\b((?:access_)?token|pairingToken|credential|secret|password|code)=[^&\s#"']+"#, "$1=[redacted]")] {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    /// `DateTime.formatIso`: `2026-10-22T10:00:00.000Z`.
    private static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// `connectionDiagnosisText` (diagnosis.ts:337-348): one plain-text block for bug reports.
    public func text(hostLabel: String) -> String {
        let marks: [HopResult: String] = [.ok: "ok", .failed: "FAILED", .unchecked: "not checked"]
        return ([ "T3 Code connection to \(hostLabel): \(headline)", "" ]
            + hops.map { "\($0.label): \(marks[$0.result]!)" } + [""]
            + facts.map { "\($0.label): \($0.value)" }
            + (moreInfoURL.map { ["", "More info: \($0)"] } ?? [])).joined(separator: "\n")
    }
}
