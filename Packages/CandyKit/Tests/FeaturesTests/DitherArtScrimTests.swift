import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign's art takes the scrim of whatever page shows, also when the thread panel and a utility page trade places
/// without anything else redrawing the art. The thread kept the heavy page scrim after the Orchestrator pane in 1.14.0.
@MainActor
struct DitherArtScrimTests {
    @Test func scrimFollowsThePanelAndTheOrchestratorPane() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
        let main = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = main
        let art = DitherArtView(frame: main.bounds)
        main.addSubview(art)
        // An open thread, never shown as the new-thread page: it registers when it joins the window.
        let panel = ThreadPanelView(frame: main.bounds)
        main.addSubview(panel)
        let thread = art.scrimAlphaForTesting
        let display = (reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                       increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        #expect(thread == DitherArt.scrim(.thread, display))

        // A utility page takes the panel's place: the heavy page scrim.
        panel.removeFromSuperview()
        let page = art.scrimAlphaForTesting
        #expect(page > thread)

        // The Orchestrator pane reads like a thread, and the panel coming back is a thread again.
        let pane = OrchestratorPaneView(frame: main.bounds)
        main.addSubview(pane)
        #expect(art.scrimAlphaForTesting == thread)
        pane.removeFromSuperview()
        #expect(art.scrimAlphaForTesting == page)
        main.addSubview(panel)
        #expect(art.scrimAlphaForTesting == thread)
    }
}
