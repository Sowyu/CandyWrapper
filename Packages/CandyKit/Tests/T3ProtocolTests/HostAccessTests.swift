import Foundation
import Testing
@testable import T3Protocol

/// Settings > Connections host data: permissions, the access stream, the time labels.
struct HostAccessTests {
    private func session(scopes: [String]? = nil, permissions: [String]? = nil, serverUpdateScope: String? = nil) throws -> AuthSessionState {
        var json: [String: Any] = ["authenticated": true,
                                   "auth": ["policy": "loopback-browser", "bootstrapMethods": [], "sessionMethods": []]]
        if let scopes { json["scopes"] = scopes }
        if let permissions { json["permissions"] = permissions }
        if let serverUpdateScope {
            json["auth"] = ["policy": "loopback-browser", "bootstrapMethods": [], "sessionMethods": [], "serverUpdateScope": serverUpdateScope]
        }
        return try JSONDecoder().decode(AuthSessionState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func grantsFollowSessionGrantsScope() throws {
        // `permissions` wins, even empty.
        #expect(try session(scopes: ["orchestration:read"], permissions: []).grants("orchestration:read") == false)
        // Old broad scopes imply their children, unless the server knows granular scopes.
        let legacy = try session(scopes: ["orchestration:operate"])
        #expect(legacy.grants("settings:write"))
        #expect(!legacy.grants("access:write"))
        #expect(try session(scopes: ["orchestration:operate"], serverUpdateScope: "environment:maintain").grants("settings:write") == false)
    }

    @Test func togglingTerminalsKeepsReadWithUse() {
        #expect(AuthScopes.toggle([], "terminal:operate", true) == ["terminal:operate", "terminal:read"])
        #expect(AuthScopes.toggle(["terminal:read", "terminal:operate", "x"], "terminal:read", false) == ["x"])
        // Since 3315 the default grants every option, access and T3 Connect management included.
        #expect(AuthScopes.standard.count == 16 && Set(AuthScopes.standard) == Set(AuthScopes.options.map(\.scope)))
    }

    /// 4928 device approval: requests ride on pairing links, trusted devices on the snapshot (auth.ts:362-406).
    @Test func connectDevicesDecodeFromTheSnapshot() throws {
        func event(_ s: String) throws -> JSONValue { try JSONValue(parsing: Data(s.utf8)) }
        var a = AuthAccessSnapshot()
        try a.apply(event(#"{"version":1,"revision":1,"type":"snapshot","payload":{"pairingLinks":[]  ,"clientSessions":[]}}"#))
        #expect(a.connectDevices == nil)  // a 3824 server: no device approval
        try a.apply(event(#"{"version":1,"revision":2,"type":"snapshot","payload":{"pairingLinks":[{"id":"l1","subject":"s","scopes":[],"createdAt":"2026-10-10T10:00:00.000Z","expiresAt":"2026-10-10T10:05:00.000Z"},{"id":"r1","subject":"cloud-connect","scopes":[],"createdAt":"2026-10-10T10:01:00.000Z","expiresAt":"2026-10-10T10:06:00.000Z","connectDeviceRequest":{"verificationCode":"ABCD-EFGH","client":{"deviceType":"mobile","os":"iOS","label":"iPhone"}}}],"clientSessions":[],"connectDevices":[{"proofKeyThumbprint":"tp","verificationCode":"WXYZ-2345","client":{"deviceType":"desktop","os":"macOS","browser":"macOS","ipAddress":"10.0.0.2"},"approvedAt":"2026-10-09T10:00:00.000Z"}]}}"#))
        #expect(a.sortedLinks.map(\.id) == ["l1"])
        #expect(a.connectDeviceRequests.map(\.id) == ["r1"])
        #expect(a.connectDeviceRequests.first?.connectDeviceRequest?.verificationCode == "ABCD-EFGH")
        #expect(a.connectDevices?.map(\.proofKeyThumbprint) == ["tp"])
        // `describeConnectDeviceClient` drops repeats; `connectDeviceName` prefers the label.
        #expect(ConnectDeviceNames.describe(a.connectDevices?.first?.client) == "macOS · 10.0.0.2")
        #expect(ConnectDeviceNames.name(a.connectDeviceRequests.first?.connectDeviceRequest?.client) == "iPhone")
        #expect(ConnectDeviceNames.describe(nil) == "Unknown device")
        #expect(ConnectDeviceNames.name(nil) == "this device")
    }

    @Test func accessStreamFoldsIntoASnapshot() throws {
        func event(_ s: String) throws -> JSONValue { try JSONValue(parsing: Data(s.utf8)) }
        var a = AuthAccessSnapshot()
        try a.apply(event(#"{"version":1,"revision":1,"type":"snapshot","payload":{"pairingLinks":[{"id":"l1","subject":"s","scopes":["orchestration:read"],"createdAt":"2026-10-10T10:00:00.000Z","expiresAt":"2026-10-10T10:05:00.000Z"}],"clientSessions":[{"sessionId":"c1","subject":"s","scopes":[],"permissions":["orchestration:read"],"method":"bearer-session-token","client":{"deviceType":"desktop","os":"macOS"},"issuedAt":"2026-10-10T09:00:00.000Z","expiresAt":"2026-11-10T09:00:00.000Z","lastConnectedAt":null,"connected":false,"current":true}]}}"#))
        #expect(a.pairingLinks.map(\.id) == ["l1"])
        #expect(a.clientSessions.first?.granted == ["orchestration:read"])
        try a.apply(event(#"{"version":1,"revision":2,"type":"clientUpserted","payload":{"sessionId":"c2","subject":"s","scopes":[],"method":"bearer-session-token","client":{"deviceType":"mobile"},"issuedAt":"2026-10-10T09:30:00.000Z","expiresAt":"2026-11-10T09:00:00.000Z","lastConnectedAt":"2026-10-10T09:31:00.000Z","connected":true,"current":false}}"#))
        try a.apply(event(#"{"version":1,"revision":3,"type":"pairingLinkRemoved","payload":{"id":"l1"}}"#))
        #expect(a.pairingLinks.isEmpty)
        // This device first, then connected, then newest.
        #expect(a.sortedSessions.map(\.sessionId) == ["c1", "c2"])
        try a.apply(event(#"{"version":1,"revision":4,"type":"clientRemoved","payload":{"sessionId":"c1"}}"#))
        #expect(a.clientSessions.map(\.sessionId) == ["c2"])
    }

    @Test func timeLabelsMatchTimestampFormat() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(AccessTime.expiresIn(now.addingTimeInterval(252), now: now) == "Expires in 4m 12s")
        #expect(AccessTime.expiresIn(now.addingTimeInterval(3), now: now) == "Expires in a moment")
        #expect(AccessTime.expiresIn(now.addingTimeInterval(86_400 + 3600), now: now) == "Expires in 1d 1h")
        #expect(AccessTime.expiresIn(now.addingTimeInterval(-1), now: now) == "Expired")
        #expect(AccessTime.elapsed(since: now.addingTimeInterval(-7200), now: now) == "2h")
    }

    @Test func linkStateDefaultsForOlderServers() throws {
        let old = try JSONDecoder().decode(CloudLinkState.self, from: Data(#"{"linked":true,"cloudUserId":null,"relayUrl":null,"relayIssuer":null,"publishAgentActivity":false}"#.utf8))
        #expect(old.tunnelActive && !old.holdsWebhooks && old.reachability == nil)
        let body = try JSONEncoder().encode(CloudPreferencesRequest(publishAgentActivity: true))
        #expect(String(decoding: body, as: UTF8.self) == #"{"publishAgentActivity":true}"#)
    }

    /// environmentHttp.ts:411-456 and SavedEnvironmentRows.tsx:495-503.
    @Test func linkStateReachability() throws {
        func state(_ r: String) throws -> CloudLinkState {
            try JSONDecoder().decode(CloudLinkState.self, from: Data(#"{"linked":true,"managedTunnelActive":true,"publishAgentActivity":false,"reachability":\#(r)}"#.utf8))
        }
        let up = try state(#"{"status":"reachable","checkedAt":"2026-10-20T12:00:00.000Z","readyConnections":4,"protocol":"quic"}"#)
        #expect(up.reachability?.statusLine == "Tunnel connected · 4 connections · QUIC")
        let one = try state(#"{"status":"reachable","checkedAt":"x","readyConnections":1,"protocol":null}"#)
        #expect(one.reachability?.statusLine == "Tunnel connected · 1 connection")
        let down = try state(#"{"status":"unreachable","checkedAt":"x","cause":"edge_unreachable","reason":"The tunnel cannot reach Cloudflare.","hint":null,"fix":"Open port 7844."}"#)
        #expect(down.reachability?.statusLine == "The tunnel cannot reach Cloudflare. Fix: Open port 7844.")
        // The line's "More info" (connectReachabilityHelpUrl, environmentHttp.ts:479-492).
        #expect(down.reachability?.helpURL == "https://github.com/pingdotgg/t3code/blob/main/docs/user/t3-connect-troubleshooting.md#port-7844-is-blocked-on-the-host")
        #expect(up.reachability?.helpURL == nil)
    }

    /// 5258 #42311: devices first seen after this client's watermark, and the toast's words.
    @Test func newConnectDeviceNotice() {
        let a = AuthConnectDevice(proofKeyThumbprint: "a", verificationCode: "1", client: .init(label: "Ana's phone"), approvedAt: T3Timestamp(epochMs: 1_000))
        let b = AuthConnectDevice(proofKeyThumbprint: "b", verificationCode: "2", approvedAt: T3Timestamp(epochMs: 2_000))
        // A client that never looked announces nothing and starts from the newest key.
        #expect(ConnectDeviceNames.unseen([a, b], seenThrough: nil).unseen.isEmpty)
        #expect(ConnectDeviceNames.unseen([a, b], seenThrough: nil).newest == 2_000)
        #expect(ConnectDeviceNames.unseen([a, b], seenThrough: 1_000).unseen.map(\.proofKeyThumbprint) == ["b"])
        #expect(ConnectDeviceNames.unseen([a, b], seenThrough: 5_000).newest == 5_000)
        let one = ConnectDeviceNames.newDeviceToast(label: "Studio", unseen: [a])
        #expect(one.title == "New device signed in to Studio")
        #expect(one.message == "Ana's phone connected through T3 Connect. Not you? Review it.")
        #expect(ConnectDeviceNames.newDeviceToast(label: "Studio", unseen: [a, b]).message
            == "2 devices connected through T3 Connect. Not you? Review them.")
    }
}
