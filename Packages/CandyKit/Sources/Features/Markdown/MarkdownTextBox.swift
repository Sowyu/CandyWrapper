import AppKit
import DesignSystem

/// One block of wrapped rich text, broken into lines by TextKit 2 and placed in CSS line boxes:
/// every line is `lineHeight` tall and the strut font's glyph box sits centered in it, rounded the
/// way Blink rounds (`TextLine.baseline`). TextKit decides the breaks and the x positions; the
/// vertical rhythm is ours, because TextKit's line spacing model differs from CSS.
///
/// A big box, like a long code block, lays out one paragraph at a time when something draws, hits or measures it.
/// Its height must be known up front, so a scan counts each paragraph's lines: in a fixed pitch font, printable ASCII
/// and tabs are as wide as their columns, so a paragraph narrower than the box is one line. Only the paragraphs that
/// may wrap, or hold anything else, lay out at once. An 18,000 line code block used to lay out every line on open.
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

    /// A TextKit paragraph: its first character and the lines it fills.
    private struct Paragraph {
        let start: Int
        var firstLine: Int
        var lineCount: Int
    }

    let text: String
    let height: CGFloat
    let lineHeight: CGFloat
    let lineCount: Int
    /// Inline code chips (border boxes), relative to the box.
    private(set) var chips: [CGRect] = []
    var firstBaseline: CGFloat { lineCount == 0 ? 0 : baselineOffset }
    /// Widest line advance, ignoring alignment, for shrink-to-fit cells.
    let usedWidth: CGFloat

    // The line fragments belong to these; keep them alive with the box.
    private let storage: NSTextContentStorage
    private let manager: NSTextLayoutManager
    private let baselineOffset: CGFloat
    private let paragraphs: [Paragraph]
    /// Each paragraph's lines once laid out.
    private var laidOut: [[Line]?]
    /// How many paragraphs have laid out, for tests.
    private(set) var laidOutCount = 0

    /// Boxes with at least this many paragraphs lay out lazily.
    static let lazyParagraphs = 200

    /// What find in thread matches here and where each unit of it sits in `text` (`ThreadFindText.index`).
    /// Built on the first search, then kept with the box.
    private(set) lazy var findIndex: (text: String, sources: [NSRange]) = ThreadFindText.index(storage.textStorage ?? NSAttributedString())

    /// The ranges of `text` that find matches for `query`.
    func findRanges(_ query: String) -> [NSRange] {
        let index = findIndex
        return ThreadFindText.occurrences(index.text, query).map { match in
            let first = index.sources[match.location], last = index.sources[match.upperBound - 1]
            return NSRange(location: first.location, length: max(first.upperBound, last.upperBound) - first.location)
        }
    }

    /// `chipRanges` are inline code runs, `chipFont` their font; both feed the chip rectangles.
    /// `lazy` forces lazy layout on or off; by default a box lays out lazily from `lazyParagraphs` paragraphs.
    init(_ string: NSAttributedString, width: CGFloat, lineHeight: CGFloat, strut: NSFont,
         chipRanges: [NSRange] = [], chipFont: NSFont? = nil, wraps: Bool = true, lazy: Bool? = nil) {
        self.lineHeight = lineHeight
        text = string.string
        let storage = NSTextContentStorage(), manager = NSTextLayoutManager()
        self.storage = storage
        self.manager = manager
        storage.addTextLayoutManager(manager)
        // Chromium compares widths in LayoutUnits (1/64 px); the epsilon keeps an exact fit on one line.
        let containerWidth = wraps ? max(1, width) + 1.0 / 64 : 1_000_000
        let container = NSTextContainer(size: CGSize(width: containerWidth, height: 0))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.textStorage?.setAttributedString(string)
        let baselineOffset = TextLine(NSAttributedString(string: " ", attributes: [.font: strut])).baseline(top: 0, lineHeight: lineHeight)
        self.baselineOffset = baselineOffset
        let documentStart = manager.documentRange.location

        let scan = lazy == false || (lazy == nil && !chipRanges.isEmpty) ? nil
            : Self.scan(string, containerWidth: containerWidth, wraps: wraps, minParagraphs: lazy == true ? 1 : Self.lazyParagraphs)
        if let scan {
            var paragraphs = scan.paragraphs, widest = scan.widest, next = 0
            for p in paragraphs.indices {
                if paragraphs[p].lineCount == 0, let location = storage.location(documentStart, offsetBy: paragraphs[p].start) {
                    // Not surely one line: lay it out now to count its lines.
                    manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
                        paragraphs[p].lineCount = fragment.textLineFragments.count
                        for line in fragment.textLineFragments { widest = max(widest, line.typographicBounds.width) }
                        return false
                    }
                }
                paragraphs[p].firstLine = next
                next += paragraphs[p].lineCount
            }
            self.paragraphs = paragraphs
            laidOut = Array(repeating: nil, count: paragraphs.count)
            lineCount = next
            usedWidth = widest
        } else {
            manager.ensureLayout(for: manager.documentRange)
            var paragraphs: [Paragraph] = [], laidOut: [[Line]?] = [], next = 0, widest: CGFloat = 0
            manager.enumerateTextLayoutFragments(from: documentStart, options: [.ensuresLayout]) { fragment in
                let elementStart = storage.offset(from: documentStart, to: fragment.rangeInElement.location)
                let lines = Self.lines(fragment, elementStart: elementStart, firstLine: next, lineHeight: lineHeight, baselineOffset: baselineOffset)
                guard let first = lines.first else { return true }
                paragraphs.append(Paragraph(start: first.start, firstLine: next, lineCount: lines.count))
                laidOut.append(lines)
                next += lines.count
                widest = max(widest, lines.map { $0.fragment.typographicBounds.width }.max() ?? 0)
                return true
            }
            self.paragraphs = paragraphs
            self.laidOut = laidOut
            laidOutCount = paragraphs.count
            lineCount = next
            usedWidth = widest
        }
        height = CGFloat(max(1, lineCount)) * lineHeight
        if let chipFont, !chipRanges.isEmpty { chips = chipRects(chipRanges, font: chipFont) }
    }

    /// Splits `string` at `\n` for lazy layout. A paragraph that is surely one line gets `lineCount` 1 and counts
    /// towards `widest`; the rest get 0. Nil for fewer than `minParagraphs` paragraphs, and when the text ends in a newline
    /// or holds another paragraph separator, which TextKit splits differently.
    private static func scan(_ string: NSAttributedString, containerWidth: CGFloat, wraps: Bool, minParagraphs: Int)
        -> (paragraphs: [Paragraph], widest: CGFloat)? {
        let ns = string.string as NSString
        let length = ns.length
        guard length > 0, ns.character(at: length - 1) != 10 else { return nil }
        var units = [unichar](repeating: 0, count: length)
        ns.getCharacters(&units, range: NSRange(location: 0, length: length))
        var newlines = 0
        for c in units where c == 10 { newlines += 1 }
        guard newlines + 1 >= minParagraphs else { return nil }
        // Columns give widths only when every font has the same fixed advance.
        var advance: CGFloat?, samePitch = true, checked = Set<NSFont>()
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: length)) { value, _, stop in
            guard let font = value as? NSFont else { samePitch = false; stop.pointee = true; return }
            guard checked.insert(font).inserted else { return }
            let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: [.font: font])), nil, nil, nil)
            if !font.isFixedPitch || (advance != nil && advance != width) { samePitch = false; stop.pointee = true }
            advance = width
        }
        // Tabs count in columns only with Chromium's tab stops every 8 spaces (`MarkdownLayout.codeBlock`).
        var tabs = false
        if let advance, let style = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            tabs = style.tabStops.isEmpty && style.defaultTabInterval == 8 * advance
        }
        let fast = samePitch && advance != nil
        var paragraphs: [Paragraph] = [], widest: CGFloat = 0
        paragraphs.reserveCapacity(newlines + 1)
        var start = 0, columns = 0, simple = fast
        for i in 0...length {
            let c = i < length ? units[i] : 10
            if c == 10 {
                var lines = 0
                if simple, let advance {
                    let width = CGFloat(columns) * advance
                    // A margin from the edge, so rounding in TextKit's own sum can't decide the break.
                    if !wraps || width <= containerWidth - 0.01 { lines = 1; widest = max(widest, width) }
                }
                paragraphs.append(Paragraph(start: start, firstLine: 0, lineCount: lines))
                start = i + 1; columns = 0; simple = fast
            } else if c == 13 || c == 0x2029 || c == 0x85 {
                return nil
            } else if c >= 0x20 && c < 0x7F {
                columns += 1
            } else if c == 9 && tabs {
                columns = (columns / 8 + 1) * 8
            } else {
                simple = false
            }
        }
        return (paragraphs, widest)
    }

    private static func lines(_ fragment: NSTextLayoutFragment, elementStart: Int, firstLine: Int, lineHeight: CGFloat,
                              baselineOffset: CGFloat) -> [Line] {
        fragment.textLineFragments.enumerated().map { k, line in
            let baseline = CGFloat(firstLine + k) * lineHeight + baselineOffset
            let x = fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
            return Line(fragment: line, origin: CGPoint(x: x, y: baseline - line.glyphOrigin.y), baseline: baseline,
                        start: elementStart + line.characterRange.location, length: line.characterRange.length, x: x)
        }
    }

    /// Paragraph `p`'s lines, laid out on first use.
    private func lines(_ p: Int) -> [Line] {
        if let lines = laidOut[p] { return lines }
        let paragraph = paragraphs[p]
        let documentStart = manager.documentRange.location
        var lines: [Line] = []
        if let location = storage.location(documentStart, offsetBy: paragraph.start) {
            manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
                let elementStart = storage.offset(from: documentStart, to: fragment.rangeInElement.location)
                lines = Self.lines(fragment, elementStart: elementStart, firstLine: paragraph.firstLine, lineHeight: lineHeight,
                                   baselineOffset: baselineOffset)
                return false
            }
        }
        // The scan promised this many lines and the height counts on it.
        assert(lines.count == paragraph.lineCount, "paragraph \(p): the scan counted \(paragraph.lineCount) lines, TextKit made \(lines.count)")
        lines = Array(lines.prefix(paragraph.lineCount))
        laidOut[p] = lines
        laidOutCount += 1
        return lines
    }

    /// The last paragraph whose `key` is at most `value`. Paragraphs are sorted by start and by first line.
    private func paragraph(_ value: Int, by key: KeyPath<Paragraph, Int>) -> Int {
        var lo = 0, hi = paragraphs.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if paragraphs[mid][keyPath: key] <= value { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The lines touching the characters in `range`, or all lines, limited to `rows` when given.
    private func lines(touching range: NSRange?, rows: Range<Int>? = nil) -> [Line] {
        guard !paragraphs.isEmpty else { return [] }
        var first = 0, last = paragraphs.count - 1
        if let range {
            first = paragraph(range.location, by: \.start)
            last = paragraph(max(range.location, range.upperBound - 1), by: \.start)
        }
        if let rows {
            guard !rows.isEmpty, rows.upperBound > 0, rows.lowerBound < lineCount else { return [] }
            first = max(first, paragraph(max(0, rows.lowerBound), by: \.firstLine))
            last = min(last, paragraph(rows.upperBound - 1, by: \.firstLine))
        }
        guard first <= last else { return [] }
        var result: [Line] = []
        for p in first...last {
            for (k, line) in lines(p).enumerated() where rows?.contains(paragraphs[p].firstLine + k) ?? true { result.append(line) }
        }
        return result
    }

    /// The rows `clip` reaches, in box coordinates, with one line of slack each side: glyphs can reach past their line box.
    private func rows(_ clip: CGRect?) -> Range<Int>? {
        // `cacheDisplay` and `renderInContext` can pass an unbounded clip (infinite or near-infinite), which would trap converting to Int.
        guard let clip, abs(clip.minY) < 1e9, abs(clip.maxY) < 1e9, lineHeight > 0 else { return nil }
        let first = Int((clip.minY / lineHeight).rounded(.down)) - 1, last = Int((clip.maxY / lineHeight).rounded(.up)) + 1
        return first..<max(first, last + 1)
    }

    /// Chromium's inline box for `code`: the font's rounded ascent and descent around the baseline,
    /// plus 0.1rem padding and the 1px border; 0.35rem + 1px of inline padding on each side,
    /// which the attributed string reserves with kerning (see `MarkdownStyle.inline`).
    private func chipRects(_ ranges: [NSRange], font: NSFont) -> [CGRect] {
        let a = (font.ascender * 2).rounded() / 2, d = (-font.descender * 2).rounded() / 2
        let inset = MarkdownStyle.chipPaddingX + 1, padY = MarkdownStyle.chipPaddingY + 1
        var rects: [CGRect] = []
        for range in ranges {
            for line in lines(touching: range) {
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

    func character(at point: CGPoint) -> Int {
        guard lineCount > 0 else { return 0 }
        let row = min(lineCount - 1, max(0, Int(point.y / lineHeight)))
        guard let line = lines(touching: nil, rows: row..<(row + 1)).first else { return 0 }
        let attributed = line.fragment.attributedString.attributedSubstring(from: line.fragment.characterRange)
        let ct = CTLineCreateWithAttributedString(attributed)
        let offset = CTLineGetStringIndexForPosition(ct, CGPoint(x: point.x - line.x, y: 0))
        return min((text as NSString).length, line.start + max(0, offset == kCFNotFound ? line.length : offset))
    }

    /// The top of the CSS line box holding `baseline`: lines stack `lineHeight` apart from the box's top.
    /// Chromium's selection paints that whole box, not the glyphs' content area.
    func lineTop(baseline: CGFloat) -> CGFloat { (baseline / lineHeight).rounded(.down) * lineHeight }

    /// Horizontal extent and baseline of `range` on each line it touches, relative to the box.
    /// `clip`, in box coordinates, skips the lines far from it.
    func spans(_ range: NSRange, clip: CGRect? = nil) -> [(x0: CGFloat, x1: CGFloat, baseline: CGFloat)] {
        lines(touching: range, rows: rows(clip)).compactMap { line in
            let lo = max(range.location, line.start), hi = min(range.upperBound, line.start + line.length)
            guard lo < hi else { return nil }
            let local = line.start - line.fragment.characterRange.location
            let x = Self.glyphOffsets(line.fragment)
            return (line.x + x(lo - local), line.x + x(hi - local), line.baseline)
        }
    }

    /// The last of `spans(range)`, laying out only the paragraph it ends in.
    func lastSpan(_ range: NSRange) -> (x0: CGFloat, x1: CGFloat, baseline: CGFloat)? {
        guard !paragraphs.isEmpty, range.length > 0 else { return nil }
        let start = paragraphs[paragraph(range.upperBound - 1, by: \.start)].start
        let tail = NSRange(location: max(range.location, start), length: range.upperBound - max(range.location, start))
        return spans(tail).last ?? spans(range).last
    }

    /// The box a CSS highlight paints behind the text at `index` on a line whose baseline sits at `baseline`: the
    /// font's content area, its ascent above the baseline and its descent below, each rounded to device pixels as Blink rounds them.
    func contentArea(at index: Int, baseline: CGFloat) -> (y: CGFloat, height: CGFloat) {
        let font = (storage.textStorage?.length ?? 0) > index ? storage.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont : nil
        // Blink sizes the font in device pixels (2x, as `draw` assumes) and rounds its metrics there.
        let ascent = ((font?.ascender ?? lineHeight * 0.75) * 2).rounded() / 2, descent = ((-(font?.descender ?? -lineHeight * 0.25)) * 2).rounded() / 2
        return (baseline - ascent, ascent + descent)
    }

    /// Draws `range` again in `color` over the box's own glyphs: a CSS highlight's foreground. `clip` is in the context's coordinates.
    func draw(_ range: NSRange, color: NSColor, in ctx: CGContext, at origin: CGPoint, clip: CGRect? = nil) {
        guard let text = storage.textStorage else { return }
        for line in lines(touching: range, rows: rows(clip?.offsetBy(dx: -origin.x, dy: -origin.y))) {
            let lo = max(range.location, line.start), hi = min(range.upperBound, line.start + line.length, text.length)
            guard lo < hi else { continue }
            let x = Self.glyphOffsets(line.fragment)(lo - (line.start - line.fragment.characterRange.location))
            let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: lo, length: hi - lo)))
            let all = NSRange(location: 0, length: piece.length)
            piece.addAttribute(.foregroundColor, value: color, range: all)
            piece.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color.cgColor, range: all)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: origin.x + line.x + x, y: Self.snappedBaseline(origin.y + line.baseline))
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(CTLineCreateWithAttributedString(piece), ctx)
            ctx.restoreGState()
        }
    }

    /// Blink's baseline snap for a box drawn at `y` (see `draw`).
    static func snappedBaseline(_ y: CGFloat) -> CGFloat { (y * 2 - 0.5).rounded(.up) / 2 }

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
    /// `clip` limits drawing to the lines near it: every line box is `lineHeight` tall, so the range is plain arithmetic,
    /// and a lazy box lays out only those lines.
    func draw(in ctx: CGContext, at origin: CGPoint, clip: CGRect? = nil) {
        for line in lines(touching: nil, rows: rows(clip?.offsetBy(dx: -origin.x, dy: -origin.y))) {
            let baseline = Self.snappedBaseline(origin.y + line.baseline)
            line.fragment.draw(at: CGPoint(x: origin.x + line.origin.x, y: baseline - line.fragment.glyphOrigin.y), in: ctx)
        }
    }
}
