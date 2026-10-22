import AppKit
import DesignSystem

extension NSAttributedString.Key {
    static let composerMarks = NSAttributedString.Key("ComposerRichTextMarks")
    static let composerCodeBlock = NSAttributedString.Key("ComposerCodeBlock")
    /// On every quote line: the result offset where its run of same-prefix quote lines starts.
    static let composerQuote = NSAttributedString.Key("ComposerQuote")
    /// A typed pair of backticks and what is typed between them (`codePairCaretPlugin`, 7259e4f594): an id,
    /// so the text stays literal until the caret leaves the pair through its closing backtick.
    static let composerCodePair = NSAttributedString.Key("ComposerCodePair")
}

@MainActor
enum ComposerRichTextStyler {
    static func marks(_ value: Any?) -> [ComposerRichText.Mark] {
        (value as? [String] ?? []).compactMap(ComposerRichText.Mark.init(rawValue:))
    }

    static func attributes(_ marks: [ComposerRichText.Mark], base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = base
        // Plain text carries no mark keys, so it equals what the editor types and a keystroke
        // doesn't restyle the whole document (ComposerEditor.styleRichText).
        result[.composerMarks] = marks.isEmpty ? nil : marks.map(\.rawValue)
        // The line's font: the prompt font, or a heading's.
        let plain = base[.font] as? NSFont ?? ComposerEditor.font
        var font = marks.contains(.code) ? DSFont.mono(plain.pointSize * 0.92) : plain
        if marks.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if marks.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        result[.font] = font
        result[.strikethroughStyle] = marks.contains(.strike) ? NSUnderlineStyle.single.rawValue : nil
        result[.backgroundColor] = marks.contains(.code) ? Themed.color(\.mutedForeground, 0.12) : nil
        return result
    }

    // MARK: Line boxes

    /// A TextKit line that matches a CSS line box: TextKit puts `spacing` over every line but the
    /// draft's first, and CSS draws the glyphs `top` lower than TextKit does.
    struct LineBox: Equatable { var height: CGFloat; var spacing: CGFloat; var top: CGFloat }

    static var bodyBox: LineBox {
        let m = textKitLineMetrics(font: ComposerEditor.font, lineHeight: ComposerEditor.lineHeight)
        return LineBox(height: ComposerEditor.lineHeight, spacing: m.lineSpacing, top: m.top)
    }

    /// `h1` to `h6` (index.css:1783-1815): 1.25rem, 1.125rem, 1rem, then 0.875rem, weight 600,
    /// line height 1.3, `--contrast-foreground` (`h6` muted).
    static func headingSize(_ level: Int) -> CGFloat { level == 1 ? 20 : level == 2 ? 18 : level == 3 ? 16 : 14 }
    static func headingFont(_ level: Int) -> NSFont { FontRuntime.font(.prompt, size: headingSize(level), weight: .semibold) }
    static func headingBox(_ level: Int) -> LineBox {
        let height = headingSize(level) * 1.3
        let m = textKitLineMetrics(font: headingFont(level), lineHeight: height)
        return LineBox(height: height, spacing: m.lineSpacing, top: m.top)
    }

    /// What a render did besides styling.
    struct Info {
        /// The input rule applied at the caret: the result range of its atom and any character
        /// it carried, and what was there before (`undoInputRule`).
        var rule: (range: NSRange, literal: NSAttributedString)?
        /// Lists, quotes or headings were laid out; `decorated` when numbers or rails need drawing.
        var structured = false
        var decorated = false
        /// How far the first line moves down from where the editor's inset puts it.
        var topShift: CGFloat = 0
        /// The CSS margin under the last block, the line box of the last line with text, and the
        /// margin over the empty line after a final newline, which TextKit lays out without one.
        var bottom: CGFloat = 0
        var lastBox = LineBox(height: 0, spacing: 0, top: 0)
        var trailingGap: CGFloat?
    }

