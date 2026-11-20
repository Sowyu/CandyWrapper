import Foundation
import Testing
@testable import Features
import T3Protocol
import T3Store

/// @-mention a model (#31207 at 4928, client-runtime composerModelMentions.test.ts).
struct ComposerModelMentionsTests {
    static func entry(_ id: String, driver: String, name: String, status: String = "ready", models: [[String: Any]]) throws -> ProviderInstanceEntry {
        let json: [String: Any] = ["instanceId": id, "driver": driver, "displayName": name, "enabled": true, "installed": true,
                                   "status": status, "models": models.map { ["isCustom": false, "optionDescriptors": []].merging($0) { $1 } }]
        return try #require(ProviderCatalog([JSONDecoder().decode(ServerProvider.self, from: JSONSerialization.data(withJSONObject: json))]).entries.first)
    }

    @Test func atListsMatchingModelsOfReadyInstances() throws {
        let claude = try Self.entry("claudeAgent", driver: "claudeAgent", name: "Claude", models: [
            ["slug": "claude-opus-5-5", "name": "Opus 5.5"], ["slug": "claude-haiku-5-5", "name": "Haiku 5.5"],
            ["slug": "old", "name": "Opus 4", "isLegacy": true],
        ])
        let codex = try Self.entry("codex", driver: "codex", name: "Codex", status: "error", models: [["slug": "gpt-6", "name": "GPT-6 Opus"]])
        let items = ComposerModelMentions.items(query: "opus", entries: [claude, codex])
        #expect(items.map(\.id) == ["model:claudeAgent:claude-opus-5-5"])
        #expect(items.first?.label == "Opus 5.5")
        #expect(items.first?.description == "Claude")
        #expect(ComposerMenus.replacement(for: items[0]) == "model:claudeAgent/claude-opus-5-5 ")
        // One letter fills the menu with models, so it matches none; words must start a word.
        #expect(ComposerModelMentions.items(query: "o", entries: [claude]).isEmpty)
        #expect(ComposerModelMentions.items(query: "pus", entries: [claude]).isEmpty)
        #expect(ComposerModelMentions.items(query: "claude:haiku", entries: [claude]).map(\.label) == ["Haiku 5.5"])
    }

    @Test func referencesTrimProseAndKeepBalancedBrackets() {
        let found = ComposerModelMentions.collect("use model:codex/gpt-6.1. or (model:pi/foo(bar)) and xmodel:a/b")
        #expect(found.map(\.model) == ["gpt-6.1", "foo(bar)"])
        #expect(found.map(\.instanceId) == ["codex", "pi"])
        #expect(ComposerModelMentions.trimSlug("GPT-6.1-Sol[1m]") == "GPT-6.1-Sol[1m]")
        #expect(ComposerModelMentions.trimSlug("opus]).") == "opus")
    }

    @Test func editorChipsOnlyKnownModelsFollowedBySpace() {
        let known: (String, String) -> Bool = { $0 == "codex" && $1 == "gpt-6" }
        let text = "ask model:codex/gpt-6 then model:codex/gpt-7 and model:codex/gpt-6"
        let tokens = ComposerInlineTokens.collect(text, knownModel: known)
        #expect(tokens.map(\.kind) == [.model(instanceId: "codex", model: "gpt-6")])
        #expect(ComposerInlineTokens.collect(text).isEmpty)
        let look = ComposerChipLook.look(for: tokens[0], skillLabel: { $0 }, record: { _ in nil }, model: { _, _ in ("GPT-6", "codex") })
        #expect(look.kind == .model(driver: "codex"))
        #expect(look.label == "GPT-6")
    }
}
