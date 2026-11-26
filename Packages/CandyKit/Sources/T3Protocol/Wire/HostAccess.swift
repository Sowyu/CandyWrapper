import Foundation

// What Settings > Connections reads and changes on the host it is connected to: the session's
// permissions, the T3 Connect link state and preferences, pairing links and client sessions.
// Shapes from packages/contracts/src/auth.ts and environmentHttp.ts.

/// One grantable permission with T3's copy (packages/shared/src/authScopeOptions.ts, in its order).
public struct AuthScopeOption: Sendable, Equatable {
    public var scope: String
    public var title: String
    public var description: String
}

public enum AuthScopes {
    public static let orchestrationRead = "orchestration:read"
    public static let orchestrationOperate = "orchestration:operate"
    public static let settingsWrite = "settings:write"
    public static let providersManage = "providers:manage"
    public static let environmentMaintain = "environment:maintain"
    public static let previewOperate = "preview:operate"
    public static let diagnosticsRead = "diagnostics:read"
    public static let terminalRead = "terminal:read"
    public static let terminalOperate = "terminal:operate"
    public static let sourceControlWrite = "source-control:write"
    public static let filesystemRead = "filesystem:read"
    public static let filesystemWrite = "filesystem:write"
    public static let accessRead = "access:read"
    public static let accessWrite = "access:write"
    public static let relayRead = "relay:read"
    public static let relayWrite = "relay:write"

    public static let options: [AuthScopeOption] = [
        .init(scope: orchestrationRead, title: "View environment", description: "Read threads, status, checkpoints, and configuration."),
        .init(scope: orchestrationOperate, title: "Operate tasks", description: "Start, update, and stop tasks."),
        .init(scope: settingsWrite, title: "Change environment settings", description: "Edit environment preferences and keybindings."),
        .init(scope: providersManage, title: "Manage providers", description: "Configure, install, sign in to, and update providers and usage sources."),
        .init(scope: environmentMaintain, title: "Maintain environment", description: "Update the server and control environment processes."),
        .init(scope: previewOperate, title: "Control previews", description: "Open browser previews and host browser automation."),
        .init(scope: diagnosticsRead, title: "View diagnostics and usage", description: "Read process diagnostics, resource history, and usage totals."),
        .init(scope: terminalRead, title: "View terminals", description: "Read existing terminal output and status."),
        .init(scope: terminalOperate, title: "Use terminals", description: "Create terminals and send input to running shells."),
        .init(scope: sourceControlWrite, title: "Change source control", description: "Commit, push, manage branches and repositories, and change pull requests."),
        .init(scope: filesystemRead, title: "Read files", description: "Browse host files, search workspaces, and inspect local changes."),
        .init(scope: filesystemWrite, title: "Write files", description: "Edit workspace files and save plans to disk."),
        .init(scope: accessRead, title: "View access", description: "Inspect pairing links and authorized clients."),
        .init(scope: accessWrite, title: "Manage access", description: "Issue and revoke credentials for other clients."),
        .init(scope: relayRead, title: "View relay", description: "Inspect managed relay connectivity."),
        .init(scope: relayWrite, title: "Manage relay", description: "Change managed tunnel connectivity."),
    ]

    /// `AuthStandardClientScopes` (auth.ts:151-168), the default of a new pairing link. Since 3315 it includes
    /// managing access and T3 Connect, which a shell or a full-access agent could reach anyway.
    public static let standard = [orchestrationRead, orchestrationOperate, settingsWrite, providersManage, environmentMaintain,
                                  previewOperate, diagnosticsRead, terminalRead, terminalOperate, sourceControlWrite,
                                  filesystemRead, filesystemWrite, relayRead, accessRead, accessWrite, relayWrite]
    /// The `Read only` preset of the Create pairing link dialog (ConnectionsSettings.tsx:1155-1162).
    public static let readOnly = [orchestrationRead, filesystemRead, diagnosticsRead, terminalRead]

