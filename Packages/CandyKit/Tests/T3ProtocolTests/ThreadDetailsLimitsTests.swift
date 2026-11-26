import Testing
@testable import T3Protocol

/// `resolveThreadDetailsLimits` and `hubRoutes` (5258 ThreadDetailsUsage.logic.ts, usageLimits.ts:916-939).
@Suite struct ThreadDetailsLimitsTests {
    let now: Int64 = 1_800_000_000_000

    func limits(_ used: Double?, notice: String? = nil) -> ProviderUsageLimits {
        ProviderUsageLimits(checkedAt: "2027-01-15T08:00:00.000Z",
                            windows: used.map { [UsageLimitWindow(id: "five_hour", kind: "session", label: "Session", usedPercent: $0)] } ?? [],
                            unavailableReason: notice)
    }

    func provider(endpoint: String?, limits: ProviderUsageLimits?) -> ServerProvider {
        var p = ServerProvider(instanceId: ProviderInstanceId(rawValue: "claude-hub"), driver: "claudeAgent", displayName: nil)
        var auth: [String: JSONValue] = ["status": .string("authenticated")]
        if let endpoint { auth["endpoint"] = .string(endpoint) }
        p.auth = .object(auth)
        p.usageLimits = limits
        return p
    }

    @Test func hubInstanceWithoutOwnLimitsShowsTheHubPool() {
        let hub = UsageLimitSourceSnapshot(id: "h", label: "Team hub", accounts: [
            UsageLimitSourceAccount(id: "a.json", driver: "claudeAgent", models: ["claude-opus-5-5"], usageLimits: limits(40)),
            UsageLimitSourceAccount(id: "b.json", driver: "claudeAgent", models: ["claude-opus-5-5"], usageLimits: limits(60)),
            UsageLimitSourceAccount(id: "c.json", driver: "claudeAgent", models: ["claude-haiku-5-5"], usageLimits: limits(0)),
        ], origin: "https://hub.example")
        let p = provider(endpoint: "https://hub.example", limits: limits(nil, notice: "unsupported"))
        let result = UsageLimitsLogic.threadDetailsLimits(instanceId: "claude-hub", model: "claude-opus-5-5[1m]", providers: [p], sources: [hub], nowMs: now)
        guard case .pool(let windows) = result else { Issue.record("expected a pool, got \(String(describing: result))"); return }
        #expect(windows.count == 1)
        #expect(windows[0].members.count == 2)
        #expect(windows[0].remainingPercent == 50)
        #expect(UsageLimitsLogic.poolSources(windows[0]).hubs == ["Team hub"])
    }

    @Test func instanceWithItsOwnLimitsIgnoresTheHub() {
        let hub = UsageLimitSourceSnapshot(id: "h", label: "Hub", accounts: [
            UsageLimitSourceAccount(id: "a.json", driver: "claudeAgent", usageLimits: limits(10))], origin: "https://hub.example")
        let p = provider(endpoint: "https://hub.example", limits: limits(25))
        guard case .instance(let own) = UsageLimitsLogic.threadDetailsLimits(instanceId: "claude-hub", model: nil, providers: [p], sources: [hub], nowMs: now) else {
            Issue.record("expected the instance"); return
        }
        #expect(own.windows.first?.usedPercent == 25)
    }

    @Test func aliasModelFallsBackToTheDriver() {
        let hub = UsageLimitSourceSnapshot(id: "h", label: "Hub", accounts: [
            UsageLimitSourceAccount(id: "a", driver: "claudeAgent", models: ["claude-opus-5-5"], usageLimits: limits(10)),
            UsageLimitSourceAccount(id: "b", driver: "codex", models: ["gpt-6"], usageLimits: limits(10)),
            UsageLimitSourceAccount(id: "c", driver: "claudeAgent", models: [], usageLimits: limits(10)),
        ])
        let routes = UsageLimitsLogic.hubRoutes([hub], driver: "claudeAgent", model: "opus")
        #expect(hub.accounts.filter(routes).map(\.id) == ["a"])
        let thinking = UsageLimitsLogic.hubRoutes([hub], driver: "codex", model: "gpt-6(high)")
        #expect(hub.accounts.filter(thinking).map(\.id) == ["b"])
    }

    @Test func httpQuotasDecodeAndMatchTheInstance() {
        let json: JSONValue = .array([.object([
            "id": .string("q"), "kind": .string("http"), "label": .string("Quota"), "checkedAt": .string("2027-01-15T08:00:00.000Z"),
            "accounts": .array([]),
            "quotaAccounts": .array([.object(["id": .string("acct"), "label": .string("Work"), "providerInstanceId": .string("claude-hub"),
                "windows": .array([.object(["id": .string("day"), "kind": .string("other"), "label": .string("Daily"), "usedPercent": .number(30)])])])]),
        ])])
        let sources = UsageLimitSourceSnapshot.list(json)
        let quotas = UsageLimitsLogic.threadHttpQuotas(instanceId: "claude-hub", sources: sources)
        #expect(quotas.map(\.accountLabel) == ["Work"])
        #expect(quotas.first?.window.label == "Daily")
        #expect(UsageLimitsLogic.threadHttpQuotas(instanceId: "other", sources: sources).isEmpty)
    }
}
