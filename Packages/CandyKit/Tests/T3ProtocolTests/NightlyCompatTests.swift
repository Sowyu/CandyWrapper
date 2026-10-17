import Foundation
import Testing
@testable import T3Protocol

/// Wire shapes that changed between nightly 2861 and 2994, read the same way on both.
struct NightlyCompatTests {
    @Test func recorded3234ConfigDatabaseAndThreadDecode() throws {
        var configSeen = false, databaseSeen = false, threadSeen = false
        for frame in try WireTests.load("20-nightly-3234") where frame.dir == "recv" {
            let value = try JSONDecoder().decode(JSONValue.self, from: frame.bodyData)
            if value["requestId"]?.stringValue == "1", let config = value["exit"]?["value"] {
                let decoded = try config.decode(as: ServerProviderConfig.self)
                #expect(decoded.capabilities.contains("commandOutputStreaming"))
                #expect(decoded.capabilities.contains("databaseStorage"))
                configSeen = true
            }
            for item in value["values"]?.arrayValue ?? [] {
                if value["requestId"]?.stringValue == "2" {
                    let status = try item.decode(as: DatabaseStorageStatus.self)
                    #expect(status.databaseBytes > 0)
                    #expect(!status.compactCommand.isEmpty)
                    databaseSeen = true
                }
                if value["requestId"]?.stringValue == "4" {
                    _ = try item.decode(as: ThreadStreamItem.self)
                    if let projection = item["projection"] {
                        let decoded = try projection.decode(as: ThreadProjection.self)
                        #expect(!decoded.visibleTurnItems.isEmpty)
                        threadSeen = true
                    }
                }
            }
        }
        #expect(configSeen && databaseSeen && threadSeen)
    }

    static func settings(_ text: String) -> ServerThreadDefaults { ServerThreadDefaults(raw: UsageTests.json(text)) }

    @Test func sourceControlHostsFollowTheServersShape() {
        let old = Self.settings(#"{"github":{"hosts":{},"tokens":{"github.com":"••••"}},"bitbucket":{"email":"a@b.c"}}"#)
        #expect(!old.usesSourceControlHosts)
        #expect(old.sourceControlHost("github")?["tokens"]?["github.com"] == .string("••••"))
        #expect(old.sourceControlHost("bitbucket")?["email"] == .string("a@b.c"))
        #expect(old.sourceControlHostPatch("github", ["hosts": .object([:])]) == .object(["github": .object(["hosts": .object([:])])]))

        let new = Self.settings(#"{"sourceControlHosts":{"github":{"tokens":{"ghe.test":"••••"}}}}"#)
        #expect(new.usesSourceControlHosts)
        #expect(new.sourceControlHost("github")?["tokens"]?["ghe.test"] == .string("••••"))
        #expect(new.sourceControlHost("bitbucket") == nil)
        #expect(new.sourceControlHostPatch("bitbucket", ["apiToken": .string("x")])
            == .object(["sourceControlHosts": .object(["bitbucket": .object(["apiToken": .string("x")])])]))
        // An empty map still marks a 2994 server.
        #expect(Self.settings(#"{"sourceControlHosts":{}}"#).usesSourceControlHosts)
    }

    @Test func systemNotificationsAndPiUsageDecode() {
        #expect(NotificationSource.kind(.object(["kind": .string("system")])) == "system")
        #expect(NotificationSource.kind(.object(["kind": .string("future_kind")])) == "background_task")
        #expect(UsageProviderKind(rawValue: "pi") == .pi)
        #expect(UsageProviderKind.pi.label == "Pi")
        #expect(UsageProviderKind.allCases.last == .pi)
    }

    @Test func oneEmailInTwoWorkspacesIsTwoAccounts() {
        let w = UsageLimitWindow(id: "primary", kind: "session", label: "5h", usedPercent: 40, resetsAt: "2026-10-10T15:00:00.000Z", windowDurationMins: 300)
        var a = UsageTests.provider("codex", email: "me@x.com", windows: [w])
        var b = UsageTests.provider("codex2", email: "me@x.com", windows: [w])
        // Before 2994 nothing names a workspace: one account.
        let env = { (ps: [ServerProvider]) in [UsageLimitsEnvironment(environmentId: "e", label: "Mac", providers: ps, sources: [])] }
        #expect(UsageLimitsLogic.accounts(env([a, b])).count == 1)
        a.auth = .object(["status": .string("authenticated"), "email": .string("me@x.com"), "workspaceId": .string("ws-1")])
        b.auth = .object(["status": .string("authenticated"), "email": .string("me@x.com"), "workspaceId": .string("ws-2")])
        #expect(UsageLimitsLogic.accounts(env([a, b])).count == 2)

        // A hub account without a workspace joins the only one known for its email, else none.
        let resolve = UsageLimitsLogic.accountKeyResolver([.init(a)])
        let hub = UsageLimitSourceAccount(id: "auth.json", driver: "codex", email: "me@x.com", usageLimits: a.usageLimits!)
        #expect(resolve(.init(hub)) == "codex:me@x.com:ws-1")
        #expect(UsageLimitsLogic.accountKeyResolver([.init(a), .init(b)])(.init(hub)) == nil)
    }

    @Test func resetsMomentarilyInTheLastMinute() {
        let now = UsageTests.now
        let soon = UsageLimitWindow(id: "p", kind: "session", label: "5h", usedPercent: 10, resetsAt: "2026-10-10T12:00:59.000Z")
        #expect(UsageLimitsLogic.resetsIn(soon, nowMs: now) == "Resets momentarily")
        let minute = UsageLimitWindow(id: "p", kind: "session", label: "5h", usedPercent: 10, resetsAt: "2026-10-10T12:01:00.000Z")
        #expect(UsageLimitsLogic.resetsIn(minute, nowMs: now) == "resets in 1m")
        let past = UsageLimitWindow(id: "p", kind: "session", label: "5h", usedPercent: 10, resetsAt: "2026-10-10T12:00:00.000Z")
        #expect(UsageLimitsLogic.resetsIn(past, nowMs: now) == "resets now")
    }
}
