import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Model preferences on 2994 servers and workflow subagents, against useSettings.ts, serverSettings.ts
/// and subagentRuntime.ts in the 2994 tree.
struct NightlyCompatStoreTests {
    static func json(_ text: String) -> JSONValue { try! JSONValue(parsing: Data(text.utf8)) }
    static let local = [ModelFavorite(provider: "claudeAgent", model: "claude-haiku-5-5")]
    static let localPrefs = json(#"{"codex":{"hiddenModels":["gpt-old"],"modelOrder":[]}}"#)

    @Test func oldServersKeepModelPreferencesOnTheClient() {
        let settings = Self.json(#"{"defaultRuntimeMode":"full-access"}"#)
        #expect(!ModelPreferences.serverOwned(settings))
        #expect(ModelPreferences.favorites(settings, local: Self.local) == Self.local)
        #expect(ModelPreferences.providerPreferences(settings, local: Self.localPrefs) == Self.localPrefs)
        #expect(ModelPreferences.migrationPatch(settings, local: Self.local, localPreferences: Self.localPrefs) == nil)
    }

    @Test func unmigratedServerShowsLocalAndSeedsItOnce() {
        let settings = Self.json(#"{"favorites":null,"providerModelPreferences":null}"#)
        #expect(ModelPreferences.serverOwned(settings))
        #expect(ModelPreferences.favorites(settings, local: Self.local) == Self.local)
        let patch = ModelPreferences.migrationPatch(settings, local: Self.local, localPreferences: Self.localPrefs)
        #expect(patch?["migrateModelPreferences"]?["favorites"]?[0]?["model"] == .string("claude-haiku-5-5"))
        #expect(patch?["migrateModelPreferences"]?["providerModelPreferences"] == Self.localPrefs)
        // Empty local lists claim nothing.
        #expect(ModelPreferences.migrationPatch(settings, local: [], localPreferences: .object([:])) == nil)
    }

    @Test func migratedServerWinsEvenWhenEmpty() {
        let settings = Self.json(#"{"favorites":[],"providerModelPreferences":{}}"#)
        #expect(ModelPreferences.favorites(settings, local: Self.local).isEmpty)
        #expect(ModelPreferences.providerPreferences(settings, local: Self.localPrefs) == .object([:]))
        #expect(ModelPreferences.migrationPatch(settings, local: Self.local, localPreferences: Self.localPrefs) == nil)

        let (patch, next) = ModelPreferences.favoritePatch(settings, local: Self.local, localPreferences: Self.localPrefs,
                                                           provider: "codex", model: "gpt-6")
        #expect(next == [ModelFavorite(provider: "codex", model: "gpt-6")])
        #expect(patch == Self.json(#"{"setModelFavorites":[{"provider":"codex","model":"gpt-6","favorite":true}]}"#))
        let shown = ModelPreferences.applying(settings, favorites: next)
        let (off, none) = ModelPreferences.favoritePatch(shown, local: Self.local, localPreferences: Self.localPrefs,
                                                         provider: "codex", model: "gpt-6")
        #expect(none.isEmpty)
        #expect(off["setModelFavorites"]?[0]?["favorite"] == .bool(false))
    }

    @Test func hiddenAndOrderSendOnlyWhatChanged() {
        let settings = Self.json(#"{"favorites":[],"providerModelPreferences":{"codex":{"hiddenModels":["a","b"],"modelOrder":["a"]}}}"#)
        let patch = ModelPreferences.preferencesPatch(settings, local: [], localPreferences: .object([:]),
                                                      instanceId: "codex", hidden: ["b", "c"], order: ["a"])
        #expect(patch == Self.json(#"{"setModelsHidden":[{"provider":"codex","model":"a","hidden":false},{"provider":"codex","model":"c","hidden":true}]}"#))
        let reorder = ModelPreferences.preferencesPatch(settings, local: [], localPreferences: .object([:]),
                                                        instanceId: "codex", hidden: ["a", "b"], order: ["b", "a"])
        #expect(reorder == Self.json(#"{"setProviderModelOrder":{"provider":"codex","modelOrder":["b","a"]}}"#))
    }

    @Test func workflowGroupsMembersByPhase() throws {
        let coordinator = Self.json(#"""
        {"id":"sub-1","status":"running","completedAt":null,"workflow":{"name":"Review","phases":[{"index":0,"title":"Scan"},{"index":2,"title":"Fix"}],
         "agents":[
          {"index":1,"label":"B","state":"completed","phaseIndex":0,"startedAt":1760090000000,"durationMs":5000,"result":"ok"},
          {"index":0,"label":"A","state":"running","phaseIndex":0,"startedAt":1760090001000,"childThreadId":"t-a"},
          {"index":2,"label":"C","state":"failed","phaseIndex":1,"phaseTitle":"Check","result":"boom"},
          {"index":3,"label":"D","state":"queued"}]}}
        """#)
        let g = try #require(SubagentWorkflowGroup(coordinator: coordinator))
        #expect(g.name == "Review")
        #expect(g.phases.map(\.title) == ["Scan", "Check", "Fix"])
        #expect(g.phases[0].members.map(\.title) == ["A", "B"])
        #expect(g.phases[0].state == "running")
        #expect(g.phases[0].settledCount == 1)
        #expect(g.phases[1].statusLabel == "failed")
        #expect(g.phases[1].members[0].error == "boom")
        #expect(g.phases[1].members[0].result == nil)
        #expect(g.phases[2].state == "pending")
        #expect(g.unphased.map(\.status) == ["pending"])
        #expect(g.phases[0].members[1].completedAt?.epochMs == 1_760_090_005_000)
        #expect(g.phases[0].members[0].childThreadId == ThreadId("t-a"))

        // A settled coordinator settles its queued and running members.
        var stopped = coordinator.objectValue!
        stopped["status"] = .string("cancelled")
        let s = try #require(SubagentWorkflowGroup(coordinator: .object(stopped)))
        #expect(s.phases[0].members[0].status == "cancelled")
        #expect(s.phases[0].statusLabel == "stopped")

        // Subagents from servers before 2994 have no workflow.
        #expect(SubagentWorkflowGroup(coordinator: Self.json(#"{"id":"x","status":"running"}"#)) == nil)
    }
}
