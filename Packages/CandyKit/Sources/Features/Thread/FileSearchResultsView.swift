import AppKit
import CoreText
import DesignSystem
import T3Protocol
import T3Store

/// A file search's results grouped by file, the matched lines under each one with the pattern's matches marked
/// (`FileSearchResults`, components/chat/FileSearchResults.tsx at 5258, dfa73216cc #42429).
struct FileSearchResults: Hashable {
    struct Line: Hashable { var number: Int; var column: Int?; var text: String }
    struct Group: Hashable {
        var path: String
        var lines: [Line]
        var notes: [String]
        /// One single-line note and no lines: the note sits on the path's line (`inlineNote`).
        var inlineNote: String? { lines.isEmpty && notes.count == 1 && !notes[0].contains("\n") ? notes[0] : nil }
    }

    var groups: [Group]
    var pattern: String?

    /// `groupFileSearchResults` (work-log/itemDetail.ts:215-225): first-seen file order.
    init(results: [JSONValue], pattern: String?, workspaceRoot: String?) {
        var order: [String] = [], byFile: [String: [JSONValue]] = [:]
        for result in results {
            let file = result["fileName"]?.stringValue ?? ""
            if byFile[file] == nil { order.append(file) }
            byFile[file, default: []].append(result)
        }
        groups = order.map { file in
            let results = byFile[file] ?? []
            let lines = results.compactMap { r in
                r["line"]?.intValue.map { Line(number: $0, column: r["column"]?.intValue, text: (r["preview"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            let notes = results.compactMap { r -> String? in
                guard r["line"]?.intValue == nil, let preview = r["preview"]?.stringValue, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return preview.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) // `trimEnd()`
            }
            return Group(path: formatWorkspaceRelativePath(file, workspaceRoot: workspaceRoot), lines: lines, notes: notes)
        }
        self.pattern = pattern
    }

    static let maxHighlightsPerLine = 20
    static let maxHighlightedLineChars = 1_000

    /// `backtracksSafely` (:13-20): one quantifier, not on a group, and at most three `|`; any other pattern could hang
    /// the match, so it goes unmarked.
    static func backtracksSafely(_ pattern: String) -> Bool {
        let unescaped = pattern.replacingOccurrences(of: #"\\."#, with: "", options: .regularExpression)
        let quantifiers = unescaped.filter { "*+?{".contains($0) }.count
        let alternations = unescaped.filter { $0 == "|" }.count
        return quantifiers <= 1 && alternations <= 3 && unescaped.range(of: #"\)[*+{]"#, options: .regularExpression) == nil
    }

    /// `patternMatchers` (:25-33): the case-sensitive form first; a line it misses was matched without case.
    var matchers: [NSRegularExpression] {
        guard let pattern, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Self.backtracksSafely(pattern) else { return [] }
        return [[], [.caseInsensitive]].compactMap { try? NSRegularExpression(pattern: pattern, options: $0) }
    }

    /// `matchRanges` (:35-47).
    static func ranges(_ text: String, _ matchers: [NSRegularExpression]) -> [NSRange] {
        let ns = text as NSString
        guard ns.length <= maxHighlightedLineChars else { return [] }
        for matcher in matchers {
            var ranges: [NSRange] = []
            for match in matcher.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.range.length > 0 {
                ranges.append(match.range)
                if ranges.count == maxHighlightsPerLine { break }
            }
            if !ranges.isEmpty { return ranges }
        }
        return []
    }
}

/// The results box: `max-h-96 divide-y divide-border/60 overflow-y-auto rounded-md border border-border/70 bg-muted/45`,
/// in the inspector's mono size with `leading-relaxed`. Redesign draws it as its card on the ground.
final class FileSearchResultsView: DSView {
    static let maxHeight: CGFloat = 384

    var results: FileSearchResults? { didSet { if results != oldValue { body.results = results; needsLayout = true } } }
    private let scroll = NSScrollView()
    private let body = Body()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.useT3Scrollbars(.native)
        scroll.documentView = body
        addSubview(scroll)
        restyle()
    }

    static func height(_ results: FileSearchResults, width: CGFloat) -> CGFloat {
        min(maxHeight, Body.height(results, width: width - 2) + 2)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 1, dy: 1)
        let inner = bounds.width - 2
        let full = results.map { Body.height($0, width: inner) } ?? 0
        let lane = full > bounds.height - 2 + 0.5 ? ScrollAreaScroller.laneWidth : 0
        body.frame = NSRect(x: 0, y: 0, width: inner - lane, height: results.map { Body.height($0, width: inner - lane) } ?? 0)
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle(); body.needsDisplay = true }

    private func restyle() {
        let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        layer?.cornerRadius = redesign ? RedesignTokens.Card.radius : 6 // `rounded-md`
        layer?.borderWidth = 1
        layer?.borderColor = (redesign ? RedesignTokens.Card.border : TL.c(\.border, 0.7)).cgColor(in: self)
        layer?.backgroundColor = (redesign ? RedesignTokens.Card.fill : TL.c(\.muted, 0.45)).cgColor(in: self)
        layer?.masksToBounds = true
    }

    final class Body: DSView {
        var results: FileSearchResults? { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { false }

        static var font: NSFont { WorkDetailView.font }
        static var lineHeight: CGFloat { WorkDetailView.lineHeight }
        /// `px-2.5 py-1.5` per file, `mt-0.5` before its lines, `gap-x-3` after the line numbers, `line-clamp-3`.
        static let padX: CGFloat = 10, padY: CGFloat = 6, linesTop: CGFloat = 2, gutterGap: CGFloat = 12

        private static func attr(_ s: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }

        private static func numberWidth(_ group: FileSearchResults.Group) -> CGFloat {
            group.lines.map { TextLine(attr("\($0.number)", .black)).width }.max().map(ceil) ?? 0
        }

        private static func textWidth(_ group: FileSearchResults.Group, width: CGFloat) -> CGFloat {
            max(1, width - 2 * padX - numberWidth(group) - gutterGap)
        }

        private static func lineLayout(_ text: String, width: CGFloat, marks: [NSRange] = []) -> TextBlockLayout {
            let s = NSMutableAttributedString(attributedString: attr(text, TL.c(\.mutedForeground)))
            for range in marks { s.addAttribute(.foregroundColor, value: TL.c(\.foreground), range: range) }
            return TextBlockLayout(s, width: width, lineHeight: lineHeight, maxLines: 3)
        }

        private static func notesLayout(_ group: FileSearchResults.Group, width: CGFloat) -> TextBlockLayout? {
            guard group.inlineNote == nil, !group.notes.isEmpty else { return nil }
            return TextBlockLayout(attr(group.notes.joined(separator: "\n"), TL.c(\.mutedForeground)), width: max(1, width - 2 * padX), lineHeight: lineHeight)
        }

        static func groupHeight(_ group: FileSearchResults.Group, width: CGFloat) -> CGFloat {
            var h = padY + lineHeight
            if !group.lines.isEmpty {
                let w = textWidth(group, width: width)
                h += linesTop + group.lines.reduce(0) { $0 + lineLayout($1.text, width: w).height }
            }
            if let notes = notesLayout(group, width: width) { h += linesTop + notes.height }
            return h + padY
        }

        /// Each file's section plus the 1pt divider between them.
        static func height(_ results: FileSearchResults, width: CGFloat) -> CGFloat {
            results.groups.reduce(0) { $0 + groupHeight($1, width: width) } + CGFloat(max(0, results.groups.count - 1))
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let results, let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setShouldSmoothFonts(FontRuntime.smoothing)
            let width = bounds.width, matchers = results.matchers
            let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
            var y: CGFloat = 0
            for (index, group) in results.groups.enumerated() {
                if index > 0 {
                    ctx.setFillColor((redesign ? RedesignTokens.Card.border : TL.c(\.border, 0.6)).cgColor(in: self))
                    ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
                    y += 1
                }
                let h = Self.groupHeight(group, width: width)
                guard y < dirtyRect.maxY, y + h > dirtyRect.minY else { y += h; continue }
                drawHeader(group, ctx: ctx, y: y + Self.padY, width: width)
                var lineY = y + Self.padY + Self.lineHeight + Self.linesTop
                if !group.lines.isEmpty {
                    let numberW = Self.numberWidth(group), textX = Self.padX + numberW + Self.gutterGap
                    let textW = Self.textWidth(group, width: width)
                    for line in group.lines {
                        let number = TextBlockLayout(Self.attr("\(line.number)", TL.c(\.mutedForeground, 0.45)), width: numberW + 1, lineHeight: Self.lineHeight)
                        number.draw(in: ctx, origin: CGPoint(x: Self.padX, y: lineY), width: numberW, alignment: .right)
                        let marks = FileSearchResults.ranges(line.text, matchers)
                        let layout = Self.lineLayout(line.text, width: textW, marks: marks)
                        drawMarks(marks, layout: layout, ctx: ctx, origin: CGPoint(x: textX, y: lineY))
                        layout.draw(in: ctx, origin: CGPoint(x: textX, y: lineY), width: textW, alignment: .left)
                        lineY += layout.height
                    }
                }
                if let notes = Self.notesLayout(group, width: width) {
                    notes.draw(in: ctx, origin: CGPoint(x: Self.padX, y: lineY), width: width - 2 * Self.padX, alignment: .left)
                }
                y += h
            }
        }

        /// `FilePath`: the folder at `muted-foreground/70`, the name at `foreground/90`, truncated; then `gap-2` and
        /// "N matches" at `muted-foreground/60` when there are two or more, or the inline note at `/70`.
        private func drawHeader(_ group: FileSearchResults.Group, ctx: CGContext, y: CGFloat, width: CGFloat) {
            let slash = group.path.lastIndex(of: "/")
            let path = NSMutableAttributedString()
            if let slash { path.append(Self.attr(String(group.path[...slash]), TL.c(\.mutedForeground, 0.7))) }
            path.append(Self.attr(String(slash.map { group.path[group.path.index(after: $0)...] } ?? group.path[...]), TL.c(\.foreground, 0.9)))
            let trailing: NSAttributedString? = group.lines.count > 1
                ? Self.attr("\(group.lines.count) matches", TL.c(\.mutedForeground, 0.6))
                : group.inlineNote.map { Self.attr($0, TL.c(\.mutedForeground, 0.7)) }
            let trailingW = trailing.map { ceil(TextLine($0).width) } ?? 0
            let room = max(1, width - 2 * Self.padX - (trailing == nil ? 0 : trailingW + 8))
            let pathLine = TextBlockLayout(path, width: .greatestFiniteMagnitude, lineHeight: Self.lineHeight)
            let truncated = TextBlockLayout(path, width: room, lineHeight: Self.lineHeight, maxLines: 1)
            let shown = (pathLine.widths.first ?? 0) <= room ? pathLine : truncated
            shown.draw(in: ctx, origin: CGPoint(x: Self.padX, y: y), width: room, alignment: .left)
            if let trailing {
                let x = Self.padX + min(room, ceil(shown.widths.first ?? 0)) + 8
                TextBlockLayout(trailing, width: trailingW + 1, lineHeight: Self.lineHeight).draw(in: ctx, origin: CGPoint(x: x, y: y), width: trailingW, alignment: .left)
            }
        }

        /// `<mark className="rounded-xs bg-warning/20 text-foreground">`: a fill over the font's box behind each marked run.
        private func drawMarks(_ ranges: [NSRange], layout: TextBlockLayout, ctx: CGContext, origin: CGPoint) {
            guard !ranges.isEmpty else { return }
            let font = Self.font, glyphHeight = ceil(font.ascender - font.descender)
            ctx.setFillColor(TL.c(\.warning, 0.2).cgColor(in: self))
            for (i, line) in layout.lines.enumerated() {
                let lr = CTLineGetStringRange(line.line)
                for range in ranges {
                    let start = max(range.location, lr.location), end = min(NSMaxRange(range), lr.location + lr.length)
                    guard start < end else { continue }
                    let x0 = CTLineGetOffsetForStringIndex(line.line, start, nil), x1 = CTLineGetOffsetForStringIndex(line.line, end, nil)
                    let top = origin.y + CGFloat(i) * layout.lineHeight + (layout.lineHeight - glyphHeight) / 2
                    ctx.addPath(CGPath(roundedRect: CGRect(x: origin.x + x0, y: top, width: x1 - x0, height: glyphHeight), cornerWidth: 2, cornerHeight: 2, transform: nil))
                }
            }
            ctx.fillPath()
        }
    }
}