    /// Child permissions that old broad scopes implied (auth.ts:154-164).
    static let legacyParents: [String: String] = [
        filesystemRead: orchestrationRead, diagnosticsRead: orchestrationRead, settingsWrite: orchestrationOperate,
        providersManage: orchestrationOperate, environmentMaintain: orchestrationOperate, previewOperate: orchestrationOperate,
        sourceControlWrite: orchestrationOperate, filesystemWrite: orchestrationOperate, terminalRead: terminalOperate,
    ]

    /// `togglePairingScopeSelection` (ConnectionsSettings.logic.ts:15-31): viewing terminals goes with using them.
    public static func toggle(_ current: [String], _ scope: String, _ checked: Bool) -> [String] {
        let without = current.filter { $0 != scope }
        if !checked { return scope == terminalRead ? without.filter { $0 != terminalOperate } : without }
        let next = without + [scope]
        return scope == terminalOperate && !next.contains(terminalRead) ? next + [terminalRead] : next
    }
}

extension AuthSessionState {
    /// `sessionGrantsScope` (auth.ts:181-192).
    public func grants(_ scope: String) -> Bool {
        guard authenticated else { return false }
        if let permissions { return permissions.contains(scope) }
        if scopes?.contains(scope) == true { return true }
        if auth.serverUpdateScope != nil { return false }
        guard let parent = AuthScopes.legacyParents[scope] else { return false }
        return scopes?.contains(parent) == true
    }

    /// The granted list as T3 reads it for delegation (`permissions ?? scopes`).
    public var grantedScopes: [String] { authenticated ? (permissions ?? scopes ?? []) : [] }
}

/// `GET /api/connect/link-state` and the reply of `POST /api/connect/preferences`
/// (`EnvironmentCloudLinkStateResult`, environmentHttp.ts:410-424).
public struct CloudLinkState: Codable, Sendable, Equatable {
    public var linked: Bool
    public var managedTunnelActive: Bool?
    public var publishAgentActivity: Bool
    public var holdWebhooksWhileOffline: Bool?
    /// `reachability` (environmentHttp.ts:503-504): the server's latest T3 Connect check, absent until one finishes.
    public var reachability: ConnectReachability?
    /// 4928 (environmentHttp.ts:553-559): the account revoked the link, the tunnel's own hostname on this
    /// machine, and whether this backend can link from here.
    public var linkRevoked: Bool?
    public var tunnelHostname: String?
    public var linkableHere: Bool?

    public init(linked: Bool, managedTunnelActive: Bool? = nil, publishAgentActivity: Bool, holdWebhooksWhileOffline: Bool? = nil) {
        self.linked = linked; self.managedTunnelActive = managedTunnelActive
        self.publishAgentActivity = publishAgentActivity; self.holdWebhooksWhileOffline = holdWebhooksWhileOffline
    }

    /// Older servers lack `managedTunnelActive`; for them a link always has a tunnel (useCloudLinkController.ts).
    public var tunnelActive: Bool { managedTunnelActive ?? linked }
    /// `isManagedTunnelActive` (cloud/t3ConnectState.ts:9-19): a tunnel that is not revoked, and for a saved
    /// machine one T3 Connect lists as a Cloudflare tunnel.
    public func managedTunnelActive(relayProviderKind: String?) -> Bool {
        linkRevoked != true && tunnelActive && (relayProviderKind == nil || relayProviderKind == "cloudflare_tunnel")
    }
    public var holdsWebhooks: Bool { holdWebhooksWhileOffline ?? false }
}

/// `EnvironmentConnectReachability` (environmentHttp.ts:411-442): whether other devices reach this
/// environment through its tunnel. `reachable` carries the tunnel facts, `unreachable` the cause and fix.
public struct ConnectReachability: Codable, Sendable, Equatable {
    public var status: String
    public var checkedAt: String?
    public var readyConnections: Int?
    public var `protocol`: String?
    public var cause: String?
    public var reason: String?
    public var hint: String?
    public var fix: String?

