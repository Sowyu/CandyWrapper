import Foundation

/// T3's chat math syntax (shared/src/markdownMath.ts): remark-math with `singleDollarTextMath`, its tokenizer
/// swapped for micromark-extension-llm-math 3.1.0 and T3's patches to it and to the GFM table tokenizer
/// (patches/micromark-extension-llm-math@3.1.0.patch, patches/micromark-extension-gfm-table@2.1.1.patch).
/// Foundation's parser knows no math, so this finds each formula in the source first, in the Markdown context
/// micromark sees, and swaps it for a placeholder Foundation keeps whole: the autolink `<cwmath0:3x>` for an inline
/// formula, a fence with the info `cwmath0-3` for a display block and `cwmath0-f` for a closed ```` ```math ```` fence.
/// `TreeBuilder` maps them back.
// ponytail: HTML blocks and link reference definitions are scanned like paragraphs, so a formula inside a raw
// `<div>` block becomes math where T3 shows text; skip them here if agents start writing math in HTML blocks.
enum MarkdownMathScanner {
    struct Placeholders: Sendable {
        /// `cwmath` and a number the message never contains.
        let scheme: String
        let formulas: [MarkdownMath]

        /// The fence placeholder's formula: `.some(nil)` for a closed ```` ```math ```` fence, whose code is the TeX.
        func fence(_ info: String?) -> MarkdownMath?? {
            guard let language = info?.split(separator: " ", maxSplits: 1).first, language.hasPrefix(scheme + "-") else { return nil }
            let rest = language.dropFirst(scheme.count + 1)
            if rest == "f" { return .some(nil) }
            guard let n = Int(rest), formulas.indices.contains(n) else { return nil }
            return .some(formulas[n])
        }

        /// `text` cut at the inline placeholders it holds. Foundation merges a placeholder into the text around it
        /// when an outer link gives both the same attributes (`[norm $|x|$](url)`).
        func pieces(of text: String) -> [(text: String, math: MarkdownMath?)]? {
            let prefix = Array((scheme + ":").utf8)
            let b = Array(text.utf8)
            var out: [(String, MarkdownMath?)] = []
            var last = 0, i = 0
            while i + prefix.count <= b.count {
                guard b[i] == prefix[0], Array(b[i..<(i + prefix.count)]) == prefix else { i += 1; continue }
                var k = i + prefix.count, n = 0
                while k < b.count, b[k] >= 48, b[k] <= 57 { n = n * 10 + Int(b[k] - 48); k += 1 }
                guard k > i + prefix.count, k < b.count, b[k] == UInt8(ascii: "x"), formulas.indices.contains(n) else { i += 1; continue }
                if i > last { out.append((String(decoding: b[last..<i], as: UTF8.self), nil)) }
                out.append((formulas[n].copySource, formulas[n]))
                last = k + 1
                i = last
            }
            guard !out.isEmpty else { return nil }
            if last < b.count { out.append((String(decoding: b[last...], as: UTF8.self), nil)) }
            return out
        }
    }

