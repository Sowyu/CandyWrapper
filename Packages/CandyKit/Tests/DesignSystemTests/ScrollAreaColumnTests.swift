import AppKit
import Testing
@testable import DesignSystem

/// A column that never scrolls sideways (the Orchestrator chat): with always-shown scroll bars the vertical bar takes
/// part of the width, and a document sized to the frame got a horizontal scroll bar along the bottom.
@MainActor @Suite struct ScrollAreaColumnTests {
    @Test func aColumnKeepsTheVisibleWidth() {
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 2000))
        let area = ScrollAreaView(documentView: doc)
        area.scrollsHorizontally = false
        area.scrollView.scrollerStyle = .legacy
        area.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        area.layoutSubtreeIfNeeded()
        // Sized to the frame, as the chat was, the document is wider than what shows.
        let visible = area.scrollView.contentView.bounds.width
        #expect(area.contentWidth == visible)
        #expect(doc.frame.width == visible)
        #expect(!area.scrollView.hasHorizontalScroller)
        #expect(area.scrollView.horizontalScrollElasticity == .none)
        // Sized from contentWidth it fits as is.
        doc.setFrameSize(NSSize(width: area.contentWidth, height: 2000))
        area.needsLayout = true
        area.layoutSubtreeIfNeeded()
        #expect(doc.frame.width == visible)
        // A column that may scroll sideways keeps both.
        let wide = ScrollAreaView(documentView: NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 10)))
        #expect(wide.scrollView.hasHorizontalScroller)
    }
}
