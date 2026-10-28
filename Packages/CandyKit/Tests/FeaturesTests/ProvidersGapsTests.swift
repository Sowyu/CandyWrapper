import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// M9 task providers: provider update one-click (ProviderUpdateLaunchNotification.logic.ts), the browser device
/// toolbar's viewport math (browserViewportLayout.ts, browserDefaults.ts), the account badge
/// (providerInstanceDisplay.ts) and the Open in editor marks.
@MainActor
struct ProvidersGapsTests {
    private func outdated(_ id: String, driver: String = "codex", command: String? = "npm i -g codex", canUpdate: Bool = true) -> ServerProvider {
        var p = ServerProvider(instanceId: .init(id), driver: driver)
        p.latestVersion = "1.2"
        var advisory: [String: JSONValue] = ["status": .string("behind_latest"), "latestVersion": .string("1.2"), "canUpdate": .bool(canUpdate)]
        advisory["updateCommand"] = command.map(JSONValue.string) ?? .null
        p.versionAdvisory = .object(advisory)
        return p
    }

    @Test func oneClickNeedsOneSharedCommand() {
        let a = outdated("codex"), b = outdated("codex_work")
        #expect(ProviderUpdateCandidates.canOneClick(a, among: [a, b]))
        let other = outdated("codex_work", command: "brew upgrade codex")
        #expect(!ProviderUpdateCandidates.canOneClick(a, among: [a, other]))
        let manual = outdated("codex", canUpdate: false)
        #expect(!ProviderUpdateCandidates.canOneClick(manual, among: [manual]))
        var running = a
        running.updateState = .init(status: "running", finishedAt: nil, message: nil)
        #expect(!ProviderUpdateCandidates.canOneClick(running, among: [running]))
    }

    /// Antigravity's health check can't see the Google sign-in: a neutral status without a dot (#18623, providerStatus.ts:27-79).
    @Test func antigravitySignInNotChecked() {
        var p = ServerProvider(instanceId: .init("antigravity"), driver: "antigravity")
        p.status = .warning
        p.auth = .object(["status": .string("unknown"), "type": .string("oauth-personal")])
        #expect(ProvidersLogic.summary(p).headline == "Installed · Sign-in not checked")
        #expect(ProvidersLogic.statusKey(p) == "neutral")
        p.auth = .object(["status": .string("unknown"), "type": .string("api-key")])
        #expect(ProvidersLogic.summary(p).headline == "Needs attention")
        #expect(ProvidersLogic.statusKey(p) == "warning")
    }

    @Test func viewportMathFollowsT3() {
        // `resolveResponsiveBrowserViewportSize` for an 800 by 600 panel: minus the rails and the toolbar.
        #expect(BrowserViewport.toggleOn(defaultViewport: BrowserViewport.fill, panel: CGSize(width: 800, height: 600), zoom: 1)
                == BrowserViewport.freeform(.init(width: 780, height: 552)))
        #expect(BrowserViewport.toggleOn(defaultViewport: nil, panel: nil, zoom: 1) == BrowserViewport.freeform(.init(width: 1024, height: 768)))
        let preset = BrowserViewport.preset("iphone-se")!
        #expect(BrowserViewport.toggleOn(defaultViewport: preset, panel: CGSize(width: 800, height: 600), zoom: 1) == preset)
        // Small panels clamp to the 240 minimum; the lock keeps the ratio.
        #expect(BrowserViewport.resize((100, 100), dx: 0, dy: 0) == .init(width: 240, height: 240))
        #expect(BrowserViewport.resize((400, 300), dx: 400, dy: 0, east: true, aspectRatio: 4.0 / 3) == .init(width: 800, height: 600))
        #expect(BrowserViewport.isValid(width: 3840, height: 2160) && !BrowserViewport.isValid(width: 3840, height: 2161))
        #expect(BrowserViewport.selectedPreset(preset) == "iphone-se" && BrowserViewport.selectedPreset(BrowserViewport.freeform(.init(width: 300, height: 300))) == nil)
    }

    @Test func badgeInitialsAndVisibility() {
        #expect(ProviderIcon.initials("Codex") == "CO")
        #expect(ProviderIcon.initials("codex_work laptop") == "CW")
        // providerInstanceDisplay.test.ts:16-26 at 3814.
        #expect(ProviderIcon.initials("Codex (hub)") == "CH")
        #expect(ProviderIcon.initials("work_codex") == "WC")
        #expect(ProviderIcon.initials("Theo's Codex") == "TC")
        #expect(ProviderIcon.initials("Codex 'hub'") == "CH")
        #expect(ProviderIcon.initials("\u{2018}hub\u{2019}") == "HU")
        #expect(ProviderIcon.initials("(hub)") == "HU")
        #expect(ProviderIcon.initials("😀 Work") == "😀W")
        #expect(ProviderIcon.initials("😀") == "😀")
        var accented = ServerProvider(instanceId: .init("claudeAgent"), driver: "claudeAgent")
        accented.accentColor = "#2563eb"
        let plain = ServerProvider(instanceId: .init("codex"), driver: "codex")
        let catalog = ProviderCatalog([accented, plain])
        #expect(ProviderBadge.shows(catalog.entries[0], in: catalog))
        #expect(!ProviderBadge.shows(catalog.entries[1], in: catalog))
        accented.accentColor = "blue"
        #expect(ProviderBadge.accent(ProviderCatalog([accented]).entries[0]) == nil)
    }

    @Test func editorMarksRender() {
        for id in ["vscode", "vscode-insiders", "vscodium", "antigravity", "idea", "webstorm"] {
            #expect(OpenInEditors.image(id) != nil, "\(id)")
        }
        #expect(OpenInEditors.image("cursor") == nil)
    }
}
