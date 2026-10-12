import AppKit
import Testing
@testable import DesignSystem

/// AppKit displays every drawn view that remembered a visible rect again when an ancestor scrolls
/// (`NS_viewVisibleRectDidChange`). Truncating labels answer `visibleRect` themselves, so a scroll
/// leaves them alone; a non-truncating label shows the AppKit behavior the test relies on.
@MainActor
struct VisibleRectRedrawTests {
    @Test func scrollingLeavesTruncatingLabelsUndisplayed() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
        scroll.documentView = document
        window.contentView = scroll
        let clipped = LabelView("clipped")
        clipped.frame = NSRect(x: 0, y: 100, width: 200, height: 20)
        let unclipped = LabelView("unclipped")
        unclipped.truncates = false
        unclipped.frame = NSRect(x: 0, y: 140, width: 200, height: 20)
        let hidden = LabelView("hidden")
        hidden.frame = NSRect(x: 0, y: 60, width: 200, height: 20)
        for label in [clipped, unclipped, hidden] { document.addSubview(label) }
        window.display()
        hidden.isHidden = true
        window.display()
        #expect(clipped.visibleRect == clipped.bounds)
        #expect(hidden.visibleRect == hidden.bounds)
        for label in [clipped, unclipped, hidden] { label.layer?.displayIfNeeded() }
        #expect([clipped, unclipped, hidden].allSatisfy { !$0.layer!.needsDisplay() })

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 30))
        #expect(!clipped.layer!.needsDisplay())
        #expect(!hidden.layer!.needsDisplay())
        #expect(unclipped.layer!.needsDisplay())
        window.contentView = nil
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
