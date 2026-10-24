import Foundation
import SpaceModel

/// Markdown in and out of Space pages (docs/space.md "Page view"): the line-start shortcuts, paste of Markdown as
/// blocks, and the Markdown copy puts on the pasteboard. Pure, so tests drive it without a view.
public enum SpaceMarkdown {
    /// What a line-start shortcut turns the paragraph into.
    public enum Shortcut: Equatable {
        case type(BlockType)
        /// `[] `: the paragraph becomes a to-do item, a child page.
        case todo
    }

    /// The shortcut a paragraph's text forms once the user types its last character, or nil.
    /// `---` and three backticks fire without a trailing space, the rest on the space.
    public static func shortcut(_ text: String) -> Shortcut? {
        switch text {
        case "# ": .type(.h1)
        case "## ": .type(.h2)
        case "### ": .type(.h3)
        case "- ", "* ", "+ ": .type(.bullet)
        case "1. ", "1) ": .type(.number)
        case "[] ", "[ ] ": .todo
        case "> ", "\" ": .type(.quote)
        case "```": .type(.code)
        case "---": .type(.divider)
        default: nil
        }
    }

    public struct Block: Equatable {
        public var type: BlockType
        public var indent: Int
        public var text: RichText
        /// Non-nil for a to-do line, with whether it was ticked.
        public var todo: Bool?
        public var lang: String?
        public init(type: BlockType = .p, indent: Int = 0, text: RichText = RichText(), todo: Bool? = nil, lang: String? = nil) {
            self.type = type; self.indent = indent; self.text = text; self.todo = todo; self.lang = lang
        }
    }

    // MARK: Parse

