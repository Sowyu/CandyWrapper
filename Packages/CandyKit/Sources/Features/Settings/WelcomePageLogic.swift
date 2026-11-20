import Foundation
import T3Protocol
import T3Store

/// The Welcome page's decisions (apps/web/src/onboarding/welcomePage.logic.ts at Nightly 4928), kept out of
/// the view so they can be tested.
public enum WelcomePageLogic {
    /// `welcomeAgentState`.
    public enum AgentState: String, Sendable { case checking, disabled, install, attention, signIn, ready }

    /// `isProviderAvailable` (contracts server.ts:359-360).
    public static func available(_ provider: ServerProvider) -> Bool { provider.availability != "unavailable" }

    /// `resolveProjectProviderInstanceEnabled` with no project (contracts settings.ts:1646-1660).
    public static func enabledForNewThreads(_ provider: ServerProvider, settings: JSONValue?) -> Bool {
        guard let settings else { return true }
        if let instance = settings["providerInstances"]?[provider.instanceId.rawValue], instance != .null {
            return ProjectSettings.providerInstanceEnabled(instance)
        }
        return ["codex", "claudeAgent"].contains(provider.instanceId.rawValue)
    }

    /// welcomePage.logic.ts:27-41.
    public static func state(_ provider: ServerProvider, settings: JSONValue?) -> AgentState {
        if !available(provider) { return .attention }
        if !enabledForNewThreads(provider, settings: settings) { return .disabled }
        let state: AgentState = switch OnboardingProviderReadiness.state(provider) {
        case .checking: .checking
        case .disabled: .disabled
        case .install: .install
        case .attention: .attention
        case .signIn: .signIn
        case .ready: .ready
        }
        if state == .ready && provider.compatibilityAdvisory?["status"]?.stringValue == "broken" { return .attention }
        return state == .checking && provider.driver == "acpRegistry" ? .attention : state
    }

    /// `resolveProviderInstanceDisplayName` (client-runtime providerInstanceDisplay.ts:16-27).
    public static func name(_ provider: ServerProvider) -> String {
        let kind = displayNames[provider.driver] ?? humanize(provider.driver)
        let trimmed = provider.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty && trimmed != kind { return trimmed }
        if provider.instanceId.rawValue != provider.driver {
            let humanized = humanize(provider.instanceId.rawValue)
            if !humanized.isEmpty { return humanized }
        }
        return trimmed.isEmpty ? kind : trimmed
    }

    /// `PROVIDER_DISPLAY_NAMES` (contracts model.ts:197-209).
    static let displayNames = ["antigravity": "Antigravity", "codex": "Codex", "claudeAgent": "Claude", "cursor": "Cursor",
                               "grok": "Grok", "fx": "fx", "kiro": "Kiro", "muse": "Muse Code", "acpRegistry": "ACP Registry",
                               "pi": "Pi", "opencode": "OpenCode"]

