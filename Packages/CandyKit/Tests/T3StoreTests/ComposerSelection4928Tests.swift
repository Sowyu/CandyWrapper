import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Selection rows from Nightly 4928: #23957 (modelSelection.test.ts "composer fallback to another instance of the
/// same driver") and #36621 (composerDraftStore.test.ts, base traits belong to the base model).
@MainActor struct ComposerSelection4928Tests {
    /// #42041 (modelSearch.test.ts at 5258): a model is found by its full or bare ID when its name reads differently.
    @Test func modelSearchFindsTheId() throws {
        let provider = try Self.provider("opencode", driver: "opencode", models: [(slug: "opencode-go/deepseek-v4.1-flash", aliases: [])])
        var models = try #require(provider.models)
        models[0].name = "DeepSeek V4.1 Flash 1017"
        let entry = try #require(ProviderCatalog([provider]).entries.first)
        for query in ["opencode-go/deepseek-v4.1-flash", "deepseek-v4.1-flash"] {
            #expect(ModelPickerSearch.score(models[0], entry: entry, query: query, isFavorite: false) != nil, "\(query)")
        }
    }

    /// #41814: a queued edit's key holds the run's model as an explicit pick, and reading it back gives the same selection.
    @Test func explicitSelectionRoundTrips() {
        let store = ComposerSelectionStore(defaults: nil)
        let pick = ModelSelection(instanceId: Self.fallback, model: "claude-opus-5-5", selections: Self.effort("high"))
        store.setExplicitSelection("t#queued-edit:r", pick)
        #expect(store.drafts["t#queued-edit:r"]?.explicit == true)
        let back = store.pickedSelection("t#queued-edit:r")
        #expect(back.map { ComposerSelectionStore.pickMatchesThread($0, pick) } == true)
        store.didSend("t#queued-edit:r")
        #expect(store.pickedSelection("t#queued-edit:r") == nil)
    }

    static func provider(_ id: String, driver: String, enabled: Bool = true, models: [(slug: String, aliases: [String])]) throws -> ServerProvider {
        let effort: [String: Any] = ["id": "effort", "label": "Effort", "type": "select",
                                     "options": ["medium", "high", "xhigh"].map { ["id": $0, "label": $0, "isDefault": $0 == "medium"] }]
        let json: [String: Any] = ["instanceId": id, "driver": driver, "enabled": enabled, "installed": true, "status": "ready",
                                   "auth": ["status": "authenticated"],
                                   "models": models.map { ["slug": $0.slug, "name": $0.slug, "isCustom": false, "aliases": $0.aliases,
                                                           "capabilities": ["optionDescriptors": [effort]]] }]
        return try JSONDecoder().decode(ServerProvider.self, from: JSONSerialization.data(withJSONObject: json))
    }
    static let disabled = ProviderInstanceId("claudeAgent"), fallback = ProviderInstanceId("claude_team")
    static func effort(_ value: String) -> [ProviderOptionSelection] { [ProviderOptionSelection(id: "effort", value: .string(value))] }
    static func claudes() throws -> ProviderCatalog {
        let models = [(slug: "claude-opus-5-5", aliases: [String]()), (slug: "claude-sonnet-4-6", aliases: [])]
        return ProviderCatalog([try provider("claudeAgent", driver: "claudeAgent", enabled: false, models: models),
                                try provider("claude_team", driver: "claudeAgent", models: models.reversed())])
    }

    @Test func keepsTheRequestedInstancesEffortOnTheFallbackInstance() throws {
        let picked = ModelSelection(instanceId: Self.disabled, model: "claude-opus-5-5", selections: Self.effort("xhigh"))
        let ctx = ComposerSelectionContext(catalog: try Self.claudes(), projectDefaultModel: picked)
        let resolved = ComposerSelectionStore(defaults: nil).resolve("draft", ctx)
        #expect(resolved.instanceId == Self.fallback)
        #expect(resolved.modelSlug == "claude-opus-5-5")
        #expect(resolved.modelSelection == ModelSelection(instanceId: Self.fallback, model: "claude-opus-5-5", selections: Self.effort("xhigh")))
    }

    @Test func doesNotCarryOptionsPickedWithAnotherModel() throws {
        let catalog = try Self.claudes()
        let ctx = ComposerSelectionContext(catalog: catalog,
                                           projectDefaultModel: ModelSelection(instanceId: Self.disabled, model: "claude-sonnet-4-6", selections: Self.effort("high")))
        let store = ComposerSelectionStore(defaults: nil)
        // An optionless pick on the requested instance, whose options would come from the project's other model.
        store.pickModel("draft", instance: Self.disabled, model: "claude-opus-5-5", ctx)
        let resolved = store.resolve("draft", ctx)
        #expect(resolved.instanceId == Self.fallback)
        #expect(resolved.modelSlug == "claude-opus-5-5")
        #expect(resolved.options == nil)
    }

