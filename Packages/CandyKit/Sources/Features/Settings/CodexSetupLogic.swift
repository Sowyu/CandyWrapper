import Foundation
import T3Protocol

/// The decisions of T3's managed Codex setup (components/settings/CodexSetupSection.tsx:197-1000,
/// CodexSetupSection.logic.ts, ChatGptAccountPicker.tsx, ChatGptWelcomeCoordinator.tsx), kept apart from
/// the views so tests can drive them with fixture states.
public enum CodexSetupLogic {
    /// `readCodexSetupMode` (CodexSetupSection.logic.ts:1-8).
    public static func setupMode(_ config: JSONValue?) -> String {
        config?["setupMode"]?.stringValue == "managed" ? "managed" : "existing"
    }

    /// `CHATGPT_USAGE_URL` (packages/shared/src/usageLimits.ts).
    public static let usageURL = UsageLimitsLogic.chatGptUsageURL
    public static let changeAccountMethod = "chatgpt-change-account"
    static let profilePrefix = "chatgpt-profile:"

    /// The app's own URL scheme (`t3code` in release builds), from Info.plist.
    public static var appScheme: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .first.flatMap { ($0["CFBundleURLSchemes"] as? [String])?.first } ?? "t3code"
    }

    /// `returnUrl` (CodexSetupSection.tsx:263-266, 395-398): the desktop app's `window.location.href`
    /// is `t3code://app/<route>`; Welcome adds `#agents:<environment>`, Settings adds `?instanceId=`.
    public static func returnURL(onboarding: Bool, environment: String, instance: String, scheme: String = appScheme) -> String {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "app"
        if onboarding {
            c.path = "/welcome"
            c.fragment = "agents:" + environment
        } else {
            c.path = "/settings/providers"
            c.queryItems = [URLQueryItem(name: "instanceId", value: instance)]
        }
        return c.string ?? scheme + "://app/settings/providers"
    }

    /// `primaryAuthEnvironmentId` (CodexSetupSection.tsx:254-262): a remote environment signs in through the
    /// primary when the primary is connected and on this computer, and this client is the desktop app.
    public static func primaryAuthEnvironment(local: Bool, primary: String?, primaryConnected: Bool, primaryLocal: Bool,
                                              desktop: Bool) -> String? {
        guard !local, let primary, primaryConnected, primaryLocal, desktop else { return nil }
        return primary
    }

    public static func isLoopback(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return PreviewURL.isLoopbackHost(host)
    }

    // MARK: Account picker (ChatGptAccountPicker.tsx:25-32)

    /// The saved profiles the picker lists, in the server's order.
    public static func pickerProfiles(_ methods: [JSONValue]) -> [(id: String, name: String)] {
        methods.compactMap { m in
            guard let id = m["id"]?.stringValue, id.hasPrefix(profilePrefix) else { return nil }
            return (id, m["name"]?.stringValue ?? id)
        }
    }

    /// The checked radio: an explicit "different account", else the chosen profile, else the first profile.
    public static func pickerSelection(_ selection: String?, profiles: [(id: String, name: String)]) -> String {
        if selection == changeAccountMethod { return changeAccountMethod }
        return profiles.first { $0.id == selection }?.id ?? profiles.first?.id ?? changeAccountMethod
    }

    /// `onSelect` (CodexSetupSection.tsx:729-737): a method the server no longer lists becomes "different account".
    public static func pickedMethod(_ id: String, methods: [JSONValue]) -> String {
        methods.contains { $0["id"]?.stringValue == id } ? id : changeAccountMethod
    }

    // MARK: Welcome (ChatGptWelcomeCoordinator.tsx)

    public static let welcomeStorageKey = "t3:chatgpt-sharing-welcome:v1"

    public struct WelcomeProfile: Equatable, Sendable {
        public var key: String
        public var environmentLabel: String
        public var providerName: String
    }

    /// One entry per connected environment's provider that uses ChatGPT sharing, keyed
    /// `JSON.stringify([environmentId, instanceId, profileId ?? email ?? "default"])`.
    public static func welcomeProfiles(_ environments: [(id: String, label: String, connected: Bool, providers: [ServerProvider])]) -> [WelcomeProfile] {
        environments.flatMap { env -> [WelcomeProfile] in
            guard env.connected else { return [] }
            return env.providers.filter(UsageLimitsLogic.usesChatGptSharing).map { p in
                let profile = p.auth?["profileId"]?.stringValue ?? p.auth?["email"]?.stringValue ?? "default"
                return WelcomeProfile(key: jsonArray([env.id, p.instanceId.rawValue, profile]), environmentLabel: env.label,
                                      providerName: p.displayName ?? "Codex")
            }
        }
    }

    /// `JSON.stringify` of a string array, escaped as JavaScript does.
    static func jsonArray(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        // Foundation escapes `/` as `\/`; JavaScript does not.
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    public static func nextWelcome(_ profiles: [WelcomeProfile], acknowledged: [String]) -> WelcomeProfile? {
        profiles.first { !acknowledged.contains($0.key) }
    }

    /// `readAcknowledgedProfiles`: a JSON string array, anything else reads as none.
    public static func readAcknowledged(_ raw: String?) -> [String] {
        guard let raw, let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any] else { return [] }
        return value.compactMap { $0 as? String }
    }

    public static func writeAcknowledged(_ keys: [String]) -> String {
        jsonArray(keys)
    }
}

