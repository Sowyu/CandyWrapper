import AppKit
import Testing
import DesignSystem
@testable import Features

/// The row's provider icons: one per driver, the most recent first, three at most plus "+N".
@MainActor
struct SidebarProviderStackTests {
    @Test func currentComesFirstThenHistoryNewestToOldest() {
        #expect(SidebarListBuilder.providerStack(history: ["claudeAgent", "opencode"], current: "codex") == ["codex", "opencode", "claudeAgent"])
    }

    @Test func eachDriverShowsOnceAtItsLatestUse() {
        // Two Codex accounts and a return to Claude collapse to one glyph each, ordered by their last use.
        let stack = SidebarListBuilder.providerStack(history: ["codex", "claudeAgent", "codex_work"], current: "claudeAgent")
        #expect(stack == ["claudeAgent", "codex"])
        #expect(SidebarListBuilder.providerStack(history: [], current: "claudeAgent") == ["claudeAgent"])
    }

    @Test func capsAtThreeAndCountsTheRest() {
        let stack = SidebarListBuilder.providerStack(history: ["muse", "grok", "cursor", "opencode", "codex"], current: "claudeAgent")
        let capped = SidebarListBuilder.cappedProviders(stack)
        #expect(capped.shown == ["claudeAgent", "codex", "opencode"])
        #expect(capped.overflow == 3)
        #expect(SidebarListBuilder.cappedProviders(["codex", "claudeAgent"]).overflow == 0)
    }

    /// Redesign, light and dark: the stack sits at the meta line's right end, under the time, and keeps the row's
    /// height. `CW_PROVIDER_SNAPSHOTS=<dir>` writes the renders there.
    @Test(arguments: [false, true]) func redesignRowsPutTheStackAtTheBottomRight(dark: Bool) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 900)
        let codex: [String: Any] = ["instanceId": "codex", "model": "gpt-5.4"]
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            SidebarPreview.thread("a", "Claude only", project: "p1", kind: .done, minutesAgo: 3),
            SidebarPreview.thread("b", "Switched to Codex mid-thread", project: "p1", kind: .working, minutesAgo: 1,
                                  extra: ["providerInstanceId": "codex", "modelSelection": codex, "providerInstanceHistory": ["claudeAgent"],
                                          "branch": "feature/provider-icons-with-a-long-name"]),
            SidebarPreview.thread("c", "Five providers", project: "p1", kind: .done, minutesAgo: 90,
                                  extra: ["providerInstanceHistory": ["muse", "grok", "cursor", "opencode", "codex"]]),
        ]), animated: false)
        content.layoutSubtreeIfNeeded()
        for id in ["a", "b", "c"] {
            let card = try #require(content.list.rowView("thread:\(id)") as? SidebarCardRowView)
            let stack = try #require(card.subviews.first { $0 is ProviderStackView } as? ProviderStackView)
            #expect(stack.frame.minY > 20, "under the title line")
            #expect(stack.frame.maxY <= card.bounds.height)
            #expect(abs(stack.frame.maxX - (card.bounds.width - 8)) < 0.5, "flush with the row's right inset")
            let glyphs = stack.subviews.filter { !$0.isHidden && !($0 is LabelView) }
            #expect(glyphs.count == (id == "a" ? 1 : id == "b" ? 2 : 3))
            let more = stack.subviews.compactMap { $0 as? LabelView }.first { !$0.isHidden }
            #expect(more?.text == (id == "c" ? "+3" : nil))
        }
        if let dir = ProcessInfo.processInfo.environment["CW_PROVIDER_SNAPSHOTS"] {
            let rep = Snapshot.image(of: content, size: content.frame.size, scale: 2, dark: dark)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("redesign-\(dark ? "dark" : "light").png"))
        }
        window.contentView = nil
    }
}
