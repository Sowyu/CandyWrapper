import AppKit
import DesignSystem

/// A file path chip in chat markdown: T3's `MarkdownFileLink`, a `ContextChip kind="mention"` holding
/// `FileTagChipContent` (ChatMarkdown.tsx:1931, ContextChip.tsx, chat/FileTagChip.tsx).
public struct FileChip {
    /// Border box, relative to the markdown view.
    public var frame: CGRect
    var icon: CGRect
    public var meta: FileLinkMeta
    public var label: String
}

/// ContextChip metrics and colors. Sizes are in em of the chip's own font, `0.86em` of the text around it:
/// `h-[1.41em] gap-[0.33em] rounded-[0.5em] border px-[0.5em] font-medium leading-none`, the icon `size-[1.17em]`,
/// the label `leading-tight truncate`, the whole chip `align-middle`.
enum FileChipStyle {
    static let accent = OKLab.oklch(0.62, 0.11, 215) // kind "mention"
    static let foreground = OKLab.mix(accent, 0.22, Themed.color(\.contrastForeground))
    static let border = OKLab.mix(accent, 0.34, Themed.color(\.contrastBorder))
    static let hoverBorder = OKLab.mix(accent, 0.48, Themed.color(\.contrastBorder))
    static let fill = accent.withAlphaComponent(0.11)
    static let hoverFill = accent.withAlphaComponent(0.17)
    /// The folder and fallback file glyph: lucide at `text-icon-muted`.
    static var iconMuted: NSColor { Themed.color(\.iconMuted) }

    static func em(_ size: CGFloat) -> CGFloat { 0.86 * size }
    static func font(_ size: CGFloat) -> NSFont { DSFont.ui(em(size), weight: .medium) }
    static func leading(_ size: CGFloat) -> CGFloat { 1 + 0.5 * em(size) + 1.17 * em(size) + 0.33 * em(size) }
    static func trailing(_ size: CGFloat) -> CGFloat { 0.5 * em(size) + 1 }
    static func height(_ size: CGFloat) -> CGFloat { 1.41 * em(size) }

    /// Chip top relative to the line's baseline: `vertical-align: middle` centers it on baseline - x-height / 2.
    static func top(parent: NSFont, size: CGFloat) -> CGFloat { -parent.xHeight / 2 - height(size) / 2 }

    /// The label's baseline relative to the line's baseline: its `leading-tight` line box sits centered in the chip.
    static func labelBaseline(parent: NSFont, size: CGFloat) -> CGFloat {
        let line = 1.25 * em(size)
        let chipTop = top(parent: parent, size: size)
        let labelTop = chipTop + 1 + (height(size) - 2 - line) / 2
        return TextLine(NSAttributedString(string: " ", attributes: [.font: font(size)])).baseline(top: labelTop, lineHeight: line)
    }

    /// The chip as attributed text: a no-break space whose kerning reserves the border, padding, icon and gap,
    /// the label with word joiners between characters so the chip never wraps (it is an inline-flex box),
    /// and kerning after the last character for the right padding and border.
    static func string(label: String, size: CGFloat, parent: NSFont, maxWidth: CGFloat) -> NSAttributedString {
        let font = font(size)
        let reserve = leading(size) + trailing(size)
        var text = label
        // `max-w-full` plus `truncate` on the label.
        if TextLine(NSAttributedString(string: text, attributes: [.font: font])).width + reserve > maxWidth {
            while !text.isEmpty, TextLine(NSAttributedString(string: text + "…", attributes: [.font: font])).width + reserve > maxWidth {
                text.removeLast()
            }
            text += "…"
        }
        let joined = "\u{00A0}" + text.map(String.init).joined(separator: "\u{2060}")
        let out = NSMutableAttributedString(string: joined, attributes: [
            .font: font, .foregroundColor: foreground,
            .baselineOffset: -labelBaseline(parent: parent, size: size)])
        let space = TextLine(NSAttributedString(string: "\u{00A0}", attributes: [.font: font])).width
        out.addAttribute(.kern, value: leading(size) - space, range: NSRange(location: 0, length: 1))
        let last = (joined as NSString).length - 1
        if last > 0 { out.addAttribute(.kern, value: trailing(size), range: NSRange(location: last, length: 1)) }
        else { out.addAttribute(.kern, value: leading(size) - space + trailing(size), range: NSRange(location: 0, length: 1)) }
        return out
    }

    /// The pierre icon for a file, or lucide's folder for a path without an extension (PierreEntryIcon.tsx).
    @MainActor
    static func icon(for meta: FileLinkMeta) -> (IconDefinition, NSColor) {
        if meta.isDirectory { return (IconName.folder.definition, iconMuted) }
        let token = FileTypeIcon.token(for: meta.filePath)
        return (FileIcons.symbols[token] ?? FileIcons.symbols["default"]!, FileTypeIcon.color(token))
    }
}

/// The file chips one message can show, resolved once per layout: T3 resolves every inline code span
/// and link destination first so same-named files get their parent folders in the label.
struct FileChipResolver {
    let cwd: String?
    private var inline: [String: FileLinkMeta] = [:]
    private var links: [String: FileLinkMeta] = [:]
    private var suffixes: [String: String] = [:]

    init(document: MarkdownDocument, cwd: String?) {
        self.cwd = cwd
        var paths: [String] = []
        func visit(_ runs: [InlineRun]) {
            for run in runs {
                if run.code, run.link == nil {
                    let key = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if inline[key] == nil, let meta = FileLinks.resolveInlineCode(run.text, cwd: cwd) { inline[key] = meta; paths.append(meta.filePath) }
                } else if let link = run.link?.absoluteString, links[link] == nil, let meta = FileLinks.resolveLink(link, cwd: cwd) {
                    links[link] = meta
                    paths.append(meta.filePath)
                }
            }
        }
        func walk(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .paragraph(let runs), .heading(_, let runs): visit(runs)
                case .list(let list): list.items.forEach { walk($0.blocks) }
                case .blockquote(let children), .alert(_, let children): walk(children)
                case .table(let table): ([table.header] + table.rows).forEach { $0.forEach(visit) }
                case .code, .rule, .image, .math: break
                }
            }
        }
        walk(document.blocks)
        suffixes = FileLinks.parentSuffixes(paths)
    }

    var isEmpty: Bool { inline.isEmpty && links.isEmpty }
    /// The only part of a chip's look that other blocks of the message decide.
    var labelSuffixes: [String: String] { suffixes }

    func inlineCode(_ text: String) -> FileLinkMeta? { inline[text.trimmingCharacters(in: .whitespacesAndNewlines)] }
    func link(_ url: URL) -> FileLinkMeta? { links[url.absoluteString] }
    func label(_ meta: FileLinkMeta) -> String { FileLinks.label(meta, suffixes: suffixes) }
}
