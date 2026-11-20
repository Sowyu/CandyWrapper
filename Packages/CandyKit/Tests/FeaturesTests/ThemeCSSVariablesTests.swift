import AppKit
import Foundation
import Testing
import DesignSystem
import T3Protocol
@testable import Features

@MainActor
struct ThemeCSSVariablesTests {
    /// shared/src/themeCss.test.ts cases for `themeCssValueFetches`.
    @Test func valueFetchesFollowsT3() {
        #expect(ThemeCSSVariables.valueFetches("url(https://x.test/a.png)"))
        #expect(ThemeCSSVariables.valueFetches("url( 'https://x.test/a.png' )"))
        #expect(ThemeCSSVariables.valueFetches("image-set(\"a.png\" 1x)"))
        #expect(ThemeCSSVariables.valueFetches("src(\"a\")"))
        #expect(ThemeCSSVariables.valueFetches("\\75rl(x)"))
        #expect(!ThemeCSSVariables.valueFetches("url(data:image/png;base64,AAAA)"))
        #expect(!ThemeCSSVariables.valueFetches("url(#grain)"))
        #expect(!ThemeCSSVariables.valueFetches("\"url(https://x.test)\""))
        #expect(!ThemeCSSVariables.valueFetches("#ff0000"))
    }

    @Test func readsOnlyImportantThemeColorVariablesOnTheRoot() {
        let css = """
        /* :root { --app-theme-canvas: #000000 !important; } */
        :root { --app-theme-canvas: #112233 !important; --app-theme-text: #ffffff; --background: #ff0000 !important; }
        .dark { --app-theme-muted-foreground: #445566 !important; }
        :root:not(.dark) { --app-theme-terminal-selection-background: #778899 !important; }
        [data-slot="sidebar"] { --app-theme-sidebar: #abcdef !important; }
        @media (min-width: 1px) { :root { --app-theme-border: #010101 !important; } }
        :root { --app-theme-accent: url(https://evil.test/x) !important; --app-theme-focus: var(--x) !important; }
        """
        let o = ThemeCSSVariables.overrides(css)
        #expect(o.both == [.canvas: ThemePalette.canonical("#112233")!])
        #expect(o.dark == [.mutedForeground: ThemePalette.canonical("#445566")!])
        #expect(o.light == [.terminalSelection: ThemePalette.canonical("#778899")!])
        #expect(ThemeCSSVariables.roles.count == ThemeColorRole.allCases.count)
    }

    @Test func publishedThemeWearsItsCSSColors() throws {
        let theme = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"id":"agent-sky","name":"Sky","appearance":"dark","canvas":"#101820","accent":"#3388ff",
         "css":":root { --app-theme-canvas: #202020 !important; }","background":"r1"}
        """#.utf8))
        let d = try #require(ThemeLibrary.publishedTheme(theme))
        #expect(d.colors[.canvas] == ThemePalette.canonical("#202020"))
        // The CSS never shows the image, so it is not loaded.
        let library = ThemeLibrary(defaults: UserDefaults(suiteName: "ThemeCSSVariablesTests-\(UUID())")!, pinned: nil)
        library.setEnvironmentThemes([theme])
        #expect(library.backgroundRevision("agent-sky") == nil)
        guard case .object(var o) = theme else { return }
        o["css"] = .string("[data-workspace-area=\"conversation\"] { background: var(--theme-background-image) center / cover no-repeat; }")
        library.setEnvironmentThemes([.object(o)])
        #expect(library.backgroundRevision("agent-sky") == "r1")
        #expect(library.backgroundRevision("other") == nil)
    }

    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func backgroundRetriesAtOneTwoFourEightThenWaits() async {
        let bg = ThemeBackground()
        var calls = 0
        var slept: [Double] = []
        bg.sleep = { slept.append($0) }
        bg.fetch = { _, _ in calls += 1; return calls >= 5 ? Self.png() : nil }
        bg.apply(environmentId: "e", themeId: "t", revision: "1")
        while bg.image == nil { await Task.yield() }
        #expect(calls == 5)
        #expect(slept == [1, 2, 4, 8])
        // Same revision: nothing to do.
        bg.apply(environmentId: "e", themeId: "t", revision: "1")
        #expect(calls == 5)

        // Hidden: dropped; shown again: loaded again.
        bg.setVisible(false)
        #expect(bg.image == nil)
        bg.setVisible(true)
        while bg.image == nil { await Task.yield() }
        #expect(calls == 6)

        // Every attempt fails: it gives up, and the same key loads on the next change.
        calls = 0; slept = []
        bg.fetch = { _, _ in calls += 1; return Data("not an image".utf8) }
        bg.apply(environmentId: "e", themeId: "t", revision: "2")
        #expect(bg.image == nil)
        while bg.shownKey != nil { await Task.yield() }
        #expect(calls == 5)
        #expect(slept == [1, 2, 4, 8])
        bg.apply(environmentId: "e", themeId: "t", revision: nil)
        #expect(bg.image == nil)
    }
}
