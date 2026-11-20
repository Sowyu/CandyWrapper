import Foundation
import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// T3 mcp/mcpGate.test.ts and mcp/mcpApps.test.ts at 4928, plus the dialog's steps.
@MainActor
struct UseInAnotherAppTests {
    typealias U = UseInAnotherApp
    static let reachable = ConnectReachability(status: "reachable", checkedAt: "2026-11-08T00:00:00.000Z", readyConnections: 4, protocol: "quic")
    static var tunnel: CloudLinkState {
        var s = CloudLinkState(linked: true, managedTunnelActive: true, publishAgentActivity: true)
        s.tunnelHostname = "prod-a1.t3coderelay.com"
        return s
    }
    static let open = U.GateInput(signedIn: true, connected: true, approvalCodes: true, canReadRelay: true, linkState: tunnel,
                                  linkStateError: nil, thisMachine: true, relay: .listed(providerKind: nil, httpBaseUrl: nil, availability: nil),
                                  reachability: .result(reachable))
    static var saved: U.GateInput {
        var s = open
        s.thisMachine = false
        s.relay = .listed(providerKind: "cloudflare_tunnel", httpBaseUrl: "https://prod-b2.t3coderelay.com", availability: .online)
        return s
    }

    @Test func opensOnAReachableCheckAtTheTunnelsURL() {
        #expect(U.gate(Self.open) == .open(mcpURL: "https://prod-a1.t3coderelay.com/mcp"))
        // A saved machine's address comes from T3 Connect, not from what it reports itself.
        #expect(U.gate(Self.saved) == .open(mcpURL: "https://prod-b2.t3coderelay.com/mcp"))
    }

    @Test func disconnectedSavedMachineFollowsTheList() {
        var away = Self.saved
        away.connected = false
        func listed(_ a: U.Relay.Availability) -> U.GateInput {
            var i = away; i.relay = .listed(providerKind: "cloudflare_tunnel", httpBaseUrl: "https://prod-b2.t3coderelay.com", availability: a); return i
        }
        #expect(U.gate(listed(.offline)) == .disconnected(relay: .offline))
        #expect(U.gate(listed(.error)) == .disconnected(relay: .failed))
        #expect(U.gate(listed(.checking)) == .checking)
        #expect(U.gate(listed(.online)) == .disconnected(relay: nil))
        var failed = away; failed.relay = .failed
        #expect(U.gate(failed) == .disconnected(relay: .failed))
        var here = Self.open; here.connected = false
        #expect(U.gate(here) == .disconnected(relay: nil))
    }

    @Test func gateOrder() {
        var i = Self.open
        i.signedIn = nil; #expect(U.gate(i) == .checking)
        i.signedIn = false; #expect(U.gate(i) == .signIn)
        i = Self.open; i.approvalCodes = nil; #expect(U.gate(i) == .checking)
        i.approvalCodes = false; #expect(U.gate(i) == .update)
        i = Self.open; i.canReadRelay = false; #expect(U.gate(i) == .noRelayRead)
        i = Self.open; i.linkStateError = "boom"; #expect(U.gate(i) == .error("boom"))
        i = Self.open; i.linkState = nil; #expect(U.gate(i) == .checking)
        i = Self.open; i.linkState?.managedTunnelActive = false; #expect(U.gate(i) == .turnOn)
        i = Self.open; i.linkState?.linkRevoked = true; #expect(U.gate(i) == .turnOn)
        i = Self.open; i.reachability = .checking; #expect(U.gate(i) == .checking)
        i = Self.open; i.reachability = .result(nil); #expect(U.gate(i) == .offline(nil))
        let down = ConnectReachability(status: "unreachable", checkedAt: "x", cause: "timeout", reason: "Timed out.", fix: "Retry.")
        i.reachability = .result(down); #expect(U.gate(i) == .offline(down))
        // A publish-only link registers its local address as manual, which is no tunnel.
        i = Self.saved; i.relay = .listed(providerKind: "manual", httpBaseUrl: "http://192.168.1.2:3773", availability: .online)
        #expect(U.gate(i) == .turnOn)
        i = Self.saved; i.relay = .listed(providerKind: nil, httpBaseUrl: nil, availability: nil)
        #expect(U.gate(i) == .turnOn)
        i = Self.saved; i.relay = .loading; #expect(U.gate(i) == .checking)
        i = Self.saved; i.relay = .failed; #expect(U.gate(i) == .error("Could not reach T3 Connect."))
    }