    /// Blocks from Markdown text. Blank lines separate blocks and make none.
    public static func parse(_ markdown: String) -> [Block] {
        var out: [Block] = []
        var code: Block?
        var codeLines: [String] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for raw in lines {
            if code != nil {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code!.text = RichText(t: codeLines.joined(separator: "\n"))
                    out.append(code!)
                    code = nil; codeLines = []
                } else { codeLines.append(raw) }
                continue
            }
            var leading = 0
            for c in raw { if c == " " { leading += 1 } else if c == "\t" { leading += 2 } else { break } }
            let indent = min(5, leading / 2)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("```") {
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = Block(type: .code, lang: lang.isEmpty ? nil : lang)
                continue
            }
            if ["---", "***", "___"].contains(line) || (line.count >= 3 && Set(line) == ["-"]) {
                out.append(Block(type: .divider)); continue
            }
            func block(_ type: BlockType, _ rest: Substring, todo: Bool? = nil) -> Block {
                Block(type: type, indent: indent, text: inline(String(rest)), todo: todo)
            }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                let level = m.1.count
                out.append(block(level == 1 ? .h1 : level == 2 ? .h2 : .h3, m.2, todo: nil)); continue
            }
            if let m = line.firstMatch(of: /^[-*+]\s+\[([ xX]?)\]\s*(.*)$/) {
                out.append(block(.p, m.2, todo: !m.1.trimmingCharacters(in: .whitespaces).isEmpty)); continue
            }
            if let m = line.firstMatch(of: /^\[([ xX]?)\]\s+(.*)$/) {
                out.append(block(.p, m.2, todo: !m.1.trimmingCharacters(in: .whitespaces).isEmpty)); continue
            }
            if let m = line.firstMatch(of: /^[-*+]\s+(.*)$/) { out.append(block(.bullet, m.1)); continue }
            if let m = line.firstMatch(of: /^\d+[.)]\s+(.*)$/) { out.append(block(.number, m.1)); continue }
            if let m = line.firstMatch(of: /^>\s?(.*)$/) { out.append(block(.quote, m.1)); continue }
            out.append(block(.p, Substring(line)))
        }
        if var open = code {
            open.text = RichText(t: codeLines.joined(separator: "\n"))
            out.append(open)
        }
        return out
    }

    /// Inline Markdown: `**bold**`, `*italic*` or `_italic_`, `~~strike~~`, `` `code` `` and `[text](url)`.
    /// Anything unclosed stays literal.
    public static func inline(_ source: String) -> RichText {
        let s = Array(source.utf16)
        var out: [UInt16] = []
        var marks: [TextMark] = []
        var open: [String: Int] = [:]
        var i = 0
        func has(_ token: String, at j: Int) -> Bool {
            let t = Array(token.utf16)
            return j + t.count <= s.count && Array(s[j..<j + t.count]) == t
        }
        func closes(_ token: String, from j: Int) -> Bool {
            var k = j
            while k < s.count { if has(token, at: k) { return true }; k += 1 }
            return false
        }
        while i < s.count {
            if s[i] == 0x60 /* ` */, let end = (i + 1..<s.count).first(where: { s[$0] == 0x60 }) {
                let start = out.count
                out += s[(i + 1)..<end]
                if out.count > start { marks.append(TextMark(start: start, end: out.count, kind: .c)) }
                i = end + 1; continue
            }
            if s[i] == 0x5B /* [ */, let close = (i + 1..<s.count).first(where: { s[$0] == 0x5D }),
               close + 1 < s.count, s[close + 1] == 0x28, let paren = (close + 2..<s.count).first(where: { s[$0] == 0x29 }) {
                let label = inline(String(utf16CodeUnits: Array(s[(i + 1)..<close]), count: close - i - 1))
                let url = String(utf16CodeUnits: Array(s[(close + 2)..<paren]), count: paren - close - 2)
                let start = out.count
                out += Array(label.t.utf16)
                marks += label.m.map { TextMark(start: $0.start + start, end: $0.end + start, kind: $0.kind, value: $0.value) }
                if out.count > start { marks.append(TextMark(start: start, end: out.count, kind: .a, value: url)) }
                i = paren + 1; continue
            }
            var matched = false
            for (token, kind) in [("**", MarkKind.b), ("__", .b), ("~~", .s), ("*", .i), ("_", .i)] where has(token, at: i) {
                let n = token.utf16.count
                if let start = open[token] {
                    open[token] = nil
                    if out.count > start { marks.append(TextMark(start: start, end: out.count, kind: kind)) }
                    i += n; matched = true
                } else if closes(token, from: i + n), !(token == "_" && i > 0 && isWordUnit(s[i - 1])) {
                    open[token] = out.count
                    i += n; matched = true
                }
                if matched { break }
            }
            if matched { continue }
            out.append(s[i]); i += 1
        }
        return RichText(t: String(utf16CodeUnits: out, count: out.count), m: marks)
    }

    private static func isWordUnit(_ u: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: Serialize

    /// Markdown for blocks, with numbered lists counted per run.
    public static func serialize(_ blocks: [Block]) -> String {
        var lines: [String] = []
        var number: [Int: Int] = [:]
        for b in blocks {
            let pad = String(repeating: "  ", count: max(0, min(5, b.indent)))
            if b.type != .number { number[b.indent] = nil }
            let text = inlineMarkdown(b.text)
            if let done = b.todo { lines.append(pad + (done ? "- [x] " : "- [ ] ") + text); continue }
            switch b.type {
            case .h1: lines.append("# " + text)
            case .h2: lines.append("## " + text)
            case .h3: lines.append("### " + text)
            case .bullet: lines.append(pad + "- " + text)
            case .number:
                let n = (number[b.indent] ?? 0) + 1
                number[b.indent] = n
                lines.append(pad + "\(n). " + text)
            case .quote: lines.append("> " + text)
            case .code: lines.append("```" + (b.lang ?? "") + "\n" + b.text.t + "\n```")
            case .divider: lines.append("---")
            default: lines.append(pad + text)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Marks as Markdown. Overlaps nest by start, which covers what the editor produces.
    public static func inlineMarkdown(_ text: RichText) -> String {
        let units = Array(text.t.utf16)
        guard !text.m.isEmpty else { return text.t }
        var opens: [Int: [String]] = [:], closes: [Int: [String]] = [:]
        for mark in text.m.sorted(by: { ($0.start, -$0.end) < ($1.start, -$1.end) }) {
            let (a, b): (String, String)
            switch mark.kind {
            case .b: (a, b) = ("**", "**")
            case .i: (a, b) = ("_", "_")
            case .s: (a, b) = ("~~", "~~")
            case .c: (a, b) = ("`", "`")
            case .a: (a, b) = ("[", "](\(mark.value ?? ""))")
            default: continue
            }
            opens[mark.start, default: []].append(a)
            closes[mark.end, default: []].insert(b, at: 0)
        }
        var out: [UInt16] = []
        for i in 0...units.count {
            out += (closes[i] ?? []).joined().utf16
            out += (opens[i] ?? []).joined().utf16
            if i < units.count { out.append(units[i]) }
        }
        return String(decoding: out, as: UTF16.self)
    }
}
