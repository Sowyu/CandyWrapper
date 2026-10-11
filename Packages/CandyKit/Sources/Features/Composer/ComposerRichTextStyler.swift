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
        let text = input.string as NSString
        var lineStart = 0
        while lineStart < text.length {
            let newline = text.range(of: "\n", range: NSRange(location: lineStart, length: text.length - lineStart))
            let lineEnd = newline.location == NSNotFound ? text.length : newline.location
            let line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let opening = line.prefix { $0 == "`" || $0 == "~" }
            let isFence = opening.count >= 3 && Set(opening).count == 1 && (fence != nil || newline.location != NSNotFound)
            let existingBlock = lineEnd > lineStart ? input.attribute(.attachment, at: lineStart, effectiveRange: nil) as? ComposerBlockAttachment : nil
            let activeFence = fence
            var fenceBlock: ComposerBlockAttachment?
            if let existingBlock {
                switch existingBlock.kind {
                case .codeHeader(let delimiter, _): fence = delimiter; fenceBlock = existingBlock
                case .codeEnd: fence = nil; fenceBlock = existingBlock
                default: break
                }
            } else if isFence {
                if let activeFence, opening.first == activeFence.first, opening.count >= activeFence.count,
                   line.dropFirst(opening.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fenceBlock = ComposerBlockAttachment(source: line, kind: .codeEnd(activeFence), width: width)
                } else if activeFence == nil {
                    fenceBlock = ComposerBlockAttachment(source: line, kind: .codeHeader(String(opening), String(line.dropFirst(opening.count))), width: width)
                }
            }
            let code = activeFence != nil || isFence || fenceBlock != nil
            if fenceBlock === existingBlock, existingBlock != nil {
                // Existing fence atoms already updated the state above.
            } else if let current = fence {
                if isFence, opening.first == current.first, opening.count >= current.count,
                   line.dropFirst(opening.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = nil }
            } else if isFence { fence = String(opening) }
            var range = NSRange(location: lineStart, length: lineEnd - lineStart)
            let resultLineStart = result.length
            var block = range.length > 0 ? input.attribute(.attachment, at: lineStart, effectiveRange: nil) as? ComposerBlockAttachment : nil
            let typedBlockReady = !typing || (
                line != "*" && line != "+" && line != "-" && line != ">"
                && line.range(of: #"^\s*\d+[.)]$"#, options: .regularExpression) == nil
                && line != "- " && !(line.hasPrefix("- [") && !line.contains("] "))
                && line != "***" && line != "___"
            )
            if !code, typedBlockReady, block == nil, let prefix = ComposerBlockAttachment.prefix(line) {
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
                if existingBlock != nil, range.length > 1 {
                    // A caret can sit next to an atom. Never discard text typed beside it.
                    result.append(input.attributedSubstring(from: NSRange(location: range.location + 1, length: range.length - 1)))
                }
            } else if code {
                var attrs = base
                attrs[.font] = DSFont.mono(12)
                attrs[.backgroundColor] = Themed.color(\.muted)
                attrs[.composerCodeBlock] = activeFence ?? String(opening)
                result.append(NSAttributedString(string: line, attributes: attrs))
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
            if newline.location != NSNotFound { result.append(NSAttributedString(string: "\n", attributes: base)) }
            lineStart = lineEnd + 1
        }
        return result
    }

    static func serialize(_ input: NSAttributedString) -> String { mapping(input).value }
    static func mapping(_ input: NSAttributedString) -> ComposerRichText.Mapping {
        var spans: [ComposerRichText.Span] = []
        input.enumerateAttributes(in: NSRange(location: 0, length: input.length)) { attrs, range, _ in
            let source = (attrs[.attachment] as? ComposerBlockAttachment)?.source ?? (attrs[.attachment] as? ComposerChipAttachment)?.source ?? input.attributedSubstring(from: range).string
            spans.append(.init(text: source, marks: marks(attrs[.composerMarks]), atomic: attrs[.attachment] != nil))
        }
        return ComposerRichText.mapping(spans)
    }
}