    /// `source` with its formulas replaced by placeholders; nil when it holds none.
    static func hiding(_ source: Substring) -> (text: Substring, placeholders: Placeholders)? {
        guard mayContainMath(source.utf8) else { return nil }
        let b = Array(source.utf8)
        var k = 0
        while contains(b, "cwmath\(k)") { k += 1 }
        let scan = Scan(b, scheme: "cwmath\(k)")
        scan.run()
        guard !scan.edits.isEmpty else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(b.count + scan.edits.count * 12)
        var last = 0
        for edit in scan.edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            out += b[last..<edit.range.lowerBound]
            out += edit.text.utf8
            last = edit.range.upperBound
        }
        out += b[last...]
        return (Substring(String(decoding: out, as: UTF8.self)), Placeholders(scheme: scan.scheme, formulas: scan.formulas))
    }

    /// T3's `mayContainMath`: text without `$`, `\(`, `\[` or a math fence skips the scan. One byte pass.
    static func mayContainMath(_ text: Substring.UTF8View) -> Bool {
        var previous: UInt8 = 0, run = 0
        var fenceEnd: Substring.UTF8View.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == dollar || previous == backslash && (c == UInt8(ascii: "(") || c == UInt8(ascii: "[")) { return true }
            run = c == previous ? run + 1 : 1
            if run >= 3, c == backtick || c == UInt8(ascii: "~") { fenceEnd = text.index(after: i) }
            if let end = fenceEnd, c != backtick, c != UInt8(ascii: "~") {
                fenceEnd = nil
                let rest = text[end...].drop { $0 == space || $0 == tab }
                if rest.starts(with: "math".utf8) {
                    let after = rest.dropFirst(4).first
                    if after.map({ !isWord($0) }) ?? true { return true }
                }
            }
            previous = c
            i = text.index(after: i)
        }
        return false
    }

    // MARK: Streaming

    /// A top-level display block the stream has opened and not closed yet.
    enum OpenFlow: Equatable { case dollar(Int), tex }

    /// The display block `line` opens and leaves open: `$$` (not closed or broken on the same line) or `\[` alone.
    static func flowOpener(_ line: Substring) -> OpenFlow? {
        let b = trimmedLine(line)
        var p = 0
        while p < b.count, p < 3, b[p] == space { p += 1 }
        if p + 1 < b.count, b[p] == dollar, b[p + 1] == dollar {
            var q = p; while q < b.count, b[q] == dollar { q += 1 }
            let size = q - p
            while q < b.count, b[q] == space || b[q] == tab { q += 1 }
            var ignored: [UInt8] = []
            return q == b.count || dollarChunk(b, q, b.count, size, &ignored) == .open ? .dollar(size) : nil
        }
        if p + 1 < b.count, b[p] == backslash, b[p + 1] == UInt8(ascii: "[") {
            return b[(p + 2)...].allSatisfy { $0 == space || $0 == tab } ? .tex : nil
        }
        return nil
    }

    /// False when `line` closes the open block or, with text after a `$$`, turns it back into a paragraph.
    static func flowContinues(_ line: Substring, _ flow: OpenFlow) -> Bool {
        let b = trimmedLine(line)
        var ignored: [UInt8] = []
        switch flow {
        case .dollar(let size): return dollarChunk(b, 0, b.count, size, &ignored) == .open
        case .tex: return !texChunk(b, 0, b.count, &ignored)
        }
    }

    private static func trimmedLine(_ line: Substring) -> [UInt8] {
        var b = Array(line.utf8)
        if b.last == cr { b.removeLast() }
        return b
    }

    // MARK: Display block content

    enum ChunkEnd { case open, closed, killed }

    /// One line of a `$$` block (patched math-flow.js `contentChunk`): an unescaped run of at least `size` dollars
    /// closes the block when only whitespace follows it, and any other text after it makes the block a paragraph.
    static func dollarChunk(_ b: [UInt8], _ s: Int, _ e: Int, _ size: Int, _ value: inout [UInt8]) -> ChunkEnd {
        var k = s, slashes = 0
        while k < e {
            let c = b[k]
            let escaped = slashes % 2 == 1
            slashes = c == backslash ? slashes + 1 : 0
            if c == dollar, !escaped {
                var r = k
                while r < e, b[r] == dollar { r += 1 }
                if r - k >= size {
                    while r < e, b[r] == space || b[r] == tab { r += 1 }
                    guard r == e else { return .killed }
                    value += b[s..<k]
                    return .closed
                }
            }
            k += 1
        }
        value += b[s..<e]
        return .open
    }

    /// One line of a `\[` block (math-tex-flow.js): `\]` followed by only whitespace closes it. True when closed.
    static func texChunk(_ b: [UInt8], _ s: Int, _ e: Int, _ value: inout [UInt8]) -> Bool {
        var k = s
        while k + 1 < e {
            if b[k] == backslash, b[k + 1] == UInt8(ascii: "]") {
                var r = k + 2
                while r < e, b[r] == space || b[r] == tab { r += 1 }
                if r == e { value += b[s..<k]; return true }
            }
            k += 1
        }
        value += b[s..<e]
        return false
    }

    private static func contains(_ b: [UInt8], _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard b.count >= n.count else { return false }
        for i in 0...(b.count - n.count) where b[i] | 0x20 == n[0] {
            if (0..<n.count).allSatisfy({ b[i + $0] | 0x20 == n[$0] | 0x20 }) { return true }
        }
        return false
    }
}

private let dollar = UInt8(ascii: "$"), backslash = UInt8(ascii: "\\"), backtick = UInt8(ascii: "`")
private let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), lf = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
private let comma = UInt8(ascii: ","), gt = UInt8(ascii: ">"), lt = UInt8(ascii: "<"), pipe = UInt8(ascii: "|")

private func isEOL(_ c: UInt8?) -> Bool { c == lf || c == cr }
private func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
private func isLetter(_ c: UInt8) -> Bool { (c | 0x20) >= 97 && (c | 0x20) <= 122 }
private func isWord(_ c: UInt8) -> Bool { isLetter(c) || isDigit(c) || c == 95 }
private func isPunct(_ c: UInt8) -> Bool { (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126) }
private func isWhitespace(_ c: UInt8) -> Bool { c == space || c == tab || c == lf || c == cr }

// MARK: - Blocks

