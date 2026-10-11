import Foundation
import T3Protocol

/// The provider status banner over the top of the timeline (chat/ProviderStatusBanner.tsx): the
/// composer's provider is not ready, signed out, or runs a CLI version known to break turns. One
/// dismissal per status key, so a new problem shows again.
public enum ProviderStatusBannerLogic {
    private static func advisory(_ p: ServerProvider) -> (status: String, message: String?)? {
        guard let a = p.compatibilityAdvisory, let status = a["status"]?.stringValue else { return nil }
        return (status, a["message"]?.stringValue)
    }

    private static func authStatus(_ p: ServerProvider) -> String { p.auth?["status"]?.stringValue ?? "unknown" }

    /// `getIncompatibleVersion`: unsupported and broken versions fail mid-turn, so they warn even when ready.
    static func incompatible(_ p: ServerProvider) -> (status: String, message: String?)? {
        if p.status == .error && authStatus(p) == "unauthenticated" { return nil }
        guard let a = advisory(p), a.status == "broken" || (p.status == .ready && a.status == "unsupported") else { return nil }
        return a
    }

    /// `getProviderStatusBannerKey`: nil when there is nothing to say.
    public static func key(_ p: ServerProvider?) -> String? {
        guard let p, p.status != .disabled else { return nil }
        if let a = incompatible(p) {
            return [p.instanceId.rawValue, a.status, p.version ?? "", a.message ?? ""].joined(separator: "\u{0}")
        }
        if p.status == .ready { return nil }
        // Antigravity checks saved credentials when a session starts; unknown auth after a restart is fine.
        if p.driver == "antigravity", p.installed, p.status == .warning, authStatus(p) == "unknown" { return nil }
        return [p.instanceId.rawValue, p.status.rawValue, authStatus(p), p.message ?? ""].joined(separator: "\u{0}")
    }

    /// `hasProviderSetup`.
    static func hasSetup(_ p: ServerProvider) -> Bool {
        if p.driver == "antigravity" { return true }
        if case .bool(true)? = p.setup?["canAuthenticate"] { return true }
        if case .bool(true)? = p.setup?["canInstall"] { return true }
        return false
    }

    /// `formatProviderDriverKindLabel`: camel case and dashes to capitalized words.
    public static func driverLabel(_ driver: String) -> String {
        driver.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// `getProviderStatusMessage`: broken-version guidance first, then the server's message.
    static func message(_ p: ServerProvider) -> String {
        if authStatus(p) != "unauthenticated", let a = advisory(p), a.status == "broken", let m = a.message { return m }
        if let m = p.message { return m }
        let name = p.displayName?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? driverLabel(p.driver)
        if !p.installed && hasSetup(p) { return "Open provider setup to install \(driverLabel(p.driver)) on this environment." }
        if authStatus(p) == "unauthenticated" {
            if hasSetup(p) { return p.driver == "antigravity" ? "Open provider setup to sign in with Google." : "Open provider setup to sign in." }
            return "Sign in via the CLI to authenticate again."
        }
        switch p.status {
        case .ready: return "No models are available for this provider."
        case .error: return "\(name) provider is unavailable."
        default: return "\(name) provider has limited availability."
        }
    }

    /// The banner for `p` (ProviderStatusBanner.tsx:95-152), or nil when its key is nil or dismissed.
    public static func banner(_ p: ServerProvider?, dismissedKey: String?) -> ThreadErrorState.Banner? {
        guard let p, let key = key(p), key != dismissedKey else { return nil }
        let name = p.displayName?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? driverLabel(p.driver)
        let unauthenticated = p.status == .error && authStatus(p) == "unauthenticated"
        let incompatible = incompatible(p)
        let title = unauthenticated ? "\(name) is unauthenticated"
            : incompatible.map { "\(name) \(p.version ?? "") is \($0.status == "broken" ? "known to be broken" : "unsupported")" }
            ?? "\(name) provider status"
        let warning = incompatible?.status != "broken" && (p.status == .warning || incompatible != nil)
        return ThreadErrorState.Banner(message: incompatible?.message ?? message(p), variant: warning ? .warning : .error,
                                       title: title, info: true, setupLink: hasSetup(p))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
