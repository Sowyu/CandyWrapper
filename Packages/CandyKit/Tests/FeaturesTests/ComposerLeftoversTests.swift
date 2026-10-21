import Foundation
import Testing
@testable import Features
import T3Protocol
import T3Store

/// WP7.11 logic: the provider status banner, the multi-model fan-out, terminal excerpts, clone
/// progress copy and project script helpers.
struct ComposerLeftoversTests {
    static func provider(_ json: [String: Any]) throws -> ServerProvider {
        var base: [String: Any] = ["instanceId": "claudeAgent", "driver": "claudeAgent", "enabled": true, "installed": true,
                                   "status": "ready", "models": []]
        base.merge(json) { $1 }
        return try JSONDecoder().decode(ServerProvider.self, from: JSONSerialization.data(withJSONObject: base))
    }

    @Test func providerStatusBanner() throws {
        // Ready with no advisory: nothing.
        #expect(ProviderStatusBannerLogic.key(try Self.provider([:])) == nil)
        // Signed out, with setup: error banner, title and setup link (ProviderStatusBanner.tsx:95-152).
        let out = try Self.provider(["status": "error", "auth": ["status": "unauthenticated"], "setup": ["canAuthenticate": true]])
        let b = try #require(ProviderStatusBannerLogic.banner(out, dismissedKey: nil))
        #expect(b.title == "Claude Agent is unauthenticated" && b.message == "Open provider setup to sign in." && b.variant == .error && b.setupLink)
        // Dismissed under its key stays hidden; a new status shows again.
        #expect(ProviderStatusBannerLogic.banner(out, dismissedKey: ProviderStatusBannerLogic.key(out)) == nil)
        // An unsupported version on a ready provider warns.
        let old = try Self.provider(["version": "1.0", "compatibilityAdvisory": ["status": "unsupported", "message": "Update the CLI."]])
        let w = try #require(ProviderStatusBannerLogic.banner(old, dismissedKey: nil))
        #expect(w.title == "Claude Agent 1.0 is unsupported" && w.message == "Update the CLI." && w.variant == .warning)
        #expect(ProviderStatusBannerLogic.driverLabel("claudeAgent") == "Claude Agent")
    }

    @Test func fanoutToggle() {
        let base = ModelSelection(instanceId: "claudeAgent", model: "claude-haiku-5-5")
        let (two, _) = ModelFanout.toggle(nil, base: base, instance: "claudeAgent", model: "claude-haiku-4-5")
        #expect(two?.map(\.model) == ["claude-haiku-5-5", "claude-haiku-4-5"])
        let (none, single) = ModelFanout.toggle(two, base: base, instance: "claudeAgent", model: "claude-haiku-5-5")
        #expect(none == nil && single?.model == "claude-haiku-4-5")
        #expect(ModelFanout.triggerLabel(["A", "B", "C", "D"]) == "A, B, 2 more")
        #expect(ModelFanout.triggerLabel([]) == "Choose models")
    }

    @Test func terminalExcerpt() throws {
        let s = try #require(ComposerContext.TerminalSelection(terminalId: " term-1 ", terminalLabel: "Terminal 1", lineStart: 0, lineEnd: 0,
                                                               text: "\n\nhello\r\nworld\n").normalized)
        #expect(s.text == "hello\nworld" && s.lineStart == 1 && s.lineEnd == 1 && s.label == "Terminal 1 line 1")
        let record = ComposerContext.terminalRecord(id: "abc", s)
        #expect(record["kind"]?.stringValue == "terminal" && record["contextId"]?.stringValue == "terminal_abc" && record["terminalId"]?.stringValue == "term-1")
        #expect(ComposerContext.reference(ComposerContext.terminalReference(id: "abc", s)) == "[Terminal 1 line 1](t3-context://v1/terminal/terminal_abc)")
        #expect(ComposerContext.TerminalSelection(terminalId: "t", terminalLabel: "T", lineStart: 3, lineEnd: 7, text: "x").label == "T lines 3-7")
    }

    @Test func cloneCopy() throws {
        let json: JSONValue = .array([.object(["projectId": .string("p"), "remoteUrl": .string("u"), "destinationPath": .string("/a/b/repo"),
                                               "repository": .null, "phase": .string("running"), "stage": .string("receiving"),
                                               "percent": .number(45), "detail": .string("12.3 MiB | 5.0 MiB/s")])])
        let clone = try #require(ProjectCloneSnapshot.list(json).first)
        #expect(clone.displayName == "repo" && clone.progressSummary == "Receiving objects · 45% · 12.3 MiB | 5.0 MiB/s")
        var stalled = clone
        stalled.stalled = true
        #expect(stalled.progressSummary == "Receiving objects · 45% · Stalled" && stalled.renderKey != clone.renderKey)
    }

    @Test func projectScriptHelpers() {
        let setup = ProjectScript(id: "setup", name: "Setup", command: "npm i", runOnWorktreeCreate: true)
        let dev = ProjectScript(id: "dev", name: "Dev", command: "npm run dev")
        let clean = ProjectScript(id: "clean", name: "Clean", command: "cargo clean", runOnSettle: true)
        #expect(ProjectScripts.primary([setup, clean, dev])?.id == "dev")
        #expect(ProjectScripts.primary([clean, setup])?.id == "setup")
        #expect(ProjectScripts.menuLabel(setup) == "Setup (setup)" && ProjectScripts.menuLabel(clean) == "Clean (on settle)")
        #expect(ProjectScripts.scriptId(fromCommand: "script.dev.run") == "dev" && ProjectScripts.scriptId(fromCommand: "terminal.new") == nil)
    }
}
