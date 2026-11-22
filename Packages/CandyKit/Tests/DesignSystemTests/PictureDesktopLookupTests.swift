import AppKit
import Testing
@testable import DesignSystem

/// Picture looks the desktop picture up once and keeps the answer: a live resize, which refreshes every layout step,
/// reads no disk after the first refresh, and the events that can change the desktop look it up again.
struct PictureDesktopLookupTests {
    @MainActor @Test func liveResizeReadsTheDesktopOnce() throws {
        _ = NSApplication.shared
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntimeInput(light: ThemeDefinition.dither.colors(for: .light).map { ThemeRuntimeHalf(colors: $0) },
                                      dark: ThemeDefinition.dither.colors(for: .dark).map { ThemeRuntimeHalf(colors: $0) })
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let shell = SidebarLayoutView(defaults: UserDefaults(suiteName: "cw.picture-desktop.\(UUID().uuidString)")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer { window.contentView = nil }
        shell.layoutSubtreeIfNeeded()
        let art = try #require(shell.main.subviews.first { $0 is DitherArtView } as? DitherArtView)
        art.windowIsActiveOverride = true
        art.refresh()
        let first = art.desktopLookupsForTesting
        #expect(first >= 1)
        for i in 1...40 {
            art.frame = NSRect(x: 0, y: 0, width: 900 + CGFloat(i) * 7, height: 760 - CGFloat(i))
            art.needsLayout = true
            art.layoutSubtreeIfNeeded()
            art.refresh()
        }
        #expect(art.desktopLookupsForTesting == first, "\(art.desktopLookupsForTesting - first) reads during the resize")
        // The app coming back to the front may follow a desktop change in System Settings: one new lookup.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(art.desktopLookupsForTesting == first + 1)
        art.refresh()
        #expect(art.desktopLookupsForTesting == first + 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        #expect(art.desktopLookupsForTesting == first + 2)
    }
}
