import AppKit
import Testing
@testable import DesignSystem

/// The fade mask lives in the clip view's layer space, whose bounds origin moves as AppKit scrolls.
/// A mask pinned at zero blanked every row past the first screen (WP7.7c, WP7.9).
@MainActor
struct ScrollAreaFadeTests {
    final class Tall: NSView { override var isFlipped: Bool { true } }

    @Test func maskFollowsTheScrolledOrigin() throws {
        let area = ScrollAreaView(documentView: Tall(frame: NSRect(x: 0, y: 0, width: 200, height: 2000)), scrollFade: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        area.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        window.contentView?.addSubview(area)
        area.layoutSubtreeIfNeeded()
        // Past the fade band at both ends, where the stops stop changing.
        for y in [900.0, 1200.0] {
            area.scroll(to: NSPoint(x: 0, y: y))
            let clip = try #require(area.scrollView.contentView.layer)
            let mask = try #require(clip.mask)
            #expect(mask.frame.origin.y == clip.bounds.origin.y)
            #expect(mask.frame.height == clip.bounds.height)
        }
    }
}
