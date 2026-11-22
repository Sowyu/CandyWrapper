import Testing
import T3Protocol
@testable import T3Store

/// Deeper rename: the helper's reply becomes a short title, on the provider's cheapest model, offered in the menu.
struct DeeperRenameTests {
    @Test func repliesBecomeShortTitles() {
        #expect(DeeperRename.title(fromReply: "Sourdough starter summer care") == "Sourdough starter summer care")
        #expect(DeeperRename.title(fromReply: "\"Sourdough Starter Care.\"\n") == "Sourdough Starter Care")
        #expect(DeeperRename.title(fromReply: "Title: Fix lazy thread feed") == "Fix lazy thread feed")
        // The user's "prolly too long": cut to 5 words and under 40 characters at a word boundary.
        #expect(DeeperRename.title(fromReply: "CandyWrapper Redesign overhaul and 1.16 release") == "CandyWrapper Redesign overhaul and 1.16")
        #expect(DeeperRename.title(fromReply: "Fix the login flow and the session cache") == "Fix the login flow")
        let long = DeeperRename.title(fromReply: "Internationalization localization infrastructure modernization")!
        #expect(long.count <= DeeperRename.maxCharacters && !long.isEmpty)
        #expect(DeeperRename.title(fromReply: "  \n\n") == nil)
        #expect(DeeperRename.title(fromReply: "...") == nil)
    }

    @Test func helperRunsOnTheCheapestModel() {
        let opus = ModelSelection(instanceId: "claudeAgent", model: "claude-opus-5-5")
        #expect(DeeperRename.model(for: opus) == ModelSelection(instanceId: "claudeAgent", model: "claude-haiku-5-5"))
        let codex = ModelSelection(instanceId: "codex", model: "gpt-6-astra")
        #expect(DeeperRename.model(for: codex) == codex)
        #expect(DeeperRename.modelLabel("claude-haiku-5-5") == "Claude Haiku 5.5")
        #expect(DeeperRename.prompt.contains("Do not use any tools") && DeeperRename.prompt.contains("5 words"))
    }

