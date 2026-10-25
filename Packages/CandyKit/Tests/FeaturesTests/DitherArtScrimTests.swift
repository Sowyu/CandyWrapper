import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign's art takes the scrim of the frontmost page that shows: an open thread the light one, the Orchestrator's
/// pane and other pages the heavy one, whatever order the pages registered in.
@MainActor
struct DitherArtScrimTests {
    let display = (reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                   increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)

    func host() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
        let main = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = main
        return (window, main)
    }

    /// Thread, the Orchestrator pane in its place, then the thread again, as the sidebar, tabs and a notification do.
    @Test func scrimFollowsThePanelAndTheOrchestratorPane() {
        let (window, main) = host()
        let art = DitherArtView(frame: main.bounds)
        main.addSubview(art)
        // An open thread, never shown as the new-thread page: it registers when it joins the window.
        let panel = ThreadPanelView(frame: main.bounds)
        main.addSubview(panel)
        let thread = DitherArt.scrim(.thread, display), heavy = DitherArt.scrim(.page, display)
        #expect(art.scrimAlphaForTesting == thread)

        let pane = OrchestratorPaneView(frame: main.bounds)
        panel.removeFromSuperview()
        main.addSubview(pane)
        #expect(art.scrimAlphaForTesting == heavy)
        pane.removeFromSuperview()
        main.addSubview(panel)
        #expect(art.scrimAlphaForTesting == thread)
        _ = window
    }

    /// The pane in front keeps the heavy scrim when the thread panel behind it registers again afterwards, and a
    /// thread panel brought to the front takes the light one even though the pane registered last.
    @Test func theFrontmostPageWinsOverTheLastRegistration() {
        let (window, main) = host()
        let art = DitherArtView(frame: main.bounds)
        main.addSubview(art)
        let thread = DitherArt.scrim(.thread, display), heavy = DitherArt.scrim(.page, display)
        let panel = ThreadPanelView(frame: main.bounds)
        main.addSubview(panel)
        let pane = OrchestratorPaneView(frame: main.bounds)
        main.addSubview(pane)
        #expect(art.scrimAlphaForTesting == heavy)

        // The panel behind registers after the pane, as an out-of-sight thread switch does.
        panel.setDraft(projectTitle: nil)
        DitherArtView.setEmphasis(.thread, from: panel)
        #expect(art.scrimAlphaForTesting == heavy)

        // Brought to the front it wins, and hidden it doesn't count.
        panel.removeFromSuperview()
        main.addSubview(panel)
        #expect(art.scrimAlphaForTesting == thread)
        panel.isHidden = true
        #expect(art.scrimAlphaForTesting == heavy)
        panel.isHidden = false
        #expect(art.scrimAlphaForTesting == thread)
        _ = window
    }

    /// Launching into the pane: the art made after the pane already shows over a registered thread panel takes the
    /// heavy scrim at once.
    @Test func artMadeUnderTheOpenPaneIsHeavy() {
        let (window, main) = host()
        main.addSubview(ThreadPanelView(frame: main.bounds))
        let pane = OrchestratorPaneView(frame: main.bounds)
        main.addSubview(pane)
        let art = DitherArtView(frame: main.bounds)
        main.addSubview(art, positioned: .below, relativeTo: nil)
        #expect(art.scrimAlphaForTesting == DitherArt.scrim(.page, display))
        _ = window
    }

    @Test func frontOrderFollowsTheViewTree() {
        let root = NSView(), a = NSView(), b = NSView(), inner = NSView()
        root.addSubview(a); root.addSubview(b); a.addSubview(inner)
        #expect(DitherArtView.isInFront(b, of: a) && DitherArtView.isInFront(b, of: inner))
        #expect(!DitherArtView.isInFront(inner, of: b) && DitherArtView.isInFront(inner, of: a))
    }
}