    @Test func doesNotCarryOptionsToAnotherDriver() throws {
        let catalog = ProviderCatalog([try Self.provider("claudeAgent", driver: "claudeAgent", enabled: false, models: [("claude-opus-5-5", [])]),
                                       try Self.provider("codex", driver: "codex", models: [("gpt-6-astra", [])])])
        let picked = ModelSelection(instanceId: Self.disabled, model: "claude-opus-5-5", selections: Self.effort("xhigh"))
        let resolved = ComposerSelectionStore(defaults: nil).resolve("draft", ComposerSelectionContext(catalog: catalog, projectDefaultModel: picked))
        #expect(resolved.instanceId == ProviderInstanceId("codex"))
        #expect(resolved.options == nil)
    }

    @Test func aPickOfAnotherModelTakesNoneOfTheBaseTraits() throws {
        let catalog = try Self.claudes()
        let base = ModelSelection(instanceId: Self.fallback, model: "claude-sonnet-4-6", selections: Self.effort("high"))
        let store = ComposerSelectionStore(defaults: nil)
        store.pickModel("draft", instance: Self.fallback, model: "claude-opus-5-5", ComposerSelectionContext(catalog: catalog, projectDefaultModel: base))
        let resolved = store.resolve("draft", ComposerSelectionContext(catalog: catalog, projectDefaultModel: base))
        #expect(resolved.modelSlug == "claude-opus-5-5")
        #expect(resolved.options == nil)
    }

    @Test func restoresSavedTraitsWhenTheBaseModelUsesAnAlias() throws {
        let models = [(slug: "gpt-5.4", aliases: ["5.4"])]
        let catalog = ProviderCatalog([try Self.provider("codex", driver: "codex", models: models)])
        let codex = ProviderInstanceId("codex")
        let base = ModelSelection(instanceId: codex, model: "5.4", selections: Self.effort("low"))
        let ctx = ComposerSelectionContext(catalog: catalog, projectDefaultModel: base)
        let store = ComposerSelectionStore(defaults: nil)
        store.pickModel("draft", instance: codex, model: "gpt-5.4", ctx)
        #expect(store.resolve("draft", ctx).options == Self.effort("low"))
    }

    /// #33090 (modelSelection.test.ts at 4928): a thread's stored options stay while the draft holds options for
    /// another provider.
    @Test func keepsAThreadsStoredOptionsWhileTheDraftHoldsOptionsForAnotherProvider() throws {
        let codex = ProviderInstanceId("codex"), claude = ProviderInstanceId("claudeAgent")
        func catalog(claudeOn: Bool) throws -> ProviderCatalog {
            ProviderCatalog([try Self.provider("codex", driver: "codex", models: [("gpt-5.5", ["gpt-5-codex"]), ("gpt-5.4", [])]),
                             try Self.provider("claudeAgent", driver: "claudeAgent", enabled: claudeOn, models: [("claude-opus-5-5", [])])])
        }
        let stored = ModelSelection(instanceId: codex, model: "gpt-5.5", selections: Self.effort("high"))
        func options(_ thread: ModelSelection, claudeOn: Bool = true, pickCodex: [ProviderOptionSelection]?? = .some(nil)) throws -> [ProviderOptionSelection]? {
            let ctx = ComposerSelectionContext(catalog: try catalog(claudeOn: true), thread: T3StoreTests.thread("t") { $0.modelSelection = thread })
            let store = ComposerSelectionStore(defaults: nil)
            store.pickModel("t", instance: claude, model: "claude-opus-5-5", ctx)
            store.setOptions("t", Self.effort("xhigh"), ctx)
            if case .some(let picked) = pickCodex {
                store.pickModel("t", instance: codex, model: "gpt-5.5", ctx)
                if let picked { store.setOptions("t", picked, ctx) }
            }
            let shown = ComposerSelectionContext(catalog: try catalog(claudeOn: claudeOn), thread: ctx.thread)
            return store.resolve("t", shown).options
        }
        #expect(try options(stored) == stored.optionSelections)
        // Claude turned off after an unsent pick: the composer is back on the thread's instance.
        #expect(try options(stored, claudeOn: false, pickCodex: .none) == stored.optionSelections)
        #expect(try options(stored, pickCodex: .some(Self.effort("medium"))) == Self.effort("medium"))
        // A stored alias of the shown model still counts as that model.
        #expect(try options(ModelSelection(instanceId: codex, model: "gpt-5-codex", selections: Self.effort("high"))) == stored.optionSelections)
        #expect(try options(ModelSelection(instanceId: codex, model: "gpt-5.4", selections: Self.effort("high"))) == nil)
    }

    /// #37528 and #24872 (modelSelection.test.ts at 4928): a runtime-catalog driver keeps a chosen model its refresh left
    /// out, with its options; other drivers drop the options of a model they don't list.
    @Test(arguments: [("pi", true), ("acpRegistry", true), ("cursor", true), ("codex", false)])
    func keepsTheChosenModelDuringACatalogGap(_ row: (driver: String, keeps: Bool)) throws {
        let catalog = ProviderCatalog([try Self.provider("work", driver: row.driver, models: [("listed", [])])])
        let chosen = ModelSelection(instanceId: ProviderInstanceId("work"), model: "gateway/chosen-model", selections: Self.effort("high"))
        let resolved = ComposerSelectionStore(defaults: nil).resolve("t", ComposerSelectionContext(catalog: catalog, projectDefaultModel: chosen))
        #expect(resolved.modelSelection?.model == "gateway/chosen-model")
        #expect(resolved.modelSelection?.optionSelections == (row.keeps ? Self.effort("high") : []))
    }

