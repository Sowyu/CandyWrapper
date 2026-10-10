import Foundation

/// The diff panel's flat row list: file headers, hunk separators, code rows, "No newline" rows and
/// the 8px under each expanded file, with their y offsets. Pure data, rebuilt when a file folds,
/// the layout or the width changes. Each row is 24 bytes, so a 20,000-line diff costs about 500 KB.
/// T3's `diffLayout` setting: "stacked" (pierre's unified view, the default) or split.
public enum DiffViewStyle: Sendable { case unified, split }

struct DiffLayout {
    typealias Style = DiffViewStyle

    struct Row: Equatable {
        enum Kind: UInt8 { case header, separator, line, noNewline, footer }
        var kind: Kind
        var file: Int32
        /// `line` and `noNewline`: index into `UnifiedDiff.lines`, or -1. Unified rows use only
        /// `left`; split rows pair the old side (`left`) with the new side (`right`).
        /// `separator`: `left` is the hunk index, `right` the hidden line count.
        var left: Int32
        var right: Int32
        var top: CGFloat
    }

    struct Columns: Equatable {
        /// Number column width, border included (split: the new side's gets the 1px seam too).
        var gutter: CGFloat
        /// Code column x and width (unified: one; split: old side then new side).
        var codeX: [CGFloat]
        var codeWidth: [CGFloat]
        /// Characters per visual line in each code column, nil when lines do not wrap.
        var columns: [Int?]
        var isSplit: Bool { codeX.count == 2 }
    }

    let style: Style
    let width: CGFloat
    let wrap: Bool
    private(set) var rows: [Row] = []
    private(set) var height: CGFloat = 0
    /// Per file: index of its header row and its column geometry.
    private(set) var headerRow: [Int] = []
    private(set) var columns: [Columns] = []

    init(diff: UnifiedDiff, collapsed: Set<Int>, style: Style, width: CGFloat, wrap: Bool, ch: CGFloat) {
        self.style = style
        self.width = width
        self.wrap = wrap
        var y: CGFloat = 0
        rows.reserveCapacity(diff.files.count + (collapsed.count == diff.files.count ? 0 : diff.lines.count + diff.files.count * 2))
        for (f, file) in diff.files.enumerated() {
            // pierre draws added and deleted files as one column even in split view.
            let fileStyle: Style = file.change == .new || file.change == .deleted ? .unified : style
            let cols = Self.columns(for: file, diff: diff, style: fileStyle, width: width, wrap: wrap, ch: ch)
            columns.append(cols)
            headerRow.append(rows.count)
            rows.append(Row(kind: .header, file: Int32(f), left: -1, right: -1, top: y))
            y += DiffStyle.headerHeight
            guard !collapsed.contains(f), !file.hunks.isEmpty else { continue }
            func lines(_ index: Int32, _ column: Int) -> Int {
                guard index >= 0, let perLine = cols.columns[min(column, cols.columns.count - 1)] else { return 1 }
                return Self.visualLines(diff, Int(index), columns: perLine)
            }
            func add(_ kind: Row.Kind, _ left: Int32, _ right: Int32, height: CGFloat) {
                rows.append(Row(kind: kind, file: Int32(f), left: left, right: right, top: y))
                y += height
            }
            for (h, hunk) in file.hunks.enumerated() where true {
                if hunk.collapsedBefore > 0 {
                    add(.separator, Int32(h), Int32(hunk.collapsedBefore), height: DiffStyle.separatorHeight)
                }
                switch fileStyle {
                case .unified:
                    for i in hunk.lines {
                        let index = Int32(i)
                        add(.line, index, -1, height: CGFloat(lines(index, 0)) * DiffStyle.lineHeight)
                        if diff.lines[i].noNewline { add(.noNewline, index, -1, height: DiffStyle.lineHeight) }
                    }
                case .split:
                    for (l, r) in Self.splitPairs(diff, hunk.lines) {
                        let height = CGFloat(max(lines(l, 0), lines(r, 1))) * DiffStyle.lineHeight
                        add(.line, l, r, height: height)
                        let ln = l >= 0 && diff.lines[Int(l)].noNewline, rn = r >= 0 && diff.lines[Int(r)].noNewline
                        if ln || rn { add(.noNewline, ln ? l : -1, rn ? r : -1, height: DiffStyle.lineHeight) }
                    }
                }
            }
            add(.footer, -1, -1, height: DiffStyle.fileBottomPadding)
        }
        height = y
    }

