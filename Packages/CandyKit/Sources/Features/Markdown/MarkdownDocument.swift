import Foundation

/// A parsed chat message: the block tree T3's ChatMarkdown renders (react-markdown with remark-gfm and
/// T3's GitHub alert plugin), built from Foundation's Markdown parser with the full syntax.
/// Task list and alert markers reach us as literal text and are recognized here.
/// Pure value; parse once per message text and reuse it for every width.
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) { self.blocks = blocks }

    /// `preservesLineBreaks`: soft breaks become line breaks, as T3 does for user messages (`remark-breaks`).
    public init(parsing markdown: String, preservesLineBreaks: Bool = false) {
        blocks = Self.parseBlocks(Substring(markdown), preservesLineBreaks: preservesLineBreaks)
    }

    private static func parseBlocks(_ markdown: Substring, preservesLineBreaks: Bool) -> [MarkdownBlock] {
        // Source positions cost about 15% of the parse (a 1,000-line reply on the huge thread's cached open),
        // and only loose lists need them.
        let positions = mayHaveLooseList(markdown)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: positions)
        guard let parsed = try? AttributedString(markdown: String(markdown), options: options) else {
            return markdown.isEmpty ? [] : [.paragraph([InlineRun(text: String(markdown))])]
        }
        var builder = TreeBuilder()
        for run in parsed.runs {
            builder.append(text: String(parsed[run.range].characters), run: run, preservesLineBreaks: preservesLineBreaks)
        }
        if positions {
            // Source lines that hold only whitespace, 1-based like the parser's source positions.
            var blank = Set<Int>()
            for (index, line) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) { blank.insert(index + 1) }
            builder.root.markLooseLists(blank: blank)
        }
        return builder.root.children.compactMap(\.node).flatMap(Self.blocks(from:))
    }

    /// False only when no list can be loose: no blank line follows a list marker line and comes before
    /// another marker or an indented line. A blank line followed by anything else ends the list (CommonMark).
    /// True for some text that has no loose list (a fenced `- ` line, `* * *`), which only costs the slower parse.
    static func mayHaveLooseList(_ text: Substring) -> Bool {
        var inList = false, blankInList = false
        var lineStart = text.utf8.startIndex
        let end = text.utf8.endIndex
        while lineStart < end {
            let newline = text.utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? end
            let line = text.utf8[lineStart..<newline]
            // Blockquote markers count as indentation, so a loose list inside a quote is still caught.
            let body = line.drop { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: ">") }
            if body.allSatisfy({ $0 == UInt8(ascii: "\r") }) {
                if inList { blankInList = true }
            } else {
                let marker = isListMarker(body)
                if blankInList {
                    if marker || body.startIndex != line.startIndex { return true }
                    inList = false
                    blankInList = false
                }
                if marker { inList = true }
            }
            lineStart = newline < end ? text.utf8.index(after: newline) : end
        }
        return false
    }

    /// `-`, `+`, `*` or 1 to 9 digits and `.` or `)`, then whitespace or the line's end.
    private static func isListMarker(_ body: Substring.UTF8View.SubSequence) -> Bool {
        var i = body.startIndex
        guard i < body.endIndex else { return false }
        let first = body[i]
        if first == UInt8(ascii: "-") || first == UInt8(ascii: "+") || first == UInt8(ascii: "*") {
            i = body.index(after: i)
        } else {
            var digits = 0
            while i < body.endIndex, body[i] >= UInt8(ascii: "0"), body[i] <= UInt8(ascii: "9") { digits += 1; i = body.index(after: i) }
            guard (1...9).contains(digits), i < body.endIndex, body[i] == UInt8(ascii: ".") || body[i] == UInt8(ascii: ")") else { return false }
            i = body.index(after: i)
        }
        return i == body.endIndex || [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r")].contains(body[i])
    }

    // MARK: Streaming

    /// A parse that the next, longer text of a streaming answer extends instead of starting over.
    /// `stable` is the start of `text` whose blocks (`stableBlocks`) no later text can change.
    public struct Incremental: Sendable {
        public let text: String
        public let document: MarkdownDocument
        let preservesLineBreaks: Bool
        let stable: Substring
        let stableBlocks: [MarkdownBlock]
    }

    /// Parses `markdown` like `init(parsing:)`, reusing `previous` when `markdown` starts with its
    /// stable part: only the text after it is parsed, so a token costs the size of the last few
    /// blocks, not the whole answer. The result always equals a full parse (`MarkdownIncrementalTests`).
    public static func parse(_ markdown: String, preservesLineBreaks: Bool = false, extending previous: Incremental?) -> Incremental {
        guard canSplit(markdown) else {
            let document = MarkdownDocument(parsing: markdown, preservesLineBreaks: preservesLineBreaks)
            return Incremental(text: markdown, document: document, preservesLineBreaks: preservesLineBreaks, stable: "", stableBlocks: [])
        }
        var start = markdown.startIndex
        var stableBlocks: [MarkdownBlock] = []
        if let previous, previous.preservesLineBreaks == preservesLineBreaks, !previous.stable.isEmpty,
           markdown.utf8.starts(with: previous.stable.utf8) {
            start = markdown.utf8.index(markdown.startIndex, offsetBy: previous.stable.utf8.count)
            stableBlocks = previous.stableBlocks
        }
        if let cut = stableCut(markdown[start...]), cut > start {
            stableBlocks += parseBlocks(markdown[start..<cut], preservesLineBreaks: preservesLineBreaks)
            start = cut
        }
        let tail = parseBlocks(markdown[start...], preservesLineBreaks: preservesLineBreaks)
        return Incremental(text: markdown, document: MarkdownDocument(blocks: stableBlocks + tail), preservesLineBreaks: preservesLineBreaks,
                           stable: markdown[..<start], stableBlocks: stableBlocks)
    }

    /// Link reference definitions and footnotes resolve across blocks, and HTML blocks of CommonMark
    /// types 1 to 5 run over blank lines: text with any of them always parses whole.
    static func canSplit(_ text: String) -> Bool {
        // One pass over the bytes: Foundation's case-insensitive search cost more than the parse it saves.
        let bytes = Array(text.utf8)
        func lower(_ i: Int) -> UInt8 { i < bytes.count ? bytes[i] | 0x20 : 0 }
        func word(_ i: Int, _ w: String) -> Bool { w.utf8.enumerated().allSatisfy { lower(i + $0.offset) == $0.element } }
        for i in bytes.indices {
            switch bytes[i] {
            case UInt8(ascii: "]"):
                if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: ":") { return false }
            case UInt8(ascii: "<"):
                guard i + 1 < bytes.count else { break }
                let next = bytes[i + 1]
                if next == UInt8(ascii: "!") || next == UInt8(ascii: "?") { return false }
                if word(i + 1, "pre") || word(i + 1, "script") || word(i + 1, "style") || word(i + 1, "textarea") { return false }
            default: break
            }
        }
        return true
    }

    /// The start of the last line in `text` before which the blocks are final: it follows a blank
    /// line outside any fenced code, and starts at column 0 with a character that opens a new
    /// top-level block and can't continue a list or a quote (no list marker, digit, `>` or indent).
    /// Fences follow CommonMark, as the full parse does: an opener indented 0 to 3 spaces, a closer of the same
    /// character, at least as long, indented 0 to 3 spaces, alone on its line. A line indented 4 or more is content.
    static func stableCut(_ text: Substring) -> String.Index? {
        var cut: String.Index?
        var openFence: (marker: Character, length: Int, indent: Int)?
        var previousBlank = false
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(of: "\n")
            let line = text[lineStart..<(newline ?? text.endIndex)]
            if openFence == nil, previousBlank, lineStart > text.startIndex, let first = line.first, startsTopLevelBlock(first, line) {
                cut = lineStart
            }
            guard let newline else { break }
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if indent <= 3, let mark = body.first, mark == "`" || mark == "~" {
                let length = body.prefix { $0 == mark }.count
                if length >= 3 {
                    if let open = openFence {
                        if mark == open.marker, length >= open.length,
                           body.dropFirst(length).allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                            openFence = nil
                        }
                    } else if mark == "~" || !body.dropFirst(length).contains("`") {
                        openFence = (mark, length, indent)
                    }
                }
            }
            previousBlank = openFence == nil && line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
            lineStart = text.index(after: newline)
        }
        return cut
    }

    private static func startsTopLevelBlock(_ first: Character, _ line: Substring) -> Bool {
        if first.isLetter || "#`~|![".contains(first) { return true }
        // `**Bold**` or `__x__` opens a paragraph; `* ` and `*x` may be a list item or a rule.
        if first == "*" || first == "_" { return line.dropFirst().first == first && line.dropFirst(2).first.map { $0 != first && $0 != " " } == true }
        return false
    }

    // MARK: Tree to blocks

    private static func blocks(from node: Node) -> [MarkdownBlock] {
        switch node.kind {
        case .paragraph:
            let runs = node.runs
            if let image = standaloneImage(runs) { return [image] }
            return runs.isEmpty ? [] : [.paragraph(runs)]
        case .header(let level):
            return [.heading(level: level, node.runs)]
        case .orderedList, .unorderedList:
            let items = node.children.compactMap(\.node).map(listItem(from:))
            let start = node.children.compactMap(\.node).first.flatMap { item -> Int? in
                if case .listItem(let ordinal) = item.kind { return ordinal }
                return nil
            } ?? 1
            let ordered: Bool = { if case .orderedList = node.kind { return true }; return false }()
            return [.list(MarkdownList(ordered: ordered, start: start, items: items, loose: node.loose))]
        case .blockQuote:
            var children = node.children.compactMap(\.node).flatMap(blocks(from:))
            if let kind = alertKind(&children) { return [.alert(kind, children)] }
            return [.blockquote(children)]
        case .codeBlock(let info):
            var code = node.runs.map(\.text).joined()
            if code.hasSuffix("\n") { code.removeLast() }
            let (language, title) = parseFenceInfo(info)
            return [.code(language: language, title: title, code: code)]
        case .thematicBreak:
            return [.rule]
        case .table(let alignments):
            var header: [[InlineRun]] = Array(repeating: [], count: alignments.count)
            var rows: [[[InlineRun]]] = []
            for row in node.children.compactMap(\.node) {
                var cells: [[InlineRun]] = Array(repeating: [], count: alignments.count)
                for cell in row.children.compactMap(\.node) {
                    if case .tableCell(let column) = cell.kind, column < cells.count { cells[column] = cell.runs }
                }
                if case .tableHeaderRow = row.kind { header = cells } else { rows.append(cells) }
            }
            return [.table(MarkdownTable(alignments: alignments, header: header, rows: rows))]
        case .listItem, .tableHeaderRow, .tableRow, .tableCell, .root, .other:
            return node.children.compactMap(\.node).flatMap(blocks(from:))
        }
    }

    private static func listItem(from node: Node) -> MarkdownListItem {
        var blocks = node.children.compactMap(\.node).flatMap(blocks(from:))
        // GFM task item: the first paragraph starts with "[ ] " or "[x] ".
        var task: Bool?
        if case .paragraph(var runs)? = blocks.first, let first = runs.first, !first.code {
            for (marker, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where first.text.hasPrefix(marker) {
                runs[0].text.removeFirst(marker.count)
                if runs[0].text.isEmpty { runs.removeFirst() }
                blocks[0] = .paragraph(runs)
                task = checked
                break
            }
        }
        return MarkdownListItem(task: task, blocks: blocks)
    }

    /// T3's remark plugin: a quote whose first line is exactly `[!KIND]` (case-insensitive), one of GitHub's five.
    private static func alertKind(_ children: inout [MarkdownBlock]) -> MarkdownAlertKind? {
        guard case .paragraph(var runs)? = children.first, let first = runs.first, !first.code else { return nil }
        let trimmed = first.text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]"),
              let kind = MarkdownAlertKind(rawValue: trimmed.dropFirst(2).dropLast().lowercased()) else { return nil }
        // The marker must end its line: alone in the paragraph, or followed by a line break.
        runs.removeFirst()
        if let next = runs.first {
            guard next.text == "\n" || next.text == " " && next.isBreak else { return nil }
            runs.removeFirst()
        }
        if runs.isEmpty { children.removeFirst() } else { children[0] = .paragraph(runs) }
        return kind
    }

    private static func standaloneImage(_ runs: [InlineRun]) -> MarkdownBlock? {
        let content = runs.filter { !$0.text.allSatisfy(\.isWhitespace) || $0.image != nil }
        guard content.count == 1, let image = content[0].image else { return nil }
        return .image(alt: content[0].text, url: image)
    }

    /// `python title="x.py"` gives ("python", "x.py"). T3 also takes `file=` and `filename=`.
    static func parseFenceInfo(_ info: String?) -> (language: String, title: String?) {
        let info = (info ?? "").trimmingCharacters(in: .whitespaces)
        let language = info.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        var title: String?
        // The regex compiles on every call; most fences carry no attribute.
        if info.contains("="), let match = info.firstMatch(of: /(?:^|\s)(?:title|file(?:name)?)=(?:"([^"]+)"|'([^']+)'|(\S+))/.ignoresCase()) {
            title = (match.1 ?? match.2 ?? match.3).map(String.init)
        }
        // T3 renders `gitignore` with the ini grammar; plain fences are `text`.
        let resolved = language.isEmpty ? "text" : language
        return (resolved, title)
    }
}

