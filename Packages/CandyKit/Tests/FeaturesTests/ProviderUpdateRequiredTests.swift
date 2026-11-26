import AppKit
import Testing
import T3Store
import T3Protocol
@testable import Features

/// client-runtime providerUpdateRequiredModels.test.ts at 5258, with #39966's channel cases.
@MainActor struct ProviderUpdateRequiredTests {
    typealias U = ProviderUpdateRequired

    static func provider(_ driver: String, latest: String? = nil, command: String? = nil) -> ServerProvider {
        var p = PickersPreview.providers[0]
        p.driver = driver
        p.updateRequiredModels = [.init(slug: "synthetic-next", name: "Claude Synthetic Next", minVersion: "3.2.0"),
                                  .init(slug: "synthetic-max", name: "Claude Synthetic Max", minVersion: "3.1.0")]
        var advisory: [String: JSONValue] = [:]
        if let latest { advisory["latestVersion"] = .string(latest) }
        if let command { advisory["updateCommand"] = .string(command) }
        p.versionAdvisory = advisory.isEmpty ? nil : .object(advisory)
        return p
    }

    @Test func notices() {
        let claude = Self.provider("claudeAgent")
        #expect(U.notice(claude) == "Update Claude Code to v3.2.0 or newer to use Claude Synthetic Next and Claude Synthetic Max.")
        #expect(U.notice(claude, query: "max") == "Update Claude Code to v3.1.0 or newer to use Claude Synthetic Max.")
        #expect(U.notice(claude, query: "gpt") == nil && !U.channelLags(claude))
        #expect(U.notice(Self.provider("codex"), query: "next") == "Update the Codex CLI to v3.2.0 or newer to use Claude Synthetic Next.")
    }

    @Test func channelThatCannotReachTheVersion() {
        let lagging = Self.provider("claudeAgent", latest: "3.1.9")
        #expect(U.channelLags(lagging) && !U.channelLags(lagging, query: "max"))
        #expect(U.notice(lagging, query: "next") == "Using Claude Synthetic Next requires Claude Code v3.2.0 or newer, but the newest this install can update to is v3.1.9. Install Claude Code another way or wait for a newer release.")
        let cask = Self.provider("claudeAgent", latest: "3.1.9", command: "brew upgrade --cask claude-code")
        #expect(U.notice(cask, query: "next") == "Using Claude Synthetic Next requires Claude Code v3.2.0 or newer, but the claude-code Homebrew cask only has v3.1.9. Switch to the claude-code@latest cask: brew uninstall --cask claude-code && brew install --cask claude-code@latest")
        #expect(!U.channelLags(Self.provider("claudeAgent", latest: "3.3.0")))
    }

    /// The picker shows the open instance's notice under its list, and the popup grows by it.
    @MainActor @Test func pickerShowsTheNotice() {
        var providers = PickersPreview.providers
        let plain = ModelPickerView(catalog: ProviderCatalog(providers), favorites: [], active: "claudeAgent", activeModel: "claude-haiku-5-5")
        let i = providers.firstIndex { $0.driver == "claudeAgent" }!
        providers[i].updateRequiredModels = [.init(slug: "x", name: "Synthetic", minVersion: "9.0.0")]
        let view = ModelPickerView(catalog: ProviderCatalog(providers), favorites: [], active: "claudeAgent", activeModel: "claude-haiku-5-5")
        view.onManage = { _ in }
        view.frame.size = view.naturalSize
        view.layoutSubtreeIfNeeded()
        let notice = view.subviews.compactMap { $0 as? ProviderUpdateNoticeView }
        #expect(notice.count == 1 && notice[0].link != nil)
        #expect(view.naturalSize.height > plain.naturalSize.height)
        #expect(notice[0].frame.maxY <= view.bounds.height + 0.5)
    }
}
