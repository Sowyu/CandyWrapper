import Foundation

/// `splitMarkdown` (packages/shared/src/markdownChunks.ts at 5258, fb4558d77d #40631): cuts Markdown into pieces of
/// about `targetChars`, only at column-0 headings or paragraphs that start a new top-level block. Leading frontmatter
/// stays in the first piece. One-line link definitions are collected so every piece resolves them; footnotes resolve
/// only inside their own piece. Lengths count UTF-16 units, as JavaScript's do.
enum MarkdownChunks {
    struct Chunk: Equatable, Sendable {
        var text: String
        var lines: Int
    }

    /// About one screen of rendered Markdown.
    static let targetChars = 4 * 1024
    /// A piece past this (one huge fence or HTML block) is too slow to parse at once, so it shows as source.
    static let largeChunkMaxChars = 128 * 1024
    /// An end tag that never comes, or back-to-back wrappers, must not make one huge piece.
    static let wrappedMaxChars = 32 * 1024
    static let definitionsMaxChars = 16 * 1024
    static let frontmatterMaxLines = 1000

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    nonisolated(unsafe) private static let fenceOpen = re(#"^ {0,3}(`{3,}(?![^`\n]*`)|~{3,})"#)
    nonisolated(unsafe) private static let atxHeading = re(#"^#{1,6}(?:[ \t]|\r?$)"#)
    nonisolated(unsafe) private static let thematicBreak = re(#"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})\r?$"#)
    nonisolated(unsafe) private static let blockStart = re(#"^[\p{L}\p{N}`\[!|>]"#)
    nonisolated(unsafe) private static let orderedItem = re(#"^\d{1,9}[.)](?:[ \t]|\r?$)"#)
    nonisolated(unsafe) private static let spanning: [(NSRegularExpression, NSRegularExpression)] = [
        (re(#"^ {0,3}<(?:script|pre|style|textarea)(?=[\s>]|$)"#, .caseInsensitive), re(#"</(?:script|pre|style|textarea)>"#, .caseInsensitive)),
        // "<!-->" and "<!--->" close themselves, so the closer is searched from just after "<!".
        (re(#"^ {0,3}<!(?=--)"#), re(#"-->"#)),
        (re(#"^ {0,3}<\?"#), re(#"\?>"#)),
        (re(#"^ {0,3}<!\[CDATA\["#), re(#"\]\]>"#)),
        (re(#"^ {0,3}<![A-Za-z]"#), re(#">"#)),
        (re(#"^ {0,3}\$\$"#), re(#"\$\$"#)),
    ]
    nonisolated(unsafe) private static let htmlBlockStart = re(#"^ {0,3}</?[A-Za-z][A-Za-z0-9-]*(?=[\s/>]|$)"#)
    nonisolated(unsafe) private static let wrapperTag = re(#"<(/?)(?:details|table)(?=[\s/>]|$)"#, .caseInsensitive)
    nonisolated(unsafe) private static let frontmatterOpen = re(#"^\x{FEFF}?---[ \t]*\r?$"#)
    nonisolated(unsafe) private static let frontmatterClose = re(#"^(?:---|\.\.\.)[ \t]*\r?$"#)
    nonisolated(unsafe) private static let linkDefinition = re(
        #"^ {0,3}\[(?!\^)(?:[^\]\\]|\\.)+\]:[ \t]*(?:<[^<>\n]*>|[^\s<]\S*)(?:[ \t]+(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^()\\]|\\.)*\)))?[ \t]*\r?$"#)

    private static func range(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
    private static func test(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: range(s)) != nil }

    /// How the block a line opens ends.
    private enum Closer {
        case fence(String)
        case pattern(NSRegularExpression)
        case blankLine
        case frontmatter

        func closes(_ next: String, seen: inout Int) -> Bool {
            switch self {
            case .fence(let fence):
                guard let m = MarkdownChunks.fenceOpen.firstMatch(in: next, range: MarkdownChunks.range(next)),
                      let r = Range(m.range(at: 1), in: next) else { return false }
                let closer = next[r]
                let rest = (next.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                return closer.first == fence.first && closer.utf16.count >= fence.utf16.count
                    && rest.length <= closer.utf16.count
            case .pattern(let close): return MarkdownChunks.test(close, next)
            case .blankLine: return next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .frontmatter:
                seen += 1
                return MarkdownChunks.test(MarkdownChunks.frontmatterClose, next) || seen >= MarkdownChunks.frontmatterMaxLines
            }
        }
    }

    private static func blockCloser(_ line: String) -> Closer? {
        if let m = fenceOpen.firstMatch(in: line, range: range(line)), let r = Range(m.range(at: 1), in: line) {
            return .fence(String(line[r]))
        }
        for (open, close) in spanning {
            guard let m = open.firstMatch(in: line, range: range(line)) else { continue }
            let rest = (line as NSString).substring(from: m.range.length)
            return test(close, rest) ? nil : .pattern(close)
        }
        // Other HTML blocks (CommonMark types 6 and 7) run until a blank line.
        return test(htmlBlockStart, line) ? .blankLine : nil
    }

    private static func withoutComments(_ line: String) -> String {
        let s = line as NSString
        var kept = "", at = 0
        var open = s.range(of: "<!--").location
        while open != NSNotFound {
            let close = s.range(of: "-->", range: NSRange(location: open + 4, length: s.length - open - 4)).location
            if close == NSNotFound { break }
            kept += s.substring(with: NSRange(location: at, length: open - at))
            at = close + 3
            open = s.range(of: "<!--", range: NSRange(location: at, length: s.length - at)).location
        }
        return kept + s.substring(from: at)
    }

    private static func openedWrappers(_ line: String) -> Int {
        let text = withoutComments(line)
        return wrapperTag.matches(in: text, range: range(text)).reduce(0) { $0 + ($1.range(at: 1).length > 0 ? -1 : 1) }
    }

    static func split(_ text: String, targetChars: Int = targetChars) -> (chunks: [Chunk], definitions: String) {
        var chunks: [Chunk] = []
        var definitions: [String] = []
        var lines: [String] = []
        var first = true, chars = 0
        var closer: Closer?
        var seen = 0
        var afterBlankLine = false, afterDefinition = false, afterHeading = false, openedFence = false
        var definitionChars = 0, openWrappers = 0, heldCut = 0
        func flush() {
            chunks.append(Chunk(text: lines.joined(separator: "\n"), lines: lines.count))
            lines = []; chars = 0; heldCut = 0
        }
        // Foundation splits by UTF-16 unit, so "\r\n", one Character in Swift, still splits as JavaScript does.
        for line in text.components(separatedBy: "\n") {
            if let open = closer {
                if open.closes(line, seen: &seen) { closer = nil }
            } else if first, test(frontmatterOpen, line) {
                seen = 0
                closer = .frontmatter
            } else {
                if chars >= wrappedMaxChars { openWrappers = 0 }
                let cutPoint = chars >= targetChars
                    && (test(atxHeading, line) || (afterBlankLine && test(blockStart, line) && !test(orderedItem, line)))
                if cutPoint, openWrappers == 0 { flush() } else if cutPoint { heldCut = lines.count }
                closer = blockCloser(line)
                // An indented fence may sit in a list item, which this does not track.
                openedFence = (line.first == "`" || line.first == "~") && test(fenceOpen, line)
                // A definition cannot interrupt a paragraph.
                let definition = (first || afterBlankLine || afterDefinition || afterHeading) && test(linkDefinition, line)
                afterDefinition = definition
                let length = line.utf16.count
                if definition, definitionChars + length < definitionsMaxChars {
                    definitions.append(line.trimmingCharacters(in: .whitespaces))
                    definitionChars += length + 1
                }
            }
            if case .blankLine? = closer { openWrappers = max(0, openWrappers + openedWrappers(line)) }
            first = false
            lines.append(line)
            chars += line.utf16.count + 1
            // A piece too large to render goes back to the last cut a wrapper held.
            if heldCut > 0, chars - 1 > largeChunkMaxChars {
                let rest = Array(lines[heldCut...])
                lines.removeSubrange(heldCut...)
                flush()
                lines = rest
                chars = rest.reduce(0) { $0 + $1.utf16.count + 1 }
                openWrappers = 0
            }
            afterBlankLine = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            afterHeading = closer == nil && (openedFence || test(atxHeading, line) || test(thematicBreak, line))
        }
        flush()
        return (chunks, definitions.joined(separator: "\n"))
    }

    /// `withMarkdownDefinitions`: the shared definitions after a piece, leaving its offsets alone.
    static func withDefinitions(_ text: String, _ definitions: String) -> String {
        definitions.isEmpty ? text : text + "\n\n" + definitions
    }
}