extension MarkdownBlock {
    /// What a screen reader reads: the text without markup, one line per block.
    var plainText: String {
        func runs(_ r: [InlineRun]) -> String { r.map { $0.image != nil && $0.text.isEmpty ? "image" : $0.text }.joined() }
        switch self {
        case .paragraph(let r), .heading(_, let r): return runs(r)
        case .list(let list):
            return list.items.enumerated().map { i, item in
                let mark = item.task.map { $0 ? "checked, " : "unchecked, " } ?? (list.ordered ? "\(list.start + i). " : "")
                return mark + item.blocks.map(\.plainText).joined(separator: "\n")
            }.joined(separator: "\n")
        case .blockquote(let blocks), .alert(_, let blocks): return blocks.map(\.plainText).joined(separator: "\n")
        case .code(_, let title, let code): return [title, code].compactMap { $0 }.joined(separator: "\n")
        case .table(let t): return ([t.header] + t.rows).map { $0.map(runs).joined(separator: ", ") }.joined(separator: "\n")
        case .rule: return ""
        case .image(let alt, _): return alt.isEmpty ? "image" : alt
        }
    }
}

public indirect enum MarkdownBlock: Sendable, Equatable {
    case paragraph([InlineRun])
    case heading(level: Int, [InlineRun])
    case list(MarkdownList)
    case blockquote([MarkdownBlock])
    case alert(MarkdownAlertKind, [MarkdownBlock])
    case code(language: String, title: String?, code: String)
    case table(MarkdownTable)
    case rule
    /// A paragraph holding only an image. Inline images stay in the paragraph as alt text.
    case image(alt: String, url: URL)
}

