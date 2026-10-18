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
        #expect(old.tunnelActive && !old.holdsWebhooks)
        let body = try JSONEncoder().encode(CloudPreferencesRequest(publishAgentActivity: true))
        #expect(String(decoding: body, as: UTF8.self) == #"{"publishAgentActivity":true}"#)
    }
}