/// A CommonMark block pass that is just deep enough for math: containers (quotes, list items), fenced and indented
/// code, display blocks, headings, tables and paragraphs. Each paragraph, heading or table row is one inline unit.
private final class Scan {
    struct Line { var start: Int, end: Int, next: Int }
    /// Part of a unit's text: `start..<end` on one source line, then that line's ending up to `next`.
    struct Segment { var start: Int, end: Int, next: Int }
    enum Container { case quote, item(column: Int) }
    enum Leaf { case none, paragraph, table, indentedCode, fence(char: UInt8, length: Int, indent: Int, math: Range<Int>?) }

    let b: [UInt8]
    let scheme: String
    let lines: [Line]
    var edits: [(range: Range<Int>, text: String)] = []
    var formulas: [MarkdownMath] = []
    var stack: [Container] = []
    var leaf = Leaf.none
    var paragraph: [Segment] = []

    init(_ b: [UInt8], scheme: String) {
        self.b = b
        self.scheme = scheme
        var lines: [Line] = []
        var s = 0, i = 0
        while i < b.count {
            if b[i] == lf || b[i] == cr {
                let next = b[i] == cr && i + 1 < b.count && b[i + 1] == lf ? i + 2 : i + 1
                lines.append(Line(start: s, end: i, next: next))
                i = next
                s = i
            } else {
                i += 1
            }
        }
        if s < b.count { lines.append(Line(start: s, end: b.count, next: b.count)) }
        self.lines = lines
    }

    func run() {
        var i = 0
        while i < lines.count {
            let l = lines[i]
            let matched = match(l)
            var p = matched.pos, col = matched.col
            if matched.count < stack.count {
                // A lazy line continues the paragraph of a container it doesn't repeat the marker of.
                if case .paragraph = leaf, !isBlank(p, l.end), !startsBlock(p, col, l.end) {
                    paragraph.append(Segment(start: skip(p, col, l.end).0, end: l.end, next: l.next))
                    i += 1
                    continue
                }
                closeLeaf()
                stack.removeLast(stack.count - matched.count)
            }
            switch leaf {
            case .fence(let char, let length, _, let info):
                let (q, qc) = skip(p, col, l.end)
                var r = q
                while r < l.end, b[r] == char { r += 1 }
                if qc - col <= 3, r - q >= length, skip(r, 0, l.end).0 == l.end {
                    if let info { edits.append((info, scheme + "-f")) }
                    leaf = .none
                }
                i += 1
                continue
            case .indentedCode:
                let (q, qc) = skip(p, col, l.end)
                if q == l.end || qc - col >= 4 { i += 1; continue }
                leaf = .none
            default: break
            }
            // New containers.
            while true {
                let (q, qc) = skip(p, col, l.end)
                guard qc - col <= 3, q < l.end else { break }
                if b[q] == gt {
                    closeLeaf()
                    stack.append(.quote)
                    (p, col) = afterQuoteMarker(q, qc, l.end)
                    continue
                }
                if !isThematicBreak(q, l.end), let item = listMarker(q, qc, l.end) {
                    if case .paragraph = leaf, !item.interrupts { break }
                    closeLeaf()
                    stack.append(.item(column: item.column))
                    (p, col) = (item.pos, item.column)
                    continue
                }
                break
            }
            let (q, qc) = skip(p, col, l.end)
            let line = Segment(start: q, end: l.end, next: l.next)
            if q == l.end { closeLeaf(); i += 1; continue }
            if qc - col >= 4 {
                switch leaf {
                case .paragraph: paragraph.append(line)
                case .table: scanUnit([line], singleLine: true)
                default: leaf = .indentedCode
                }
                i += 1
                continue
            }
            if let fence = fenceOpener(q, l.end) {
                closeLeaf()
                leaf = .fence(char: b[q], length: fence.length, indent: qc - col, math: fence.math)
                i += 1
                continue
            }
            let dollarOpener = q + 1 < l.end && b[q] == dollar && b[q + 1] == dollar
            if dollarOpener || isTexOpener(q, l.end) {
                // The opener interrupts a paragraph even when the block never closes (micromark checks it with
                // `interrupt` set, which returns before the closing fence is known).
                closeLeaf()
                if let flow = dollarOpener ? dollarFlow(i, q, qc - col) : texFlow(i, q, qc - col) {
                    formulas.append(MarkdownMath(tex: flow.tex, display: true))
                    let prefix = continuationPrefix()
                    edits.append((q..<lines[flow.last].end, "```\(scheme)-\(formulas.count - 1)\n\(prefix)m\n\(prefix)```"))
                    i = flow.last + 1
                    continue
                }
                paragraph = [line]
                leaf = .paragraph
                i += 1
                continue
            }
            if let content = atxHeading(q, l.end) {
                closeLeaf()
                scanUnit([Segment(start: content, end: l.end, next: l.next)], singleLine: true)
                i += 1
                continue
            }
            if isThematicBreak(q, l.end) { closeLeaf(); i += 1; continue }
            if case .table = leaf { scanUnit([line], singleLine: true); i += 1; continue }
            if case .paragraph = leaf, let header = paragraph.last, isDelimiterRow(q, l.end, header: header) {
                // The table's header row is the paragraph's last line; GFM cells hold single-line math only.
                paragraph.removeLast()
                closeLeaf()
                scanUnit([header], singleLine: true)
                leaf = .table
                i += 1
                continue
            }
            paragraph.append(line)
            leaf = .paragraph
            i += 1
        }
        closeLeaf()
    }

