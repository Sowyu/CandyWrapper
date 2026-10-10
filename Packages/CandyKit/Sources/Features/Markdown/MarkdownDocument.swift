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
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            self.blocks = markdown.isEmpty ? [] : [.paragraph([InlineRun(text: markdown)])]
            return
        }
        var builder = TreeBuilder()
        for run in parsed.runs {
            builder.append(text: String(parsed[run.range].characters), run: run, preservesLineBreaks: preservesLineBreaks)
        }
        self.blocks = builder.root.children.compactMap(\.node).flatMap(Self.blocks(from:))
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
            return [.list(MarkdownList(ordered: ordered, start: start, items: items))]
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
        if let match = info.firstMatch(of: /(?:^|\s)(?:title|file(?:name)?)=(?:"([^"]+)"|'([^']+)'|(\S+))/.ignoresCase()) {
            title = (match.1 ?? match.2 ?? match.3).map(String.init)
        }
        // T3 renders `gitignore` with the ini grammar; plain fences are `text`.
        let resolved = language.isEmpty ? "text" : language
        return (resolved, title)
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
        root.insert(inline, along: path[...])
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

    var runs: [InlineRun] {
        children.flatMap { child -> [InlineRun] in
            switch child {
            case .run(let r): [r]
            case .node(let n): n.runs
            }
        }
    }

    mutating func insert(_ run: InlineRun, along path: ArraySlice<(PresentationIntent.Kind, Int)>) {
        guard let (kind, identity) = path.first else {
            // Merge with the previous run when the style matches, so a paragraph is a few runs, not one per token.
            if case .run(var last)? = children.last, last.sameStyle(as: run), !run.isBreak, !last.isBreak {
                last.text += run.text
                children[children.count - 1] = .run(last)
            } else {
                children.append(.run(run))
            }
            return
        }
        if case .node(var last)? = children.last, last.identity == identity {
            last.insert(run, along: path.dropFirst())
            children[children.count - 1] = .node(last)
        } else {
            var node = Node(kind: Self.kind(kind), identity: identity)
            node.insert(run, along: path.dropFirst())
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
