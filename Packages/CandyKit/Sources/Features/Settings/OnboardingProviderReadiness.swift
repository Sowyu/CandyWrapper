import T3Protocol

/// onboarding/providerReadiness.logic.ts:38-74.
public enum OnboardingProviderReadiness {
    public enum State: Int, Sendable { case checking, disabled, install, attention, signIn, ready }
    public static func state(_ provider: ServerProvider?) -> State {
        guard let provider else { return .checking }
        if !provider.enabled || provider.status == .disabled { return .disabled }
        if !provider.installed && provider.status == .warning && provider.auth?["status"]?.stringValue == "unknown" { return .checking }
        if !provider.installed { return .install }
        if provider.auth?["status"]?.stringValue == "unauthenticated" { return .signIn }
        return provider.status == .ready ? .ready : .attention
    }
    public static func select(_ providers: [ServerProvider], driver: String) -> ServerProvider? {
        providers.filter { $0.driver == driver }.reduce(nil) { current, next in
            guard let current else { return next }
            return state(next).rawValue > state(current).rawValue ? next : current
        }
    }
}
