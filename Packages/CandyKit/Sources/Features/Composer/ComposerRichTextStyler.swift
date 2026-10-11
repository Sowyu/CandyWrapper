import AppKit
import DesignSystem

extension NSAttributedString.Key {
    static let composerMarks = NSAttributedString.Key("ComposerRichTextMarks")
    static let composerCodeBlock = NSAttributedString.Key("ComposerCodeBlock")
}

@MainActor
// ponytail: block atoms approximate Tiptap nodes; replace with structural editing and full position maps before claiming block parity.
enum ComposerRichTextStyler {
    static func marks(_ value: Any?) -> [ComposerRichText.Mark] {
        (value as? [String] ?? []).compactMap(ComposerRichText.Mark.init(rawValue:))
    }

    static func attributes(_ marks: [ComposerRichText.Mark], base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = base
        result[.composerMarks] = marks.map(\.rawValue)
        var font = marks.contains(.code) ? DSFont.mono(14 * 0.92) : ComposerEditor.font
        if marks.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if marks.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        result[.font] = font
        result[.strikethroughStyle] = marks.contains(.strike) ? NSUnderlineStyle.single.rawValue : 0
        result[.backgroundColor] = marks.contains(.code) ? Themed.color(\.mutedForeground, 0.12) : nil
        return result
    }

    /// Parse plain runs only. Existing marks and atomic chips remain editable native runs.
    /// Fences own their body, so Markdown and mention syntax inside code stays literal.
    static func render(_ input: NSAttributedString, base: [NSAttributedString.Key: Any], width: CGFloat = 560, typing: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var fence: String?
        // The open block's header was an atom before this edit: a closing fence typed inside it
        // stays code until Return ends the block there (`exitCodeBlockOnClosingFence`).
        var fenceWasRendered = false
        var lastLine: ComposerBlockAttachment.Kind?
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
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
            let resultLineStart = result.length
            var block = range.length > 0 && !staleEnd ? existingBlock : nil
            let typedBlockReady = !typing || (
                line != "*" && line != "+" && line != "-" && line != ">"
                && line.range(of: #"^\s*\d+[.)]$"#, options: .regularExpression) == nil
                && line != "- " && !(line.hasPrefix("- [") && !line.contains("] "))
            )
            // While typing, only `---` and `*** ` or `___ ` make a rule (`horizontalRuleInputRule`);
            // other rule spellings stay what they were typed as until the draft is read back.
            let typedRuleReady = !typing || line == "---" || line.range(of: #"^(\*\*\*|___)\s$"#, options: .regularExpression) != nil
            if !code, typedBlockReady, block == nil, let prefix = ComposerBlockAttachment.prefix(line),
               typedRuleReady || { if case .rule = prefix.kind { return false } else { return true } }() {
                block = ComposerBlockAttachment(source: prefix.source, kind: prefix.kind, width: width)
                let rendered = NSMutableAttributedString(attachment: block!)
                rendered.addAttributes(base, range: NSRange(location: 0, length: rendered.length))
                result.append(rendered)
                let count = prefix.source.utf16.count
                range.location += count; range.length -= count
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
                result.append(NSAttributedString(string: source(input, range), attributes: attrs))
            } else {
                var plain = ""
                func flushPlain() {
                    for span in ComposerRichText.parse(plain) {
                        result.append(NSAttributedString(string: span.text, attributes: attributes(span.marks, base: base)))
                    }
                    plain = ""
                }
                input.enumerateAttributes(in: range) { attrs, sub, _ in
                    let part = input.attributedSubstring(from: sub)
                    let existing = marks(attrs[.composerMarks])
                    if attrs[.attachment] != nil {
                        flushPlain(); result.append(part)
                    } else if !existing.isEmpty {
                        flushPlain()
                        result.append(NSAttributedString(string: part.string, attributes: attributes(existing, base: base)))
                    } else { plain += part.string }
                }
                flushPlain()
            }
            if let block, case .heading(let level) = block.kind, result.length > resultLineStart {
                let size: CGFloat = level == 1 ? 20 : level == 2 ? 18 : level == 3 ? 16 : 14
                result.addAttribute(.font, value: DSFont.ui(size, weight: .semibold), range: NSRange(location: resultLineStart, length: result.length - resultLineStart))
            }
            lastLine = fenceBlock?.kind ?? block?.kind
            if case .rule? = lastLine, range.length > 0 { lastLine = nil }
            if newline.location != NSNotFound { result.append(NSAttributedString(string: "\n", attributes: base)) }
            lineStart = lineEnd + 1
        }
        // A rule cannot hold the caret, so a draft never ends in one: the empty line after a
        // final rule is the caret's, and the draft does not write it (`isTrailingLineAfterRule`).
        if case .rule? = lastLine, !text.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: base)) }
        return result
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
        return ComposerRichText.mapping(spans)
    }
}