public struct MarkdownList: Sendable, Equatable {
    public var ordered: Bool
    public var start: Int
    public var items: [MarkdownListItem]
    /// CommonMark's loose list: a blank line between two items or between two blocks of one item.
    /// react-markdown then wraps every item's text in a `<p>` with its margins.
    public var loose = false
}

public struct MarkdownListItem: Sendable, Equatable {
    /// nil for a plain item, else whether the task box is checked.
    public var task: Bool?
    public var blocks: [MarkdownBlock]
}

public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable { case none, left, center, right }
    public var alignments: [Alignment]
    public var header: [[InlineRun]]
    public var rows: [[[InlineRun]]]
}

public enum MarkdownAlertKind: String, Sendable, CaseIterable {
    case note, tip, important, warning, caution
}

/// A run of text with one inline style.
public struct InlineRun: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var strikethrough = false
    public var skillLabel: String?
    public var code = false
    public var link: URL?
    public var image: URL?
    /// A soft or hard break; `text` is a space or "\n".
    public var isBreak = false

    public init(text: String, bold: Bool = false, italic: Bool = false, strikethrough: Bool = false, code: Bool = false,
                link: URL? = nil, image: URL? = nil, isBreak: Bool = false) {
        self.text = text; self.bold = bold; self.italic = italic; self.strikethrough = strikethrough
        self.code = code; self.link = link; self.image = image; self.isBreak = isBreak
    }
}