    @Test func resolvesTheACPDefaultMarkerWithoutAnUnavailableModel() throws {
        let json: [String: Any] = ["instanceId": "acp_work", "driver": "acpRegistry", "enabled": true, "installed": true, "status": "ready",
                                   "auth": ["status": "authenticated"],
                                   "models": [["slug": "agent-model", "name": "Agent", "isCustom": false, "isDefault": true]]]
        let acp = try JSONDecoder().decode(ServerProvider.self, from: JSONSerialization.data(withJSONObject: json))
        let marker = ModelSelection(instanceId: ProviderInstanceId("acp_work"), model: "default", selections: nil)
        let resolved = ComposerSelectionStore(defaults: nil).resolve("t", ComposerSelectionContext(catalog: ProviderCatalog([acp]), projectDefaultModel: marker))
        #expect(resolved.model?.slug == "agent-model")
        #expect(resolved.modelSelection?.model == "agent-model")
    }

    /// #24619 (composerDraftStore.test.ts at 4928): a seeded model yields to a started thread's selection; a pick wins.
    @Test func seededModelsYieldToStartedThreadSelections() throws {
        let catalog = try Self.claudes()
        let runs = ModelSelection(instanceId: Self.fallback, model: "claude-sonnet-4-6", selections: nil)
        let seed = ModelSelection(instanceId: Self.fallback, model: "claude-opus-5-5", selections: nil)
        func shown(started: Bool, pick: Bool) -> String? {
            let thread = T3StoreTests.thread("t") { $0.modelSelection = runs; $0.latestRunId = started ? RunId("r") : nil }
            let ctx = ComposerSelectionContext(catalog: catalog, thread: thread)
            let store = ComposerSelectionStore(defaults: nil)
            store.seedNewDraft("t", carry: (seed, nil), carriedFromSameDraft: false, projectDefault: nil, alreadyOpen: false)
            if pick { store.pickModel("t", instance: Self.fallback, model: "claude-opus-5-5", ctx) }
            return store.resolve("t", ctx).modelSlug
        }
        #expect(shown(started: false, pick: false) == "claude-opus-5-5")
        #expect(shown(started: true, pick: false) == "claude-sonnet-4-6")
        #expect(shown(started: true, pick: true) == "claude-opus-5-5")
    }
}

/// #37593 (useDraftEnvironmentRouting.browser.test.tsx at 4928): a draft moved to another machine starts on what a new
/// thread there would, unless the user picked a model.
@MainActor struct DraftMachineSwitchSeedTests {
    @Test func reseedsFromTheTargetMachineUnlessPicked() throws {
        let catalog = try ComposerSelection4928Tests.claudes()
        let id = ComposerSelection4928Tests.fallback
        let seed = ModelSelection(instanceId: id, model: "claude-opus-5-5", selections: nil)
        let targetDefault = ModelSelection(instanceId: id, model: "claude-sonnet-4-6", selections: nil)
        func shown(pick: Bool) -> String? {
            let store = ComposerSelectionStore(defaults: nil)
            store.seedNewDraft("d", carry: (seed, nil), carriedFromSameDraft: false, projectDefault: nil, alreadyOpen: false)
            let target = ComposerSelectionContext(catalog: catalog, projectDefaultModel: targetDefault)
            if pick { store.pickModel("d", instance: id, model: "claude-opus-5-5", target) }
            store.seedNewDraft("d", carry: (nil, nil), carriedFromSameDraft: true, projectDefault: nil, alreadyOpen: true)
            return store.resolve("d", target).modelSlug
        }
        #expect(shown(pick: false) == "claude-sonnet-4-6")
        #expect(shown(pick: true) == "claude-opus-5-5")
    }
}

/// #27397 (modelTraits.test.ts at 4928): Pi's thinking trigger names itself before a level is picked, without inventing one.
struct PiThinkingTriggerTests {
    @Test(arguments: [(String?.none, String?.none, "thinking", "Thinking"), (nil, "high", "thinking", "High"), ("low", nil, "thinking", "Low"),
                      ("max", "high", "thinking", "Max"), (nil, nil, "effort", "")])
    func labelsPiThinkingWithoutInventingASelection(_ row: (current: String?, defaultValue: String?, id: String, label: String)) {
        let options = ["low", "high", "max"].map { ProviderOptionChoice(id: $0, label: $0.prefix(1).uppercased() + $0.dropFirst(), isDefault: $0 == row.defaultValue ? true : nil) }
        var descriptor = ProviderOptionDescriptor(id: row.id, label: "Thinking", type: .select, options: options)
        descriptor.currentValue = row.current.map { .string($0) }
        #expect(ModelTraits.triggerLabel([descriptor]) == row.label)
    }
}