    func closeLeaf() {
        if case .paragraph = leaf { scanUnit(paragraph, singleLine: false) }
        paragraph = []
        leaf = .none
    }

    // MARK: Containers

    /// How many open containers the line continues, and where its content starts.
    func match(_ l: Line) -> (count: Int, pos: Int, col: Int) {
        var p = l.start, col = 0, matched = 0
        for container in stack {
            let (q, qc) = skip(p, col, l.end)
            switch container {
            case .quote:
                guard qc - col <= 3, q < l.end, b[q] == gt else { return (matched, p, col) }
                (p, col) = afterQuoteMarker(q, qc, l.end)
            case .item(let column):
                if q == l.end {
                    (p, col) = (q, qc)
                } else {
                    guard qc >= column else { return (matched, p, col) }
                    (p, col) = skip(p, col, l.end, to: column)
                }
            }
            matched += 1
        }
        return (matched, p, col)
    }

    /// The prefix that repeats every open container on a new line.
    func continuationPrefix() -> String {
        var out = "", col = 0
        for container in stack {
            switch container {
            case .quote: out += "> "; col += 2
            case .item(let column): out += String(repeating: " ", count: max(0, column - col)); col = max(col, column)
            }
        }
        return out
    }

    /// Skips spaces and tabs from `p` at column `col`, stopping once the column reaches `limit`.
    // ponytail: a tab counts whole even where CommonMark splits it into virtual spaces; fine for chat text.
    func skip(_ p: Int, _ col: Int, _ end: Int, to limit: Int = .max) -> (Int, Int) {
        var p = p, col = col
        while p < end, col < limit {
            if b[p] == space { col += 1 } else if b[p] == tab { col += 4 - col % 4 } else { break }
            p += 1
        }
        return (p, col)
    }

    func afterQuoteMarker(_ q: Int, _ qc: Int, _ end: Int) -> (Int, Int) {
        var p = q + 1, col = qc + 1
        if p < end, b[p] == space || b[p] == tab { col = b[p] == tab ? col + 4 - col % 4 : col + 1; p += 1 }
        return (p, col)
    }

    func isBlank(_ p: Int, _ end: Int) -> Bool { b[p..<end].allSatisfy { $0 == space || $0 == tab } }

    /// Whether a line that drops a container's marker opens a block instead of continuing the paragraph lazily.
    /// Any list marker counts: the paragraph's own container is gone, so `2.` starts an item here (cmark).
    func startsBlock(_ p: Int, _ col: Int, _ end: Int) -> Bool {
        let (q, qc) = skip(p, col, end)
        guard qc - col <= 3, q < end else { return false }
        if b[q] == gt || isThematicBreak(q, end) || fenceOpener(q, end) != nil || atxHeading(q, end) != nil || isTexOpener(q, end) { return true }
        if q + 1 < end, b[q] == dollar, b[q + 1] == dollar { return true }
        return listMarker(q, qc, end) != nil
    }

    /// A list marker at `q`: where the item's content starts, its column, and whether it may interrupt a paragraph
    /// (a bullet or `1.` with text after it).
    func listMarker(_ q: Int, _ qc: Int, _ end: Int) -> (pos: Int, column: Int, interrupts: Bool)? {
        var k = q, number = -1
        if b[k] == UInt8(ascii: "-") || b[k] == UInt8(ascii: "+") || b[k] == UInt8(ascii: "*") {
            k += 1
        } else {
            var digits = 0
            number = 0
            while k < end, isDigit(b[k]), digits < 10 { number = number * 10 + Int(b[k] - 48); digits += 1; k += 1 }
            guard (1...9).contains(digits), k < end, b[k] == UInt8(ascii: ".") || b[k] == UInt8(ascii: ")") else { return nil }
            k += 1
        }
        let markerColumn = qc + (k - q)
        if k == end { return (end, markerColumn + 1, false) }
        guard b[k] == space || b[k] == tab else { return nil }
        let (r, rc) = skip(k, markerColumn, end)
        let interrupts = number < 0 || number == 1
        if r == end { return (end, markerColumn + 1, false) }
        if rc - markerColumn >= 5 { return (k + 1, markerColumn + 1, interrupts) }
        return (r, rc, interrupts)
    }