/// One managed Codex setup's inputs (CodexSetupSection.tsx:197-325) and what T3 derives from them.
public struct CodexSetupState: Sendable {
    public enum Awaiting: String, Sendable { case signIn = "sign-in", handoff }
    /// What the account line says (`accountDescription` and the onboarding card's description).
    public enum Description: Equatable, Sendable {
        case text(String)
        /// "Signed in as <email>." with the email redacted until clicked.
        case signedIn(String)
        /// `CodexSignInDescription` (CodexSetupSection.tsx:1088-1113): plain, or the help toggle.
        case signInHelp(label: String, toggle: Bool)
    }

    public var provider: ServerProvider?
    public var enabled = true
    public var readOnly = false
    /// `authQuery.data` (`ProviderAuthState`), nil until the first value.
    public var auth: JSONValue?
    public var authError = false
    /// `installQuery.data` (`ProviderInstallState`), nil until the first value.
    public var install: JSONValue?
    public var installError = false
    /// The latest `provider.chatgpt.handoff.subscribe` value while a primary handoff runs.
    public var handoff: JSONValue?
    public var handoffActive = false
    public var transferFailed = false
    public var pending = false
    public var awaitingProvider: Awaiting?
    public var autoStart = false
    public var autoStartHandled = false
    public var requestedMethodId = "chatgpt"
    /// `window.desktopBridge.receiveProviderAuthCallback` exists (always in the app).
    public var desktopBridge = true
    /// The environment's HTTP address is on this computer.
    public var local = true

    public init() {}

    /// `auth`: the handoff's auth state while one runs, else the instance's own.
    public var effectiveAuth: JSONValue? { handoff?["phase"]?.stringValue == "auth" ? handoff?["state"] : auth }
    public var phase: String? { effectiveAuth?["phase"]?.stringValue }
    public var flowId: String? { effectiveAuth?["flowId"]?.stringValue }
    var methods: [JSONValue] { effectiveAuth?["methods"]?.arrayValue ?? [] }
    public var reconnectEmail: String? { methods.first { $0["id"]?.stringValue == "chatgpt" }?["accountEmail"]?.stringValue }
    public var requestedAccountEmail: String? { methods.first { $0["id"]?.stringValue == requestedMethodId }?["accountEmail"]?.stringValue }
    public var hasSavedAccount: Bool { methods.contains { $0["id"]?.stringValue?.hasPrefix(CodexSetupLogic.profilePrefix) == true } }
    /// The sign-in page: the browser interaction's URL, else `authorizationUrl`.
    public var url: String? {
        let interaction = effectiveAuth?["interaction"]
        return interaction?["type"]?.stringValue == "browser" ? interaction?["url"]?.stringValue : effectiveAuth?["authorizationUrl"]?.stringValue
    }
    public var handoffFinished: Bool { handoff?["phase"]?.stringValue == "finished" }

    public var installPhase: String? { install?["phase"]?.stringValue }
    public var installedVersion: String? { install?["installedVersion"]?.stringValue }
    public var installed: Bool { installedVersion != nil }
    public var authenticated: Bool { provider?.auth?["status"]?.stringValue == "authenticated" }
    public var canInstall: Bool { provider?.setup?["canInstall"]?.boolValue == true }
    public var canAuthenticate: Bool { provider?.setup?["canAuthenticate"]?.boolValue == true }
    public var updateAvailable: Bool {
        guard installed, install?["source"]?.stringValue != "local", let version = install?["version"]?.stringValue else { return false }
        return version != installedVersion
    }
    /// `clientCallback`: this client catches the loopback callback (always in the app, unless a handoff runs).
    public var clientCallback: Bool { !handoffActive && (!local || desktopBridge) }
    /// `remoteWeb`: a browser client that cannot catch the callback; it asks for the redirect URL instead.
    public var remoteWeb: Bool { clientCallback && !desktopBridge }

    public var finishingSignIn: Bool {
        awaitingProvider != nil && !authenticated && (phase == "succeeded" || awaitingProvider == .handoff)
    }
    public var startingAutomatically: Bool { autoStart && !autoStartHandled }
    public var waitingForAuthState: Bool {
        awaitingProvider == .signIn && !authenticated && (effectiveAuth == nil || phase == "idle")
    }
    public var authInProgress: Bool {
        finishingSignIn || waitingForAuthState || handoffActive || ["starting", "waiting", "verifying"].contains(phase ?? "")
    }
    public var installActive: Bool { ["downloading", "extracting", "verifying"].contains(installPhase ?? "") }
    public var authActive: Bool { startingAutomatically || authInProgress || (pending && !installActive) }
    public var unavailable: Bool { readOnly || !enabled || pending || authError || installError }
    public var busy: Bool { pending || authInProgress || installActive }
    /// The connection button's disabled state (CodexSetupSection.tsx:819-826, 958-965).
    public var connectionDisabled: Bool { unavailable || busy || (!installed ? !canInstall : !canAuthenticate) }

