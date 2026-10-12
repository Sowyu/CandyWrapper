import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// The recorded `server.getConfig` reply (fixtures/transcripts/01-basic.jsonl) through the picker
/// model, plus the dispatch and resolution rules from T3's composerProviderState, TraitsPicker and
/// ChatView tests (I-composer-flow.md 8.5).
@MainActor
struct ModelPickerTests {
    static func recordedConfig() throws -> ServerProviderConfig {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("fixtures/transcripts/01-basic.jsonl"), encoding: .utf8)
        var configId: String?
        for line in text.split(separator: "\n") {
            let record = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard record["kind"] as? String == "ws", let body = record["body"] as? [String: Any] else { continue }
            if body["tag"] as? String == "server.getConfig" { configId = body["id"] as? String }
            if body["_tag"] as? String == "Exit", body["requestId"] as? String == configId,
               let exit = body["exit"] as? [String: Any], let value = exit["value"] {
                return try JSONDecoder().decode(ServerProviderConfig.self, from: JSONSerialization.data(withJSONObject: value))
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    static func names(_ rows: [ModelPickerRow]) -> [String] {
        rows.map {
            switch $0 {
            case .model(let item): item.model.name + (item.isSelected ? " *" : "")
            case .legacy(_, let count, let expanded): "Legacy models (\(count))" + (expanded ? " open" : "")
            }
        }
    }

    /// `resolveComposerInteractionMode(...).enabled`, which gates Implement in a new thread.
    @Test func interactionModeEnabled() {
        var provider = ServerProvider(instanceId: "g", driver: "grok", models: [])
        let off = ComposerSelectionContext(catalog: ProviderCatalog([provider]))
        let on = ComposerSelectionContext(catalog: ProviderCatalog([provider]), planModeEnabled: true)
        #expect(!off.interactionModeEnabled(provider))
        #expect(on.interactionModeEnabled(provider))
        #expect(!on.interactionModeEnabled(nil))
        provider.showInteractionModeToggle = false
        #expect(!on.interactionModeEnabled(provider))
    }

    @Test func pickerAppliesHiddenModelsAndExplicitOrder() throws {
        let config = try Self.recordedConfig()
        let catalog = ProviderCatalog(config.providers)
        let entry = try #require(catalog.entry("claudeAgent"))
        let hidden = try #require(entry.models.first?.slug)
        let promoted = try #require(entry.models.last?.slug)
        let preferences: JSONValue = .object(["claudeAgent": .object(["hiddenModels": .array([.string(hidden)]), "modelOrder": .array([.string(promoted)])])])
        let sections = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: hidden, favorites: [], rail: .instance("claudeAgent"), query: "", expandedLegacy: ["claudeAgent"], preferences: preferences)
        let models = sections.rows.compactMap { row -> String? in if case .model(let item) = row { return item.model.slug }; return nil }
        #expect(!models.contains(hidden))
        #expect(models.contains(promoted))
        let search = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: hidden, favorites: [], rail: .favorites, query: entry.models.first!.name, expandedLegacy: [], preferences: preferences)
        #expect(!search.rows.contains { if case .model(let item) = $0 { return item.entry.id == "claudeAgent" && item.model.slug == hidden }; return false })
    }

    @Test func decodesRecordedConfig() throws {
        let config = try Self.recordedConfig()
        #expect(config.providers.map(\.instanceId.rawValue) == ["codex", "claudeAgent", "cursor", "grok", "opencode", "antigravity", "muse", "pi"])
        #expect(config.settings.defaultRuntimeMode == .fullAccess)
        #expect(config.settings.defaultModelSelection == nil)
        let claude = try #require(config.providers.first { $0.instanceId == "claudeAgent" })
        #expect(claude.status == .ready && claude.continuationGroupKey == "claude:home:/Users/user/.claude")
        #expect(claude.models.count == 13)
        let opus = try #require(claude.models.first)
        #expect(opus.slug == "claude-opus-5-5" && opus.badge == "new")
        #expect(opus.optionDescriptors.map(\.id) == ["effort", "fastMode"])
        #expect(opus.optionDescriptors[0].promptInjectedValues == ["ultrathink"])
        #expect(opus.optionDescriptors[0].options.first { $0.isDefault == true }?.label == "Medium")
        let grok = try #require(config.providers.first { $0.instanceId == "grok" })
        #expect(grok.supportedRuntimeModes == [.approvalRequired, .auto, .fullAccess])
    }