    // MARK: Leaf openers

    func isThematicBreak(_ q: Int, _ end: Int) -> Bool {
        let c = b[q]
        guard c == UInt8(ascii: "-") || c == UInt8(ascii: "*") || c == UInt8(ascii: "_") else { return false }
        var count = 0
        for x in b[q..<end] {
            if x == c { count += 1 } else if x != space && x != tab { return false }
        }
        return count >= 3
    }

    /// A ``` or ~~~ fence: its length and the range of a `math` info word.
    func fenceOpener(_ q: Int, _ end: Int) -> (length: Int, math: Range<Int>?)? {
        let c = b[q]
        guard c == backtick || c == UInt8(ascii: "~") else { return nil }
        var k = q
        while k < end, b[k] == c { k += 1 }
        guard k - q >= 3 else { return nil }
        if c == backtick, b[k..<end].contains(backtick) { return nil }
        let (w, _) = skip(k, 0, end)
        var z = w
        while z < end, !isWhitespace(b[z]) { z += 1 }
        return (k - q, Array(b[w..<z]) == Array("math".utf8) ? w..<z : nil)
    }

    func isTexOpener(_ q: Int, _ end: Int) -> Bool {
        q + 1 < end && b[q] == backslash && b[q + 1] == UInt8(ascii: "[") && isBlank(q + 2, end)
    }

    /// Where an ATX heading's text starts.
    func atxHeading(_ q: Int, _ end: Int) -> Int? {
        var k = q
        while k < end, b[k] == UInt8(ascii: "#") { k += 1 }
        guard (1...6).contains(k - q), k == end || b[k] == space || b[k] == tab else { return nil }
        return skip(k, 0, end).0
    }

    /// A GFM delimiter row (`| --- | :-: |`) under a header line, one of them holding a pipe.
    func isDelimiterRow(_ q: Int, _ end: Int, header: Segment) -> Bool {
        let row = b[q..<end]
        guard row.contains(UInt8(ascii: "-")), row.allSatisfy({ $0 == pipe || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "-") || $0 == space || $0 == tab })
        else { return false }
        return row.contains(pipe) || b[header.start..<header.end].contains(pipe)
    }

    // MARK: Display blocks

    /// A `$$` block from line `i` (patched math-flow.js): content may follow the opener, an unescaped closing run
    /// may end any line, and the block counts only once closed.
    func dollarFlow(_ i: Int, _ q: Int, _ indent: Int) -> (last: Int, tex: String)? {
        let l = lines[i]
        var p = q
        while p < l.end, b[p] == dollar { p += 1 }
        let size = p - q
        p = skip(p, 0, l.end).0
        var value: [UInt8] = []
        if p < l.end {
            switch MarkdownMathScanner.dollarChunk(b, p, l.end, size, &value) {
            case .closed: return (i, Self.flowValue(value))
            case .killed: return nil
            case .open: break
            }
        }
        var j = i + 1
        while j < lines.count {
            let line = lines[j]
            let (matched, lp, lc) = match(line)
            guard matched == stack.count else { return nil }
            value += b[lines[j - 1].end..<lines[j - 1].next]
            let (c, cc) = skip(lp, lc, line.end)
            var r = c
            while r < line.end, b[r] == dollar { r += 1 }
            if cc - lc <= 3, r - c >= size, skip(r, 0, line.end).0 == line.end { return (j, Self.flowValue(value)) }
            let s = skip(lp, lc, line.end, to: lc + indent).0
            switch MarkdownMathScanner.dollarChunk(b, s, line.end, size, &value) {
            case .closed: return (j, Self.flowValue(value))
            case .killed: return nil
            case .open: break
            }
            j += 1
        }
        return nil
    }

    /// A `\[` block alone on line `i` (patched math-tex-flow.js), up to a `\]` that ends its line.
    func texFlow(_ i: Int, _ q: Int, _ indent: Int) -> (last: Int, tex: String)? {
        var value: [UInt8] = []
        var j = i + 1
        while j < lines.count {
            let line = lines[j]
            let (matched, lp, lc) = match(line)
            guard matched == stack.count else { return nil }
            value += b[lines[j - 1].end..<lines[j - 1].next]
            let (c, cc) = skip(lp, lc, line.end)
            if cc - lc <= 3, c + 1 < line.end, b[c] == backslash, b[c + 1] == UInt8(ascii: "]"), skip(c + 2, 0, line.end).0 == line.end {
                return (j, Self.flowValue(value))
            }
            let s = skip(lp, lc, line.end, to: lc + indent).0
            if MarkdownMathScanner.texChunk(b, s, line.end, &value) { return (j, Self.flowValue(value)) }
            j += 1
        }
        return nil
    }

    /// mdast-util-math drops one line ending at each end of a block's value.
    static func flowValue(_ value: [UInt8]) -> String {
        var a = 0, z = value.count
        if a < z, value[a] == cr { a += a + 1 < z && value[a + 1] == lf ? 2 : 1 } else if a < z, value[a] == lf { a += 1 }
        if z > a, value[z - 1] == lf { z -= z - 2 >= a && value[z - 2] == cr ? 2 : 1 } else if z > a, value[z - 1] == cr { z -= 1 }
        return String(decoding: value[a..<z], as: UTF8.self)
    }

    // MARK: Inline

    func scanUnit(_ segments: [Segment], singleLine: Bool) {
        guard segments.contains(where: { b[$0.start..<$0.end].contains { $0 == dollar || $0 == backslash } }) else { return }
        var c: [UInt8] = [], at: [Int] = []
        for (n, s) in segments.enumerated() {
            let end = n < segments.count - 1 ? s.next : s.end
            c += b[s.start..<end]
            at += s.start..<end
        }
        for (range, math) in InlineScan(c: c, singleLine: singleLine).formulas() {
            formulas.append(math)
            edits.append((at[range.lowerBound]..<(at[range.upperBound - 1] + 1), "<\(scheme):\(formulas.count - 1)x>"))
        }
    }
}

