import Foundation
import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Text generators (T3 eb97d82156, PR #33147): textGenerators.test.ts plus the wizard and section against a fake server.
/// No key is real and nothing touches the Keychain: the key only travels in the fake `server.updateSettings` payload.
@MainActor
struct TextGeneratorsTests {
    typealias T = TextGenerators
    static func settings(_ generators: [String: JSONValue]? = [:], instances: [String: JSONValue] = [:]) -> ServerSettingsValues {
        var o: [String: JSONValue] = ["providerInstances": .object(instances)]
        if let generators { o["textGenerators"] = .object(generators) }
        return ServerSettingsValues(.object(o))
    }

    @Test func namesAndBrands() {
        #expect(T.displayName(.init(kind: "openaiCompatible", baseUrl: "https://openrouter.ai/api/v1")) == "OpenRouter")
        #expect(T.displayName(.init(kind: "openaiCompatible", label: "Mine", baseUrl: "https://openrouter.ai/api/v1")) == "Mine")
        #expect(T.displayName(.init(kind: "openaiCompatible", baseUrl: "http://localhost:11434/v1")) == "localhost:11434")
        #expect(T.brand(kind: "anthropic", baseUrl: "https://x.example") == "anthropic")
        #expect(T.brand(kind: "openaiCompatible", baseUrl: "https://eu.openrouter.ai/api/v1") == "openrouter")
        #expect(T.brand(kind: "openaiCompatible", baseUrl: "https://api.openai.com/v1") == "openai")
        #expect(T.brand(kind: "openaiCompatible", baseUrl: "http://localhost:11434/v1") == "ollama")
        #expect(T.brand(kind: "openaiCompatible", baseUrl: "http://box:1234/v1") == "openaiCompatible")
        #expect(T.rowDetail(.init(kind: "anthropic", baseUrl: "https://api.anthropic.com/v1", enabled: false)) == "Off · api.anthropic.com/v1")
    }

    @Test func idsAvoidInstancesDriversAndGenerators() {
        let s = Self.settings(["openai": T.Config(kind: "openaiCompatible", baseUrl: "https://api.openai.com/v1").json],
                              instances: ["openai-2": .object([:])])
        #expect(T.nextId("openai", settings: s, providers: []) == "openai-3")
        #expect(T.nextId("codex", settings: s, providers: []) == "codex-2")
        #expect(T.nextId("anthropic", settings: s, providers: [ServerProvider(instanceId: "anthropic", driver: "x")]) == "anthropic-2")
        #expect(T.nextId("custom", settings: s, providers: []) == "custom")
    }

    @Test func baseUrlRules() {
        #expect(T.validBaseUrl("http://localhost:11434/v1"))
        #expect(!T.validBaseUrl("ftp://x.example"))
        #expect(!T.validBaseUrl("https://user:pw@x.example"))
        #expect(!T.validBaseUrl("https://x.example/v1?key=1"))
        #expect(!T.validBaseUrl("https://x.example/#a"))
        #expect(!T.validBaseUrl(""))
    }

    @Test func draftKeepsTheRedactedKeyAndAsksOnlyForWhatItNeeds() {
        var d = T.Draft(existing: nil)
        #expect(d.keyRequired && !d.showsBaseUrl && !d.canConnect)
        d.key = "  sk-test-not-real  "
        #expect(d.canConnect && d.config?.apiKey == "sk-test-not-real" && d.config?.label == nil)
        d.pick(T.presets[3])
        #expect(d.showsBaseUrl && !d.keyRequired && !d.canConnect)
        d.baseUrl = "http://localhost:11434/v1"
        #expect(d.canConnect)
        let saved = T.Config(kind: "anthropic", baseUrl: "https://api.anthropic.com/v1", apiKey: "<redacted>", enabled: false)
        let edit = T.Draft(existing: saved)
        #expect(!edit.keyRequired && edit.keyConfigured && !edit.showsBaseUrl)
        #expect(edit.config == saved)
    }

    @Test func targetsReplaceAnInstanceAndKeepASelectedModel() {
        let gen = T.Config(kind: "anthropic", baseUrl: "https://api.anthropic.com/v1")
        let off = T.Config(kind: "anthropic", baseUrl: "https://api.anthropic.com/v1", enabled: false)
        let providers = [ServerProvider(instanceId: "codex", driver: "codex"), ServerProvider(instanceId: "anthropic", driver: "claudeAgent")]
        let out = T.targets(providers: providers, generators: [("anthropic", gen), ("off", off)], models: ["anthropic": [("claude-haiku-5-5", "Claude Haiku 5.5")]],
                            errors: [:], selected: [ModelSelection(instanceId: "anthropic", model: "old-model")])
        #expect(out.map(\.instanceId.rawValue) == ["codex", "anthropic"])
        #expect(out[1].driver == "anthropic" && out[1].models.map(\.slug) == ["claude-haiku-5-5", "old-model"])
        let failed = T.targets(providers: [], generators: [("anthropic", gen)], models: [:], errors: ["anthropic": "401"], selected: [])
        #expect(failed[0].status == .error && failed[0].message == "401")
    }

    @Test func listInputAndUnsupportedServers() {
        let config = T.Config(kind: "openaiCompatible", baseUrl: "http://localhost:11434/v1")
        #expect(T.listInput(id: "a", config: config) == .object(["id": .string("a"), "config": config.json]))
        #expect(T.listInput(id: "a", test: true, model: "m") == .object(["id": .string("a"), "test": .bool(true), "model": .string("m")]))
        #expect(!T.supported(Self.settings(nil)))
        #expect(T.supported(Self.settings()))
        #expect(T.models(.object(["models": .array([.object(["id": .string("a"), "name": .string("A")])])])).map(\.name) == ["A"])
    }

    /// A fake server: records calls, answers the model list, saves the patch into the scope.
    @MainActor final class Fake {
        let context = SettingsPageContext()
        var calls: [(String, JSONValue)] = []
        var listResult: JSONValue = .object(["models": .array([.object(["id": .string("m1"), "name": .string("Model 1")])])])
        var fail: String?
        @MainActor init(_ generators: [String: JSONValue] = [:]) {
            let settings = TextGeneratorsTests.settings(generators)
            context.scope = SettingsScopeState(environments: [SettingsScopeEnvironment(id: "a", label: "Studio", settings: settings)], primaryId: "a")
            context.request = { [unowned self] _, method, payload in
                self.calls.append((method, payload))
                if let fail = self.fail { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: fail]) }
                return method == "server.updateSettings" ? .object([:]) : self.listResult
            }
        }
    }

    @Test func wizardChecksThenSavesWithTheKey() async throws {
        let fake = Fake()
        let w = TextGeneratorWizard(context: fake.context, environment: "a", editing: nil)
        var saved: (String, T.Config)?
        w.save = { saved = ($0, $1) }
        w.newId = { $0.id }
        w.connect()
        #expect(fake.calls.isEmpty)
        let key = try #require(Self.find(SecureInputView.self, in: w.dialog))
        key.onChange?("sk-test-not-real")
        w.connect()
        for _ in 0..<50 where w.step == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(w.step == 1)
        #expect(fake.calls.first?.0 == "server.listTextGeneratorModels")
        #expect(fake.calls.first?.1["config"]?["apiKey"]?.stringValue == "sk-test-not-real")
        #expect(saved?.0 == "openai" && saved?.1.apiKey == "sk-test-not-real")
    }

    @Test func wizardShowsTheCheckError() async throws {
        let fake = Fake()
        fake.fail = "Incorrect API key provided."
        let w = TextGeneratorWizard(context: fake.context, environment: "a", editing: nil)
        var saved = false
        w.save = { _, _ in saved = true }
        Self.find(SecureInputView.self, in: w.dialog)?.onChange?("sk-test-not-real")
        w.connect()
        for _ in 0..<50 where fake.calls.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(w.step == 0 && !saved)
    }

    @Test func sectionListsRowsAndHidesOnOldServers() throws {
        let fake = Fake(["openrouter": T.Config(kind: "openaiCompatible", baseUrl: "https://openrouter.ai/api/v1", apiKey: "<redacted>").json])
        let section = TextGeneratorsSection(context: fake.context)
        let env = fake.context.scope.environments[0]
        section.update(env, settings: env.settings!)
        #expect(!section.section.isHidden)
        let rows = section.section.group.rows.compactMap { $0 as? SettingsRowView }
        #expect(rows.map(\.title) == ["OpenRouter"] && rows[0].detail == "openrouter.ai/api/v1")
        section.update(env, settings: Self.settings(nil))
        #expect(section.section.isHidden)
        section.update(env, settings: Self.settings())
        #expect((section.section.group.rows.first as? SettingsRowView)?.title == "No text generators yet")
    }

    static func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let v = view as? V { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        if let d = view as? DialogView { for v in d.panelContent { if let f = find(type, in: v) { return f } } }
        return nil
    }
}