    /// Reference 13: rail Favorites, Codex (not ready, dimmed), Claude; four current models and the
    /// legacy expander with nine.
    @Test func sectionsMatchReference13() throws {
        let catalog = ProviderCatalog(try Self.recordedConfig().providers)
        let rail = ModelPickerSections.initialRail(active: "claudeAgent", favorites: [], catalog: catalog)
        #expect(rail == .instance("claudeAgent"))
        let s = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: "claude-haiku-5-5", favorites: [],
                                    rail: rail, query: "", expandedLegacy: [])
        #expect(s.rail.map(\.entry.displayName) == ["Codex", "Claude"])
        #expect(s.rail.map(\.isDisabled) == [true, false])
        #expect(s.rail[0].tooltip.hasPrefix("Codex — Unavailable. Could not start Codex CLI"))
        #expect(Self.names(s.rows) == ["Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Fable 5.1", "Claude Haiku 5.5 *", "Legacy models (9)"])

        let open = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: "claude-haiku-5-5", favorites: [],
                                       rail: rail, query: "", expandedLegacy: ["claudeAgent"])
        #expect(open.rows.count == 14)
        #expect(Self.names(open.rows)[4] == "Legacy models (9) open")
        #expect(Self.names(open.rows).last == "Claude Haiku 4.5")

        // Codex has no ready models; Favorites lists favorites in instance order, ungrouped.
        let codex = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: "claude-haiku-5-5", favorites: [],
                                        rail: .instance("codex"), query: "", expandedLegacy: [])
        #expect(codex.rows.isEmpty)
        let favs = [ModelFavorite(provider: "claudeAgent", model: "claude-sonnet-5-5"), ModelFavorite(provider: "claudeAgent", model: "claude-opus-5-5")]
        let fav = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: "claude-haiku-5-5", favorites: favs,
                                      rail: .favorites, query: "", expandedLegacy: [])
        #expect(Self.names(fav.rows) == ["Claude Opus 5.5", "Claude Sonnet 5.5"])
        #expect(ModelPickerSections.initialRail(active: "claudeAgent", favorites: favs, catalog: catalog) == .favorites)
        // In an instance list favorites float to the top.
        let grouped = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: "x", favorites: [favs[0]],
                                          rail: .instance("claudeAgent"), query: "", expandedLegacy: [])
        #expect(Self.names(grouped.rows).prefix(2) == ["Claude Sonnet 5.5", "Claude Opus 5.5"])
        #expect(ModelPickerSections.adjacentRail(.favorites, direction: 1, catalog: catalog) == .instance("claudeAgent"))
        #expect(ModelPickerSections.adjacentRail(.instance("claudeAgent"), direction: 1, catalog: catalog) == .favorites)
    }

    @Test func searchSpansInstancesAndRanksPrefixFirst() throws {
        let catalog = ProviderCatalog(try Self.recordedConfig().providers)
        let s = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: "claude-haiku-5-5", favorites: [],
                                    rail: .instance("claudeAgent"), query: "haiku", expandedLegacy: [])
        #expect(!s.showsRail)
        #expect(Self.names(s.rows) == ["Claude Haiku 4.5", "Claude Haiku 5.5 *"])
        let fuzzy = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: "", favorites: [],
                                        rail: .instance("claudeAgent"), query: "op 5.5", expandedLegacy: [])
        #expect(Self.names(fuzzy.rows).first == "Claude Opus 5.5")
        let none = ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: "", favorites: [],
                                       rail: .instance("claudeAgent"), query: "zzzz", expandedLegacy: [])
        #expect(none.rows.isEmpty)
    }

    /// composerProviderState.test.tsx: defaults are display-only, explicit picks are sent, fast mode
    /// defaults to an explicit false.
    @Test func dispatchOptions() throws {
        let claude = ProviderCatalog(try Self.recordedConfig().providers).entry("claudeAgent")!
        let opus = claude.model("claude-opus-5-5"), haiku = claude.model("claude-haiku-5-5")
        #expect(ModelTraits.dispatchOptions(haiku, nil) == nil)
        #expect(ModelTraits.dispatchOptions(opus, nil) == [ProviderOptionSelection(id: "fastMode", value: .bool(false))])
        let picked = ModelTraits.pick(ModelTraits.descriptors(opus, selections: nil), id: "effort", value: .string("high"))
        #expect(picked == [ProviderOptionSelection(id: "effort", value: .string("high"))])
        #expect(ModelTraits.dispatchOptions(opus, picked) == [ProviderOptionSelection(id: "effort", value: .string("high")),
                                                              ProviderOptionSelection(id: "fastMode", value: .bool(false))])
        // A pick equal to the default is still sent; unknown ids are dropped.
        let medium = [ProviderOptionSelection(id: "effort", value: .string("medium")), ProviderOptionSelection(id: "bogus", value: .string("x"))]
        #expect(ModelTraits.dispatchOptions(haiku, medium) == [ProviderOptionSelection(id: "effort", value: .string("medium"))])
        // Ultrathink never lands in options: it resolves to the default.
        #expect(ModelTraits.dispatchOptions(haiku, [ProviderOptionSelection(id: "effort", value: .string("ultrathink"))])
                == [ProviderOptionSelection(id: "effort", value: .string("medium"))])
        let wire = ModelSelection(instanceId: "claudeAgent", model: "claude-opus-5-5", selections: ModelTraits.dispatchOptions(opus, nil))
        let json = String(decoding: try JSONEncoder.sorted.encode(wire), as: UTF8.self)
        #expect(json == #"{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"fastMode","value":false}]}"#)
        let bare = String(decoding: try JSONEncoder.sorted.encode(ModelSelection(instanceId: "claudeAgent", model: "claude-haiku-5-5", selections: nil)), as: UTF8.self)
        #expect(bare == #"{"instanceId":"claudeAgent","model":"claude-haiku-5-5"}"#)
        // Legacy object options decode.
        let legacy = try JSONDecoder().decode(ModelSelection.self, from: Data(#"{"provider":"claudeAgent","model":"m","options":{"effort":"max","fastMode":true}}"#.utf8))
        #expect(legacy.optionSelections == [ProviderOptionSelection(id: "effort", value: .string("max")), ProviderOptionSelection(id: "fastMode", value: .bool(true))])
    }

    /// TraitsPicker.test.ts:68: trigger label rules.
    @Test func traitsLabels() throws {
        let claude = ProviderCatalog(try Self.recordedConfig().providers).entry("claudeAgent")!
        let opus = claude.model("claude-opus-5-5")
        #expect(ModelTraits.triggerLabel(ModelTraits.descriptors(claude.model("claude-haiku-5-5"), selections: nil)) == "Medium")
        #expect(ModelTraits.triggerLabel(ModelTraits.descriptors(opus, selections: [.init(id: "fastMode", value: .bool(false))])) == "Medium")
        #expect(ModelTraits.triggerLabel(ModelTraits.descriptors(opus, selections: [.init(id: "effort", value: .string("xhigh")),
                                                                                    .init(id: "fastMode", value: .bool(true))])) == "Extra High Fast")
        #expect(ModelTraits.triggerLabel(ModelTraits.descriptors(claude.model("claude-sonnet-4-6"), selections: nil)) == "High · 200K"
                || ModelTraits.triggerLabel(ModelTraits.descriptors(claude.model("claude-sonnet-4-6"), selections: nil)).hasPrefix("High · "))
        #expect(ModelTraits.triggerLabel(ModelTraits.descriptors(claude.model("claude-haiku-4-5"), selections: [.init(id: "thinking", value: .bool(true))])) == "Thinking On")
        #expect(ModelTraits.triggerLabel(ModelTraits.descriptors(opus, selections: nil), ultrathink: true) == "Ultrathink")
        #expect(ModelTraits.applyUltrathinkPrefix("fix it") == "Ultrathink:\nfix it")
        #expect(ModelTraits.applyUltrathinkPrefix("/review now") == "/review now")
        #expect(ModelTraits.ultrathinkInBody("Ultrathink:\nplease ultrathink") && !ModelTraits.ultrathinkInBody("Ultrathink:\nfix"))
    }

    @Test func resolutionAndPicks() throws {
        let config = try Self.recordedConfig()
        let catalog = ProviderCatalog(config.providers)
        let store = ComposerSelectionStore(defaults: nil)
        let ctx = ComposerSelectionContext(catalog: catalog, serverDefaults: config.settings)
        // A new draft with nothing remembered: the first ready instance and its declared default.
        var r = store.resolve("draft", ctx)
        #expect(r.instanceId == "claudeAgent" && r.modelSlug == "claude-fable-5-1" && r.triggerLabel == "Claude Fable 5.1")
        #expect(r.runtimeMode == .fullAccess && r.runtimeModeOptions == RuntimeMode.all && r.interactionMode == .default)
        #expect(r.modelSelection == ModelSelection(instanceId: "claudeAgent", model: "claude-fable-5-1", selections: nil))

        // Pick Opus, set High: the draft and the sticky memory change; a new draft inherits both.
        #expect(store.pickModel("draft", instance: "claudeAgent", model: "claude-opus-5-5", ctx) == nil)
        r = store.resolve("draft", ctx)
        store.setOptions("draft", ModelTraits.pick(r.descriptors, id: "effort", value: .string("high")), ctx)
        r = store.resolve("draft", ctx)
        #expect(r.modelSelection?.optionSelections == [.init(id: "effort", value: .string("high")), .init(id: "fastMode", value: .bool(false))])
        #expect(ModelTraits.triggerLabel(r.descriptors) == "High")
        #expect(store.resolve("other-draft", ctx).modelSlug == "claude-opus-5-5")
        store.pickModel("draft", instance: "claudeAgent", model: "claude-haiku-5-5", ctx)
        store.pickModel("draft", instance: "claudeAgent", model: "claude-opus-5-5", ctx)
        #expect(store.resolve("draft", ctx).options == [.init(id: "effort", value: .string("high"))])

        // An existing thread shows its own selection and mode; an access pick persists at send.
        let thread = try JSONDecoder().decode(ThreadShell.self, from: Data(baseThreadJSON.replacingOccurrences(of: "codex", with: "claudeAgent")
            .replacingOccurrences(of: "gpt-5.4", with: "claude-haiku-5-5").utf8))
        let tctx = ComposerSelectionContext(catalog: catalog, thread: thread, serverDefaults: config.settings, hasStartedSession: true)
        r = store.resolve(thread.id.rawValue, tctx)
        #expect(r.modelSlug == "claude-haiku-5-5" && r.runtimeModeToPersist == nil && r.interactionModeToPersist == nil)
        store.setRuntimeMode(thread.id.rawValue, .approvalRequired)
        r = store.resolve(thread.id.rawValue, tctx)
        #expect(r.runtimeMode == .approvalRequired && r.runtimeModeToPersist == .approvalRequired)
        store.didSend(thread.id.rawValue)
        #expect(store.resolve(thread.id.rawValue, tctx).runtimeModeToPersist == nil)

        // Grok-style providers drop modes; the thread's mode shows the first supported one.
        var grok = ServerProvider(instanceId: "g", driver: "grok", models: [ServerProviderModel(slug: "m", name: "M")])
        grok.supportedRuntimeModes = [.approvalRequired, .fullAccess]
        #expect(ProviderInstanceEntry(provider: grok).runtimeModes == [.approvalRequired, .fullAccess])

        // Favorites persist as [{provider, model}].
        let defaults = UserDefaults(suiteName: "cw-wp54-tests")!
        defaults.removePersistentDomain(forName: "cw-wp54-tests")
        let persisted = ComposerSelectionStore(defaults: defaults)
        persisted.toggleFavorite("claudeAgent", "claude-opus-5-5")
        let raw = try #require(defaults.data(forKey: ComposerSelectionStore.favoritesKey))
        #expect(String(decoding: raw, as: UTF8.self) == #"[{"model":"claude-opus-5-5","provider":"claudeAgent"}]"#
                || String(decoding: raw, as: UTF8.self) == #"[{"provider":"claudeAgent","model":"claude-opus-5-5"}]"#)
        #expect(ComposerSelectionStore(defaults: defaults).isFavorite("claudeAgent", "claude-opus-5-5"))
        persisted.toggleFavorite("claudeAgent", "claude-opus-5-5")
        #expect(!ComposerSelectionStore(defaults: defaults).isFavorite("claudeAgent", "claude-opus-5-5"))
        defaults.removePersistentDomain(forName: "cw-wp54-tests")
    }

    @Test func blockRules() throws {
        let catalog = ProviderCatalog(try Self.recordedConfig().providers)
        let claude = catalog.entry("claudeAgent")!
        var pi = ServerProvider(instanceId: "pi", driver: "pi", models: [ServerProviderModel(slug: "a", name: "A"), ServerProviderModel(slug: "b", name: "B")])
        pi.requiresNewThreadForModelChange = true
        let piCatalog = ProviderCatalog([pi])
        let store = ComposerSelectionStore(defaults: nil)
        let started = ComposerSelectionContext(catalog: piCatalog, hasStartedSession: true, supportsProviderHandoff: false)
        #expect(store.pickModel("t", instance: "pi", model: "b", started) == "Start a new chat to change models")
        #expect(store.pickModel("t", instance: "pi", model: "a", started) == nil)
        let current = store.resolve("x", ComposerSelectionContext(catalog: catalog))
        #expect(ComposerSelectionStore.blockReason(from: current, to: ProviderInstanceEntry(provider: pi), model: "a",
                                                   ComposerSelectionContext(catalog: catalog, hasStartedSession: true, supportsProviderHandoff: false))
                == "Start a new chat to switch providers")
        #expect(ComposerSelectionStore.blockReason(from: current, to: claude, model: "claude-opus-5-5",
                                                   ComposerSelectionContext(catalog: catalog, hasStartedSession: false)) == nil)
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
