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

    @Test func menuOffersItUnderRegenerateTitle() {
        var state = ThreadActionMenu.State()
        #expect(!ThreadActionMenu.items(state).contains { $0.id == "deeper-rename" })
        state.deeperRenameModel = "Claude Haiku 5.5"
        let ids = ThreadActionMenu.items(state).map(\.id)
        let at = ids.firstIndex(of: "deeper-rename")
        #expect(at != nil && at == ids.firstIndex(of: "regenerate-title").map { $0 + 1 })
        #expect(ThreadActionMenu.items(state).first { $0.id == "deeper-rename" }?.label == "Deeper rename with Claude Haiku 5.5")
        state.isRegeneratingTitle = true
        #expect(ThreadActionMenu.items(state).first { $0.id == "deeper-rename" }?.disabled == true)
    }
}
