import Testing
import T3Protocol
@testable import Features

/// Idle compaction's wire forms (contracts settings.ts:1328-1372, scopedSettings.ts:221-225).
@MainActor
struct IdleCompactionSettingsTests {
    private func settings(_ json: [String: JSONValue]) -> ServerSettingsValues { ServerSettingsValues(.object(json)) }

    @Test func modeReadsFromWhicheverFieldTheServerHas() {
        #expect(settings([:]).globalIdleCompaction == "onReturn")
        #expect(settings(["compactIdleThreads": .bool(true)]).globalIdleCompaction == "beforeCacheExpires")
        #expect(settings(["compactIdleThreads": .string("off")]).globalIdleCompaction == "off")
        #expect(settings(["compactIdleThreads": .bool(true), "idleCompaction": .string("onReturn")]).globalIdleCompaction == "onReturn")
        #expect(!settings(["compactIdleThreads": .bool(false)]).readsIdleCompactionModes)
    }

    @Test func instanceOverrideWinsUnlessDefault() {
        let s = settings(["idleCompaction": .string("beforeCacheExpires"), "providerInstances": .object([
            "claudeAgent": .object(["config": .object(["idleCompaction": .string("off")])]),
            "work": .object(["config": .object(["idleCompaction": .string("default")])]),
        ])])
        #expect(s.resolveIdleCompaction(instanceId: "claudeAgent") == "off")
        #expect(s.resolveIdleCompaction(instanceId: "work") == "beforeCacheExpires")
        #expect(s.resolveIdleCompaction(instanceId: "other") == "beforeCacheExpires")
    }

    @Test func eachEnvironmentGetsTheFormItReads() {
        let envs = [
            SettingsScopeEnvironment(id: "fixed", label: "Fixed", settings: settings(["compactIdleThreads": .bool(false), "idleCompaction": .string("onReturn")])),
            SettingsScopeEnvironment(id: "modes", label: "Modes", settings: settings(["compactIdleThreads": .string("onReturn")])),
            SettingsScopeEnvironment(id: "switch", label: "Switch", settings: settings(["compactIdleThreads": .bool(false)])),
        ]
        let writes = SettingsScopeState(environments: envs, primaryId: "fixed").plan(["idleCompaction": .string("beforeCacheExpires")]).writes
        #expect(writes.map(\.patch) == [
            ["idleCompaction": .string("beforeCacheExpires")],
            ["compactIdleThreads": .string("beforeCacheExpires")],
            ["compactIdleThreads": .bool(true)],
        ])
    }
}