    public init(status: String, checkedAt: String? = nil, readyConnections: Int? = nil, protocol: String? = nil,
                cause: String? = nil, reason: String? = nil, hint: String? = nil, fix: String? = nil) {
        self.status = status; self.checkedAt = checkedAt; self.readyConnections = readyConnections; self.protocol = `protocol`
        self.cause = cause; self.reason = reason; self.hint = hint; self.fix = fix
    }

    /// `connectReachabilityHelpUrl` (contracts environmentHttp.ts:479-492): the troubleshooting section for the cause.
    public var helpURL: String? {
        let sections = [
            "not_linked": "sign-in-account-or-link-problems", "connector_not_running": "the-hosts-tunnel-is-offline",
            "connector_not_ready": "the-hosts-tunnel-is-offline", "no_connector": "the-hosts-tunnel-is-offline",
            "edge_unreachable": "port-7844-is-blocked-on-the-host", "origin_unreachable": "the-tunnel-works-but-t3-code-does-not-answer",
            "unexpected_response": "the-tunnel-works-but-t3-code-does-not-answer",
            "dns_failed": "the-t3-connect-address-does-not-resolve-or-answer", "timeout": "the-t3-connect-address-does-not-resolve-or-answer",
        ]
        return cause.flatMap { sections[$0] }.map(t3ConnectTroubleshootingURL)
    }

    /// The row's status line: `formatConnectReachable` ("Tunnel connected · 4 connections · QUIC", :445-456)
    /// or the unreachable reason, hint and fix (SavedEnvironmentRows.tsx:500-503). Nil for other statuses.
    public var statusLine: String? {
        switch status {
        case "reachable":
            var parts = ["Tunnel connected"]
            if let n = readyConnections { parts.append("\(n) connection\(n == 1 ? "" : "s")") }
            if let p = `protocol`, !p.isEmpty { parts.append(p.uppercased()) }
            return parts.joined(separator: " · ")
        case "unreachable":
            return [reason, hint, fix.map { "Fix: \($0)" }].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        default:
            return nil
        }
    }
}

/// `POST /api/connect/preferences` (`EnvironmentCloudPreferencesRequest`). Omit the hold flag to keep it.
public struct CloudPreferencesRequest: Encodable, Sendable, Equatable {
    public var publishAgentActivity: Bool
    public var holdWebhooksWhileOffline: Bool?
    public init(publishAgentActivity: Bool, holdWebhooksWhileOffline: Bool? = nil) {
        self.publishAgentActivity = publishAgentActivity; self.holdWebhooksWhileOffline = holdWebhooksWhileOffline
    }
}

/// `AuthPairingLink` (auth.ts:334-341). Metadata only; the credential comes from creation alone.
public struct AuthPairingLink: Decodable, Sendable, Equatable {
    public var id: String
    public var scopes: [String]?
    public var permissions: [String]?
    public var label: String?
    public var createdAt: T3Timestamp
    public var expiresAt: T3Timestamp
    /// Set while a T3 Connect device waits for approval (4928 auth.ts:369-379). Older servers never send it.
    public var connectDeviceRequest: AuthConnectDeviceRequest?
    /// `permissions ?? scopes` (toDesktopPairingLinkRecord).
    public var granted: [String] { permissions ?? scopes ?? [] }

    public init(id: String, scopes: [String], label: String? = nil, createdAt: T3Timestamp, expiresAt: T3Timestamp,
                connectDeviceRequest: AuthConnectDeviceRequest? = nil) {
        self.id = id; self.permissions = scopes; self.label = label; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.connectDeviceRequest = connectDeviceRequest
    }
}

/// `AuthConnectDeviceRequest` (auth.ts:362-367): a T3 Connect device waiting for someone here to approve it.
public struct AuthConnectDeviceRequest: Decodable, Sendable, Equatable {
    public var verificationCode: String
    /// What the device said about itself. Absent until it asks.
    public var client: AuthClientSession.Client?
    public init(verificationCode: String, client: AuthClientSession.Client? = nil) {
        self.verificationCode = verificationCode; self.client = client
    }
}

