import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// A page that registers as a full page while it's in a window, as a page in the thread panel's place does.
final class HeavyPageView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DitherArtView.setEmphasis(window == nil ? nil : .page, from: self)
    }
    override func viewDidHide() { super.viewDidHide(); DitherArtView.pagesMoved() }
    override func viewDidUnhide() { super.viewDidUnhide(); DitherArtView.pagesMoved() }
}

/// Redesign's art follows the frontmost page that shows, whatever order the pages registered in, so Gradient's cells
/// show only while the new-thread page is in front.
@MainActor
struct DitherArtPageTests {
    func host() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
        let main = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = main
        return (window, main)
    }

    /// Thread, a page in its place, then the thread again, as the sidebar, tabs and a notification do.
    @Test func pageFollowsThePanelAndAPage() {
        let (window, main) = host()
        let art = DitherArtView(frame: main.bounds)
        main.addSubview(art)
        // An open thread, never shown as the new-thread page: it registers when it joins the window.
        let panel = ThreadPanelView(frame: main.bounds)
        main.addSubview(panel)
        #expect(art.page == .thread)

        let pane = HeavyPageView(frame: main.bounds)
        panel.removeFromSuperview()
        main.addSubview(pane)
        #expect(art.page == .page)
        pane.removeFromSuperview()
        main.addSubview(panel)
        #expect(art.page == .thread)
        _ = window
    }

    /// The pane in front keeps the art when the thread panel behind it registers again afterwards, and a thread panel
    /// brought to the front takes it even though the pane registered last.
    @Test func theFrontmostPageWinsOverTheLastRegistration() {
        let (window, main) = host()
        let art = DitherArtView(frame: main.bounds)
        main.addSubview(art)
        let panel = ThreadPanelView(frame: main.bounds)
        main.addSubview(panel)
        let pane = HeavyPageView(frame: main.bounds)
        main.addSubview(pane)
        #expect(art.page == .page)

        // The panel behind registers after the pane, as an out-of-sight thread switch does.
        panel.setDraft(projectTitle: nil)
        DitherArtView.setEmphasis(.thread, from: panel)
        #expect(art.page == .page)

        // Brought to the front it wins, and hidden it doesn't count.
        panel.removeFromSuperview()
        main.addSubview(panel)
        #expect(art.page == .thread)
        panel.isHidden = true
        #expect(art.page == .page)
        panel.isHidden = false
        #expect(art.page == .thread)
        _ = window
    }

    /// Launching into a page: the art made after the page already shows over a registered thread panel follows it.
    @Test func artMadeUnderAnOpenPageFollowsIt() {
        let (window, main) = host()
        main.addSubview(ThreadPanelView(frame: main.bounds))
        let pane = HeavyPageView(frame: main.bounds)
        main.addSubview(pane)
        let art = DitherArtView(frame: main.bounds)
        main.addSubview(art, positioned: .below, relativeTo: nil)
        #expect(art.page == .page)
        _ = window
    }

    @Test func frontOrderFollowsTheViewTree() {
        let root = NSView(), a = NSView(), b = NSView(), inner = NSView()
        root.addSubview(a); root.addSubview(b); a.addSubview(inner)
        #expect(DitherArtView.isInFront(b, of: a) && DitherArtView.isInFront(b, of: inner))
        #expect(!DitherArtView.isInFront(inner, of: b) && DitherArtView.isInFront(inner, of: a))
    }
}