    nonisolated(unsafe) private static let rulePatterns: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues: [
        #"^- \[([ xX])\] $"#, #"^([*+])(\s)$"#, #"^(-)([ \t]+)([^\s\[])$"#, #"^(\d+[.)])(\s)$"#, #"^>(\s)$"#,
        #"^(---|\*\*\*|___)\s?$"#, #"^(#{1,6})(\s)$"#, #"^\[([ xX])\] $"#,
    ].map { ($0, try! NSRegularExpression(pattern: $0)) })

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        let ns = text as NSString
        guard let m = rulePatterns[pattern]?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    /// T3's typed block rules (ComposerPromptEditorTiptap.tsx:566-720), matched like Tiptap's
    /// input rules against a top-level line's text before the caret, right after a keystroke.
    /// `consumed` is how much of that text the marker takes; the dash rule carries its last
    /// character into the item, so `- [ ] ` can still be typed whole.
    static func inputRule(_ before: String, atLineEnd: Bool) -> (source: String, kind: ComposerBlockAttachment.Kind, consumed: Int)? {
        // Every rule starts with one of these and is short: most keystrokes stop here.
        let count = before.utf16.count
        guard count <= 24, let first = before.utf16.first, Array("-*+>#_0123456789".utf16).contains(first) else { return nil }
        // A task starts empty, so its box is written without the space after it (`listItemPrefix`).
        if let m = groups(#"^- \[([ xX])\] $"#, before) {
            let checked = m[1].lowercased() == "x"
            return (checked ? "- [x]" : "- [ ]", .task(checked), count)
        }
        if let m = groups(#"^([*+])(\s)$"#, before) { return (m[0], .bullet, count) }
        if let m = groups(#"^(-)([ \t]+)([^\s\[])$"#, before) { return (m[1] + m[2], .bullet, (m[1] + m[2]).utf16.count) }
        if let m = groups(#"^(\d+[.)])(\s)$"#, before) { return (m[0], .ordered, count) }
        if let m = groups(#"^>(\s)$"#, before) { return (m[0], .quote, count) }
        // `---` lands on its third dash; `***` and `___` wait for a space.
        if atLineEnd, let m = groups(#"^(---|\*\*\*|___)\s?$"#, before), m[0].hasPrefix("---") || m[0].last?.isWhitespace == true {
            return (m[0], .rule, count)
        }
        if let m = groups(#"^(#{1,6})(\s)$"#, before) { return (m[0], .heading(m[1].count), count) }
        return nil
    }

    /// The layout line a block atom starts.
    static func layoutLine(_ block: ComposerBlockAttachment?) -> ComposerBlockLayout.Line {
        guard let block else { return .paragraph }
        switch block.kind {
        case .bullet, .ordered, .task:
            let parts = block.listParts!
            let kind: ComposerBlockLayout.ListKind = if case .task = block.kind { .task } else if case .ordered = block.kind { .ordered } else { .bullet }
            return .list(kind, indent: parts.indent, marker: kind == .task ? "" : parts.marker)
        case .quote: return .quote(block.source)
        case .heading(let level): return .heading(level)
        case .rule: return .rule
        case .codeHeader, .codeEnd: return .code
        }
    }

    static func render(_ input: NSAttributedString, base: [NSAttributedString.Key: Any], width: CGFloat = 560, typing: Bool = false,
                       caret: Int? = nil, parse: NSRange? = nil) -> NSAttributedString {
        renderInfo(input, base: base, width: width, typing: typing, caret: caret, parse: parse).text
    }

    /// Parse plain runs only. Existing marks and atomic chips remain editable native runs.
    /// Fences own their body, so Markdown and mention syntax inside code stays literal.
    ///
    /// A line without a block atom becomes a block when the whole draft is read (`typing` false),
    /// when it lies in `parse` (a paste), or when the keystroke that ended at `caret` completes one
    /// of T3's input rules. A list, quote or heading atom that an edit left inside a line goes, the
    /// way joining a block onto the line before drops its marker.
    static func renderInfo(_ input: NSAttributedString, base: [NSAttributedString.Key: Any], width: CGFloat = 560, typing: Bool = false,
                           caret: Int? = nil, parse: NSRange? = nil) -> (text: NSAttributedString, info: Info) {
        let result = NSMutableAttributedString(string: "")
        var info = Info()
        var fence: String?
        // The open block's header was an atom before this edit: a closing fence typed inside it
        // stays code until Return ends the block there (`exitCodeBlockOnClosingFence`).
        var fenceWasRendered = false
        var lastLine: ComposerBlockAttachment.Kind?
        // Where each result line starts, the block it is, and its atom, for the layout pass.
        var lines: [(start: Int, line: ComposerBlockLayout.Line, atom: Int?)] = []
        let text = input.string as NSString
        var lineStart = 0
        while lineStart < text.length {
            let newline = text.range(of: "\n", range: NSRange(location: lineStart, length: text.length - lineStart))
            let lineEnd = newline.location == NSNotFound ? text.length : newline.location
            let line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let existingBlock = lineEnd > lineStart ? input.attribute(.attachment, at: lineStart, effectiveRange: nil) as? ComposerBlockAttachment : nil
            let activeFence = fence
            var fenceBlock: ComposerBlockAttachment?
            var staleEnd = false
            switch existingBlock?.kind {
            case .codeHeader(let delimiter, _)?:
                fence = delimiter; fenceWasRendered = true; fenceBlock = existingBlock
            case .codeEnd?:
                // A closing fence with no block open (its opening was deleted) goes, as in T3,
                // where the close is an attribute of the block.
                if activeFence != nil { fence = nil; fenceBlock = existingBlock } else { staleEnd = true }
            default:
                if let activeFence {
                    if !(typing && fenceWasRendered), ComposerBlockAttachment.isClosingFence(line, activeFence) {
                        fenceBlock = ComposerBlockAttachment(source: line, kind: .codeEnd(activeFence), width: width)
                        fence = nil
                    }
                } else if newline.location != NSNotFound, let open = ComposerBlockAttachment.openingFence(line) {
                    fenceBlock = ComposerBlockAttachment(source: line, kind: .codeHeader(open.fence, open.info), width: width)
                    fence = open.fence; fenceWasRendered = false
                }
            }
            let code = activeFence != nil || fenceBlock != nil
            var range = NSRange(location: lineStart, length: lineEnd - lineStart)
            if staleEnd { range.location += 1; range.length -= 1 }
            // An empty block keeps one empty line for the caret; the draft writes none.
            if case .codeEnd? = fenceBlock?.kind, case .codeHeader? = lastLine {
                lines.append((result.length, .code, nil))
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
            let resultLineStart = result.length
            var block = range.length > 0 && !staleEnd ? existingBlock : nil
            var newBlock: (source: String, kind: ComposerBlockAttachment.Kind, consumed: Int)?
            if !code, block == nil {
                let full = !typing || parse.map { NSIntersectionRange($0, NSRange(location: lineStart, length: lineEnd - lineStart + 1)).length > 0 } == true
                if full, let prefix = ComposerBlockAttachment.prefix(line) {
                    newBlock = (prefix.source, prefix.kind, prefix.source.utf16.count)
                } else if typing, let caret, caret > lineStart, caret <= lineEnd,
                          let rule = inputRule(text.substring(with: NSRange(location: lineStart, length: caret - lineStart)), atLineEnd: caret == lineEnd) {
                    newBlock = rule
                    info.rule = (NSRange(location: resultLineStart, length: 1 + caret - lineStart - rule.consumed),
                                 input.attributedSubstring(from: NSRange(location: lineStart, length: caret - lineStart)))
                }
            } else if !code, typing, let caret, let bullet = block, case .bullet = bullet.kind, caret > lineStart + 1, caret <= lineEnd,
                      caret - lineStart == 5, text.character(at: lineStart + 1) == 91,
                      let parts = bullet.listParts, ["-", "*", "+"].contains(parts.marker),
                      let m = groups(#"^\[([ xX])\] $"#, text.substring(with: NSRange(location: lineStart + 1, length: caret - lineStart - 1))) {
                // `[ ] ` typed at the start of a bullet item makes it a task where it stands
                // (`bulletToTaskInputRule`, `convertBulletItemToTask`); the task grammar only knows `-`.
                let checked = m[1].lowercased() == "x"
                newBlock = (parts.indent + "-" + (parts.space.isEmpty ? " " : parts.space) + (checked ? "[x]" : "[ ]"), .task(checked), caret - lineStart)
                info.rule = (NSRange(location: resultLineStart, length: 1), input.attributedSubstring(from: NSRange(location: lineStart, length: caret - lineStart)))
            }
            if let newBlock {
                block = ComposerBlockAttachment(source: newBlock.source, kind: newBlock.kind, width: width)
                range.location += newBlock.consumed; range.length -= newBlock.consumed
            }
            var lineBase = base
            if case .heading(let level)? = block?.kind {
                lineBase[.font] = headingFont(level)
                lineBase[.foregroundColor] = level == 6 ? Themed.color(\.contrastMutedForeground) : Themed.color(\.contrastForeground)
            }
            if let block, newBlock != nil {
                let rendered = NSMutableAttributedString(attachment: block)
                rendered.addAttributes(lineBase, range: NSRange(location: 0, length: rendered.length))
                result.append(rendered)
            }
            if let fenceBlock {
                let rendered = NSMutableAttributedString(attachment: fenceBlock)
                rendered.addAttributes(base, range: NSRange(location: 0, length: rendered.length))
                if case .codeHeader(let delimiter, _) = fenceBlock.kind {
                    rendered.addAttribute(.composerCodeBlock, value: delimiter, range: NSRange(location: 0, length: rendered.length))
                }
                result.append(rendered)
                if fenceBlock === existingBlock, range.length > 1 {
                    // A caret can sit next to an atom. Never discard text typed beside it.
                    result.append(input.attributedSubstring(from: NSRange(location: range.location + 1, length: range.length - 1)))
                }
            } else if code {
                var attrs = base
                attrs[.font] = DSFont.mono(12)
                attrs[.backgroundColor] = Themed.color(\.muted)
                attrs[.composerCodeBlock] = activeFence ?? ""
                // A fence opened above existing blocks or chips takes their source as code.
                let rendered = NSMutableAttributedString(string: source(input, range), attributes: attrs)
                // Keep mapped token colors while a long fence waits for highlighting.
                // Newly converted chips have different source offsets and use plain code colors.
                if !input.containsAttachments(in: range) {
                    input.enumerateAttribute(.foregroundColor, in: range) { color, sub, _ in
                        guard let color, input.attribute(.composerCodeBlock, at: sub.location, effectiveRange: nil) != nil else { return }
                        rendered.addAttribute(.foregroundColor, value: color,
                                              range: NSRange(location: sub.location - range.location, length: sub.length))
                    }
                }
                result.append(rendered)
            } else {
                // A typed pair stays literal while it is still one: backticks around plain text, no chips or marks.
                var literalPairs: Set<Int> = []
                input.enumerateAttribute(.composerCodePair, in: range, options: .longestEffectiveRangeNotRequired) { value, sub, _ in
                    guard let id = value as? Int else { return }
                    var whole = sub
                    _ = input.attribute(.composerCodePair, at: sub.location, longestEffectiveRange: &whole, in: range)
                    let pair = text.substring(with: whole)
                    if pair.count >= 2, pair.hasPrefix("`"), pair.hasSuffix("`"), !pair.dropFirst().dropLast().contains("`"),
                       !input.containsAttachments(in: whole),
                       ComposerRichTextStyler.plain(input, whole) { literalPairs.insert(id) }
                }
                var plain = ""
                func flushPlain() {
                    for span in ComposerRichText.parse(plain, typing: typing) {
                        result.append(NSAttributedString(string: span.text, attributes: attributes(span.marks, base: lineBase)))
                    }
                    plain = ""
                }
                input.enumerateAttributes(in: range) { attrs, sub, _ in
                    let part = input.attributedSubstring(from: sub)
                    let existing = marks(attrs[.composerMarks])
                    if let atom = attrs[.attachment] as? ComposerBlockAttachment {
                        // This line's own atom stays; one an edit moved inside the line goes.
                        guard sub.location == lineStart, newBlock == nil else {
                            if case .codeHeader = atom.kind { flushPlain(); result.append(part) }
                            else if case .codeEnd = atom.kind { flushPlain(); result.append(part) }
                            return
                        }
                        flushPlain()
                        let kept = NSMutableAttributedString(attributedString: part)
                        kept.addAttributes(lineBase, range: NSRange(location: 0, length: kept.length))
                        result.append(kept)
                    } else if attrs[.attachment] != nil {
                        flushPlain(); result.append(part)
                    } else if let id = attrs[.composerCodePair] as? Int, literalPairs.contains(id) {
                        flushPlain()
                        var pairAttributes = attributes([], base: lineBase)
                        pairAttributes[.composerCodePair] = id
                        result.append(NSAttributedString(string: part.string, attributes: pairAttributes))
                    } else if !existing.isEmpty {
                        flushPlain()
                        result.append(NSAttributedString(string: part.string, attributes: attributes(existing, base: lineBase)))
                    } else { plain += part.string }
                }
                flushPlain()
            }
            let lineBlock = fenceBlock ?? block
            lines.append((resultLineStart, code ? .code : layoutLine(block), lineBlock != nil && result.length > resultLineStart ? resultLineStart : nil))
            lastLine = lineBlock?.kind
            if case .rule? = lastLine, range.length > 0 { lastLine = nil }
            if newline.location != NSNotFound { result.append(NSAttributedString(string: "\n", attributes: base)) }
            lineStart = lineEnd + 1
        }
        // A rule cannot hold the caret, so a draft never ends in one: the empty line after a
        // final rule is the caret's, and the draft does not write it (`isTrailingLineAfterRule`).
        if case .rule? = lastLine, !text.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: base)) }
        if lines.isEmpty || result.mutableString.hasSuffix("\n") { lines.append((result.length, .paragraph, nil)) }
        layOut(result, lines, &info, width: width)
        return (result, info)
    }

    /// Paragraph styles for T3's block layout (ComposerBlockLayout): indents, collapsed margins
    /// and line boxes, so TextKit puts each baseline where Chromium does.
    private static func layOut(_ result: NSMutableAttributedString, _ lines: [(start: Int, line: ComposerBlockLayout.Line, atom: Int?)],
                               _ info: inout Info, width: CGFloat) {
        let body = bodyBox
        info.lastBox = body
        guard lines.contains(where: { if case .list = $0.line { true } else if case .quote = $0.line { true } else if case .heading = $0.line { true } else { false } }) else { return }
        let layout = ComposerBlockLayout.layout(lines.map(\.line))
        let baseStyle = (result.length > 0 ? result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil) ?? .default
        var previous = body, quoteStart = 0
        info.structured = true
        for (i, entry) in lines.enumerated() {
            let end = i + 1 < lines.count ? lines[i + 1].start : result.length
            let g = layout.lines[i]
            var box = body
            if case .heading(let level) = entry.line { box = headingBox(level) }
            // CSS stacks line boxes and margins; TextKit stacks natural line heights and the
            // spacing over each line, so the spacing before carries the difference.
            let before = i == 0 ? 0 : max(0, g.marginBefore + (previous.spacing - previous.top) + box.top - box.spacing)
            if i == 0 { info.topShift = layout.top + box.top - body.top }
            var first: CGFloat = 0, head: CGFloat = 0
            switch entry.line {
            case .list: first = g.markerX; head = g.textX
            case .quote(let prefix):
                head = ComposerBlockLayout.quoteIndent
                if i == 0 || lines[i - 1].line != .quote(prefix) { quoteStart = entry.start }
                if end > entry.start { result.addAttribute(.composerQuote, value: quoteStart, range: NSRange(location: entry.start, length: end - entry.start)) }
                info.decorated = true
            default: break
            }
            if case .list(.ordered, _, _) = entry.line { info.decorated = true }
            // TextKit draws the empty line after a final newline inside this paragraph's fragment,
            // so the CSS margin over that line rides on this one's spacing after.
            var after: CGFloat = 0
            if i == lines.count - 2, lines[i + 1].start == result.length, layout.lines[i + 1].marginBefore > 0 {
                after = max(0, layout.lines[i + 1].marginBefore + (box.spacing - box.top) + body.top - body.spacing)
            }
            if end > entry.start, first != 0 || head != 0 || before != 0 || after != 0 || box.spacing != body.spacing {
                let style = paragraphStyle(baseStyle, first: first, head: head, before: before, after: after, spacing: box.spacing)
                result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: entry.start, length: end - entry.start))
            }
            // A bullet's glyph follows its depth: disc, circle, then square.
            if case .list(.bullet, _, _) = entry.line, let atom = entry.atom,
               let old = result.attribute(.attachment, at: atom, effectiveRange: nil) as? ComposerBlockAttachment, old.bullet != g.bullet {
                let attrs = result.attributes(at: atom, effectiveRange: nil)
                let replacement = NSMutableAttributedString(attachment: ComposerBlockAttachment(source: old.source, kind: old.kind, width: width, bullet: g.bullet))
                replacement.addAttributes(attrs.filter { $0.key != .attachment }, range: NSRange(location: 0, length: replacement.length))
                result.replaceCharacters(in: NSRange(location: atom, length: 1), with: replacement)
            }
            if end > entry.start { info.lastBox = box } else if i > 0 { info.trailingGap = g.marginBefore }
            previous = box
        }
        info.bottom = layout.bottom
    }

    private struct StyleKey: Hashable { var first, head, before, after, spacing, baseSpacing: CGFloat }
    private static var styles: [StyleKey: NSParagraphStyle] = [:]
    private static func paragraphStyle(_ base: NSParagraphStyle, first: CGFloat, head: CGFloat, before: CGFloat, after: CGFloat, spacing: CGFloat) -> NSParagraphStyle {
        let key = StyleKey(first: first, head: head, before: before, after: after, spacing: spacing, baseSpacing: base.lineSpacing)
        if let cached = styles[key] { return cached }
        let style = base.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = first
        style.headIndent = head
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineSpacing = spacing
        styles[key] = style
        return style
    }


    /// No inline marks anywhere in `range`.
    static func plain(_ input: NSAttributedString, _ range: NSRange) -> Bool {
        var plain = true
        input.enumerateAttribute(.composerMarks, in: range) { value, _, stop in if !marks(value).isEmpty { plain = false; stop.pointee = true } }
        return plain
    }

    /// The Markdown of `range` with every atom written as its source.
    private static func source(_ input: NSAttributedString, _ range: NSRange) -> String {
        var out = ""
        input.enumerateAttributes(in: range) { attrs, sub, _ in
            out += (attrs[.attachment] as? ComposerBlockAttachment)?.source ?? (attrs[.attachment] as? ComposerChipAttachment)?.source
                ?? input.attributedSubstring(from: sub).string
        }
        return out
    }

    static func serialize(_ input: NSAttributedString) -> String { mapping(input).value }
    /// The draft as T3 writes it (`serializeEditorDoc`). Display and source keep one offset per
    /// display character: a piece the draft does not write stays as an empty atomic span.
    static func mapping(_ input: NSAttributedString) -> ComposerRichText.Mapping {
        var spans: [ComposerRichText.Span] = []
        var blocks: [ComposerBlockAttachment?] = []
        input.enumerateAttributes(in: NSRange(location: 0, length: input.length)) { attrs, range, _ in
            if let attachment = attrs[.attachment] {
                let block = attachment as? ComposerBlockAttachment
                spans.append(.init(text: block?.source ?? (attachment as? ComposerChipAttachment)?.source ?? "", marks: marks(attrs[.composerMarks]), atomic: true))
                blocks.append(block)
                return
            }
            // One piece per line and per newline, so the block rules below can read lines.
            let text = input.attributedSubstring(from: range).string as NSString
            let runMarks = marks(attrs[.composerMarks])
            var start = 0
            while start < text.length {
                let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
                let end = newline.location == NSNotFound ? text.length : newline.location
                if end > start { spans.append(.init(text: text.substring(with: NSRange(location: start, length: end - start)), marks: runMarks)); blocks.append(nil) }
                if newline.location == NSNotFound { break }
                spans.append(.init(text: "\n", marks: [])); blocks.append(nil)
                start = end + 1
            }
        }
        func isNewline(_ i: Int) -> Bool { i < spans.count && !spans[i].atomic && spans[i].text == "\n" }
        func hide(_ i: Int) { spans[i] = .init(text: "", marks: [], atomic: true) }
        for i in spans.indices {
            guard let block = blocks[i] else { continue }
            switch block.kind {
            case .codeHeader(let fence, let info):
                // Lines from the header line on; the block ends at its closing fence or the draft's end.
                var lines = [""], close: Int?, j = i + 1
                while j < spans.count {
                    if case .codeEnd? = blocks[j]?.kind { close = j; break }
                    if case .codeHeader? = blocks[j]?.kind { break }
                    if isNewline(j) { lines.append("") } else { lines[lines.count - 1] += spans[j].text }
                    j += 1
                }
                let body = close == nil ? Array(lines.dropFirst()) : Array(lines.dropFirst().dropLast())
                // An empty block writes no body line (`codeBlockSource`: no newline without content).
                if body == [""], isNewline(i + 1) { hide(i + 1) }
                // Code holding a line that would close the fence is written inside a longer one.
                let longest = body.filter { ComposerBlockAttachment.isClosingFence($0, fence) }.map { $0.prefix { $0 == fence.first }.count }.max() ?? 0
                if longest > 0, let c = fence.first {
                    let longer = String(repeating: c, count: longest + 1)
                    spans[i].text = longer + info
                    if let close { spans[close].text = longer }
                }
            case .rule:
                if i == spans.count - 2, isNewline(i + 1) { hide(i + 1) }
            case .bullet, .ordered, .task:
                // A bare marker keeps its missing space only while the item is empty (`listItemPrefix`).
                if let last = block.source.last, last != " ", last != "\t", i + 1 < spans.count, !isNewline(i + 1) { spans[i].text += " " }
            default: break
            }
        }
        // A paragraph on the line right after a quote reads as part of it in Markdown (a lazy
        // continuation), so the draft writes a blank line between them. The newline before it
        // writes both, and the blank line holds no caret (`needsBlankLineAfterQuote`, 02e9d2417a).
        func isQuote(_ i: Int) -> Bool { if i < blocks.count, case .quote? = blocks[i]?.kind { true } else { false } }
        var quoteLine = isQuote(0)
        for i in spans.indices where isNewline(i) {
            if quoteLine, i + 1 < spans.count, blocks[i + 1] == nil, !isNewline(i + 1) {
                spans[i] = .init(text: "\n\n", marks: [], atomic: true)
            }
            quoteLine = isQuote(i + 1)
        }
        return ComposerRichText.mapping(spans)
    }
}