/// `AuthConnectDevice` (auth.ts:381-388): a T3 Connect device key this environment trusts.
public struct AuthConnectDevice: Decodable, Sendable, Equatable {
    public var proofKeyThumbprint: String
    public var verificationCode: String
    public var client: AuthClientSession.Client?
    public var approvedAt: T3Timestamp
    public init(proofKeyThumbprint: String, verificationCode: String, client: AuthClientSession.Client? = nil, approvedAt: T3Timestamp) {
        self.proofKeyThumbprint = proofKeyThumbprint; self.verificationCode = verificationCode; self.client = client; self.approvedAt = approvedAt
    }
}

public enum ConnectDeviceNames {
    /// `unseenConnectDevices` (client-runtime connectDeviceNotices.ts, T3 5258): keys first seen after `seenThrough`.
    /// A client that never looked starts from the newest key, so it does not announce itself.
    public static func unseen(_ devices: [AuthConnectDevice], seenThrough: Int64?) -> (unseen: [AuthConnectDevice], newest: Int64) {
        let newest = max(0, devices.compactMap(\.approvedAt.epochMs).max() ?? 0)
        guard let seenThrough else { return ([], newest) }
        return (devices.filter { ($0.approvedAt.epochMs ?? 0) > seenThrough }, max(seenThrough, newest))
    }

    /// The "New device signed in" toast (ConnectDeviceApprovalCoordinator.tsx:113-130, T3 5258).
    public static func newDeviceToast(label: String, unseen: [AuthConnectDevice]) -> (title: String, message: String) {
        let title = "New device signed in to \(label)"
        if unseen.count == 1, let first = unseen.first {
            return (title, "\(describe(first.client)) connected through T3 Connect. Not you? Review it.")
        }
        return (title, "\(unseen.count) devices connected through T3 Connect. Not you? Review them.")
    }

    /// `connectDeviceName` (ConnectionsSettings.logic.ts:513-522).
    public static func name(_ client: AuthClientSession.Client?) -> String {
        client?.label ?? client?.os ?? client?.browser ?? "this device"
    }

    /// `describeConnectDeviceClient` (ConnectionsSettings.logic.ts:525-537): what the device says, deduplicated.
    public static func describe(_ client: AuthClientSession.Client?) -> String {
        var seen: Set<String> = []
        let bits = [client?.label, client?.os, client?.browser, client?.ipAddress].compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return bits.isEmpty ? "Unknown device" : bits.joined(separator: " · ")
    }

    /// The session subject a T3 Connect client signs in with (`CLOUD_CONNECT_SESSION_SUBJECT`).
    public static let sessionSubject = "cloud-connect"
}

/// `AuthClientSession` (auth.ts:344-365).
public struct AuthClientSession: Decodable, Sendable, Equatable {
    public struct Client: Decodable, Sendable, Equatable {
        public var label: String?
        public var ipAddress: String?
        public var deviceType: String
        public var os: String?
        public var browser: String?
        public init(label: String? = nil, ipAddress: String? = nil, deviceType: String = "unknown", os: String? = nil, browser: String? = nil) {
            self.label = label; self.ipAddress = ipAddress; self.deviceType = deviceType; self.os = os; self.browser = browser
        }
    }
    public var sessionId: String
    public var subject: String
    public var scopes: [String]?
    public var permissions: [String]?
    public var client: Client
    public var issuedAt: T3Timestamp
    public var lastConnectedAt: T3Timestamp?
    /// Bearer sessions last 30 days and can't be refreshed (SessionStore.ts:432).
    public var expiresAt: T3Timestamp?
    public var connected: Bool
    public var current: Bool
    public var granted: [String] { permissions ?? scopes ?? [] }

    public init(sessionId: String, subject: String, scopes: [String], client: Client, issuedAt: T3Timestamp,
                lastConnectedAt: T3Timestamp? = nil, connected: Bool, current: Bool) {
        self.sessionId = sessionId; self.subject = subject; self.permissions = scopes; self.client = client
        self.issuedAt = issuedAt; self.lastConnectedAt = lastConnectedAt; self.connected = connected; self.current = current
    }
}