    /// pierre's split rows: context lines pair with themselves; in a change block deletions pair
    /// with additions in order and the longer side runs on against an empty buffer.
    static func splitPairs(_ diff: UnifiedDiff, _ range: Range<Int>) -> [(Int32, Int32)] {
        var pairs: [(Int32, Int32)] = []
        var i = range.lowerBound
        while i < range.upperBound {
            if diff.lines[i].kind == .context {
                pairs.append((Int32(i), Int32(i)))
                i += 1
                continue
            }
            var deletions: [Int32] = [], additions: [Int32] = []
            while i < range.upperBound, diff.lines[i].kind == .deletion { deletions.append(Int32(i)); i += 1 }
            while i < range.upperBound, diff.lines[i].kind == .addition { additions.append(Int32(i)); i += 1 }
            for k in 0..<max(deletions.count, additions.count) {
                pairs.append((k < deletions.count ? deletions[k] : -1, k < additions.count ? additions[k] : -1))
            }
        }
        return pairs
    }

    static func columns(for file: UnifiedDiff.File, diff: UnifiedDiff, style: Style, width: CGFloat, wrap: Bool, ch: CGFloat) -> Columns {
        let maxNumber = file.hunks.last.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) - 1 } ?? 1
        let gutter = DiffStyle.gutterWidth(digits: String(maxNumber).count, ch: ch)
        func perLine(_ codeWidth: CGFloat, border: CGFloat = 0) -> Int? {
            // The code box is the column minus `padding-inline: 1ch` on both sides.
            wrap ? max(1, Int(((codeWidth - border - 2 * ch) / ch + 0.0001).rounded(.down))) : nil
        }
        switch style {
        case .unified:
            let w = max(0, width - gutter)
            return Columns(gutter: gutter, codeX: [gutter], codeWidth: [w], columns: [perLine(w)])
        case .split:
            // `grid-template-columns: min-content 1fr min-content 1fr`, with a 1px seam on each side
            // of the middle (the old code column's border-right and the new gutter's border-left).
            let half = max(0, (width - 2 * gutter - 1) / 2)
            return Columns(gutter: gutter, codeX: [gutter, gutter + half + gutter + 1], codeWidth: [half, half],
                           columns: [perLine(half, border: 1), perLine(half)])
        }
    }

    /// Visual lines of one code line at `columns` characters, like `white-space: pre-wrap;
    /// word-break: break-word` in a monospace font: break after spaces, split longer words anywhere.
    // ponytail: every character is one column (tabs: tab-size 2); wide CJK and emoji glyphs are
    // narrower here than in Chromium. Measure glyph advances if non-Latin code wraps wrong.
    static func visualLines(_ diff: UnifiedDiff, _ index: Int, columns: Int) -> Int {
        let line = diff.lines[index]
        if Int(line.length) <= columns { return 1 } // bytes >= characters, so it fits
        return wrapBreaks(diff.text(line), columns: columns).count + 1
    }

    /// UTF-16 offsets where each visual line after the first starts.
    static func wrapBreaks(_ text: String, columns: Int) -> [Int] {
        var breaks: [Int] = []
        var column = 0, offset = 0
        var lastSpaceEnd: (offset: Int, column: Int)? = nil // a break opportunity after a space run
        for scalar in text.unicodeScalars {
            let width = scalar == "\t" ? tabSize - column % tabSize : 1
            if scalar != " ", scalar != "\t", column + width > columns {
                if let space = lastSpaceEnd, space.offset > (breaks.last ?? 0) {
                    breaks.append(space.offset)
                    column -= space.column
                } else {
                    breaks.append(offset)
                    column = 0
                }
                lastSpaceEnd = nil
            }
            column += width
            offset += scalar.utf16.count
            if scalar == " " || scalar == "\t" { lastSpaceEnd = (offset, column) }
        }
        return breaks
    }

    private static var tabSize: Int { 2 }

    /// Index of the last row starting at or above `y`.
    func rowIndex(at y: CGFloat) -> Int {
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].top <= y { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    func bottom(of index: Int) -> CGFloat { index + 1 < rows.count ? rows[index + 1].top : height }
}