// MARK: - Inline

/// micromark's text tokenizer for one paragraph, heading or table row, reduced to what decides where math may
/// start: escapes, code spans, autolinks, inline HTML and link destinations hide their text from it.
private struct InlineScan {
    let c: [UInt8]
    /// A GFM table row: a formula can't run past the row's end (the patched table tokenizer's `mathSingleLine`).
    let singleLine: Bool
    var n: Int { c.count }

    func formulas() -> [(Range<Int>, MarkdownMath)] {
        var out: [(Range<Int>, MarkdownMath)] = []
        var i = 0, escapedDollar = -1, brackets = 0
        while i < n {
            let ch = c[i]
            switch ch {
            case backslash:
                // math-tex-text.js runs before character escapes, and not after a backslash (`previous`).
                if i + 1 < n, c[i + 1] == UInt8(ascii: "(") || c[i + 1] == UInt8(ascii: "["), i == 0 || c[i - 1] != backslash,
                   let end = texText(i) {
                    out.append((i..<end, MarkdownMath(tex: tex(i + 2, end - 2), display: c[i + 1] == UInt8(ascii: "["))))
                    i = end
                    continue
                }
                if i + 1 < n, isPunct(c[i + 1]) {
                    if c[i + 1] == dollar { escapedDollar = i + 1 }
                    i += 2
                    continue
                }
                i += 1
            case dollar:
                // A dollar can't open right after another one unless that one was escaped.
                if i == 0 || c[i - 1] != dollar || escapedDollar == i - 1, let found = dollarText(i) {
                    out.append((i..<found.end, MarkdownMath(tex: tex(i + found.size, found.end - found.size), display: found.size >= 2)))
                    i = found.end
                    continue
                }
                i += 1
            case backtick:
                var r = i
                while r < n, c[r] == backtick { r += 1 }
                let size = r - i
                var k = r, close: Int?
                while k < n {
                    guard c[k] == backtick else { k += 1; continue }
                    var e = k
                    while e < n, c[e] == backtick { e += 1 }
                    if e - k == size { close = e; break }
                    k = e
                }
                i = close ?? r
            case lt:
                i = angle(i) ?? i + 1
            case UInt8(ascii: "["):
                brackets += 1
                i += 1
            case UInt8(ascii: "]"):
                if brackets > 0 {
                    brackets -= 1
                    if i + 1 < n, c[i + 1] == UInt8(ascii: "("), let end = resource(i + 1) { i = end; continue }
                }
                i += 1
            case UInt8(ascii: "w"), UInt8(ascii: "W"), UInt8(ascii: "h"), UInt8(ascii: "H"):
                i = literalAutolink(i) ?? i + 1
            default:
                i += 1
            }
        }
        return out
    }

    /// TeX between the delimiters; one space or line ending comes off each end when both ends have one
    /// (`resolveMathText`).
    func tex(_ from: Int, _ to: Int) -> String {
        var a = from, z = to
        func pad(_ x: UInt8) -> Bool { x == space || isEOL(x) }
        if z > a, pad(c[a]), pad(c[z - 1]), c[a..<z].contains(where: { !pad($0) }) {
            a += c[a] == cr && c[a + 1] == lf ? 2 : 1
            z -= c[z - 1] == lf && c[z - 2] == cr ? 2 : 1
        }
        return String(decoding: c[a..<z], as: UTF8.self)
    }