    @Test func mcpURLTakesOnlyHttpsDNSNames() {
        #expect(U.mcpURL(thisMachine: true, tunnelHostname: "a.b.com", relayProviderKind: nil, relayHttpBaseUrl: nil) == "https://a.b.com/mcp")
        #expect(U.mcpURL(thisMachine: true, tunnelHostname: "a.b.com;rm -rf", relayProviderKind: nil, relayHttpBaseUrl: nil) == nil)
        #expect(U.mcpURL(thisMachine: true, tunnelHostname: "localhost", relayProviderKind: nil, relayHttpBaseUrl: nil) == nil)
        #expect(U.mcpURL(thisMachine: true, tunnelHostname: nil, relayProviderKind: nil, relayHttpBaseUrl: nil) == nil)
        #expect(U.mcpURL(thisMachine: false, tunnelHostname: nil, relayProviderKind: "cloudflare_tunnel", relayHttpBaseUrl: "http://a.b.com") == nil)
        #expect(U.mcpURL(thisMachine: false, tunnelHostname: nil, relayProviderKind: "manual", relayHttpBaseUrl: "https://a.b.com") == nil)
    }

    @Test func afterFailedCheckCountsOnlyNewerServerChecks() {
        var prior = Self.tunnel
        prior.reachability = ConnectReachability(status: "unreachable", checkedAt: "2026-11-08T00:00:00.000Z")
        var latest = Self.tunnel
        latest.reachability = ConnectReachability(status: "reachable", checkedAt: "2026-11-08T00:01:00.000Z")
        let fresh = U.afterFailedCheck(prior: prior, latest: latest)
        #expect(fresh.result?.status == "reachable" && fresh.since == "2026-11-08T00:01:00.000Z")
        let same = U.afterFailedCheck(prior: prior, latest: prior)
        #expect(same.result == nil && same.since == "2026-11-08T00:00:00.000Z")
        let none = U.afterFailedCheck(prior: nil, latest: nil)
        #expect(none.result == nil && none.since == nil)
        // Read nothing before: only a later server check counts.
        let unread = U.afterFailedCheck(prior: nil, latest: latest)
        #expect(unread.result == nil && unread.since == "2026-11-08T00:01:00.000Z")
    }