// MARK: - Presentation intents to a tree

/// Rebuilds the block tree from the flat runs: each run lists its enclosing blocks innermost first,
/// with an identity per block, so a run joins the open block with the same identity or opens a new one.
private struct TreeBuilder {
    var root = Node(kind: .root, identity: -1)

    mutating func append(text: String, run: AttributedString.Runs.Run, preservesLineBreaks: Bool) {
        let path = (run.presentationIntent?.components ?? []).reversed().map { ($0.kind, $0.identity) }
        var inline = InlineRun(text: text)
        let lines = run.markdownSourcePosition.map { $0.startLine...max($0.startLine, $0.endLine) }
        if let i = run.inlinePresentationIntent {
            inline.bold = i.contains(.stronglyEmphasized)
            inline.italic = i.contains(.emphasized)
            inline.strikethrough = i.contains(.strikethrough)
            inline.code = i.contains(.code)
            if i.contains(.lineBreak) { inline.text = "\n"; inline.isBreak = true }
            if i.contains(.softBreak) { inline.text = preservesLineBreaks ? "\n" : " "; inline.isBreak = true }
        }
        inline.link = run.link
        inline.image = run.imageURL
        root.insert(inline, lines: lines, along: path[...])
    }
}

private struct Node {
    enum Kind {
        case root, paragraph, header(Int), orderedList, unorderedList, listItem(Int), blockQuote
        case codeBlock(String?), thematicBreak, table([MarkdownTable.Alignment]), tableHeaderRow, tableRow, tableCell(Int), other
    }
    enum Child { case node(Node), run(InlineRun); var node: Node? { if case .node(let n) = self { return n }; return nil } }