    /// The two models the user names, with the descriptors the 4928 sandbox reports (fixtures/transcripts/26-nightly-4928.jsonl).
    static let luna = ServerProviderModel(slug: "gpt-6-luna", name: "GPT-6-Luna", optionDescriptors: [
        ProviderOptionDescriptor(id: "reasoningEffort", label: "Reasoning", type: .select,
                                 options: [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra High")]
                                    .map { ProviderOptionChoice(id: $0.0, label: $0.1, isDefault: $0.0 == "medium") }, currentValue: .string("medium")),
        ProviderOptionDescriptor(id: "serviceTier", label: "Speed", type: .select,
                                 options: [ProviderOptionChoice(id: "default", label: "Standard", isDefault: true), ProviderOptionChoice(id: "priority", label: "Fast")],
                                 currentValue: .string("default")),
    ])
    static let haiku = ServerProviderModel(slug: "claude-haiku-5-5", name: "Claude Haiku 5.5", optionDescriptors: [
        ProviderOptionDescriptor(id: "effort", label: "Effort", type: .select,
                                 options: ["low", "medium", "high", "ultrathink"].map { ProviderOptionChoice(id: $0, label: $0, isDefault: $0 == "medium") },
                                 promptInjectedValues: ["ultrathink"]),
        ProviderOptionDescriptor(id: "ultracode", label: "Ultracode", type: .boolean),
    ])

    /// A title is a small job: the lowest effort and the fastest speed unless the user chose otherwise, and a saved value
    /// the model no longer accepts falls back to its default.
    @Test func optionsDefaultToLowestEffortAndFastestSpeed() throws {
        func pairs(_ s: [ProviderOptionSelection]) -> [String] { s.map { "\($0.id)=\($0.value)" } }
        #expect(pairs(DeeperRename.options(saved: .array([]), model: Self.luna)) == ["reasoningEffort=string(\"low\")", "serviceTier=string(\"priority\")"])
        #expect(pairs(DeeperRename.options(saved: .array([]), model: Self.haiku)) == ["effort=string(\"low\")"])
        #expect(pairs(DeeperRename.defaultOptions([ProviderOptionDescriptor(id: "fastMode", label: "Fast Mode", type: .boolean)])) == ["fastMode=bool(true)"])
        let saved = try JSONValue(encoding: [ProviderOptionSelection(id: "reasoningEffort", value: .string("xhigh")),
                                             ProviderOptionSelection(id: "effort", value: .string("ultrathink"))])
        #expect(pairs(DeeperRename.options(saved: saved, model: Self.luna)).first == "reasoningEffort=string(\"xhigh\")")
        // Haiku has no reasoningEffort, and Ultrathink is a prompt word, not a level: both fall back.
        #expect(pairs(DeeperRename.options(saved: saved, model: Self.haiku)).first == "effort=string(\"low\")")
        #expect(DeeperRename.options(saved: .array([]), model: nil).isEmpty)
    }

    /// The helper's turn carries the options the way a composer send does, in `modelSelection.options`.
    @Test func theHelpersTurnCarriesTheOptions() throws {
        let providers = [ServerProvider(instanceId: "codex", driver: "codex", displayName: "Codex", models: [Self.luna])]
        let selection = DeeperRename.withOptions(ModelSelection(instanceId: "codex", model: "gpt-6-luna"), saved: .array([]), providers: providers)
        let command = DeeperRename.helperMessage(helper: ThreadId("helper"), messageId: "m1", model: selection, instructions: nil)
        let model = try #require(command["modelSelection"])
        #expect(command["type"]?.stringValue == "message.dispatch" && model["model"]?.stringValue == "gpt-6-luna")
        let options = try #require(model["options"]).decode(as: [ProviderOptionSelection].self)
        #expect(options == [ProviderOptionSelection(id: "reasoningEffort", value: .string("low")), ProviderOptionSelection(id: "serviceTier", value: .string("priority"))])
        // A model with no options sends none.
        let bare = DeeperRename.withOptions(ModelSelection(instanceId: "codex", model: "gone"), saved: .array([]), providers: providers)
        #expect(bare.options == nil)
    }

    /// The user's "Thread title instructions" reach the rewrite too, under T3's heading for them.
    @Test func theTitleInstructionsAreAppended() {
        #expect(DeeperRename.prompt(instructions: nil) == DeeperRename.prompt)
        #expect(DeeperRename.prompt(instructions: "  \n") == DeeperRename.prompt)
        let text = DeeperRename.prompt(instructions: " Lead with the main subject. ")
        #expect(text.hasPrefix(DeeperRename.prompt) && text.hasSuffix("\n\nTitle instructions from the user:\nLead with the main subject."))
        let command = DeeperRename.helperMessage(helper: ThreadId("h"), messageId: "m", model: ModelSelection(instanceId: "codex", model: "x"), instructions: "Use German.")
        #expect(command["text"]?.stringValue?.hasSuffix("Use German.") == true)
    }

    /// The user replaced T3's Regenerate title with this one, named so it reads as different (2026-11-21).
    @Test func menuOffersOneRewriteTitleInRegenerateTitlesPlace() {
        var state = ThreadActionMenu.State()
        #expect(!ThreadActionMenu.items(state).contains { $0.id == "rewrite-title" || $0.id == "regenerate-title" },
                "no title action without side chats")
        state.canRewriteTitle = true
        let items = ThreadActionMenu.items(state)
        let ids = items.map(\.id)
        #expect(!ids.contains("regenerate-title") && !ids.contains("deeper-rename"))
        #expect(ids.firstIndex(of: "rewrite-title") == ids.firstIndex(of: "rename").map { $0 + 1 })
        let item = items.first { $0.id == "rewrite-title" }
        #expect(item?.label == "Rewrite title" && item?.tooltip == "Reads the whole thread and writes a new title.")
        #expect(items.allSatisfy { !$0.label.contains("Deeper") && !$0.label.contains("Haiku") })
        state.isRegeneratingTitle = true
        #expect(ThreadActionMenu.items(state).first { $0.id == "rewrite-title" }?.disabled == true)
    }

    /// Settings > Title rewrite model: the chosen model runs while the server offers it, else the default.
    @Test func theChosenModelRunsAndAMissingOneFallsBack() {
        let parent = ModelSelection(instanceId: "claudeAgent", model: "claude-opus-5-5")
        let providers = [ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude",
                                        models: [ServerProviderModel(slug: "claude-haiku-5-5", name: "Haiku"),
                                                 ServerProviderModel(slug: "claude-sonnet-5-5", name: "Sonnet")])]
        let sonnet = ModelSelection(instanceId: "claudeAgent", model: "claude-sonnet-5-5")
        #expect(DeeperRename.model(chosen: nil, parent: parent, providers: providers) == (ModelSelection(instanceId: "claudeAgent", model: "claude-haiku-5-5"), false))
        #expect(DeeperRename.model(chosen: sonnet, parent: parent, providers: providers) == (sonnet, false))
        let gone = ModelSelection(instanceId: "claudeAgent", model: "claude-fable-5-2")
        #expect(DeeperRename.model(chosen: gone, parent: parent, providers: providers) == (ModelSelection(instanceId: "claudeAgent", model: "claude-haiku-5-5"), true))
        let otherProvider = ModelSelection(instanceId: "codex", model: "gpt-6-astra")
        #expect(DeeperRename.model(chosen: otherProvider, parent: parent, providers: providers).fellBack)
        #expect(DeeperRename.chosen(.object([:])) == nil)
        #expect(DeeperRename.chosen(.object(["instanceId": .string("claudeAgent"), "model": .string("claude-sonnet-5-5")])) == sonnet)
    }
}
