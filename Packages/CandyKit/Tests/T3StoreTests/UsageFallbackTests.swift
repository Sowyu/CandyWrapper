import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Provider fallback (#26164, #27859 at 4928, packages/shared/src/usageLimits.test.ts).
struct UsageFallbackTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func provider(_ id: String, driver: String, models: [String], used: Double? = nil, windowId: String = "weekly",
                         resetsAt: String? = "2030-01-01T00:00:00.000Z", auth: String = "authenticated") throws -> ServerProvider {
        var json: [String: Any] = ["instanceId": id, "driver": driver, "enabled": true, "installed": true, "status": "ready",
                                   "auth": ["status": auth],
                                   "models": models.map { ["slug": $0, "name": $0.uppercased(), "isCustom": false, "optionDescriptors": []] }]
        if let used {
            var window: [String: Any] = ["id": windowId, "kind": "weekly", "label": "Weekly", "usedPercent": used]
            if let resetsAt { window["resetsAt"] = resetsAt }
            json["usageLimits"] = ["checkedAt": "2026-11-19T00:00:00.000Z", "windows": [window]]
        }
        return try JSONDecoder().decode(ServerProvider.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func fallsBackOnlyWhenTheDefaultIsOutOfUsage() throws {
        let claude = try Self.provider("claudeAgent", driver: "claudeAgent", models: ["opus"], used: 100)
        let codex = try Self.provider("codex", driver: "codex", models: ["gpt-6"])
        let def = ModelSelection(instanceId: ProviderInstanceId("claudeAgent"), model: "opus")
        let backup = ModelSelection(instanceId: ProviderInstanceId("codex"), model: "gpt-6")
        let r = UsageFallback.resolve(defaultSelection: def, fallback: backup, catalog: ProviderCatalog([claude, codex]), now: Self.now)
        #expect(r?.selection == backup)
        #expect(r?.resetsAt == "2030-01-01T00:00:00.000Z")
        // A window that already reset, a fallback that is signed out, or one out of usage itself keeps the default.
        let reset = try Self.provider("claudeAgent", driver: "claudeAgent", models: ["opus"], used: 100, resetsAt: "2020-01-01T00:00:00.000Z")
        #expect(UsageFallback.resolve(defaultSelection: def, fallback: backup, catalog: ProviderCatalog([reset, codex]), now: Self.now) == nil)
        let signedOut = try Self.provider("codex", driver: "codex", models: ["gpt-6"], auth: "unauthenticated")
        #expect(UsageFallback.resolve(defaultSelection: def, fallback: backup, catalog: ProviderCatalog([claude, signedOut]), now: Self.now) == nil)
        let spent = try Self.provider("codex", driver: "codex", models: ["gpt-6"], used: 100)
        #expect(UsageFallback.resolve(defaultSelection: def, fallback: backup, catalog: ProviderCatalog([claude, spent]), now: Self.now) == nil)
    }

    @Test func poolsCountPerModel() throws {
        let cursor = try Self.provider("cursor", driver: "cursor", models: ["gpt-6"], used: 100, windowId: "autoPercentUsed")
        #expect(UsageFallback.exhaustedWindow(cursor, now: Self.now, model: "gpt-6") == nil)
        #expect(UsageFallback.exhaustedWindow(cursor, now: Self.now, model: "auto") == nil)
        let gravity = try Self.provider("antigravity", driver: "antigravity", models: ["gemini-3"], used: 100, windowId: "3p-weekly")
        #expect(UsageFallback.exhaustedWindow(gravity, now: Self.now, model: "gemini-3") == nil)
        #expect(UsageFallback.exhaustedWindow(gravity, now: Self.now, model: "claude-opus")?.id == "3p-weekly")
    }

    @MainActor @Test func newDraftStartsOnTheFallbackWithItsEffort() throws {
        let claude = try Self.provider("claudeAgent", driver: "claudeAgent", models: ["opus"], used: 100)
        let codex = try Self.provider("codex", driver: "codex", models: ["gpt-6"])
        var defaults = ServerThreadDefaults(defaultModelSelection: ModelSelection(instanceId: ProviderInstanceId("claudeAgent"), model: "opus"))
        defaults.fallbackModelSelection = ModelSelection(instanceId: ProviderInstanceId("codex"), model: "gpt-6")
        var ctx = ComposerSelectionContext(catalog: ProviderCatalog([claude, codex]), serverDefaults: defaults)
        ctx.now = Self.now
        let store = ComposerSelectionStore(defaults: nil)
        let resolved = store.resolve("draft", ctx)
        #expect(resolved.instanceId == ProviderInstanceId("codex"))
        #expect(resolved.modelSlug == "gpt-6")
        #expect(resolved.fallback?.defaultSelection.model == "opus")
        // Without the setting, the default stays.
        defaults.fallbackModelSelection = nil
        #expect(store.resolve("draft", ComposerSelectionContext(catalog: ProviderCatalog([claude, codex]), serverDefaults: defaults)).fallback == nil)
    }
}