    var kind: Kind
    var identity: Int
    var children: [Child] = []
    /// The source lines the node's text spans, nil when it has none.
    var lines: ClosedRange<Int>?
    var loose = false

    /// Sets `loose` on every list with a blank source line between two items or between two blocks of one item.
    mutating func markLooseLists(blank: Set<Int>) {
        func gap(_ a: ClosedRange<Int>?, _ b: ClosedRange<Int>?) -> Bool {
            guard let a, let b, b.lowerBound > a.upperBound + 1 else { return false }
            return (a.upperBound + 1..<b.lowerBound).contains { blank.contains($0) }
        }
        func blankBetween(_ nodes: [Node]) -> Bool { zip(nodes, nodes.dropFirst()).contains { gap($0.lines, $1.lines) } }
        switch kind {
        case .orderedList, .unorderedList:
            let items = children.compactMap(\.node)
            loose = blankBetween(items) || items.contains { blankBetween($0.children.compactMap(\.node)) }
        default: break
        }
        for index in children.indices {
            if case .node(var child) = children[index] {
                child.markLooseLists(blank: blank)
                children[index] = .node(child)
            }
        }
    }

    var runs: [InlineRun] {
        children.flatMap { child -> [InlineRun] in
            switch child {
            case .run(let r): [r]
            case .node(let n): n.runs
            }
        }
    }

    mutating func insert(_ run: InlineRun, lines l: ClosedRange<Int>?, along path: ArraySlice<(PresentationIntent.Kind, Int)>) {
        if let l { lines = lines.map { min($0.lowerBound, l.lowerBound)...max($0.upperBound, l.upperBound) } ?? l }
        // The last child comes out of the array before it changes, so its text and children are
        // uniquely referenced and grow in place. Changing a copy while the array still held the
        // original copied them on every run: quadratic, 67 ms for a 22 KB reply of short lines.
        guard let (kind, identity) = path.first else {
            // Merge with the previous run when the style matches, so a paragraph is a few runs, not one per token.
            if case .run(var last)? = children.last, last.sameStyle(as: run), !run.isBreak, !last.isBreak {
                children.removeLast()
                last.text += run.text
                children.append(.run(last))
            } else {
                children.append(.run(run))
            }
            return
        }
        if case .node(var last)? = children.last, last.identity == identity {
            children.removeLast()
            last.insert(run, lines: l, along: path.dropFirst())
            children.append(.node(last))
        } else {
            var node = Node(kind: Self.kind(kind), identity: identity)
            node.insert(run, lines: l, along: path.dropFirst())
            children.append(.node(node))
        }
    }

    static func kind(_ k: PresentationIntent.Kind) -> Kind {
        switch k {
        case .paragraph: .paragraph
        case .header(let level): .header(level)
        case .orderedList: .orderedList
        case .unorderedList: .unorderedList
        case .listItem(let ordinal): .listItem(ordinal)
        case .blockQuote: .blockQuote
        case .codeBlock(let hint): .codeBlock(hint)
        case .thematicBreak: .thematicBreak
        case .table(let columns): .table(columns.map {
            switch $0.alignment {
            case .left: .left
            case .center: .center
            case .right: .right
            @unknown default: .none
            }
        })
        case .tableHeaderRow: .tableHeaderRow
        case .tableRow: .tableRow
        case .tableCell(let column): .tableCell(column)
        @unknown default: .other
        }
    }
}

private extension InlineRun {
    func sameStyle(as other: InlineRun) -> Bool {
        bold == other.bold && italic == other.italic && strikethrough == other.strikethrough && code == other.code
            && link == other.link && image == other.image
    }
}