    /// `$…$` or `$$…$$` at `start` (patched math-text.js): its end and the opening run's size.
    func dollarText(_ start: Int) -> (end: Int, size: Int)? {
        var p = start
        while p < n, c[p] == dollar { p += 1 }
        let sizeOpen = p - start
        guard p < n, !isEOL(c[p]) else { return nil }
        let openWhitespace = c[p] == space || c[p] == tab || c[p] == comma
        if sizeOpen == 1, openWhitespace { return nil }
        var slashes = 0
        var previousData: UInt8?, beforeData: UInt8?
        var inData = false
        while true {
            if !inData {
                guard p < n else { return nil }
                let ch = c[p]
                if ch == backtick || (sizeOpen == 1 || singleLine) && isEOL(ch) { return nil }
                if ch == dollar {
                    let before = c[p - 1]
                    var q = p
                    while q < n, c[q] == dollar { q += 1 }
                    if q - p == sizeOpen {
                        if isEOL(before) { return nil }
                        if q < n, isDigit(c[q]) { return nil }
                        let closeWhitespace = before == space || before == tab || before == comma
                        return openWhitespace == closeWhitespace ? (q, sizeOpen) : nil
                    }
                    p = q
                    inData = true
                    continue
                }
                if ch == space || isEOL(ch) { p += 1; continue }
                inData = true
            } else {
                let ch: UInt8? = p < n ? c[p] : nil
                if ch == backtick { return nil }
                if ch == dollar, slashes % 2 == 1 { slashes = 0; p += 1; continue }
                // `://` inside: a URL, not a formula.
                if ch == UInt8(ascii: "/"), previousData == UInt8(ascii: "/"), beforeData == UInt8(ascii: ":") { return nil }
                beforeData = previousData
                previousData = ch
                slashes = ch == backslash ? slashes + 1 : 0
                guard let ch, ch != space, ch != dollar, !isEOL(ch) else { inData = false; continue }
                p += 1
            }
        }
    }

    /// `\(…\)` or `\[…\]` at `start` (patched math-tex-text.js): its end. A `\[…\]` of only digits, commas and
    /// spaces is a citation, not math.
    func texText(_ start: Int) -> Int? {
        let close = c[start + 1] == UInt8(ascii: "(") ? UInt8(ascii: ")") : UInt8(ascii: "]")
        var p = start + 2, substantive = false, inData = false
        while true {
            if !inData {
                guard p < n else { return nil }
                let ch = c[p]
                if ch == backtick || singleLine && isEOL(ch) { return nil }
                if ch == backslash {
                    let next: UInt8? = p + 1 < n ? c[p + 1] : nil
                    if next == close { return close == UInt8(ascii: "]") && !substantive ? nil : p + 2 }
                    p += next == backslash ? 2 : 1
                    inData = true
                    continue
                }
                if ch == space || isEOL(ch) { p += 1; continue }
                inData = true
            } else {
                let ch: UInt8? = p < n ? c[p] : nil
                if ch == backtick { return nil }
                if let ch, ch != backslash, ch != space, ch != comma, !isEOL(ch), !isDigit(ch) { substantive = true }
                guard let ch, ch != space, ch != backslash, !isEOL(ch) else { inData = false; continue }
                p += 1
            }
        }
    }

    /// An inline link's `(destination "title")` from the `(` at `open`: the index after its `)`.
    func resource(_ open: Int) -> Int? {
        var k = open + 1
        func spaces() { while k < n, isWhitespace(c[k]) { k += 1 } }
        spaces()
        guard k < n else { return nil }
        if c[k] == lt {
            k += 1
            while k < n, c[k] != gt {
                if isEOL(c[k]) || c[k] == lt { return nil }
                k += c[k] == backslash ? 2 : 1
            }
            guard k < n else { return nil }
            k += 1
        } else {
            var depth = 0
            while k < n {
                let ch = c[k]
                if ch == backslash, k + 1 < n, isPunct(c[k + 1]) { k += 2; continue }
                if ch <= space { break }
                if ch == UInt8(ascii: "(") { depth += 1 }
                if ch == UInt8(ascii: ")") { if depth == 0 { break }; depth -= 1 }
                k += 1
            }
        }
        spaces()
        if k < n, c[k] == UInt8(ascii: "\"") || c[k] == UInt8(ascii: "'") || c[k] == UInt8(ascii: "(") {
            let end = c[k] == UInt8(ascii: "(") ? UInt8(ascii: ")") : c[k]
            k += 1
            while k < n, c[k] != end { k += c[k] == backslash ? 2 : 1 }
            guard k < n else { return nil }
            k += 1
            spaces()
        }
        return k < n && c[k] == UInt8(ascii: ")") ? k + 1 : nil
    }