    @Test func appLinksFillInT3CodeAndTheEncodedURL() throws {
        let url = "https://prod-a1.t3coderelay.com/mcp?x=1&y=two words"
        func opened(_ id: String) throws -> URLComponents {
            let app = try #require(U.apps.first { $0.id == id })
            let action = try #require(U.action(app, mcpURL: url))
            return try #require(URLComponents(string: action.link))
        }
        let poke = try opened("poke")
        #expect(poke.queryItems?.first { $0.name == "name" }?.value == "T3 Code")
        #expect(poke.queryItems?.first { $0.name == "url" }?.value == url)
        let claude = try opened("claude")
        #expect(claude.queryItems?.first { $0.name == "connectorUrl" }?.value == url)
        for app in U.apps {
            let action = U.action(app, mcpURL: url)
            for link in [action?.link, app.docs].compactMap({ $0 }) { #expect(URL(string: link)?.scheme == "https", "\(app.name)") }
            #expect(McpAppTile.image(app.logo) != nil, "\(app.name) logo")
        }
        let grok = try #require(U.apps.first { $0.id == "grok-bot" })
        let action = try #require(U.action(grok, mcpURL: url))
        #expect(action.copy?.text == "Add the MCP server \(url) and connect it.")
        let appLink = try #require(action.appLink)
        #expect(URLComponents(string: appLink)?.queryItems?.first?.value == action.copy?.text)
        let openclaw = try #require(U.apps.first { $0.id == "openclaw" })
        #expect(U.action(openclaw, mcpURL: url) == nil)
        #expect(!U.shownApps.contains { $0.id == "gemini" })
    }

    @Test func levelsFollowTheSession() throws {
        func session(_ permissions: [String]) throws -> AuthSessionState {
            let json: [String: Any] = ["authenticated": true, "permissions": permissions,
                                       "auth": ["policy": "loopback-browser", "bootstrapMethods": [], "sessionMethods": []]]
            return try JSONDecoder().decode(AuthSessionState.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let none = U.blockedLevels(session: try session([AuthScopes.orchestrationRead]), environment: "Mac")
        #expect(none.count == 5 && none[.auto] == "This device needs the Manage access permission on Mac.")
        #expect(U.defaultLevel(blocked: none) == nil)
        let some = U.blockedLevels(session: try session([AuthScopes.accessWrite, AuthScopes.orchestrationRead, AuthScopes.orchestrationOperate]), environment: "Mac")
        #expect(some.keys.sorted { $0.rawValue < $1.rawValue } == [.fullAccess])
        #expect(U.defaultLevel(blocked: some) == .auto)
        #expect(U.defaultLevel(blocked: [.auto: "x"]) == .autoAcceptEdits)
        #expect(McpClientAccess.fullAccess.scopes.contains(AuthScopes.sourceControlWrite))
    }

    @Test func linkedLineKeepsTheLowerLevel() {
        #expect(U.linkedLine([], access: .auto) == nil)
        #expect(U.linkedLine([("Pi", "full-access", false), ("NAS", "read-only", true)], access: .auto) == "Linked: Pi · Auto, NAS · Expired")
        #expect(U.linkedLine([("Pi", "approval-required", false)], access: .auto) == "Linked: Pi · Supervised")
        #expect(U.linkedLine([("Pi", "full-access", false)], access: nil) == "Linked: Pi · Full access")
        #expect(U.expiry(secondsLeft: 299) == "Expires 4:59 · one use")
    }

    @Test func approvalCodeRequestCarriesTheLevel() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PairingCredentialRequest.mcpApproval(.auto))) as? [String: String]
        #expect(body == ["label": "App sign-in", "access": "auto"])
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PairingCredentialRequest(label: "x", scopes: ["a"]))) as? [String: Any]
        #expect(old?.keys.sorted() == ["label", "scopes"])
    }

    @Test func wizardWalksAppAccessConnect() throws {
        let w = UseInAnotherAppDialog(environment: "Mac", hostedApproval: false)
        #expect(w.dialog.footerButtons.isEmpty && w.dialog.headerContent == nil)
        w.blocked = [.auto: "no"]
        w.gate = .open(mcpURL: "https://a.b.com/mcp")
        #expect(w.dialog.headerContent != nil)
        let next = try #require(w.dialog.footerButtons.last as? ButtonView)
        #expect(next.title == "Next" && !next.isEnabled)
        let grid = try #require(Self.find(McpAppGrid.self, in: w.body))
        grid.onSelect?(1)
        #expect(w.choice == 1)
        (w.dialog.footerButtons.last as? ButtonView)?.performAction()
        #expect(w.step == 1 && w.access == .autoAcceptEdits)
        (w.dialog.footerButtons.last as? ButtonView)?.performAction()
        #expect(w.step == 2)
        var minted: McpClientAccess?
        w.onMint = { minted = $0 }
        let get = try #require(Self.buttons(in: w.body).first { $0.title == "Get code" })
        get.performAction()
        #expect(minted == .autoAcceptEdits)
        w.code = .live(credential: "AUTOED-ABC", expiresAt: Date().addingTimeInterval(120))
        #expect(Self.buttons(in: w.body).first { $0.title == "Get code" || $0.title == "New code" } == nil)
        w.code = .live(credential: "AUTOED-ABC", expiresAt: Date().addingTimeInterval(-1))
        #expect(Self.buttons(in: w.body).contains { $0.title == "New code" })
        w.stop()
        // Hosted approval skips Access and needs no code.
        let hosted = UseInAnotherAppDialog(environment: "Mac", hostedApproval: true)
        hosted.gate = .open(mcpURL: "https://a.b.com/mcp")
        Self.find(McpAppGrid.self, in: hosted.body)?.onSelect?(0)
        (hosted.dialog.footerButtons.last as? ButtonView)?.performAction()
        #expect(hosted.step == 2 && !Self.buttons(in: hosted.body).contains { $0.title == "Get code" })
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }
    static func buttons(in view: NSView) -> [ButtonView] {
        (view as? ButtonView).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
}