    /// `humanizeSlug`: split camelCase and separators, then capitalize each word.
    static func humanize(_ slug: String) -> String {
        var out = ""
        var previousLower = false
        for ch in slug {
            if ch == "_" || ch == "-" {
                if !out.hasSuffix(" ") { out.append(" ") }
                previousLower = false
                continue
            }
            if ch.isUppercase && previousLower { out.append(" ") }
            out.append(ch)
            previousLower = ch.isLowercase
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        var result = ""
        var startOfWord = true
        for ch in trimmed {
            result.append(startOfWord ? Character(ch.uppercased()) : ch)
            startOfWord = !(ch.isLetter || ch.isNumber || ch == "_")
        }
        return result
    }

    public struct Groups: Equatable {
        public var checking: Bool
        public var readyCount: Int
        public var found: [ServerProvider]
        public var available: [ServerProvider]
    }

    /// `groupWelcomeAgents`: agents on the computer (ready, sign-in, attention) and agents to add. Agents still
    /// being checked are listed to add, so a slow check never drops one.
    public static func group(_ providers: [ServerProvider]?, settings: JSONValue?) -> Groups {
        let order: [AgentState: Int] = [.ready: 0, .signIn: 1, .attention: 2]
        var found: [(ServerProvider, AgentState)] = []
        var rest: [ServerProvider] = []
        var checking = providers == nil
        var ready = 0
        for provider in providers ?? [] {
            let state = state(provider, settings: settings)
            if state == .ready { ready += 1 }
            if state == .checking { checking = true }
            if order[state] != nil { found.append((provider, state)) } else { rest.append(provider) }
        }
        let byName: (ServerProvider, ServerProvider) -> Bool = { name($0).localizedCompare(name($1)) == .orderedAscending }
        found.sort { order[$0.1]! != order[$1.1]! ? order[$0.1]! < order[$1.1]! : byName($0.0, $1.0) }
        return Groups(checking: checking, readyCount: ready, found: found.map(\.0), available: rest.sorted(by: byName))
    }

    /// `isBrokenVersion`.
    public static func brokenVersion(_ provider: ServerProvider) -> Bool {
        provider.installed && provider.compatibilityAdvisory?["status"]?.stringValue == "broken"
    }

    static let installable: Set<String> = ["codex", "claudeAgent"]
    public static func isInstallable(_ driver: String) -> Bool { installable.contains(driver) }

    /// `needsInstallOrSignIn` (WelcomePage.tsx:482-489).
    public static func needsTerminal(_ provider: ServerProvider, settings: JSONValue?) -> Bool {
        let state = state(provider, settings: settings)
        return isInstallable(provider.driver) && !brokenVersion(provider) && (state == .install || state == .signIn)
    }

    /// `codexNeedsSetup`.
    public static func codexNeedsSetup(_ provider: ServerProvider, settings: JSONValue?) -> Bool {
        if provider.driver != "codex" || provider.auth?["status"]?.stringValue == "authenticated" || brokenVersion(provider) { return false }
        let state = state(provider, settings: settings)
        return state == .install || state == .signIn || (state == .attention && available(provider))
    }

    public enum CliStep: Equatable { case wait, open, done }
    /// `cliTerminalStep`: what Use existing CLI does next.
    public static func cliTerminalStep(_ provider: ServerProvider, settings: JSONValue?) -> CliStep {
        if provider.setup?["canAuthenticate"]?.boolValue == true { return .wait }
        let state = state(provider, settings: settings)
        if state == .checking { return .wait }
        if brokenVersion(provider) { return .done }
        if provider.installed && provider.auth?["status"]?.stringValue == "authenticated" { return .done }
        let fixable = state == .install || state == .signIn || (state == .attention && available(provider))
        return fixable ? .open : .done
    }

    /// `welcomeOffersPhone`, without the managed policy CandyWrapper does not read.
    public static func offersPhone(isPrimary: Bool, cloud: Bool, canShare: Bool) -> Bool { isPrimary && cloud && canShare }

    /// `codexCardProvider`: the instance the setup card shows, kept through a rebuild that drops it briefly.
    public static func codexCardProvider(_ providers: [ServerProvider]?, instanceId: String?, last: ServerProvider?,
                                         settings: JSONValue?) -> ServerProvider? {
        guard let instanceId else { return nil }
        guard let provider = providers?.first(where: { $0.instanceId.rawValue == instanceId })
            ?? (last?.instanceId.rawValue == instanceId ? last : nil) else { return nil }
        let open = codexNeedsSetup(provider, settings: settings) || state(provider, settings: settings) == .checking
        return open ? provider : nil
    }

    /// The row's detail line (WelcomePage.tsx:1234-1250); `headline` stands in for `getProviderSummary`.
    public static func detail(_ provider: ServerProvider, state: AgentState, compact: Bool, headline: String?) -> String? {
        let broken = brokenVersion(provider) ? provider.compatibilityAdvisory?["message"]?.stringValue : nil
        if state == .install { return isInstallable(provider.driver) ? nil : "Not installed" }
        if compact || state == .ready || state == .checking { return nil }
        if state == .attention { return provider.unavailableReason ?? broken ?? provider.message ?? headline }
        return broken ?? headline
    }

    // MARK: Commands (providerReadiness.logic.ts:20-87)

    /// `quoteProviderBinary`.
    static func quote(_ binary: String, fallback: String, platform: String) -> String {
        let safe = binary.range(of: "^[A-Za-z0-9_./:\\\\-]+$", options: .regularExpression) != nil
        if safe && (platform == "windows" || !binary.contains("\\")) { return binary }
        if platform == "windows" { return "& '" + binary.replacingOccurrences(of: "'", with: "''") + "'" }
        if platform == "darwin" || platform == "linux" {
            let escape = { (s: Substring) in s.replacingOccurrences(of: "'", with: "'\"'\"'") }
            if binary.hasPrefix("~/") || binary.hasPrefix("~\\") { return "~/'" + escape(binary.dropFirst(2)) + "'" }
            return "'" + escape(Substring(binary)) + "'"
        }
        return fallback
    }

    /// `resolveOnboardingProviderInstallCommand`.
    public static func installCommand(driver: String, platform: String) -> String {
        let windows = platform == "windows"
        return driver == "claudeAgent"
            ? (windows ? "irm https://claude.ai/install.ps1 | iex" : "curl -fsSL https://claude.ai/install.sh | bash")
            : (windows ? "irm https://chatgpt.com/codex/install.ps1 | iex" : "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
    }

    /// `resolveOnboardingProviderLoginCommand`.
    public static func loginCommand(_ provider: ServerProvider, settings: JSONValue?, platform: String) -> String {
        let config = settings?["providerInstances"]?[provider.instanceId.rawValue]?["config"]
        switch provider.driver {
        case "claudeAgent": return quote(config?["binaryPath"]?.stringValue ?? "claude", fallback: "claude", platform: platform) + " auth login"
        case "codex": return quote(config?["binaryPath"]?.stringValue ?? "codex", fallback: "codex", platform: platform) + " login"
        default: return provider.driver
        }
    }

    /// `turnedOnInstance`: older settings can keep `enabled: false` inside `config` too.
    public static func turnedOn(_ instance: JSONValue) -> JSONValue {
        guard var object = instance.objectValue else { return instance }
        object["enabled"] = .bool(true)
        if var config = object["config"]?.objectValue, config["enabled"]?.boolValue == false {
            config["enabled"] = .bool(true)
            object["config"] = .object(config)
        }
        return .object(object)
    }

    // MARK: Projects (WelcomePage.tsx:1520-1555, welcomeState.ts)

    /// `WelcomeImportSelection`: kept until setup finishes, so a visit to Settings or a restart keeps the choices.
    public struct Selection: Codable, Equatable, Sendable {
        public var knownKeys: [String]
        public var keys: [String]
        public var optedOut: Bool
        public init(knownKeys: [String], keys: [String], optedOut: Bool) {
            self.knownKeys = knownKeys; self.keys = keys; self.optedOut = optedOut
        }
    }

    /// `welcomeImportSelectionKey`.
    public static func selectionKey(_ environmentId: String) -> String { "t3code:welcome-import-selection:\(environmentId)" }

    /// `isNewOnboardingProject` (projectImport.logic.ts:111-131).
    public static func isNew(_ candidate: OnboardingProjectCandidate, roots: [String]) -> Bool {
        if candidate.projectId != nil { return false }
        let path = SidebarModel.normalizeProjectPath(candidate.path)
        return path.isEmpty || !roots.contains { SidebarModel.normalizeProjectPath($0) == path }
    }

    /// The picked candidates: stored picks for listed projects, recent new ones for projects found since.
    public static func selected(_ candidates: [OnboardingProjectCandidate], selection: Selection?, recent: Set<String>) -> [OnboardingProjectCandidate] {
        if selection?.optedOut == true { return [] }
        let known = Set(selection?.knownKeys ?? []), picked = Set(selection?.keys ?? [])
        return candidates.filter { known.contains($0.key) ? picked.contains($0.key) : recent.contains($0.key) }
    }

    /// The main box's picks when checked: recent new projects, else any new ones, else everything listed.
    public static func defaultKeys(_ candidates: [OnboardingProjectCandidate], recent: [OnboardingProjectCandidate],
                                   isNew: (OnboardingProjectCandidate) -> Bool) -> [String] {
        let fresh = candidates.filter(isNew)
        return (recent.isEmpty ? fresh.isEmpty ? candidates : fresh : recent).map(\.key)
    }

    /// The Start button's title (WelcomePage.tsx:310-322).
    public static func startTitle(importing: Bool, selected: Int, new: Int) -> String {
        if importing { return selected > 0 ? "Importing…" : "Starting…" }
        if new > 0 { return "Import \(new) \(new == 1 ? "project" : "projects") and start" }
        return selected > 0 ? "Import threads and start" : "Start"
    }

    /// The scan's sources as a list (`useImportSourcesLabel`, `Intl.ListFormat` conjunction in English).
    public static let importSourcesLabel = "Claude Code, Codex, and Pi"
}