/// `subscribeAuthAccess` folded into a snapshot (client-runtime state/auth.ts `applyAuthAccessStreamEvent`).
public struct AuthAccessSnapshot: Sendable, Equatable {
    public var pairingLinks: [AuthPairingLink] = []
    public var clientSessions: [AuthClientSession] = []
    /// Nil from servers before 4928, which have no device approval (auth.ts:405-406). A change to the
    /// trusted devices arrives as a whole new snapshot (server ws.ts:3546-3550).
    public var connectDevices: [AuthConnectDevice]?
    public init(pairingLinks: [AuthPairingLink] = [], clientSessions: [AuthClientSession] = [], connectDevices: [AuthConnectDevice]? = nil) {
        self.pairingLinks = pairingLinks; self.clientSessions = clientSessions; self.connectDevices = connectDevices
    }

    /// Applies one stream event (`{version, revision, type, payload}`). Unknown types change nothing.
    public mutating func apply(_ event: JSONValue) throws {
        guard let type = event["type"]?.stringValue, let payload = event["payload"] else { return }
        switch type {
        case "snapshot":
            pairingLinks = try (payload["pairingLinks"] ?? .array([])).decode(as: [AuthPairingLink].self)
            clientSessions = try (payload["clientSessions"] ?? .array([])).decode(as: [AuthClientSession].self)
            connectDevices = try payload["connectDevices"].map { try $0.decode(as: [AuthConnectDevice].self) }
        case "pairingLinkUpserted":
            let link = try payload.decode(as: AuthPairingLink.self)
            pairingLinks = pairingLinks.filter { $0.id != link.id } + [link]
        case "pairingLinkRemoved":
            let id = payload["id"]?.stringValue
            pairingLinks.removeAll { $0.id == id }
        case "clientUpserted":
            let session = try payload.decode(as: AuthClientSession.self)
            clientSessions = clientSessions.filter { $0.sessionId != session.sessionId } + [session]
        case "clientRemoved":
            let id = payload["sessionId"]?.stringValue
            clientSessions.removeAll { $0.sessionId == id }
        default:
            return
        }
    }

    /// Pending T3 Connect device requests, newest first (ConnectionsSettings.tsx:766-768).
    public var connectDeviceRequests: [AuthPairingLink] {
        pairingLinks.filter { $0.connectDeviceRequest != nil }.sorted { ($0.createdAt.epochMs ?? 0) > ($1.createdAt.epochMs ?? 0) }
    }

    /// Newest first (`sortDesktopPairingLinks`), without the device requests (ConnectionsSettings.tsx:763-765).
    public var sortedLinks: [AuthPairingLink] {
        pairingLinks.filter { $0.connectDeviceRequest == nil }.sorted { ($0.createdAt.epochMs ?? 0) > ($1.createdAt.epochMs ?? 0) }
    }

    /// This device, then connected ones, then newest (`sortDesktopClientSessions`).
    public var sortedSessions: [AuthClientSession] {
        clientSessions.sorted { l, r in
            if l.current != r.current { return l.current }
            if l.connected != r.connected { return l.connected }
            return (l.issuedAt.epochMs ?? 0) > (r.issuedAt.epochMs ?? 0)
        }
    }
}

/// `POST /api/auth/pairing-token` (`AuthCreatePairingCredentialInput` and `AuthPairingCredentialResult`).
public struct PairingCredentialRequest: Encodable, Sendable, Equatable {
    public var label: String?
    public var scopes: [String]?
    /// 4928 (auth.ts:515-530): a code that approves one app sign-in at this `McpClientAccess` level, or with
    /// `purpose: "peer-link"` a link code. Servers without `mcpApprovalCodes` ignore it.
    public var access: String?
    public var purpose: String?
    public init(label: String?, scopes: [String]?, access: String? = nil, purpose: String? = nil) {
        self.label = label; self.scopes = scopes; self.access = access; self.purpose = purpose
    }

