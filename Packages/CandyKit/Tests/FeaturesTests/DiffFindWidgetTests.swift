import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct DiffFindGlyphParseTests {
    @Test func glyphsParse() {
        for (name, d) in [("case", DiffFindGlyphs.matchCase), ("word", DiffFindGlyphs.wholeWord), ("regex", DiffFindGlyphs.regex),
                          ("arrow", DiffFindGlyphs.arrowRight), ("close", DiffFindGlyphs.close)] {
            do { _ = try SVGPath.parse(d) } catch { Issue.record("\(name): \(error)") }
        }
    }
}

/// The diff find widget against @pierre/diffs' search panel as T3 2861 renders it: a 38pt box, the 200pt field
/// 5pt in, the toggles inside its end, previous and next last, the close button centered on the padding box's
/// top-right corner, and Previous and Next disabled without matches.
@MainActor
struct DiffFindWidgetTests {
    @Test func geometryMatchesPierre() {
        let widget = DiffFindWidget()
        widget.countText = "No results"
        let size = widget.preferredSize
        #expect(size.height == 38 + DiffFindWidget.overhang)
        widget.frame = NSRect(origin: .zero, size: size)
        widget.layoutSubtreeIfNeeded()
        let top = DiffFindWidget.overhang
        #expect(widget.field.frame == NSRect(x: 6, y: top + 6, width: 198, height: 26))
        #expect(widget.matchCase.frame.origin == CGPoint(x: 139, y: top + 9))
        #expect(abs(widget.regex.frame.maxX - (5 + 200 - 4)) < 0.01)
        #expect(widget.next.frame.maxX == widget.preferredSize.width - DiffFindWidget.overhang - 5)
        #expect(widget.close.frame.midX == size.width - DiffFindWidget.overhang - 1 && widget.close.frame.midY == top + 1)
        #expect(!widget.previous.isEnabled && !widget.next.isEnabled)
        widget.hasMatches = true
        #expect(widget.previous.isEnabled && widget.next.isEnabled)
    }
}
