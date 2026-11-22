import Testing
import T3Protocol
@testable import T3Store

/// Deeper rename: the helper's reply becomes a short title, on the provider's cheapest model, offered in the menu.
struct DeeperRenameTests {
    @Test func aPendingRewritePreservesAnInterveningRename() {
        #expect(DeeperRename.renameCommand("t", original: "First", current: "Manual edit", suggestion: "Helper title") == nil)
        #expect(DeeperRename.renameCommand("t", original: "First", current: nil, suggestion: "Helper title") == nil)
        #expect(DeeperRename.renameCommand("t", original: "First", current: "First", suggestion: "Helper title") != nil)
    }

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
