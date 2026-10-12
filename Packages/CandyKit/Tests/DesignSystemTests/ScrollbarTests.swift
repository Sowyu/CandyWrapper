import AppKit
import Testing
@testable import DesignSystem

/// T3's thumb geometry per style (index.css:1744-1760, scroll-area.tsx:85-104, terminal/ghostty/surface.ts:694-700).
@MainActor
struct ScrollbarTests {
    @Test func thumbGeometry() {
        // AppKit may hand an overlay scroller a wider frame; the lane stays the trailing 6px.
        let native = ScrollAreaScroller(style: .native)
        native.frame = NSRect(x: 0, y: 0, width: 8, height: 200)
        native.knobProportion = 0.5
        native.doubleValue = 0
        #expect(native.rect(for: .knob) == NSRect(x: 2, y: 0, width: 6, height: 100))

        let overlay = ScrollAreaScroller(style: .overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 7, height: 208)
        overlay.knobProportion = 0.5
        #expect(overlay.rect(for: .knob) == NSRect(x: 0, y: 4, width: 6, height: 100))
        #expect(overlay.layer?.opacity == 0)

        let terminal = ScrollAreaScroller(style: .terminal)
        terminal.frame = NSRect(x: 0, y: 0, width: 6, height: 200)
        terminal.knobProportion = 0.01
        terminal.doubleValue = 1
        #expect(terminal.rect(for: .knob) == NSRect(x: 1, y: 182, width: 4, height: 18))
    }

    @Test func nativeBarsReserveTheirLane() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        scroll.useT3Scrollbars(.native)
        #expect(scroll.scrollerStyle == .legacy)
        #expect(type(of: scroll.verticalScroller!).scrollerWidth(for: .regular, scrollerStyle: .legacy) == ScrollAreaScroller.laneWidth)
        scroll.useT3Scrollbars(.native, reservesLane: false)
        #expect(scroll.scrollerStyle == .overlay)
    }
}
