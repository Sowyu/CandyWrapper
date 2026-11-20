import AppKit
import Testing
import T3Store
@testable import Features

/// The empty right panel's "Open a surface" list offers Side chat where the + menu does, and S opens it
/// (RightPanelTabs.tsx:410-422, passed at :1635-1654 at 4928).
@MainActor @Suite struct LauncherSideChatTests {
    static func labels(_ launcher: SurfaceLauncherView) -> [String] {
        launcher.subviews.compactMap { ($0 as? LauncherRow)?.action.label }
    }

    @Test func sideChatRowFollowsThePlusMenu() {
        let panel = RightPanelView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let window = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(panel)
        let launcher = panel.launcher
        if launcher.superview == nil { panel.addSubview(launcher) }
        #expect(!Self.labels(launcher).contains("Side chat"))

        panel.sideChatOffered = true
        #expect(Self.labels(launcher).last == "Side chat")
        var picked: RightPanelSurface.Kind?
        launcher.onPick = { picked = $0 }
        #expect(launcher.handleKey("s"))
        #expect(picked == .sideChat)

        // Offered but not startable yet: listed, disabled, and S does nothing.
        picked = nil
        panel.sideChatDisabledReason = "Side chats start after the first message."
        #expect(Self.labels(launcher).last == "Side chat")
        #expect(!launcher.handleKey("s"))
        #expect(picked == nil)

        panel.sideChatOffered = false
        panel.sideChatDisabledReason = nil
        #expect(!Self.labels(launcher).contains("Side chat"))
        withExtendedLifetime(window) {}
    }
}
