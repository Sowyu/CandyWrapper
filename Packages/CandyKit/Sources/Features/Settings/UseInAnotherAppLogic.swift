import Foundation
import T3Protocol

/// "Use T3 Code in another app (MCP)" without views (T3 965ddc1d6c, PR #33196): the app catalog
/// (components/mcp/mcpApps.ts), the gate before the steps (mcp/mcpGate.ts) and the levels a code can approve
/// (mcp/UseInAnotherAppDialog.tsx:216-255).
public enum UseInAnotherApp {
    /// How the Connect step hands the server's MCP URL to an app (`McpAppHandoff`, mcpApps.ts:14-31). Every link is https.
    public enum Handoff: Sendable {
        /// Opens the app's add form with T3 Code filled in.
        case open(@Sendable (String) -> String)
        /// Copies the URL, then opens the page it goes on.
        case copyURL(String)
        /// Copies a message for the app's chat, then opens the app (`appLink` first when it has one).
        case copyMessage(link: String, appLink: (@Sendable (String) -> String)?, message: @Sendable (String) -> String)
        /// Commands to run where the app runs.
        case commands(@Sendable (String) -> [String])
    }

    public struct App: Sendable {
        public let id: String
        public let name: String
        /// The PNG in Resources/mcp-logos.
        public let logo: String
        public let handoff: Handoff
        /// "Set up another way", next to the URL.
        public let steps: [String]
        /// One line under the primary action.
        public let note: String?
        public let docs: String?
        /// Kept out of the grid until its sign-in works.
        public let hidden: Bool

        init(_ id: String, _ name: String, logo: String, _ handoff: Handoff, steps: [String], note: String? = nil, docs: String? = nil, hidden: Bool = false) {
            self.id = id; self.name = name; self.logo = logo; self.handoff = handoff
            self.steps = steps; self.note = note; self.docs = docs; self.hidden = hidden
        }
    }