    /// An autolink or an inline HTML tag, comment, declaration or processing instruction at `start`: its end.
    func angle(_ start: Int) -> Int? {
        var k = start + 1
        guard k < n else { return nil }
        func find(_ s: String) -> Int? {
            let t = Array(s.utf8)
            var j = k
            while j + t.count <= n { if Array(c[j..<(j + t.count)]) == t { return j + t.count }; j += 1 }
            return nil
        }
        if isLetter(c[k]) {
            var s = k
            while s < n, isLetter(c[s]) || isDigit(c[s]) || c[s] == UInt8(ascii: "+") || c[s] == UInt8(ascii: ".") || c[s] == UInt8(ascii: "-") { s += 1 }
            if (2...32).contains(s - k), s < n, c[s] == UInt8(ascii: ":") {
                var e = s + 1
                while e < n, c[e] > space, c[e] != lt, c[e] != gt { e += 1 }
                if e < n, c[e] == gt { return e + 1 }
            }
            return openTag(start)
        }
        switch c[k] {
        case UInt8(ascii: "/"):
            k += 1
            guard k < n, isLetter(c[k]) else { return nil }
            while k < n, isLetter(c[k]) || isDigit(c[k]) || c[k] == UInt8(ascii: "-") { k += 1 }
            while k < n, isWhitespace(c[k]) { k += 1 }
            return k < n && c[k] == gt ? k + 1 : nil
        case UInt8(ascii: "!"):
            if c[k...].starts(with: "!--".utf8) { k += 3; return find("-->") }
            if c[k...].starts(with: "![CDATA[".utf8) { return find("]]>") }
            return k + 1 < n && isLetter(c[k + 1]) ? find(">") : nil
        case UInt8(ascii: "?"):
            return find("?>")
        default:
            return nil
        }
    }

    func openTag(_ start: Int) -> Int? {
        var k = start + 1
        while k < n, isLetter(c[k]) || isDigit(c[k]) || c[k] == UInt8(ascii: "-") { k += 1 }
        while k < n {
            let gap = k
            while k < n, isWhitespace(c[k]) { k += 1 }
            guard k < n else { return nil }
            if c[k] == gt { return k + 1 }
            if c[k] == UInt8(ascii: "/") { return k + 1 < n && c[k + 1] == gt ? k + 2 : nil }
            guard k > gap, isLetter(c[k]) || c[k] == UInt8(ascii: "_") || c[k] == UInt8(ascii: ":") else { return nil }
            while k < n, isWord(c[k]) || c[k] == UInt8(ascii: ".") || c[k] == UInt8(ascii: ":") || c[k] == UInt8(ascii: "-") { k += 1 }
            var v = k
            while v < n, isWhitespace(c[v]) { v += 1 }
            guard v < n, c[v] == UInt8(ascii: "=") else { continue }
            v += 1
            while v < n, isWhitespace(c[v]) { v += 1 }
            guard v < n else { return nil }
            if c[v] == UInt8(ascii: "\"") || c[v] == UInt8(ascii: "'") {
                let quote = c[v]
                v += 1
                while v < n, c[v] != quote { v += 1 }
                guard v < n else { return nil }
                k = v + 1
            } else {
                let start = v
                while v < n, !isWhitespace(c[v]), !"\"'=<>`".utf8.contains(c[v]) { v += 1 }
                guard v > start else { return nil }
                k = v
            }
        }
        return nil
    }

    /// A GFM literal autolink (`www.x.com/?$a`, `https://x/$y`) at `start`: its end, without trailing punctuation.
    func literalAutolink(_ start: Int) -> Int? {
        func has(_ s: String) -> Bool {
            let t = Array(s.utf8)
            return start + t.count <= n && (0..<t.count).allSatisfy { c[start + $0] | 0x20 == t[$0] }
        }
        let previous: UInt8? = start > 0 ? c[start - 1] : nil
        var k: Int
        if has("www.") {
            guard previous.map({ isWhitespace($0) || "(*_[]~".utf8.contains($0) }) ?? true else { return nil }
            k = start + 4
        } else if has("http://") || has("https://") {
            guard previous.map({ !isLetter($0) }) ?? true else { return nil }
            k = start + (has("https://") ? 8 : 7)
        } else {
            return nil
        }
        guard k < n, isWord(c[k]) || c[k] == UInt8(ascii: "-") else { return nil }
        while k < n, !isWhitespace(c[k]), c[k] != lt { k += 1 }
        while k > start, "?!.,:*_~".utf8.contains(c[k - 1]) { k -= 1 }
        return k
    }
}