    /// `createMcpApprovalCodeCommand` (client-runtime state/peerPairingCode.ts:130-141): label "App sign-in" and the level.
    public static func mcpApproval(_ access: McpClientAccess) -> PairingCredentialRequest {
        PairingCredentialRequest(label: "App sign-in", scopes: nil, access: access.rawValue)
    }
}

/// `AuthMcpClientAccess` (auth.ts:270-290): what an app signed in over MCP may do, lowest first.
public enum McpClientAccess: String, CaseIterable, Sendable, Equatable {
    case readOnly = "read-only", approvalRequired = "approval-required", autoAcceptEdits = "auto-accept-edits"
    case auto, fullAccess = "full-access"

    /// `mcpClientScopes`: the scopes a session at this level gets, and so the ones the minting session must hold.
    public var scopes: [String] {
        switch self {
        case .readOnly: [AuthScopes.orchestrationRead]
        case .fullAccess: [AuthScopes.orchestrationRead, AuthScopes.orchestrationOperate, AuthScopes.settingsWrite, AuthScopes.sourceControlWrite]
        default: [AuthScopes.orchestrationRead, AuthScopes.orchestrationOperate]
        }
    }
}

public struct PairingCredentialResult: Decodable, Sendable, Equatable {
    public var id: String
    public var credential: String
    public var label: String?
    public var expiresAt: T3Timestamp
    /// 4928: set on a peer-link code, and on an app sign-in code to its level. Older servers omit both.
    public var purpose: String?
    public var access: String?
}

/// `POST /api/auth/clients/revoke-others`.
public struct RevokeOthersResult: Decodable, Sendable, Equatable {
    public var revokedCount: Int
}

/// Time labels of the access rows (apps/web/src/timestampFormat.ts).
public enum AccessTime {
    /// `formatExpiresInLabel` (timestampFormat.ts:316-355).
    public static func expiresIn(_ date: Date, now: Date) -> String {
        let diff = date.timeIntervalSince(now)
        if diff <= 0 { return "Expired" }
        let total = Int(diff.rounded(.down))
        if total < 5 { return "Expires in a moment" }
        if total < 60 { return "Expires in \(total)s" }
        if total < 3600 {
            let m = total / 60, s = total % 60
            return s == 0 ? "Expires in \(m)m" : "Expires in \(m)m \(s)s"
        }
        if total < 86_400 {
            let h = total / 3600, m = (total % 3600) / 60, s = total % 60
            var parts = ["\(h)h"]
            if m > 0 { parts.append("\(m)m") }
            if s > 0 { parts.append("\(s)s") }
            return "Expires in " + parts.joined(separator: " ")
        }
        let d = total / 86_400, rem = total % 86_400
        if rem == 0 { return "Expires in \(d)d" }
        let h = rem / 3600, m = (rem % 3600) / 60, s = rem % 60
        var tail: [String] = []
        if h > 0 { tail.append("\(h)h") }
        if m > 0 { tail.append("\(m)m") }
        if s > 0 { tail.append("\(s)s") }
        return tail.isEmpty ? "Expires in \(d)d" : "Expires in \(d)d " + tail.joined(separator: " ")
    }

    /// `formatElapsedDurationLabel` (timestampFormat.ts:267-285).
    public static func elapsed(since date: Date, now: Date) -> String {
        let diff = now.timeIntervalSince(date)
        if diff <= 0 { return "just now" }
        let seconds = Int(diff.rounded(.down))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// `formatAccessTimestamp`: `dateStyle: medium, timeStyle: short` in the user's locale.
    public static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// `t3ConnectTroubleshootingUrl` (contracts environmentHttp.ts:474-477): a section of docs/user/t3-connect-troubleshooting.md,
/// which clients link as "More info".
public func t3ConnectTroubleshootingURL(_ section: String) -> String {
    "https://github.com/pingdotgg/t3code/blob/main/docs/user/t3-connect-troubleshooting.md#\(section)"
}