    /// Signed out locally but the remote revocation failed (CodexSetupSection.tsx:740-741).
    public var logoutWarning: String? {
        guard phase == "idle", let message = effectiveAuth?["message"]?.stringValue, message.hasPrefix("Signed out locally.") else { return nil }
        return message
    }

    /// `runtimeDescription` (CodexSetupSection.tsx:574-584).
    public var runtimeDescription: String {
        switch installPhase {
        case "downloading":
            let mb = { (v: Double) in String(format: "%.1f", v / 1_000_000) }
            let done = install?["downloadedBytes"]?.doubleValue ?? 0
            let total = install?["totalBytes"]?.doubleValue
            return "Downloading \(mb(done))\(total.map { " of \(mb($0))" } ?? "") MB."
        case "extracting": return "Installing Codex."
        case "verifying": return "Checking Codex."
        default:
            if installed {
                let source = install?["source"]?.stringValue == "local" ? "Using your installed Codex" : "Managed by T3 Code"
                return source + (installedVersion.map { " · v\($0)" } ?? "") + "."
            }
            return install?["message"]?.stringValue ?? "T3 Code downloads and manages Codex for you."
        }
    }

    var email: String? {
        guard let e = provider?.auth?["email"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else { return nil }
        return e
    }

    /// `accountDescription` (CodexSetupSection.tsx:585-611), the settings row's description.
    public var accountDescription: Description {
        if finishingSignIn { return .text("Finishing sign-in...") }
        if installActive { return .text(runtimeDescription) }
        if authActive || phase == "failed" || phase == "cancelled" {
            if phase == "waiting", let email = requestedAccountEmail { return .text("Continue as \(email) on OpenAI.") }
            return .text(effectiveAuth?["message"]?.stringValue ?? "Finish signing in in your browser.")
        }
        if authenticated { return email.map(Description.signedIn) ?? .text("Signed in with ChatGPT.") }
        return .text(reconnectEmail ?? "Use your ChatGPT subscription.")
    }

    /// `callbackCompletion` exists: no handoff, waiting, and a sign-in page.
    public var showsCallbackCompletion: Bool { !handoffActive && phase == "waiting" && url != nil }

    /// The onboarding card's description (CodexSetupSection.tsx:760-805).
    public var onboardingDescription: Description {
        if installActive { return .text(runtimeDescription) }
        if authenticated { return email.map(Description.signedIn) ?? .text("Connected to ChatGPT.") }
        if showsCallbackCompletion && !remoteWeb { return .signInHelp(label: "Complete sign-in in your browser.", toggle: true) }
        if startingAutomatically || waitingForAuthState || phase == "starting" || phase == "waiting" || (pending && !installActive) {
            return .signInHelp(label: "Complete sign-in in your browser.", toggle: false)
        }
        if authActive || phase == "failed" || phase == "cancelled" { return accountDescription }
        return .text("Code with your ChatGPT subscription.")
    }

    /// `waitingControl`'s label and enabled state (CodexSetupSection.tsx:624-653).
    public func waitingControl(onboarding: Bool) -> (title: String, enabled: Bool) {
        let enabled = handoffFinished ? !(pending || !transferFailed) : !(url == nil || phase != "waiting")
        let title: String
        if finishingSignIn { title = "Finishing sign-in..." }
        else if handoffFinished { title = transferFailed ? "Retry connection" : "Finishing sign-in..." }
        else if phase == "waiting" { title = remoteWeb ? "Open ChatGPT sign-in" : "Open sign-in page" }
        else { title = onboarding ? "Open sign-in page" : "Signing in..." }
        return (title, enabled)
    }

    /// The connection button's label in settings (CodexSetupSection.tsx:972-976).
    public var connectionTitle: String {
        pending ? "Setting up..." : hasSavedAccount ? "Reconnect account" : "Continue with ChatGPT"
    }

    /// The onboarding connection button (CodexSetupSection.tsx:831-835) also reads the install.
    public var onboardingConnectionTitle: String {
        installActive || pending ? "Setting up..." : hasSavedAccount ? "Reconnect account" : "Continue with ChatGPT"
    }

    /// The line under the settings rows (CodexSetupSection.tsx:1001-1009).
    public func errorLine(_ error: String?) -> String? {
        guard error != nil || authError || installError || installPhase == "failed" else { return nil }
        return error ?? (installPhase == "failed" ? install?["message"]?.stringValue : "Could not read Codex setup status. Reconnect and try again.")
    }

    /// The onboarding card's alert (CodexSetupSection.tsx:743-751).
    public func onboardingError(_ error: String?) -> String? {
        logoutWarning ?? error ?? (authError || installError ? "Could not read setup status. Reconnect and try again."
            : installPhase == "failed" ? install?["message"]?.stringValue : nil)
    }

    /// The auto start effect may run now (CodexSetupSection.tsx:477-498).
    public var autoStartReady: Bool {
        autoStart && !autoStartHandled && !unavailable && !busy && install != nil && canInstall
    }
}
