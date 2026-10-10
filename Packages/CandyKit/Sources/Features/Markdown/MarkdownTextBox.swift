import AppKit
import DesignSystem

/// One block of wrapped rich text, broken into lines by TextKit 2 and placed in CSS line boxes:
/// every line is `lineHeight` tall and the strut font's glyph box sits centered in it, rounded the
/// way Blink rounds (`TextLine.baseline`). TextKit decides the breaks and the x positions; the
/// vertical rhythm is ours, because TextKit's line spacing model differs from CSS.
@MainActor
final class MarkdownTextBox {
    struct Line {
        let fragment: NSTextLineFragment
        /// The point handed to `NSTextLineFragment.draw(at:in:)`.
        let origin: CGPoint
        let baseline: CGFloat
        /// Document offset of the line's first character, and its length.
        let start: Int
        let length: Int
        let x: CGFloat
    }

    let lines: [Line]
    let height: CGFloat
    let lineHeight: CGFloat
    /// Inline code chips (border boxes), relative to the box.
    private(set) var chips: [CGRect] = []
    var firstBaseline: CGFloat { lines.first?.baseline ?? 0 }
    /// Widest line advance, ignoring alignment, for shrink-to-fit cells.
    let usedWidth: CGFloat

    // The line fragments belong to these; keep them alive with the box.
    private let storage: NSTextContentStorage
    private let manager: NSTextLayoutManager

    /// `chipRanges` are inline code runs, `chipFont` their font; both feed the chip rectangles.
    init(_ string: NSAttributedString, width: CGFloat, lineHeight: CGFloat, strut: NSFont,
         chipRanges: [NSRange] = [], chipFont: NSFont? = nil, wraps: Bool = true) {
        self.lineHeight = lineHeight
        let storage = NSTextContentStorage(), manager = NSTextLayoutManager()
        self.storage = storage
        self.manager = manager
        storage.addTextLayoutManager(manager)
        // Chromium compares widths in LayoutUnits (1/64 px); the epsilon keeps an exact fit on one line.
        let container = NSTextContainer(size: CGSize(width: wraps ? max(1, width) + 1.0 / 64 : 1_000_000, height: 0))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.textStorage?.setAttributedString(string)
        manager.ensureLayout(for: manager.documentRange)

        let strutLine = TextLine(NSAttributedString(string: " ", attributes: [.font: strut]))
        var lines: [Line] = []
        let documentStart = manager.documentRange.location
        manager.enumerateTextLayoutFragments(from: documentStart, options: [.ensuresLayout]) { fragment in
            let elementStart = storage.offset(from: documentStart, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let top = CGFloat(lines.count) * lineHeight
                let baseline = strutLine.baseline(top: top, lineHeight: lineHeight)
                let x = fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
                lines.append(Line(fragment: line, origin: CGPoint(x: x, y: baseline - line.glyphOrigin.y), baseline: baseline,
                                  start: elementStart + line.characterRange.location, length: line.characterRange.length, x: x))
            }
            return true
        }
        self.lines = lines
        height = CGFloat(max(1, lines.count)) * lineHeight
        usedWidth = lines.map { $0.fragment.typographicBounds.width }.max() ?? 0
        if let chipFont, !chipRanges.isEmpty { chips = chipRects(chipRanges, font: chipFont) }
    }

    /// Chromium's inline box for `code`: the font's rounded ascent and descent around the baseline,
    /// plus 0.1rem padding and the 1px border; 0.35rem + 1px of inline padding on each side,
    /// which the attributed string reserves with kerning (see `MarkdownStyle.inline`).
    private func chipRects(_ ranges: [NSRange], font: NSFont) -> [CGRect] {
        let a = (font.ascender * 2).rounded() / 2, d = (-font.descender * 2).rounded() / 2
        let inset = MarkdownStyle.chipPaddingX + 1, padY = MarkdownStyle.chipPaddingY + 1
        var rects: [CGRect] = []
        for range in ranges {
            for line in lines {
                let lo = max(range.location, line.start), hi = min(range.upperBound, line.start + line.length)
                guard lo < hi else { continue }
                let local = line.start - line.fragment.characterRange.location
                let x = Self.glyphOffsets(line.fragment)
                let x0 = line.x + x(lo - local) - (lo == range.location ? inset : 0)
                let x1 = line.x + x(hi - local)
                rects.append(CGRect(x: x0, y: line.baseline - a - padY, width: x1 - x0, height: a + d + 2 * padY))
            }
        }
        return rects
    }

    /// Glyph origins by string index within a line fragment. `locationForCharacter(at:)` splits a kerned
    /// character's extra advance around the caret, so it misplaces the edges the kerning reserves.
    private static func glyphOffsets(_ line: NSTextLineFragment) -> (Int) -> CGFloat {
        let range = line.characterRange
        let ct = CTLineCreateWithAttributedString(line.attributedString.attributedSubstring(from: range))
        var origins: [Int: CGFloat] = [:]
        var end: CGFloat = 0
        for run in CTLineGetGlyphRuns(ct) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
            var advances = [CGSize](repeating: .zero, count: n)
            CTRunGetStringIndices(run, CFRange(), &indices)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            for k in 0..<n {
                origins[range.location + indices[k]] = min(origins[range.location + indices[k]] ?? .greatestFiniteMagnitude, positions[k].x)
                end = max(end, positions[k].x + advances[k].width)
            }
        }
        return { index in origins[index] ?? end }
    }

    /// Blink paints each baseline on the nearest whole device pixel, ties going up the page (measured on wrapped paragraphs, list items
    /// and code blocks), so the snap uses the position in the view, not in the box.
    // ponytail: 2x device pixels, as in TextLine.baseline; pass the window's scale for 1x screens
    func draw(in ctx: CGContext, at origin: CGPoint) {
        for line in lines {
            let baseline = ((origin.y + line.baseline) * 2 - 0.5).rounded(.up) / 2
            line.fragment.draw(at: CGPoint(x: origin.x + line.origin.x, y: baseline - line.fragment.glyphOrigin.y), in: ctx)
        }
    }
}