    static func encoded(_ s: String) -> String {
        // `encodeURIComponent`: everything but A-Z a-z 0-9 - _ . ! ~ * ' ( ).
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// `MCP_APPS` (mcpApps.ts:49-188), in T3's order.
    public static let apps: [App] = [
        App("poke", "Poke", logo: "poke", .open { "https://poke.com/integrations/new?name=T3%20Code&url=\(encoded($0))" },
            steps: ["Open poke.com/integrations/new.", "Paste the URL and add the integration."],
            docs: "https://poke.com/docs/mcp-servers"),
        App("claude", "Claude", logo: "claude",
            .open { "https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=T3%20Code&connectorUrl=\(encoded($0))" },
            steps: ["In Claude, open Customize, then Connectors.", "Choose Add custom connector and paste the URL.",
                    "The Free plan allows one custom connector."],
            docs: "https://claude.com/docs/connectors/building/directory-vs-custom"),
        App("chatgpt", "ChatGPT", logo: "chatgpt", .copyURL("https://chatgpt.com/plugins"),
            steps: ["Open chatgpt.com/plugins on the web, then + and Add custom MCP server.", "Paste the URL. Choose OAuth.",
                    "Create it as a plugin, then install it."],
            docs: "https://developers.openai.com/api/docs/guides/custom-mcp-server"),
        App("grok-bot", "Grok Bot", logo: "grokbot",
            .copyMessage(link: "https://x.ai/bot", appLink: { "grokbot://app/v1/prompt?text=\(encoded($0))" },
                         message: { "Add the MCP server \($0) and connect it." }),
            steps: ["Send this message to any of your Grok Bots."], note: "Shared with all your Grok Bots.",
            docs: "https://docs.x.ai/grok-bot/computer-and-apps"),
        App("gemini", "Gemini", logo: "gemini", .copyURL("https://gemini.google.com/apps"),
            steps: ["In Gemini, open Settings, then Connected apps.", "Choose Custom apps, then Add, and paste the URL."],
            docs: "https://support.google.com/gemini/answer/17209137", hidden: true),
        App("muse", "Muse", logo: "muse",
            .copyMessage(link: "https://muse.ai", appLink: nil, message: { "Create a custom connector for the MCP server \($0)." }),
            steps: ["Send this message to Muse."], docs: "https://www.meta.com/help/artificial-intelligence/1687253048996149/"),
        App("instinct", "Instinct", logo: "instinct",
            .copyMessage(link: "https://app.instinct.com", appLink: nil, message: { "Connect the MCP server \($0)." }),
            steps: ["In Instinct, open Settings, then MCP connections, if your account has it."]),
        App("openclaw", "OpenClaw", logo: "openclaw",
            .commands { ["openclaw gateway stop", "openclaw mcp add t3code --url \($0) --transport streamable-http --auth oauth",
                         "openclaw mcp login t3code", "openclaw gateway start"] },
            steps: ["Open the Control UI, then + and Plugins, and choose Add MCP server.",
                    "Paste the URL, and choose Streamable HTTP and OAuth.", "Select Sign in for it under Settings → MCP."],
            docs: "https://docs.openclaw.ai/tools/mcp"),
        App("hermes-agent", "Hermes Agent", logo: "hermes",
            .commands { ["hermes mcp add t3code --url \($0) --auth oauth --connect-timeout 315"] },
            steps: ["Add t3code under mcp_servers in ~/.hermes/config.yaml, with the URL and auth: oauth.",
                    "Run hermes mcp login t3code."],
            note: "On a remote host, paste the final URL back when asked.",
            docs: "https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp"),
    ]
    public static var shownApps: [App] { apps.filter { !$0.hidden } }
    /// `OTHER_MCP_APP_STEPS`: the "Something else…" choice.
    public static let otherSteps = ["Add a remote MCP server with OAuth."]

    /// The primary button: its label, the https page, the app link tried first and what it copies first
    /// (`mcpHandoffAction`, mcpApps.ts:196-221). Nil for apps set up with commands. It never copies the code.
    public struct Action: Equatable, Sendable {
        public let label: String
        public let link: String
        public let appLink: String?
        public let copy: (text: String, title: String)?
        public static func == (a: Action, b: Action) -> Bool {
            a.label == b.label && a.link == b.link && a.appLink == b.appLink && a.copy?.text == b.copy?.text && a.copy?.title == b.copy?.title
        }
    }

    public static func action(_ app: App, mcpURL: String) -> Action? {
        switch app.handoff {
        case .open(let link):
            return Action(label: "Open in \(app.name)", link: link(mcpURL), appLink: nil, copy: nil)
        case .copyURL(let link):
            return Action(label: "Copy URL and open \(app.name)", link: link, appLink: nil, copy: (mcpURL, "URL copied"))
        case .copyMessage(let link, let appLink, let message):
            let text = message(mcpURL)
            return Action(label: "Copy message and open \(app.name)", link: link, appLink: appLink?(text), copy: (text, "Message copied"))
        case .commands:
            return nil
        }
    }

    /// The message to copy in "Set up another way", for apps handed a message.
    public static func message(_ app: App?, mcpURL: String) -> String? {
        if case .copyMessage(_, _, let message)? = app?.handoff { return message(mcpURL) }
        return nil
    }

    // MARK: Gate

    /// What stands between the user and the steps (`McpGate`, mcpGate.ts:19-33). Only `open` goes on: cloud
    /// apps need a public address, so the environment must answer on its T3 Connect tunnel.
    public enum Gate: Equatable, Sendable {
        public enum RelayTrouble: Equatable, Sendable { case offline, failed }
        case checking, signIn
        /// `relay`: T3 Connect reports the saved machine offline, or its list could not be read; nil means reconnect.
        case disconnected(relay: RelayTrouble?)
        case update, noRelayRead
        case error(String)
        case turnOn
        /// The server's unreachable answer, or nil when the check itself failed.
        case offline(ConnectReachability?)
        case open(mcpURL: String)
    }

    /// The account's machines on T3 Connect, where a saved machine's address and health come from.
    public enum Relay: Equatable, Sendable {
        public enum Availability: Equatable, Sendable { case checking, online, offline, error }
        case loading, failed
        case listed(providerKind: String?, httpBaseUrl: String?, availability: Availability?)
    }

    public enum Reachability: Equatable, Sendable {
        case checking
        /// The check's answer, or nil when it failed.
        case result(ConnectReachability?)
    }

    public struct GateInput: Equatable, Sendable {
        /// Nil until T3 Connect sign-in has loaded.
        public var signedIn: Bool?
        public var connected: Bool
        /// The `mcpApprovalCodes` capability; nil until the descriptor loads.
        public var approvalCodes: Bool?
        public var canReadRelay: Bool
        public var linkState: CloudLinkState?
        public var linkStateError: String?
        /// The primary environment: its link state names its own tunnel.
        public var thisMachine: Bool
        public var relay: Relay
        public var reachability: Reachability
        public init(signedIn: Bool?, connected: Bool, approvalCodes: Bool?, canReadRelay: Bool, linkState: CloudLinkState?,
                    linkStateError: String?, thisMachine: Bool, relay: Relay, reachability: Reachability) {
            self.signedIn = signedIn; self.connected = connected; self.approvalCodes = approvalCodes
            self.canReadRelay = canReadRelay; self.linkState = linkState; self.linkStateError = linkStateError
            self.thisMachine = thisMachine; self.relay = relay; self.reachability = reachability
        }
    }

    /// `resolveMcpGate` (mcpGate.ts:35-97).
    public static func gate(_ input: GateInput) -> Gate {
        guard let signedIn = input.signedIn else { return .checking }
        guard signedIn else { return .signIn }
        let relay = input.relay
        if !input.connected {
            if input.thisMachine { return .disconnected(relay: nil) }
            // T3 Connect checks only its own tunnels; a publish-only link's check always fails.
            var availability: Relay.Availability?
            if case .listed(let kind, _, let a) = relay, kind == "cloudflare_tunnel" { availability = a }
            if relay == .loading || availability == .checking { return .checking }
            if relay == .failed || availability == .error { return .disconnected(relay: .failed) }
            return .disconnected(relay: availability == .offline ? .offline : nil)
        }
        guard let codes = input.approvalCodes else { return .checking }
        guard codes else { return .update }
        guard input.canReadRelay else { return .noRelayRead }
        if let error = input.linkStateError { return .error(error) }
        guard let linkState = input.linkState else { return .checking }
        var endpoint: (kind: String?, url: String?)?
        if !input.thisMachine, case .listed(let kind, let url, _) = relay, kind != nil || url != nil { endpoint = (kind, url) }
        guard linkState.managedTunnelActive(relayProviderKind: endpoint?.kind) else { return .turnOn }
        if !input.thisMachine {
            if relay == .loading { return .checking }
            if relay == .failed { return .error("Could not reach T3 Connect.") }
            if endpoint == nil { return .turnOn }
        }
        if input.reachability == .checking { return .checking }
        let url = mcpURL(thisMachine: input.thisMachine, tunnelHostname: linkState.tunnelHostname,
                         relayProviderKind: endpoint?.kind, relayHttpBaseUrl: endpoint?.url)
        guard case .result(let reach) = input.reachability else { return .checking }
        if reach?.status == "reachable", let url { return .open(mcpURL: url) }
        return .offline(reach?.status == "unreachable" ? reach : nil)
    }

    /// `t3ConnectMcpUrl` (cloud/t3ConnectState.ts:38-59). The URL ends up in commands people paste into a
    /// shell, so only https and plain DNS names pass.
    public static func mcpURL(thisMachine: Bool, tunnelHostname: String?, relayProviderKind: String?, relayHttpBaseUrl: String?) -> String? {
        let raw: String? = thisMachine ? "https://\(tunnelHostname ?? "")"
            : relayProviderKind == "cloudflare_tunnel" ? relayHttpBaseUrl : nil
        guard let raw, let url = URL(string: raw), url.scheme == "https", let host = url.host,
              host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "https://\(host.lowercased())\(port)/mcp"
    }

    /// `afterFailedCheck` (mcpGate.ts:104-128): what a failed check request leaves. A result newer than
    /// `prior` counts; otherwise only a later server check does, and with nothing read at all only a retry.
    public static func afterFailedCheck(prior: CloudLinkState?, latest: CloudLinkState?) -> (result: ConnectReachability?, since: String?) {
        let fresh = latest?.reachability, known = prior?.reachability
        if let fresh, prior != nil, known == nil || (fresh.checkedAt ?? "") > (known?.checkedAt ?? "") {
            return (fresh, fresh.checkedAt)
        }
        guard let baseline = latest ?? prior else { return (nil, nil) }
        return (nil, baseline.reachability?.checkedAt ?? "")
    }

    // MARK: Levels

    /// `DEFAULT_LEVELS`: the Access step starts at Auto, else the next level down that can be granted.
    public static let defaultLevels: [McpClientAccess] = [.auto, .autoAcceptEdits, .approvalRequired, .readOnly]

    /// Why each level cannot be granted (`useGrantableLevels`, UseInAnotherAppDialog.tsx:225-255); absent when it can.
    /// Managed policy is left out: CandyWrapper does not read organization policy.
    public static func blockedLevels(session: AuthSessionState?, environment: String) -> [McpClientAccess: String] {
        var out: [McpClientAccess: String] = [:]
        for level in McpClientAccess.allCases {
            if session?.grants(AuthScopes.accessWrite) != true {
                out[level] = "This device needs the Manage access permission on \(environment)."
            } else if let session, !level.scopes.allSatisfy(session.grants) {
                out[level] = "This device cannot grant this on \(environment)."
            }
        }
        return out
    }

    public static func defaultLevel(blocked: [McpClientAccess: String]) -> McpClientAccess? {
        defaultLevels.first { blocked[$0] == nil }
    }

    /// `accessConfig` (auth/ConnectAgentSurface.tsx:38-48 with chat/runtimeModeConfig.ts:13-38 at 4928).
    public static func label(_ level: McpClientAccess) -> String { LinkAccess.label(level.rawValue) }
    public static func description(_ level: McpClientAccess) -> String {
        level == .fullAccess ? "Runs commands and edits files without asking"
            : LinkAccess.all.first { $0.value == level.rawValue }?.description ?? ""
    }

    /// `LinkedLine` (UseInAnotherAppDialog.tsx:880-913): machines this one links to, at the level a call forwarded
    /// there gets, the lower of the app's and the link's own. Nil without links.
    public static func linkedLine(_ links: [(name: String, access: String, expired: Bool)], access: McpClientAccess?) -> String? {
        guard !links.isEmpty else { return nil }
        let rank = { (raw: String) in McpClientAccess.allCases.firstIndex { $0.rawValue == raw } ?? 0 }
        let named = links.map { link -> String in
            let level = access.map { rank(link.access) < rank($0.rawValue) ? link.access : $0.rawValue } ?? link.access
            return "\(link.name) · \(link.expired ? "Expired" : LinkAccess.label(level))"
        }
        return "Linked: \(named.joined(separator: ", "))"
    }

    /// `Expires 4:59 · one use` (UseInAnotherAppDialog.tsx:839-843).
    public static func expiry(secondsLeft: Int) -> String {
        let s = max(0, secondsLeft)
        return "Expires \(s / 60):\(String(format: "%02d", s % 60)) · one use"
    }

    /// The dialog title. T3 names the server's product, since the MCP endpoint is T3 Code's; the label is the environment's.
    public static func title(environment: String?) -> String {
        "Use T3 Code in another app (MCP) · \(environment ?? "T3 Code")"
    }
}
