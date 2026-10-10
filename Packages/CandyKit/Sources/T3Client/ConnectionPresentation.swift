import Foundation

public extension ConnectionState {
    /// The failure message T3 shows with a status, kept only where T3 keeps it (presentation.ts:29-58).
    var presentedError: String? {
        switch phase {
        case .available, .offline, .connected: nil
        default: lastFailure
        }
    }

    /// `connectionStatusText` (client-runtime connection/presentation.ts:60-79).
    var statusText: String {
        switch status {
        case .available: "Available"
        case .offline: "Offline"
        case .connecting: "Connecting..."
        case .reconnecting: presentedError.map { "Failed to connect. Reconnecting... Reason: \($0)" } ?? "Reconnecting..."
        case .connected: "Connected"
        case .unsupported: "Client not supported"
        case .error: presentedError.map { "Connection failed. Reason: \($0)" } ?? "Connection failed"
        }
    }
}

/// The Environments row subtitle's status (ConnectionsSettings.tsx `savedBackendStatus`, :1452-1482).
public struct EnvironmentRowStatus: Sendable, Equatable {
    public let text: String
    /// Drawn in the destructive color.
    public let isError: Bool

    /// `state` nil means no session runs for it, T3's "available".
    public init(enabled: Bool, state: ConnectionState?) {
        let status = state?.status ?? .available
        if !enabled && status != .unsupported {
            (text, isError) = ("Off", false)
            return
        }
        let error = state?.presentedError
        switch status {
        case .connected: (text, isError) = ("Connected", false)
        case .connecting: (text, isError) = ("Connecting", false)
        case .reconnecting: (text, isError) = (error.map { "Reconnecting: \($0)" } ?? "Reconnecting", true)
        case .unsupported: (text, isError) = ("Client not supported", false)
        case .error: (text, isError) = (error.map { "Connection failed: \($0)" } ?? "Connection failed", true)
        case .offline: (text, isError) = ("Offline", false)
        case .available: (text, isError) = ("Not connected", false)
        }
    }

    /// The subtitle tooltip (:1604-1615): the long status, or "Switched off".
    public static func tooltip(enabled: Bool, state: ConnectionState?) -> String {
        let s = state ?? ConnectionState()
        if s.status == .unsupported { return s.presentedError ?? s.statusText }
        return enabled ? s.statusText : "Switched off"
    }

    /// `environmentTransportLabel` for a direct-route machine (EnvironmentRow.tsx:26-52): with several
    /// routes, `via <route>` for the one in use, else the first route's label; with one, its URL.
    public static func transport(routes: [URL], inUse: URL?) -> String {
        guard routes.count > 1 else { return routes.first.map(displayURL) ?? "Remote link" }
        if let inUse, let active = routes.first(where: { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(inUse) }) {
            return "via \(EnvironmentRoute.label(active))"
        }
        return EnvironmentRoute.label(routes[0])
    }

    /// T3 shows the saved `httpBaseUrl`, an origin with a trailing slash.
    public static func displayURL(_ url: URL) -> String { EnvironmentRoute.origin(url) + "/" }
}
