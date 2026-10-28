import AppKit
import DesignSystem

extension NSAttributedString.Key {
    /// What find in thread matches in place of these characters, as T3 indexes the rendered page
    /// (packages/shared/src/threadFindText.ts): a chip's label, "" for what only draws (favicons, image
    /// alt text, code block titles), "\u{0}" where T3 starts a new text segment.
    static let markdownFindText = NSAttributedString.Key("CandyMarkdownFindText")
    /// What copying puts on the pasteboard in place of these characters: a formula's TeX (MarkdownMath.tsx `data-markdown-copy`).
    static let markdownCopyText = NSAttributedString.Key("CandyMarkdownCopyText")
}

/// Runs the few main-actor lookups a layout needs (chips, image sizes, diagrams) from any thread. A layout off the main
/// thread waits for the main thread here, so the main thread must never wait for a layout.
func onMain<T>(_ body: @MainActor () -> T) -> T {
    withoutActuallyEscaping(body) { body in
        nonisolated(unsafe) let body = body
        nonisolated(unsafe) var out: T?
        let run = { MainActor.assumeIsolated { out = body() } }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        return out!
    }
}

/// T3's `.chat-markdown` values (`apps/web/src/index.css:1759-2073`, ChatMarkdown.tsx), research note H section 4.
enum MarkdownStyle {
    static let fontSize: CGFloat = 14
    static var lineHeight: CGFloat { 14 * 1.625 * FontRuntime.interfaceScale }
    /// `margin: 0.65rem 0` on p, ul, ol, blockquote, pre and the table container.
    static let blockMargin: CGFloat = 10.4
    static let headingMargin: (top: CGFloat, bottom: CGFloat) = (20, 8)
    static let headingSizes: [CGFloat] = [20, 18, 16, 14, 14, 14]
    static let listGutter: CGFloat = 20
    static let itemGap: CGFloat = 4
    /// Inline code: 12px mono, `padding: 0.1rem 0.35rem`, 1px border, 6px radius.
    static var chipFontSize: CGFloat { ThreadDesign.uses3814 ? 11.9 : 12 }
    static var chipPaddingX: CGFloat { ThreadDesign.uses3814 ? 11.9 * 0.35 : 5.6 }
    static var chipPaddingY: CGFloat { ThreadDesign.uses3814 ? 11.9 * 0.1 : 1.6 }
    static var chipRadius: CGFloat { ThreadDesign.uses3814 ? 4 : 6 }
    /// Code blocks: 13px mono at `leading-snug`, `padding: 0.8rem 0.9rem`, 30px header.
    static let codeFontSize: CGFloat = 13
    static var codeLineHeight: CGFloat { 13 * FontRuntime.codeScale * 1.375 }
    static let codePadding = (x: CGFloat(14.4), y: CGFloat(12.8))
    static let codeHeader: CGFloat = 30
    /// `.chat-markdown pre::-webkit-scrollbar { height: var(--app-scrollbar-width) }`, 6px (index.css:90, 2072-2074,
    /// T3 b5a0696a98): the lane an overflowing block adds below its padding.
    static let codeScrollbar: CGFloat = 6
    static var tableFontSize: CGFloat { ThreadDesign.uses3814 ? 14 : 12 }
    static var tableLineHeight: CGFloat { tableFontSize * 1.625 }
    static let imageMaxWidth: CGFloat = 480

    static var body: NSColor { ThreadDesign.markdownBody }
    static var strong: NSColor { Themed.color(\.contrastForeground) }
    static var muted: NSColor { Themed.color(\.contrastMutedForeground) }
    static var link: NSColor { Themed.color(\.infoForeground) }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let font = DSFont.ui(size, weight: weight)
        guard italic else { return font }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? font
    }

    /// CSS `font-weight: bolder` from a parent weight.
    static func bolder(_ weight: NSFont.Weight) -> NSFont.Weight { ThreadDesign.uses3814 ? .semibold : weight.rawValue >= NSFont.Weight.semibold.rawValue ? .black : .bold }

    nonisolated(unsafe) private static var noBreakSpaceWidths: [NSFont: CGFloat] = [:]
    private static let noBreakSpaceLock = NSLock()
    /// A no-break space's advance in `font`, measured once per font.
    static func noBreakSpaceWidth(_ font: NSFont) -> CGFloat {
        if let width = noBreakSpaceLock.withLock({ noBreakSpaceWidths[font] }) { return width }
        let width = TextLine(NSAttributedString(string: "\u{00A0}", attributes: [.font: font])).width
        noBreakSpaceLock.withLock { noBreakSpaceWidths[font] = width }
        return width
    }

    /// Inline text: the attributed string, the inline code ranges and the file chips in it.
    struct Inline {
        var string: NSAttributedString
        var code: [NSRange]
        var files: [(range: NSRange, meta: FileLinkMeta, label: String)]
        /// Web links (not file links), for hit testing.
        var links: [(range: NSRange, url: URL)] = []
        /// `t3-context://` chips: a placeholder space in the text, drawn by the layout item.
        var contexts: [(range: NSRange, chip: MarkdownContextChip)] = []
        /// External link favicons: a reserved space before the link's first character.
        var favicons: [(range: NSRange, host: String)] = []
        /// Inline formulas: a kerned no-break space as wide as the formula, drawn by a `.math` item.
        var formulas: [(range: NSRange, layout: MathLayout)] = []
    }

    /// Inline runs as an attributed string. Inline code reserves its padding and border with kerning
    /// on the character before it and on its own last character; the ranges come back for the chips.
    /// With `files`, path-shaped inline code and file links become file chips (`FileChipStyle`).
    static func inline(_ runs: [InlineRun], size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                       alignment: NSTextAlignment = .natural, headIndent: CGFloat = 0, firstLineIndent: CGFloat? = nil,
                       files: FileChipResolver? = nil, contexts: MarkdownContextChips? = nil,
                       maxChipWidth: CGFloat = .greatestFiniteMagnitude, findable: Bool = true) -> Inline {
        let out = NSMutableAttributedString()
        var contextChips: [(range: NSRange, chip: MarkdownContextChip)] = []
        var favicons: [(range: NSRange, host: String)] = []
        var formulas: [(range: NSRange, layout: MathLayout)] = []
        var chips: [NSRange] = []
        var fileChips: [(range: NSRange, meta: FileLinkMeta, label: String)] = []
        var webLinks: [(range: NSRange, url: URL)] = []
        let pad = chipPaddingX + 1
        var leadingChip = false
        let parent = font(size, weight: weight)
        func appendFile(_ meta: FileLinkMeta) {
            let label = files!.label(meta)
            let start = out.length
            out.append(FileChipStyle.string(label: label, size: size, parent: parent, maxWidth: maxChipWidth))
            let range = NSRange(location: start, length: out.length - start)
            // Find matches the chip's whole label (threadFindText.ts `fileLinkLabel`), not its drawn characters.
            out.addAttribute(.markdownFindText, value: label, range: range)
            fileChips.append((range, meta, label))
        }
        var i = 0
        while i < runs.count {
            var run = runs[i]
            if let files, run.code, run.link == nil, let meta = files.inlineCode(run.text) {
                appendFile(meta)
                i += 1
                continue
            }
            if let files, let link = run.link, let meta = files.link(link) {
                // T3 renders the link's label as plain text followed by the chip, or only the chip when
                // the label already names the file (`isMarkdownFileLinkLabel`).
                var end = i
                while end < runs.count, runs[end].link == link { end += 1 }
                let label = runs[i..<end].map(\.text).joined()
                if !FileLinks.isFileLinkLabel(label, href: link.absoluteString) {
                    let plain = runs[i..<end].map { r -> InlineRun in var r = r; r.link = nil; return r }
                    let inner = inline(Array(plain), size: size, weight: weight, color: color)
                    // ponytail: inline code inside such a label loses its code box; keep `inner.code` if that shows up
                    out.append(inner.string)
                    out.append(NSAttributedString(string: " ", attributes: [.font: parent, .foregroundColor: color]))
                }
                appendFile(meta)
                i = end
                continue
            }
            func appendContextChip(_ chip: MarkdownContextChip) {
                var chip = chip
                let look = chip.look
                let measured = onMain { ComposerChipAttachment.measure(look, maxWidth: maxChipWidth) }
                chip.label = measured.label
                chip.frame.size = measured.size
                // One no-break space as wide as the chip: the chip never wraps and the layout item draws it.
                let space = TextLine(NSAttributedString(string: "\u{00A0}", attributes: [.font: parent])).width
                let start = out.length
                // Find skips a user message's context reference and ends the text segment there (threadFindText.ts).
                out.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: parent, .foregroundColor: color,
                                                                                .kern: measured.size.width - space, .markdownFindText: "\u{0}"]))
                contextChips.append((NSRange(location: start, length: 1), chip))
            }
            if let url = run.link, let threadId = MarkdownContextChips.threadLinkId(url.absoluteString) {
                // `parseThreadLinkHref` before every other link kind (ChatMarkdown.tsx:1067-1074): a thread chip
                // labelled with the link text, or the id when it has none.
                var end = i
                while end < runs.count, runs[end].link == url { end += 1 }
                let text = runs[i..<end].map(\.text).joined()
                i = end
                nonisolated(unsafe) let resolver = contexts ?? MarkdownContextChips()
                appendContextChip(onMain { resolver.threadLinkChip(threadId: threadId, label: text.isEmpty ? threadId : text) })
                continue
            }
            if let url = run.link, url.scheme == "t3-context", let parsed = ComposerContext.parseHref(url.absoluteString) {
                var end = i
                while end < runs.count, runs[end].link == url { end += 1 }
                let text = runs[i..<end].map(\.text).joined()
                let label = text.isEmpty ? parsed.contextId : text
                i = end
                guard let contexts else {
                    // Without a renderer the link shows its label as text (ChatMarkdown.tsx:2933-2937).
                    out.append(NSAttributedString(string: label, attributes: [.font: parent, .foregroundColor: color]))
                    continue
                }
                nonisolated(unsafe) let resolver = contexts
                appendContextChip(onMain { resolver.chip(kind: parsed.kind, contextId: parsed.contextId, label: label) })
                continue
            }
            if let math = run.math {
                if let layout = MathRenderer.layout(math.tex, display: false, textSize: size) {
                    // `inline-block whitespace-nowrap px-0.5` (MarkdownMath.tsx:25): one unbreakable box with 2px each side.
                    let start = out.length
                    out.append(NSAttributedString(string: "\u{00A0}", attributes: [
                        .font: parent, .foregroundColor: color,
                        .kern: min(layout.width + 2 * MarkdownMathStyle.padX, maxChipWidth) - noBreakSpaceWidth(parent),
                        .markdownMath: true, .markdownFindText: math.tex, .markdownCopyText: math.copySource]))
                    formulas.append((NSRange(location: start, length: 1), layout))
                    i += 1
                    continue
                }
                // Stage 1 can't typeset it: the TeX shows as inline code.
                run.text = math.copySource
                run.code = true
                run.math = nil
            }
            var findText: String?
            if let url = run.link, let citation = ThreadAssistantCitation.parse(url.absoluteString) {
                run.text = "❝ " + citation.label
                run.code = true
                findText = citation.label
            }
            let index = i
            i += 1
            if let skill = run.skill {
                appendContextChip(onMain { MarkdownContextChip(look: ComposerChipLook(kind: .skill, label: ProviderSkills.displayName(skill)),
                    action: .skill(skill), tooltip: "$" + skill.name, accessibility: "Skill, " + ProviderSkills.displayName(skill)) })
                out.addAttribute(.markdownFindText, value: ProviderSkills.displayName(skill), range: NSRange(location: out.length - 1, length: 1))
                continue
            }
            // An image's alt text is not page text; a hard break ends the find segment (threadFindText.ts).
            if run.image != nil { findText = "" }
            if run.isBreak, run.text == "\n" { findText = "\u{0}" }
            let start = out.length
            if let url = run.link, findText == nil, index == 0 || runs[index - 1].link != url, let host = MarkdownFavicons.host(url),
               runs[index...].prefix(while: { $0.link == url }).contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) {
                // `MarkdownLinkFavicon`: `ms-[0.25em] me-[0.2em] size-[14px]` before the link's first character, which it never
                // wraps away from (`whitespace-nowrap`, ChatMarkdown.tsx:1880-1930). A kerned no-break space reserves it.
                let linkFont = run.code ? DSFont.mono(chipFontSize) : font(size, weight: run.bold ? bolder(weight) : weight, italic: run.italic)
                let space = noBreakSpaceWidth(linkFont)
                out.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: linkFont, .kern: 0.45 * size + 14 - space, .markdownFindText: ""]))
                favicons.append((NSRange(location: start, length: 1), host))
            }
            let textStart = out.length
            var attributes: [NSAttributedString.Key: Any] = [:]
            if run.code {
                // Inline code keeps `white-space: normal`: its spaces collapse to one, and a leading space after a
                // space or at the start of a line disappears (` M hello.py` after "showed ").
                // ponytail: a space after code that ends in one still shows; collapse it too if a reply needs it
                run.text = run.text.replacing(/[ \t\n]+/, with: " ")
                let previous = out.length > 0 ? out.mutableString.character(at: out.length - 1) : nil
                if previous == nil || previous == 0x20 || previous == 0x2028 { run.text = String(run.text.drop { $0 == " " }) }
                attributes[.font] = DSFont.mono(chipFontSize)
                attributes[.foregroundColor] = strong
            } else {
                attributes[.font] = font(size, weight: run.bold ? bolder(weight) : weight, italic: run.italic)
                attributes[.foregroundColor] = run.link != nil ? link : color
            }
            if run.link?.scheme == "https" || run.link?.scheme == "http" { attributes[.markdownExternalLink] = true }
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let findText { attributes[.markdownFindText] = findText }
            // An image inside running text shows its alt text, like a broken inline image.
            if run.isBreak, run.text == "\n" { run.text = "\u{2028}" }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
            if let url = run.link, out.length > start {
                // Adjacent runs of one link (bold inside a link) make one target.
                if let last = webLinks.last, last.url == url, last.range.upperBound == start {
                    webLinks[webLinks.count - 1].range.length += out.length - start
                } else {
                    webLinks.append((NSRange(location: start, length: out.length - start), url))
                }
            }
            if run.code, out.length > textStart {
                chips.append(NSRange(location: textStart, length: out.length - textStart))
                if textStart > 0 {
                    let previous = (out.attribute(.kern, at: textStart - 1, effectiveRange: nil) as? CGFloat) ?? 0
                    out.addAttribute(.kern, value: previous + pad, range: NSRange(location: textStart - 1, length: 1))
                } else {
                    leadingChip = true
                }
                out.addAttribute(.kern, value: pad, range: NSRange(location: out.length - 1, length: 1))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = [] // CSS breaks greedily; no orphan or Hangul rules
        paragraph.alignment = alignment
        paragraph.firstLineHeadIndent = (firstLineIndent ?? headIndent) + (leadingChip ? pad : 0)
        paragraph.headIndent = headIndent
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        if !findable { out.addAttribute(.markdownFindText, value: "", range: NSRange(location: 0, length: out.length)) }
        return Inline(string: out, code: chips, files: fileChips, links: webLinks, contexts: contextChips, favicons: favicons, formulas: formulas)
    }
}

/// Everything a message's markdown draws at one width: positioned text, boxes, markers and the
/// frames of the code and table buttons. Built once per width and cached by `MarkdownView`.
/// Built on one thread, then only read: a large message lays out off the main thread and hands the result over.
public final class MarkdownLayout: @unchecked Sendable {
    public let width: CGFloat
    public private(set) var height: CGFloat = 0
    /// The bottom margin the last block's descendants leave inside `height` (a loose list item's `<p>`). A next
    /// sibling's own top margin collapses with it.
    public var trailingMargin: CGFloat { rootEnds.last?.innerBottom ?? 0 }

    enum Item {
        case text(MarkdownTextBox, CGPoint)
        /// A filled rounded rect, optionally with a 1px inside border (`sides` limits the border).
        case box(CGRect, fill: NSColor?, border: NSColor?, radius: CGFloat)
        case glyphs(NSAttributedString, baselineRight: CGPoint)
        /// `disc`, `circle` or `square` list markers, which Blink paints as shapes, not glyphs.
        case symbol(Int, CGRect, NSColor)
        case checkbox(CGRect, checked: Bool)
        case icon(IconName, CGRect, NSColor)
        /// A pierre file icon for a path, in its theme color (`PierreEntryIcon`).
        case fileIcon(String, CGRect)
        /// A file path chip's box and icon; its label is part of the text item drawn after it.
        case fileChip(FileChip)
        /// A `t3-context://` chip, drawn whole over its placeholder space.
        case contextChip(MarkdownContextChip)
        /// A web link's area on one line (not drawn; hit tested by `MarkdownView`).
        case link(CGRect, URL)
        /// An external link's favicon box (14pt square) for `host`.
        case favicon(String, CGRect)
        /// A formula with its baseline's left end at the point, in the text color, clipped to the rect when it has one
        /// (an inline formula wider than the column). The clip stays in the item so it can't unbalance a table's scroll.
        case math(MathLayout, CGPoint, NSColor, clip: CGRect?)
        /// Text find counts but nothing draws: a diagram's source beside it (ChatMarkdown.tsx:1074-1079).
        case hiddenText(String, codeIndex: Int)
        /// Clips the items until the matching `.endClip` (wide tables).
        case clip(CGRect)
        /// A code block body with wrapping off (`.chat-markdown pre`, `overflow-x: auto`, index.css:1961-1985): clips
        /// the items until the matching `.endClip` and shifts them by the block's horizontal scroll offset, which
        /// `MarkdownView` keeps. `contentWidth` is the body's scroll width; past `viewport.width` the body overflows and
        /// its bottom `codeScrollbar` points hold the scrollbar.
        case scroll(codeIndex: Int, viewport: CGRect, contentWidth: CGFloat)
        case endClip
        /// A rendered Mermaid diagram's bitmap.
        case image(CGImage, CGRect)
        case remoteImage(URL, String, CGRect)
    }

    static func tableMarkdown(_ table: MarkdownTable) -> String { Builder.markdown(table) }
    static func tableCSV(_ table: MarkdownTable) -> String { Builder.csv(table) }

    struct Control {
        enum Action { case copy(String), copyTable(MarkdownTable), toggleWrap(Int), toggleTable(Int), toggleDiagram(Int), retryDiagram(String), runShell(String) }
        var frame: CGRect
        var icon: IconName?
        var variant: ButtonView.Variant
        var action: Action
        /// A text button (Retry) in place of an icon.
        var title: String? = nil
    }

    /// Mermaid fences (ChatMarkdown.tsx:1013-1080): drawn as diagrams once the response settles (`enabled`),
    /// in the app's theme, except the blocks whose "Show code" toggle is on.
    public struct Diagrams: Equatable, Sendable {
        public var enabled: Bool
        /// The app's colors and font, which the diagram is drawn in.
        public var palette: MermaidDiagrams.Palette
        public var showingCode: Set<Int>
        /// The code block a streaming reply is still writing: it shows as code, without the view toggle.
        public var openIndex: Int?
        public init(enabled: Bool, palette: MermaidDiagrams.Palette, showingCode: Set<Int> = [], openIndex: Int? = nil) {
            self.enabled = enabled; self.palette = palette; self.showingCode = showingCode; self.openIndex = openIndex
        }
    }

    /// Code blocks in document order, nested ones included, as the layout numbers them.
    static func codeBlockCount(_ blocks: [MarkdownBlock]) -> Int {
        blocks.reduce(0) { n, b in
            switch b {
            case .code: n + 1
            case .blockquote(let c), .alert(_, let c): n + codeBlockCount(c)
            case .list(let l): n + l.items.reduce(0) { $0 + codeBlockCount($1.blocks) }
            default: n
            }
        }
    }

    /// Whether `text` ends inside an open code fence (`isClosedCodeFence`, ChatMarkdown.tsx:474-496): a fence of
    /// three or more backticks or tildes opens, and only a line of the same character, at least as long, closes it.
    // ponytail: fences inside block quotes count as text; parse quote markers if replies stream diagrams in quotes
    public static func endsInOpenFence(_ text: String) -> Bool {
        // A megabyte answer asks on every update: one pass over the bytes, the same lines as the split below.
        text.utf8.withContiguousStorageIfAvailable(endsInOpenFence(bytes:)) ?? endsInOpenFence(characters: text)
    }

    static func endsInOpenFence(characters text: String) -> Bool {
        var open: (Character, Int)?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard let c = trimmed.first, c == "`" || c == "~" else { continue }
            let run = trimmed.prefix { $0 == c }.count
            guard run >= 3 else { continue }
            if let (oc, ol) = open {
                if c == oc, run >= ol, trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) { open = nil }
            } else if c == "~" || !trimmed.dropFirst(run).contains("`") {
                open = (c, run)
            }
        }
        return open != nil
    }

    /// `endsInOpenFence` over UTF-8. Lines end at a lone `\n` or `\r`; a `\r\n` pair is one Character, which the split
    /// above doesn't treat as a separator, so neither does this. Fences, spaces and tabs are ASCII, so bytes compare as
    /// the Characters do.
    static func endsInOpenFence(bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        let backtick = UInt8(ascii: "`"), tilde = UInt8(ascii: "~")
        var open: (UInt8, Int)?
        var start = 0
        let count = bytes.count
        while start <= count {
            var end = start
            while end < count {
                let b = bytes[end]
                if b == lf, end == 0 || bytes[end - 1] != cr { break }
                if b == cr, end + 1 >= count || bytes[end + 1] != lf { break }
                end += 1
            }
            var i = start
            while i < end, bytes[i] == space || bytes[i] == tab { i += 1 }
            if i < end, bytes[i] == backtick || bytes[i] == tilde {
                let c = bytes[i]
                var run = 0
                while i + run < end, bytes[i + run] == c { run += 1 }
                if run >= 3 {
                    let rest = (i + run)..<end
                    if let (oc, ol) = open {
                        if c == oc, run >= ol, rest.allSatisfy({ bytes[$0] == space || bytes[$0] == tab }) { open = nil }
                    } else if c == tilde || !rest.contains(where: { bytes[$0] == backtick }) {
                        open = (c, run)
                    }
                }
            }
            start = end + 1
        }
        return open != nil
    }

    private(set) var items: [Item] = []
    private(set) var controls: [Control] = []
    /// File chips in drawing order, for hit testing.
    public private(set) var fileChips: [FileChip] = []
    /// Context chips in drawing order, for hit testing.
    public private(set) var contextChips: [MarkdownContextChip] = []
    /// Web link areas, one per line a link touches.
    public private(set) var links: [(frame: CGRect, url: URL)] = []
    /// The y of each top-level block, so a streaming update can redraw from its first changed block down.
    public private(set) var blockTops: [CGFloat] = []
    /// Code block and wide table bodies that scroll sideways, in drawing order.
    private(set) var scrollers: [(index: Int, viewport: CGRect, contentWidth: CGFloat)] = []
    /// The remote images and rendered diagrams, in drawing order: the views `MarkdownView` places over them.
    private(set) var images: [Item] = []
    /// Where drawing starts for each top-level block: its first item, and the selection offset, file chip and context chip
    /// counts the items before it reach. A draw pass walks only the blocks its rect touches.
    private(set) var drawStarts: [(item: Int, selection: Int, chip: Int, context: Int)] = []

    /// What a later layout of the same message reuses: its top-level blocks, where the flow stood
    /// after each, and the inputs every block's layout depends on.
    fileprivate private(set) var rootBlocks: [MarkdownBlock] = []
    fileprivate private(set) var rootEnds: [RootEnd] = []
    private var reuseKey: ReuseKey?
    fileprivate var expandedTables: Set<Int> = []
    /// The root block drawn without syntax colors: the code block a streaming answer ends with.
    fileprivate var plainRoot: Int?
    fileprivate var rootBoxes: [Box] = []
    /// The text boxes this layout made or took over for the blocks it laid out itself. Only a
    /// layout that reused an earlier one keeps them: that is a streaming answer, whose next update
    /// lays out its last block again and takes the boxes whose input did not change.
    fileprivate private(set) var textBoxes: [TextBoxCache.Key: MarkdownTextBox] = [:]
    /// How many text boxes came from `reusing` instead of TextKit (tests).
    private(set) var reusedTextBoxes = 0
    /// The flow after one top-level block: the items and controls so far, the y below the block,
    /// its own bottom margin (before the root zeroes the last one) and the next code block index.
    fileprivate struct RootEnd { var items: Int; var controls: Int; var y: CGFloat; var bottom: CGFloat; var codeIndex: Int; var tableIndex: Int; var mathIndex = 0; var innerBottom: CGFloat = 0 }
    private struct ReuseKey: Equatable {
        var unwrapped: Set<Int>, wrapsCode: Bool, bodyColor: NSColor?, cwd: String?, diagrams: Diagrams?, contexts: MarkdownContextChips?, fileLabels: [String: String]
        var runsShell: Bool
        var fitsExpandedTables: Bool
    }
    /// How many top-level blocks came from `reusing` instead of being laid out (tests).
    private(set) var reusedBlocks = 0

    /// `wrapsCode`: whether code blocks start wrapped (T3's `wordWrap` client setting, ChatMarkdown.tsx:555-557, 867).
    /// `unwrappedCode`: indices of code blocks whose wrap toggle flipped that. `bodyColor` replaces the
    /// 80% foreground of body text (user bubbles and plan cards draw at 100%). `cwd` anchors relative file
    /// paths (T3's `markdownCwd`: the thread's worktree or the project root); without it only absolute paths chip.
    /// `runsShell`: shell code blocks get "Run in terminal" (an assistant answer that finished, with a project).
    /// `fitsExpandedTables`: the markdown sits in a chat lane at least 36rem wide, where expanded tables fit the lane.
    /// `reusing`: the layout of an earlier version of this message at the same width. Its leading
    /// top-level blocks that did not change keep their layout, so a streaming answer lays out only
    /// its last blocks per update.
    /// `streaming`: a code block the answer ends with may still be open, so it shows plain until text follows it or the
    /// answer settles. Coloring it again on every token cost work in proportion to the whole fence.
    /// `parallel`: off the main thread, a long message lays out its top-level blocks in chunks on every core. The result is
    /// the same layout. On the main thread it stays serial, because a chunk may wait for the main thread (`onMain`).
    static var parallelBlocksForTests: Int { Builder.parallelBlocks }

    /// An empty layout `height` tall: what a view shows while its real layout is made in the background.
    init(placeholderWidth width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public init(document: MarkdownDocument, width: CGFloat, wrapsCode: Bool = true, unwrappedCode: Set<Int> = [], bodyColor: NSColor? = nil, cwd: String? = nil,
                expandedTables: Set<Int> = [], diagrams: Diagrams? = nil, contexts: MarkdownContextChips? = nil, runsShell: Bool = false,
                fitsExpandedTables: Bool = false, streaming: Bool = false, reusing previous: MarkdownLayout? = nil, parallel: Bool = false) {
        self.width = width
        self.expandedTables = expandedTables
        if streaming, case .code = document.blocks.last { plainRoot = document.blocks.count - 1 }
        let files = FileChipResolver(document: document, cwd: cwd)
        var builder = Builder(unwrapped: unwrappedCode, wrapsCode: wrapsCode, files: files.isEmpty ? nil : files,
                              boxes: TextBoxCache(previous: previous?.width == width ? previous?.textBoxes : nil, records: previous != nil))
        builder.expandedTables = expandedTables
        builder.contexts = contexts
        builder.diagrams = diagrams
        builder.cwd = cwd
        builder.runsShell = runsShell
        builder.fitsExpandedTables = fitsExpandedTables
        builder.plainRoot = plainRoot
        let key = ReuseKey(unwrapped: unwrappedCode, wrapsCode: wrapsCode, bodyColor: bodyColor, cwd: cwd, diagrams: diagrams, contexts: contexts, fileLabels: files.labelSuffixes,
                           runsShell: runsShell, fitsExpandedTables: fitsExpandedTables)
        if let previous, previous.width == width, previous.reuseKey == key { builder.previous = previous }
        let color = bodyColor ?? MarkdownStyle.body
        if parallel, builder.previous == nil, !Thread.isMainThread, document.blocks.count >= Builder.parallelBlocks {
            builder.precomputed = builder.rootBoxes(document.blocks, width: width, context: .init(color: color))
        }
        let flow = builder.flow(document.blocks, width: width, context: .init(color: bodyColor ?? MarkdownStyle.body), root: true)
        builder.precomputed = nil
        reusedBlocks = builder.reusedBlocks
        rootBoxes = builder.rootBoxes
        reuseKey = key
        textBoxes = builder.boxes.made
        reusedTextBoxes = builder.boxes.hits
        rootBlocks = document.blocks
        rootEnds = builder.rootEnds
        items = flow.items
        controls = flow.controls
        for item in items {
            switch item {
            case .fileChip(let chip): fileChips.append(chip)
            case .contextChip(let chip): contextChips.append(chip)
            case .link(let r, let url): links.append((r, url))
            case .scroll(let index, let viewport, let width): scrollers.append((index, viewport, width))
            case .remoteImage, .image: images.append(item)
            default: break
            }
        }
        height = flow.height
        blockTops = builder.rootTops
        var selection = 0, chip = 0, context = 0, next = 0
        drawStarts.reserveCapacity(rootEnds.count)
        for end in rootEnds {
            drawStarts.append((next, selection, chip, context))
            for item in items[next..<end.items] {
                switch item {
                case .text(let box, _): selection += box.length + 1
                case .fileChip: chip += 1
                case .contextChip: context += 1
                default: break
                }
            }
            next = end.items
        }
    }

    /// The items a draw pass over `rect` needs, with the counts the items before them reach. Glyphs and rings reach 8 pt
    /// past their block.
    func drawRange(_ rect: CGRect) -> (items: Range<Int>, selection: Int, chip: Int, context: Int) {
        guard drawStarts.count == rootEnds.count, drawStarts.count == blockTops.count, !rootEnds.isEmpty else { return (items.indices, 0, 0, 0) }
        // The first block whose bottom reaches the rect, and the first after it whose top lies below it.
        var lo = 0, hi = rootEnds.count
        while lo < hi { let mid = (lo + hi) / 2; if rootEnds[mid].y + 8 < rect.minY { lo = mid + 1 } else { hi = mid } }
        let first = lo
        hi = rootEnds.count
        while lo < hi { let mid = (lo + hi) / 2; if blockTops[mid] - 8 <= rect.maxY { lo = mid + 1 } else { hi = mid } }
        let end = lo
        guard first < end else { return (0..<0, 0, 0, 0) }
        let start = drawStarts[first]
        return (start.item..<rootEnds[end - 1].items, start.selection, start.chip, start.context)
    }
}

// MARK: - Block layout

/// A laid-out block: CSS margins (to collapse with neighbours), its border-box height, and its
/// content relative to its top-left.
fileprivate struct Box {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    /// The part of `top` and `bottom` that comes from descendants (a loose list item's `<p>`), which
    /// `.chat-markdown > :first-child` and `:last-child` don't zero.
    var innerTop: CGFloat = 0
    var innerBottom: CGFloat = 0
    var height: CGFloat = 0
    var items: [MarkdownLayout.Item] = []
    var controls: [MarkdownLayout.Control] = []
    var baseline: CGFloat?

    mutating func add(_ other: Box, at p: CGPoint) {
        items += other.items.map { $0.moved(by: p) }
        controls += other.controls.map { var c = $0; c.frame = c.frame.offsetBy(dx: p.x, dy: p.y); return c }
        if baseline == nil, let b = other.baseline { baseline = b + p.y }
    }
}

private struct Context {
    var color: NSColor
    var ulDepth = 0
    var olDepth = 0
}

private struct Builder {
    let unwrapped: Set<Int>
    let wrapsCode: Bool
    let files: FileChipResolver?
    var codeIndex = 0
    var tableIndex = 0
    /// Display formulas so far; each scrolls as `MarkdownMathStyle.scrollID(index)`.
    var mathIndex = 0
    var expandedTables: Set<Int> = []
    var previous: MarkdownLayout?
    var rootBoxes: [Box] = []
    var reusedBlocks = 0
    var diagrams: MarkdownLayout.Diagrams?
    var contexts: MarkdownContextChips?
    var cwd: String?
    var runsShell = false
    var fitsExpandedTables = false
    var plainRoot: Int?
    /// The code block being laid out is `plainRoot`.
    var drawsPlain = false
    var rootTops: [CGFloat] = []
    var rootEnds: [MarkdownLayout.RootEnd] = []

    var boxes: TextBoxCache
    /// Root boxes laid out ahead, with the code, table and display formula counts after each (`rootBoxes`).
    var precomputed: (boxes: [Box], ends: [(code: Int, table: Int, math: Int)])?

    init(unwrapped: Set<Int>, wrapsCode: Bool, files: FileChipResolver?, boxes: TextBoxCache) {
        self.unwrapped = unwrapped; self.wrapsCode = wrapsCode; self.files = files; self.boxes = boxes
    }

    /// Block children in normal flow. Margins between siblings collapse to the larger one; the first
    /// child's top and last child's bottom margin pass through to the parent (no border or padding
    /// stops them), except at the root, where T3 zeroes them (`.chat-markdown > :first-child`).
    /// Unchanged root blocks reuse their boxes, including blocks following a toggled table.
    mutating func flow(_ blocks: [MarkdownBlock], width: CGFloat, context: Context, root: Bool = false, tight: Bool = false) -> Box {
        var out = Box()
        var y: CGFloat = 0
        var previousBottom: CGFloat?
        func canReuse(_ index: Int, _ code: Int, _ table: Int) -> Bool {
            guard root, let previous, index < previous.rootBlocks.count else { return false }
            let oldCode = index == 0 ? 0 : previous.rootEnds[index - 1].codeIndex
            let oldTable = index == 0 ? 0 : previous.rootEnds[index - 1].tableIndex
            let oldMath = index == 0 ? 0 : previous.rootEnds[index - 1].mathIndex
            guard code == oldCode, table == oldTable, mathIndex == oldMath, blocks[index] == previous.rootBlocks[index] else { return false }
            // A code block laid out plain while it was open gets its colors once text follows it.
            if index == previous.plainRoot, index != plainRoot { return false }
            let tables = table..<previous.rootEnds[index].tableIndex
            return expandedTables.intersection(tables) == previous.expandedTables.intersection(tables)
        }
        var first = 0
        if root, let previous {
            while first < blocks.count, canReuse(first, codeIndex, tableIndex) {
                codeIndex = previous.rootEnds[first].codeIndex
                tableIndex = previous.rootEnds[first].tableIndex
                mathIndex = previous.rootEnds[first].mathIndex
                first += 1
            }
            if first > 0 {
                let end = previous.rootEnds[first - 1]
                out.items = Array(previous.items.prefix(end.items))
                out.controls = Array(previous.controls.prefix(end.controls))
                rootTops = Array(previous.blockTops.prefix(first))
                rootEnds = Array(previous.rootEnds.prefix(first))
                rootBoxes = Array(previous.rootBoxes.prefix(first))
                y = end.y
                previousBottom = end.bottom
                reusedBlocks = first
            }
        }
        for index in first..<blocks.count {
            var box: Box
            if root, let precomputed {
                box = precomputed.boxes[index]
                (codeIndex, tableIndex, mathIndex) = precomputed.ends[index]
            } else if canReuse(index, codeIndex, tableIndex), let previous {
                box = previous.rootBoxes[index]
                codeIndex = previous.rootEnds[index].codeIndex
                tableIndex = previous.rootEnds[index].tableIndex
                mathIndex = previous.rootEnds[index].mathIndex
                reusedBlocks += 1
            } else {
                drawsPlain = root && index == plainRoot
                box = layout(blocks[index], width: width, context: context, tight: tight)
                drawsPlain = false
            }
            if root { rootBoxes.append(box) }
            let ownBottom = box.bottom
            // The root zeroes its first and last child's own margins; a loose list item's `<p>` margin still shows.
            if root, index == 0 { y += box.innerTop; box.top = 0 }
            if root, index == blocks.count - 1 { box.bottom = 0 }
            if let previousBottom { y += max(previousBottom, box.top) } else { out.top = box.top }
            if root { rootTops.append(y) }
            out.add(box, at: CGPoint(x: 0, y: y))
            y += box.height
            previousBottom = box.bottom
            if root { rootEnds.append(.init(items: out.items.count, controls: out.controls.count, y: y, bottom: ownBottom, codeIndex: codeIndex, tableIndex: tableIndex, mathIndex: mathIndex, innerBottom: box.innerBottom)) }
        }
        out.bottom = previousBottom ?? 0
        out.height = y + (root ? rootEnds.last?.innerBottom ?? 0 : 0)
        return out
    }

    /// Messages with at least this many top-level blocks lay out in parallel chunks off the main thread.
    static let parallelBlocks = 48

    /// Lays out every root block at (0, 0) in parallel chunks. Each chunk starts from the code, table and display formula
    /// counts the blocks before it reach, which a cheap pass counts first. Nil when a chunk ends on other counts than
    /// the pass expected, and the caller lays out in series.
    func rootBoxes(_ blocks: [MarkdownBlock], width: CGFloat, context: Context) -> (boxes: [Box], ends: [(code: Int, table: Int, math: Int)])? {
        var code = 0, table = 0, math = 0
        func count(_ block: MarkdownBlock) {
            switch block {
            case .code: code += 1
            case .table: table += 1
            // Only a formula that typesets takes a scroll index (`displayMath`); this also warms the formula cache.
            case .math(let m): if MathRenderer.layout(m.tex, display: true, textSize: MarkdownStyle.fontSize) != nil { math += 1 }
            case .blockquote(let children), .alert(_, let children): children.forEach(count)
            case .list(let list): for item in list.items { item.blocks.forEach(count) }
            default: break
            }
        }
        var ends: [(code: Int, table: Int, math: Int)] = []
        ends.reserveCapacity(blocks.count)
        for block in blocks { count(block); ends.append((code, table, math)) }
        let chunks = min(blocks.count, ProcessInfo.processInfo.activeProcessorCount * 4)
        // Four workers: more of them hold the Objective-C runtime's locks often enough that the main thread's own layout
        // waits on them (a resize measured 100 to 180 ms stalls with eight on an M4).
        // ponytail: fixed at 4; tune with the large-reply stress test if layouts on many-core Macs feel slow to appear
        let workers = max(1, min(chunks, 4, ProcessInfo.processInfo.activeProcessorCount - 2))
        let template = self
        nonisolated(unsafe) var results = [[Box]?](repeating: nil, count: chunks)
        nonisolated(unsafe) var next = 0
        let lock = NSLock()
        nonisolated(unsafe) let appearance = NSAppearance.current ?? NSAppearance(named: .aqua)!
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
          appearance.performAsCurrentDrawingAppearance {
          while true {
            let chunk: Int = lock.withLock { defer { next += 1 }; return next }
            guard chunk < chunks else { return }
            let range = (blocks.count * chunk / chunks)..<(blocks.count * (chunk + 1) / chunks)
            var builder = template
            builder.boxes = TextBoxCache(previous: nil, records: false)
            builder.previous = nil
            if range.lowerBound > 0 { (builder.codeIndex, builder.tableIndex, builder.mathIndex) = ends[range.lowerBound - 1] }
            var out: [Box] = []
            out.reserveCapacity(range.count)
            for index in range {
                builder.drawsPlain = index == builder.plainRoot
                out.append(builder.layout(blocks[index], width: width, context: context, tight: false))
                builder.drawsPlain = false
                guard (builder.codeIndex, builder.tableIndex, builder.mathIndex) == ends[index] else { return }
            }
            lock.withLock { results[chunk] = out }
          }
          }
        }
        var boxes: [Box] = []
        boxes.reserveCapacity(blocks.count)
        for chunk in results {
            guard let chunk else { return nil }
            boxes += chunk
        }
        return (boxes, ends)
    }

    mutating func layout(_ block: MarkdownBlock, width: CGFloat, context: Context, tight: Bool) -> Box {
        switch block {
        case .paragraph(let runs):
            var box = text(runs, width: width, size: MarkdownStyle.fontSize, lineHeight: MarkdownStyle.lineHeight, color: context.color)
            // Tight list items hold their text inline, without a <p> and its margins.
            let m = tight ? 0 : MarkdownStyle.blockMargin
            box.top = m; box.bottom = m
            return box
        case .heading(let level, let runs):
            let size = MarkdownStyle.headingSizes[min(max(level, 1), 6) - 1]
            var box = text(runs, width: width, size: size, weight: .semibold, lineHeight: size * 1.3,
                           color: level == 6 ? MarkdownStyle.muted : MarkdownStyle.strong)
            box.top = MarkdownStyle.headingMargin.top
            box.bottom = MarkdownStyle.headingMargin.bottom
            return box
        case .list(let list):
            return self.list(list, width: width, context: context)
        case .blockquote(let children):
            // 3669 keeps the quote in the surrounding text color and draws the bar in that color at 35%,
            // `color-mix(in srgb, currentcolor 35%, transparent)` (index.css:1982-1990, 1df9c32943).
            let indent: CGFloat = 2 + 12.8
            let content = flow(children, width: width - indent, context: context)
            var box = Box(top: max(MarkdownStyle.blockMargin, content.top), bottom: max(MarkdownStyle.blockMargin, content.bottom), height: content.height)
            box.items.append(.box(CGRect(x: 0, y: 0, width: 2, height: content.height), fill: OKLab.mix(context.color, 0.35, .clear), border: nil, radius: 0))
            box.add(content, at: CGPoint(x: indent, y: 0))
            return box
        case .alert(let kind, let children):
            return alert(kind, children, width: width, context: context)
        case .code(let language, let title, let code):
            let index = codeIndex
            codeIndex += 1
            // MarkdownMermaidCodeBlock.tsx:30, 42: a closed mermaid fence shows its diagram unless "Show code" is on;
            // the fence a reply is still writing shows code without the toggle.
            let mermaid = language.lowercased() == "mermaid" && diagrams?.enabled == true && diagrams?.openIndex != index
            if mermaid, let diagrams, !diagrams.showingCode.contains(index), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return diagramBlock(code: code, index: index, palette: diagrams.palette, width: width)
            }
            return codeBlock(language: language, title: title, code: code, width: width, wraps: wrapsCode != unwrapped.contains(index),
                             viewToggle: mermaid, plain: drawsPlain)
        case .table(let table):
            return self.table(table, width: width, context: context)
        case .rule:
            // Preflight's hr: a 1px top border in --border, no margin.
            return Box(height: 1, items: [.box(CGRect(x: 0, y: 0, width: width, height: 1), fill: Themed.color(\.border), border: nil, radius: 0)])
        case .image(let alt, let url):
            // A standalone image sits on the paragraph's baseline. Until it decodes it holds the loading slot,
            // 16:9 and at most 30rem wide, and keeps it if it fails; once its size is known it takes its own box
            // (ChatMarkdown.tsx:1386-1400). Workspace images keep a 1px frame (`rounded-lg border border-border/40`).
            let strut = TextLine(NSAttributedString(string: " ", attributes: [.font: MarkdownStyle.font(MarkdownStyle.fontSize)]))
            let below = MarkdownStyle.lineHeight - strut.baseline(top: 0, lineHeight: MarkdownStyle.lineHeight)
            let source = MarkdownImageSource.classify(url.absoluteString, workspaceRoot: cwd)
            if InlineAudioSource.isAudio(name: url.absoluteString) {
                return Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin, height: 76 + below,
                           items: [.remoteImage(url, alt, CGRect(x: 0, y: 0, width: min(576, width), height: 76))])
            }
            // T3 3814 ChatMarkdown.tsx:1408-1412: an arbitrary host-file embed is a file chip.
            if case .workspaceFile = source, ![FilePreviewKind.image, .video, .audio].contains(FilePreviewKind.of(url.path)) {
                return layout(.paragraph([InlineRun(text: url.lastPathComponent, link: url)]), width: width, context: context, tight: tight)
            }
            let key = source.key
            if let natural = onMain({ MarkdownImages.failed.contains(key) ? nil : MarkdownImages.sizes[key] }) {
                let border: CGFloat = source.framed ? 1 : 0
                let size = MarkdownImages.displaySize(natural: natural, maxWidth: width, border: border)
                let rect = CGRect(origin: .zero, size: size)
                var items: [MarkdownLayout.Item] = []
                if source.framed { items.append(.box(rect, fill: nil, border: Themed.color(\.border, 0.4), radius: 10)) }
                items.append(.remoteImage(url, alt, rect.insetBy(dx: border, dy: border)))
                return Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin, height: size.height + below, items: items)
            }
            let w = min(width, MarkdownStyle.imageMaxWidth), h = w * 9 / 16
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            return Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin, height: h + below,
                       items: [.box(rect, fill: Themed.color(\.muted, 0.6), border: Themed.color(\.border, 0.4), radius: 10), .remoteImage(url, alt, rect)])
        case .math(let math):
            return displayMath(math, width: width, color: context.color)
        }
    }

    /// A display formula, centered, scrolling sideways when wider than `width` (MarkdownMath.tsx:20-58). A formula stage 1
    /// can't typeset shows its TeX as inline code, one chip per source line.
    mutating func displayMath(_ math: MarkdownMath, width: CGFloat, color: NSColor) -> Box {
        let size = MarkdownStyle.fontSize, font = MarkdownStyle.font(size)
        guard let layout = MathRenderer.layout(math.tex, display: true, textSize: size) else {
            var runs: [InlineRun] = []
            for (i, line) in math.copySource.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if i > 0 { runs.append(InlineRun(text: "\n", isBreak: true)) }
                if !line.isEmpty { runs.append(InlineRun(text: String(line), code: true)) }
            }
            var box = text(runs, width: width, size: size, lineHeight: MarkdownStyle.lineHeight, color: color)
            box.top = MarkdownStyle.blockMargin; box.bottom = MarkdownStyle.blockMargin
            return box
        }
        let index = mathIndex
        mathIndex += 1
        let (above, below) = MarkdownMathStyle.content(layout, parent: font, lineHeight: MarkdownStyle.lineHeight)
        let pad = MarkdownMathStyle.padX, padY = MarkdownMathStyle.padY
        // A `\tag` sits at the right edge; the formula stays centered, so the content reserves the tag's width on both sides.
        let tagRoom = layout.tag.map { $0.width + 0.5 * size * MathRenderer.scale } ?? 0
        let contentWidth = layout.width + 2 * pad + 2 * tagRoom
        let overflows = contentWidth > width + 1.0 / 64
        let height = padY + above + below + padY + (overflows ? MarkdownMathStyle.scrollbar : 0)
        var box = Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin, height: height, baseline: padY + above)
        let x = overflows ? pad + tagRoom : (width - layout.width) / 2
        // One no-break space as wide as the formula carries selection, copy (its TeX) and find; the `.math` item draws it.
        let placeholder = NSAttributedString(string: "\u{00A0}", attributes: [
            .font: font, .kern: layout.width - MarkdownStyle.noBreakSpaceWidth(font), .markdownMath: true, .markdownFindText: math.tex, .markdownCopyText: math.copySource])
        let textBox = boxes.make(placeholder, width: max(width, contentWidth), lineHeight: above + below, strut: font, wraps: false)
        let viewport = CGRect(x: 0, y: 0, width: width, height: height)
        if overflows { box.items.append(.scroll(codeIndex: MarkdownMathStyle.scrollID(index), viewport: viewport, contentWidth: contentWidth)) }
        box.items.append(.text(textBox, CGPoint(x: x, y: padY)))
        box.items.append(.math(layout, CGPoint(x: x, y: padY + above), color, clip: nil))
        if let tag = layout.tag { box.items.append(.math(tag, CGPoint(x: max(width, contentWidth) - pad - tag.width, y: padY + above), color, clip: nil)) }
        if overflows { box.items.append(.endClip) }
        return box
    }

    func text(_ runs: [InlineRun], width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, lineHeight: CGFloat,
              color: NSColor, alignment: NSTextAlignment = .natural, headIndent: CGFloat = 0, firstLineIndent: CGFloat? = nil,
              findable: Bool = true) -> Box {
        let inline = MarkdownStyle.inline(runs, size: size, weight: weight, color: color, alignment: alignment,
                                          headIndent: headIndent, firstLineIndent: firstLineIndent, files: files, contexts: contexts,
                                          maxChipWidth: width, findable: findable)
        let parent = MarkdownStyle.font(size, weight: weight)
        let textBox = boxes.make(inline.string, width: width, lineHeight: lineHeight, strut: parent,
                                 chipRanges: inline.code, chipFont: DSFont.mono(MarkdownStyle.chipFontSize),
                                 inlineBoxes: MarkdownMathStyle.inlineBoxes(inline, parent: parent, lineHeight: lineHeight))
        var box = Box(height: textBox.height, baseline: textBox.firstBaseline)
        box.items += MarkdownMathStyle.items(inline, in: textBox, parent: parent, color: color)
        for chip in textBox.chips {
            box.items.append(.box(chip, fill: ThreadDesign.inlineCodeFill, border: ThreadDesign.inlineCodeBorder, radius: MarkdownStyle.chipRadius))
        }
        box.items += Self.fileChips(inline, in: textBox, size: size, weight: weight)
        box.items += Self.contextChips(inline, in: textBox, size: size, weight: weight)
        box.items += Self.links(inline, in: textBox, lineHeight: lineHeight, size: size)
        box.items.append(.text(textBox, .zero))
        return box
    }

    /// Each favicon in its reserved space: `ms-[0.25em]`, 14px square, `vertical-align: -0.125em`.
    static func favicons(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, size: CGFloat) -> [MarkdownLayout.Item] {
        inline.favicons.compactMap { favicon in
            guard let span = textBox.spans(favicon.range).first else { return nil }
            return .favicon(favicon.host, CGRect(x: span.x0 + 0.25 * size, y: span.baseline + 0.125 * size - 14, width: 14, height: 14))
        }
    }

    /// Link areas, and the favicon at the start of each external link from the same spans (spans cost a CTLine per line).
    static func links(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, lineHeight: CGFloat, size: CGFloat) -> [MarkdownLayout.Item] {
        inline.links.flatMap { link in
            let spans = textBox.spans(link.range)
            var items = spans.map { span in
                MarkdownLayout.Item.link(CGRect(x: span.x0, y: span.baseline - lineHeight * 0.75, width: span.x1 - span.x0, height: lineHeight), link.url)
            }
            if let favicon = inline.favicons.first(where: { $0.range.location == link.range.location }), let span = spans.first {
                items.append(.favicon(favicon.host, CGRect(x: span.x0 + 0.25 * size, y: span.baseline + 0.125 * size - 14, width: 14, height: 14)))
            }
            return items
        }
    }

    /// Each context chip at its placeholder, `align-middle` like the file chips.
    static func contextChips(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, size: CGFloat, weight: NSFont.Weight) -> [MarkdownLayout.Item] {
        let top = FileChipStyle.top(parent: MarkdownStyle.font(size, weight: weight), size: size)
        return inline.contexts.compactMap { entry in
            guard let span = textBox.spans(entry.range).first else { return nil }
            var chip = entry.chip
            chip.frame.origin = CGPoint(x: span.x0, y: span.baseline + top)
            return .contextChip(chip)
        }
    }

    static func fileChips(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, size: CGFloat, weight: NSFont.Weight) -> [MarkdownLayout.Item] {
        let parent = MarkdownStyle.font(size, weight: weight)
        let top = FileChipStyle.top(parent: parent, size: size), height = FileChipStyle.height(size)
        let em = FileChipStyle.em(size), iconSize = ThreadDesign.uses3814 ? size : 1.17 * em
        return inline.files.compactMap { file in
            guard let span = textBox.spans(file.range).first else { return nil }
            let frame = CGRect(x: span.x0, y: span.baseline + top, width: span.x1 - span.x0, height: height)
            let icon = CGRect(x: frame.minX + (ThreadDesign.uses3814 ? 0 : 1 + 0.5 * em), y: frame.midY - iconSize / 2, width: iconSize, height: iconSize)
            return .fileChip(FileChip(frame: frame, icon: icon, meta: file.meta, label: file.label))
        }
    }

    // MARK: Lists

    mutating func list(_ list: MarkdownList, width: CGFloat, context: Context) -> Box {
        var inner = context
        if list.ordered { inner.olDepth += 1 } else { inner.ulDepth += 1 }
        let body = MarkdownStyle.font(MarkdownStyle.fontSize)
        // ChatMarkdown widens an ordered list's gutter to (digits + 2)ch when markers need two or more digits.
        var gutter = MarkdownStyle.listGutter
        if list.ordered {
            let digits = max(String(list.start).count, String(list.start + max(list.items.count - 1, 0)).count)
            if digits > 1 { gutter = CGFloat(digits + 2) * TextLine(NSAttributedString(string: "0", attributes: [.font: body])).width }
        }
        var out = Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin)
        var y: CGFloat = 0
        var previousBottom: CGFloat?
        for (index, item) in list.items.enumerated() {
            var content: Box
            if let checked = item.task {
                content = taskItem(item, checked: checked, width: width - gutter, gutter: gutter, context: inner)
            } else {
                // A loose list's items hold their text in a `<p>`, whose margins collapse with `li + li`.
                content = flow(item.blocks, width: width - gutter, context: inner, tight: !list.loose)
            }
            // `li + li { margin-top: 0.25rem }`, collapsing with whatever the item's first child brings.
            content.top = max(index == 0 ? 0 : MarkdownStyle.itemGap, content.top)
            if let previousBottom { y += max(previousBottom, content.top) } else { out.top = max(out.top, content.top); out.innerTop = content.top }
            if item.task == nil, !list.ordered, let baseline = content.baseline {
                // Blink's ListMarker: a bullet (ascent * 2/3 + 1) / 2 device px wide, its top 3(ascent - ascent * 2/3) / 2
                // below the ascent line, its right edge 8px before the content (measured).
                // ponytail: device pixels at 2x, like TextLine.baseline
                let ascent = Int((body.ascender * 2).rounded())
                let size = CGFloat((ascent * 2 / 3 + 1) / 2) / 2
                let top = y + baseline - CGFloat(ascent - 3 * (ascent - ascent * 2 / 3) / 2) / 2
                out.items.append(.symbol(min(inner.ulDepth, 3) - 1, CGRect(x: gutter - 8 - size, y: top, width: size, height: size), context.color))
            } else if item.task == nil, let baseline = content.baseline {
                let marker = NSAttributedString(string: markerText(list, index: index, context: inner), attributes: [
                    .font: list.ordered ? NSFont.monospacedDigitSystemFont(ofSize: MarkdownStyle.fontSize, weight: .regular) : body,
                    .foregroundColor: context.color])
                out.items.append(.glyphs(marker, baselineRight: CGPoint(x: gutter, y: y + baseline)))
            }
            out.add(content, at: CGPoint(x: gutter, y: y))
            y += content.height
            previousBottom = content.bottom
        }
        out.bottom = max(out.bottom, previousBottom ?? 0)
        out.innerBottom = previousBottom ?? 0
        out.height = y
        return out
    }

    /// The marker text Chromium paints outside the item: the counter or symbol plus a space.
    func markerText(_ list: MarkdownList, index: Int, context: Context) -> String {
        guard list.ordered else { return ["\u{2022} ", "\u{25E6} ", "\u{25AA} "][min(context.ulDepth, 3) - 1] }
        let n = list.start + index
        switch context.olDepth {
        case 1: return "\(n). "
        case 2: return "\(Self.alpha(n)). "
        default: return "\(Self.roman(n)). "
        }
    }

    static func alpha(_ n: Int) -> String {
        var n = n, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(UInt8(97 + n % 26))) + s; n /= 26 }
        return s
    }

    static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"),
                                      (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = n, s = ""
        for (value, numeral) in table { while n >= value { s += numeral; n -= value } }
        return s
    }

    /// A task item: the disabled checkbox sits inline where the bullet would be
    /// (`margin: 0 0.35em 0.15em calc(-1 * var(--list-gutter))`, `vertical-align: middle`), then a space.
    mutating func taskItem(_ item: MarkdownListItem, checked: Bool, width: CGFloat, gutter: CGFloat, context: Context) -> Box {
        let body = MarkdownStyle.font(MarkdownStyle.fontSize)
        let space = TextLine(NSAttributedString(string: " ", attributes: [.font: body])).width
        let lead = -gutter + 13 + 0.35 * MarkdownStyle.fontSize + space
        var blocks = item.blocks
        var box: Box
        if case .paragraph(let runs)? = blocks.first {
            blocks.removeFirst()
            // The first line starts after the box; the text box spans the full gutter so wrapped lines align.
            let first = text(runs, width: width + gutter, size: MarkdownStyle.fontSize, lineHeight: MarkdownStyle.lineHeight,
                             color: context.color, headIndent: gutter, firstLineIndent: gutter + lead)
            box = Box()
            box.add(first, at: CGPoint(x: -gutter, y: 0))
            box.height = first.height
            let rest = flow(blocks, width: width, context: context, tight: true)
            if !blocks.isEmpty { box.add(rest, at: CGPoint(x: 0, y: box.height + rest.top)); box.height += rest.top + rest.height }
        } else {
            box = flow(blocks, width: width, context: context, tight: true)
        }
        // vertical-align: middle puts the margin box's middle at baseline - x-height / 2.
        let baseline = box.baseline ?? TextLine(NSAttributedString(string: " ", attributes: [.font: body])).baseline(top: 0, lineHeight: MarkdownStyle.lineHeight)
        let marginBox = 13 + 0.15 * MarkdownStyle.fontSize
        let top = baseline - body.xHeight / 2 - marginBox / 2
        box.items.insert(.checkbox(CGRect(x: -gutter, y: top, width: 13, height: 13), checked: checked), at: 0)
        return box
    }

    // MARK: Alerts

    mutating func alert(_ kind: MarkdownAlertKind, _ children: [MarkdownBlock], width: CGFloat, context: Context) -> Box {
        let (label, icon, border, light, dark): (String, IconName, String, String, String) = switch kind {
        case .note: ("Note", .info, "blue-500", "blue-600", "blue-400")
        case .tip: ("Tip", .lightbulb, "emerald-500", "emerald-600", "emerald-400")
        case .important: ("Important", .messageSquareWarning, "purple-500", "purple-600", "purple-400")
        case .warning: ("Warning", .triangleAlert, "amber-500", "amber-600", "amber-500")
        case .caution: ("Caution", .octagonAlert, "red-500", "red-600", "red-400")
        }
        let indent: CGFloat = 2 + 12
        let titleColor = Themed.base(light, dark: dark)
        // Title: a flex <p> (so 10.4px margins) with a 14px icon, a 6px gap and the medium-weight label.
        // Find skips the title (`data-thread-find-ignore`, ChatMarkdown.tsx:2837).
        var title = text([InlineRun(text: label)], width: width - indent - 14 - 6, size: MarkdownStyle.fontSize, weight: .medium,
                         lineHeight: MarkdownStyle.lineHeight, color: titleColor, findable: false)
        title.items = title.items.map { $0.moved(by: CGPoint(x: 14 + 6, y: 0)) }
        title.items.append(.icon(icon, CGRect(x: 0, y: (MarkdownStyle.lineHeight - 14) / 2, width: 14, height: 14), titleColor))
        title.top = MarkdownStyle.blockMargin
        title.bottom = MarkdownStyle.blockMargin
        var titleAndBody = Box()
        let body = flow(children, width: width - indent, context: context)
        titleAndBody.add(title, at: .zero)
        let gap = children.isEmpty ? 0 : max(title.bottom, body.top)
        titleAndBody.add(body, at: CGPoint(x: 0, y: title.height + gap))
        titleAndBody.height = title.height + (children.isEmpty ? 0 : gap + body.height)
        // `my-1 border-l-2 pl-3`: 4px margins that collapse with the children's.
        var box = Box(top: max(4, title.top), bottom: max(4, children.isEmpty ? title.bottom : body.bottom), height: titleAndBody.height)
        box.items.append(.box(CGRect(x: 0, y: 0, width: 2, height: titleAndBody.height), fill: Themed.base(border, 0.7), border: nil, radius: 0))
        box.add(titleAndBody, at: CGPoint(x: indent, y: 0))
        return box
    }

    /// A code block's text with its token colors. Neither depends on the width or the appearance (the colors are
    /// dynamic), so long blocks keep theirs: a window resize or reopening the thread lays out again without lexing
    /// again. Lexing an 18,000 line block took 0.1 s of every layout.
    // ponytail: the last 16 blocks of 2,000 UTF-16 units or more; key by something cheaper than the text if it shows in profiles
    nonisolated(unsafe) private static var coloredCodeCache: [ColoredCodeKey: NSAttributedString] = [:]
    nonisolated(unsafe) fileprivate static var coloredCodeOrder: [ColoredCodeKey] = []
    fileprivate static let coloredCodeLock = NSLock()
    nonisolated(unsafe) private static var italics: [NSFont: NSFont] = [:]
    struct ColoredCodeKey: Hashable { var code: String; var language: String; var font: NSFont }

    /// `plain` skips the tokens and the cache: an open code block of a streaming answer changes with every token.
    static func coloredCode(_ code: String, language: String, font: NSFont, plain: Bool = false) -> NSAttributedString {
        let cached = !plain && code.utf16.count >= 2_000
        let key = ColoredCodeKey(code: code, language: language, font: font)
        if cached, let hit = coloredCodeLock.withLock({ coloredCodeCache[key] }) { return hit }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = []
        // Chromium's default tab-size is 8 spaces.
        paragraph.defaultTabInterval = 8 * TextLine(NSAttributedString(string: " ", attributes: [.font: font])).width
        paragraph.tabStops = []
        // The paragraph style goes in before the tokens split the string into runs: added after, it rebuilt
        // every run's attributes, 0.1 s for an 18,000 line block.
        let string = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: CodeTokenKind.plain.color,
                                                                          .paragraphStyle: paragraph])
        // ponytail: NSFontManager off the main thread, under a lock and once per font; fall back to descriptor traits if it ever asserts
        let italic = coloredCodeLock.withLock {
            if let hit = italics[font] { return hit }
            let made = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            italics[font] = made
            return made
        }
        for token in plain ? [] : CodeHighlighter.tokens(code, language: language) {
            string.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            if token.kind == .emphasis { string.addAttribute(.font, value: italic, range: token.range) }
        }
        guard cached else { return string }
        let frozen = string.copy() as! NSAttributedString
        coloredCodeLock.withLock {
            if coloredCodeCache.updateValue(frozen, forKey: key) == nil { coloredCodeOrder.append(key) }
            if coloredCodeOrder.count > 16 { coloredCodeCache[coloredCodeOrder.removeFirst()] = nil }
        }
        return frozen
    }

    // MARK: Code blocks

    mutating func codeBlock(language: String, title: String?, code: String, width: CGFloat, wraps: Bool, viewToggle: Bool = false,
                            plain: Bool = false) -> Box {
        let p = MarkdownStyle.codePadding
        let font = DSFont.mono(MarkdownStyle.codeFontSize)
        let string = Self.coloredCode(code, language: language, font: font, plain: plain)
        let inner = width - 2 - 2 * p.x
        let textBox = boxes.make(string, width: inner, lineHeight: MarkdownStyle.codeLineHeight, strut: font, wraps: wraps)
        // Chromium's scroll width counts both inline paddings; the classic scrollbar takes its 7px below them.
        let contentWidth = textBox.usedWidth + 2 * p.x
        let overflows = !wraps && contentWidth > width - 2 + 1.0 / 64
        let height = 1 + MarkdownStyle.codeHeader + p.y + textBox.height + p.y + (overflows ? MarkdownStyle.codeScrollbar : 0) + 1
        var box = Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin, height: height)
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        // Light: 1px border at 70% on --secondary. Dark: a transparent border on --input at 32%.
        // Classic Glass: a dense pane, so code reads as on a solid card.
        box.items.append(.box(frame, fill: WindowGlass.pick(stock: Themed.color(light: \.secondary, 1, dark: \.input, 0.32),
                                                            frost: WindowGlass.denseFill),
                              border: WindowGlass.pick(stock: Themed.color(light: \.border, 0.7, dark: \.border, 0), frost: WindowGlass.edge),
                              radius: ThreadDesign.uses3814 ? 8 : 10))
        // Header: `pt-1.5 pr-1.5 pl-3`, the 24px buttons set its height; title 11px mono at 72% foreground.
        // `MarkdownCodeBlockTitleContent` (ChatMarkdown.tsx:801-840): a fence title shows its file icon and the title; a bare
        // language shows only the icon of a file in that language (`syntheticFileNameForLanguageId`, pierre-icons.ts:123-169),
        // or the language's name when no specific icon exists.
        let titleFont = DSFont.mono(11)
        let iconPath = title ?? Self.syntheticFileName(language: language)
        let showsIcon = title != nil || FileTypeIcon.token(for: iconPath) != "default"
        if showsIcon { box.items.append(.fileIcon(iconPath, CGRect(x: 1 + 12, y: 1 + 6 + 5, width: 14, height: 14))) }
        let labelX: CGFloat = title != nil ? 1 + 12 + 14 + 6 : 1 + 12
        // Find skips the header (`THREAD_FIND_IGNORE_PROPS`, ChatMarkdown.tsx:746, 959).
        let label = NSAttributedString(string: title ?? (showsIcon ? "" : language), attributes: [
            .font: titleFont, .foregroundColor: Themed.color(\.contrastForeground, 0.72), .markdownFindText: ""])
        let labelLine = 11 * 1.375
        let command = runsShell ? Self.runnableCommand(language: language, code: code) : nil
        let actions: CGFloat = 50 + (command == nil ? 0 : 26) + (viewToggle ? 26 : 0)
        if label.length > 0 {
            let titleBox = boxes.make(label, width: width - labelX - 6 - actions - 8, lineHeight: labelLine, strut: titleFont, wraps: false)
            box.items.append(.text(titleBox, CGPoint(x: labelX, y: 1 + 6 + (24 - labelLine) / 2)))
        }
        let copyX = width - 1 - 6 - 24
        // Wrap, "Run in terminal", the mermaid view toggle, copy (MarkdownCodeBlock.tsx:240-284), 24px buttons 2px
        // apart, so "Show diagram" sits where the diagram face has "Show code" (5a4e998053).
        var x = copyX
        if viewToggle {
            x -= 26
            box.controls.append(.init(frame: CGRect(x: x, y: 1 + 6, width: 24, height: 24), icon: .workflow, variant: .ghostMuted,
                                      action: .toggleDiagram(codeIndex - 1)))
        }
        if let command {
            x -= 26
            box.controls.append(.init(frame: CGRect(x: x, y: 1 + 6, width: 24, height: 24), icon: .play, variant: .ghostMuted,
                                      action: .runShell(command)))
        }
        box.controls.append(.init(frame: CGRect(x: x - 26, y: 1 + 6, width: 24, height: 24), icon: .textWrap,
                                  variant: wraps ? .secondary : .ghostMuted, action: .toggleWrap(codeIndex - 1)))
        box.controls.append(.init(frame: CGRect(x: copyX, y: 1 + 6, width: 24, height: 24), icon: .copy, variant: .ghostMuted, action: .copy(code)))
        let body = CGRect(x: 1, y: 1 + MarkdownStyle.codeHeader, width: width - 2, height: height - 2 - MarkdownStyle.codeHeader)
        if !wraps { box.items.append(.scroll(codeIndex: codeIndex - 1, viewport: body, contentWidth: overflows ? contentWidth : body.width)) }
        box.items.append(.text(textBox, CGPoint(x: 1 + p.x, y: 1 + MarkdownStyle.codeHeader + p.y)))
        if !wraps { box.items.append(.endClip) }
        return box
    }

    /// `syntheticFileNameForLanguageId` (pierre-icons.ts:123-169).
    static func syntheticFileName(language: String) -> String {
        let id = language.lowercased()
        if id == "dockerfile" { return "Dockerfile" }
        let aliases = ["bash": "sh", "csharp": "cs", "elixir": "ex", "haskell": "hs", "javascript": "js", "jsx": "jsx", "kotlin": "kt",
                       "markdown": "md", "mdx": "mdx", "plaintext": "txt", "powershell": "ps1", "python": "py", "ruby": "rb", "rust": "rs",
                       "shell": "sh", "shellscript": "sh", "swift": "swift", "typescript": "ts", "tsx": "tsx", "yaml": "yml"]
        return "file." + (aliases[id] ?? id)
    }

    /// `canRun` (ChatMarkdown.tsx:872-881): a shell fence whose trimmed text is not empty, does not end in a line
    /// continuation and holds no control or invisible format characters (so one line: `\n` is a control character).
    /// `code` here has lost the fence's final newline, which T3 checks for and then leaves out of the test.
    // ponytail: T3 also requires a closed fence (isClosedCodeFence); a finished answer ending in an unclosed shell fence shows Run here
    static func runnableCommand(language: String, code: String) -> String? {
        guard ["sh", "bash", "zsh", "fish", "shell", "powershell", "pwsh"].contains(language) else { return nil }
        let command = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.hasSuffix("\\"),
              !code.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
        else { return nil }
        return command
    }

    /// The diagram face of `MarkdownCodeBlock` (MarkdownCodeBlock.tsx:223-232): `my-[0.65rem]` in a transparent 1px
    /// border, a `pt-1.5 pr-1.5` row with "Show code" and copy at the right, then the diagram centered at most the
    /// column's width (pele's `max-width:100%`, MermaidDiagram.tsx:271-290). While it first renders, the source holds
    /// its space as an invisible `<pre>` (MarkdownMermaidCodeBlock.tsx:64-69); a failure shows the message above the
    /// source, with Retry when the renderer failed to load (MermaidDiagram.tsx:257-269, 294-320).
    func diagramBlock(code: String, index: Int, palette: MermaidDiagrams.Palette, width: CGFloat) -> Box {
        var box = Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin)
        // Find counts the source, not the diagram's own labels.
        box.items.append(.hiddenText(code, codeIndex: index))
        let ignored: [NSAttributedString.Key: Any] = [.markdownFindText: ""]
        box.controls.append(.init(frame: CGRect(x: width - 1 - 6 - 24 - 2 - 24, y: 1 + 6, width: 24, height: 24), icon: .code,
                                  variant: .ghostMuted, action: .toggleDiagram(index)))
        box.controls.append(.init(frame: CGRect(x: width - 1 - 6 - 24, y: 1 + 6, width: 24, height: 24), icon: .copy, variant: .ghostMuted,
                                  action: .copy(code)))
        let top: CGFloat = 1 + 6 + 24, inner = max(0, width - 2)
        var y: CGFloat = 0
        switch onMain({ MermaidDiagrams.shared.result(code, palette: palette, width: inner) }) {
        case .rendered(let image, let size)?:
            let w = min(size.width, inner), h = size.width > 0 ? (size.height * w / size.width).rounded() : 0
            box.items.append(.image(image, CGRect(x: 1 + ((inner - w) / 2).rounded(), y: top, width: w, height: h)))
            y = h
        case .failed(let message, let retryable)?:
            let font = DSFont.ui(12)
            let line = NSAttributedString(string: "Unable to render diagram: \(message)", attributes: [.font: font, .foregroundColor: Themed.color(\.destructive)].merging(ignored) { $1 })
            let error = MarkdownTextBox(line, width: inner - (retryable ? 64 : 0), lineHeight: 16, strut: font)
            box.items.append(.text(error, CGPoint(x: 1, y: top)))
            if retryable {
                box.controls.append(.init(frame: CGRect(x: 1 + inner - 56, y: top, width: 56, height: 24), icon: nil, variant: .ghost,
                                          action: .retryDiagram(code), title: "Retry"))
            }
            let mono = DSFont.mono(12)
            let source = MarkdownTextBox(NSAttributedString(string: code, attributes: [.font: mono, .foregroundColor: MarkdownStyle.body].merging(ignored) { $1 }),
                                         width: inner, lineHeight: 16, strut: mono)
            let sourceTop = max(error.height, retryable ? 24 : 0) + 8
            box.items.append(.text(source, CGPoint(x: 1, y: top + sourceTop)))
            y = sourceTop + source.height
        case nil:
            // `.chat-markdown pre`: `0.65rem` margins, a 1px border and `0.8rem` padding around the code's lines.
            let lines = CGFloat(code.split(separator: "\n", omittingEmptySubsequences: false).count)
            y = 2 * MarkdownStyle.blockMargin + 2 + 2 * 12.8 + lines * MarkdownStyle.codeLineHeight
        }
        box.height = top + y + 1
        return box
    }

    // MARK: Tables

    /// `MarkdownTable`: 12px cells with `0.45rem 0.75rem` padding (header `0.55rem` block padding, weight 600),
    /// none before the first column or after the last since 3669 (index.css:2138-2152, 2d620f5dcc), a 1px
    /// bottom rule at 60% border under every row, then the expand and copy buttons 2px below.
    mutating func table(_ table: MarkdownTable, width: CGFloat, context: Context) -> Box {
        let index = tableIndex
        tableIndex += 1
        let modern = ThreadDesign.uses3814
        let expanded = modern || expandedTables.contains(index)
        let columns = table.alignments.count
        let size = MarkdownStyle.tableFontSize, line = MarkdownStyle.tableLineHeight
        func cellString(_ runs: [InlineRun], header: Bool, column: Int) -> MarkdownStyle.Inline {
            let alignment: NSTextAlignment = switch table.alignments[column] {
            case .center: .center
            case .right: .right
            default: .left
            }
            return MarkdownStyle.inline(runs, size: size, weight: header ? .semibold : .regular, color: context.color, alignment: alignment, files: files, contexts: contexts)
        }
        func natural(_ s: NSAttributedString) -> CGFloat {
            boxes.make(s, width: 0, lineHeight: line, strut: MarkdownStyle.font(size), wraps: false).usedWidth
        }
        var widths = [CGFloat](repeating: 0, count: columns)
        for row in [table.header] + table.rows {
            for (c, runs) in row.enumerated() where c < columns {
                let n = natural(cellString(runs, header: row == table.header, column: c).string)
                widths[c] = max(widths[c], min(384, n + MarkdownLayout.tableCellPadding(c, of: columns).total))
            }
        }
        let total = widths.reduce(0, +)
        if total < width, total > 0 { widths = widths.map { $0 + (width - total) * $0 / total } }
        var tableWidth = max(width, total)
        let wraps = modern || expanded && fitsExpandedTables
        if expanded {
            (widths, tableWidth) = MarkdownLayout.expandedTableWidths(([table.header] + table.rows).enumerated().map { r, row in
                row.prefix(columns).enumerated().map { c, runs in cellString(runs, header: r == 0, column: c).string }
            }, columns: columns, width: width, fitsLane: wraps, natural: natural)
        }

        var box = Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin)
        var y: CGFloat = 0
        let rule = Themed.color(\.contrastBorder, 0.6)
        for (r, row) in ([table.header] + table.rows).enumerated() {
            let padY: CGFloat = r == 0 ? 8.8 : 7.2
            var x: CGFloat = 0
            var rowHeight = line
            var cells: [(Box, CGFloat)] = []
            for c in 0..<columns {
                let runs = c < row.count ? row[c] : []
                let inline = cellString(runs, header: r == 0, column: c)
                let s = inline.string, chips = inline.code
                let displayed = NSMutableAttributedString(attributedString: s)
                if !expanded || (r == 0 && !wraps), displayed.length > 0 {
                    let paragraph = (displayed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    paragraph.lineBreakMode = .byTruncatingTail
                    displayed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: displayed.length))
                }
                let padding = MarkdownLayout.tableCellPadding(c, of: columns)
                let cellFont = MarkdownStyle.font(size, weight: r == 0 ? .semibold : .regular)
                let textBox = boxes.make(displayed, width: widths[c] - padding.total, lineHeight: line, strut: MarkdownStyle.font(size),
                                         chipRanges: chips, chipFont: DSFont.mono(MarkdownStyle.chipFontSize),
                                         inlineBoxes: MarkdownMathStyle.inlineBoxes(inline, parent: cellFont, lineHeight: line))
                var cell = Box(height: textBox.height)
                cell.items += MarkdownMathStyle.items(inline, in: textBox, parent: cellFont, color: context.color)
                for chip in textBox.chips {
                    cell.items.append(.box(chip, fill: ThreadDesign.inlineCodeFill, border: ThreadDesign.inlineCodeBorder, radius: MarkdownStyle.chipRadius))
                }
                cell.items += Self.fileChips(inline, in: textBox, size: size, weight: r == 0 ? .semibold : .regular)
                cell.items += Self.contextChips(inline, in: textBox, size: size, weight: r == 0 ? .semibold : .regular)
                cell.items += Self.favicons(inline, in: textBox, size: size)
                cell.items.append(.text(textBox, .zero))
                rowHeight = max(rowHeight, textBox.height)
                cells.append((cell, x + padding.lead))
                x += widths[c]
            }
            for (cell, cx) in cells { box.add(cell, at: CGPoint(x: cx, y: y + padY)) }
            y += padY * 2 + rowHeight
            box.items.append(.box(CGRect(x: 0, y: y, width: tableWidth, height: 1), fill: rule, border: nil, radius: 0))
            y += 1
        }
        // Negative scroll IDs keep table and code state separate while sharing the input and scrollbar paths.
        let viewport = CGRect(x: 0, y: 0, width: width, height: y + (tableWidth > width ? MarkdownStyle.codeScrollbar : 0))
        box.items.insert(.scroll(codeIndex: -index - 1, viewport: viewport, contentWidth: tableWidth), at: 0)
        box.items.append(.endClip)
        // Classic Glass sets the table on a dense pane, below the faded content.
        box.items.insert(.box(viewport, fill: WindowGlass.pick(stock: .clear, frost: WindowGlass.denseFill),
                              border: WindowGlass.pick(stock: .clear, frost: WindowGlass.edge), radius: 8), at: 0)
        y = viewport.maxY
        // Nightly 3824 wraps cells directly and keeps only Copy (MarkdownTable.tsx:29-34, #26449).
        // Redesign and Glass retain their table controls.
        if !modern {
            box.controls.append(.init(frame: CGRect(x: 0, y: y + 2, width: 24, height: 24), icon: expanded ? .minimize2 : .maximize2,
                                      variant: expanded ? .secondary : .ghostMuted, action: .toggleTable(index)))
        }
        box.controls.append(.init(frame: CGRect(x: width - 24, y: y + 2, width: 24, height: 24), icon: .copy, variant: .ghostMuted,
                                  action: .copyTable(table)))
        box.height = y + 2 + 24
        return box
    }

    static func csv(_ table: MarkdownTable) -> String {
        ([table.header] + table.rows).map { row in
            row.map { runs in
                let text = runs.map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return text.contains(",") || text.contains("\"") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    /// "Copy as Markdown" for a table.
    static func markdown(_ table: MarkdownTable) -> String {
        func row(_ cells: [[InlineRun]]) -> String {
            "| " + cells.map { runs in
                runs.map { run in
                    var text = run.text.replacingOccurrences(of: "\n", with: " ")
                    if run.code {
                        let fence = text.contains("`") ? "``" : "`"
                        text = fence + text + fence
                    }
                    if run.bold { text = "**" + text + "**" }
                    if run.italic { text = "_" + text + "_" }
                    if run.strikethrough { text = "~~" + text + "~~" }
                    if let link = run.link { text = "[" + text + "](" + link.absoluteString + ")" }
                    return text
                }.joined().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|", with: "\\|")
            }.joined(separator: " | ") + " |"
        }
        let rule = "| " + table.alignments.map { a -> String in
            switch a {
            case .left: "---"
            case .center: ":---:"
            case .right: "---:"
            case .none: "---"
            }
        }.joined(separator: " | ") + " |"
        return ([row(table.header), rule] + table.rows.map(row)).joined(separator: "\n")
    }
}

extension MarkdownLayout {
    /// Column widths of an expanded table, cell padding included, and the table's width. Headers lose the 24rem cap,
    /// body cells keep it (index.css:2151-2162). Without `fitsLane` the table keeps `min-width: max-content` and
    /// scrolls. With it, a lane at least 36rem wide (index.css:2164-2178, T3 f8b06c5fd0) drops that minimum, so
    /// headers wrap and the table shrinks to the lane, each column giving up its room above its longest word in
    /// proportion, as Chromium's auto table layout does. The table only overflows when the longest words don't fit.
    private static let unbroken = try! NSRegularExpression(pattern: "\\S+")

    /// A cell's `0.75rem` side padding, without the first column's leading or the last column's trailing
    /// side (`:is(th, td):first-child` and `:last-child`, index.css:2146-2152).
    static func tableCellPadding(_ column: Int, of columns: Int) -> (lead: CGFloat, total: CGFloat) {
        let lead: CGFloat = column == 0 ? 0 : 12, trail: CGFloat = column == columns - 1 ? 0 : 12
        return (lead, lead + trail)
    }

    static func expandedTableWidths(_ rows: [[NSAttributedString]], columns: Int, width: CGFloat, fitsLane: Bool,
                                    natural: (NSAttributedString) -> CGFloat) -> (widths: [CGFloat], tableWidth: CGFloat) {
        var mins = [CGFloat](repeating: 0, count: columns), maxs = mins
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() where c < columns {
                var hasFormula = false
                if ThreadDesign.uses3814 {
                    cell.enumerateAttribute(.markdownMath, in: NSRange(location: 0, length: cell.length)) { value, _, stop in
                        if value != nil { hasFormula = true; stop.pointee = true }
                    }
                }
                let cap: CGFloat = hasFormula ? .infinity : ThreadDesign.uses3814 ? 384 : r == 0 ? .infinity : 384
                let padding = tableCellPadding(c, of: columns).total
                maxs[c] = max(maxs[c], min(cap, natural(cell) + padding))
                guard fitsLane else { continue }
                // ponytail: breaks only at spaces, not after hyphens, add UAX 14 opportunities if a column comes out wide
                let longest = Self.unbroken.matches(in: cell.string, range: NSRange(location: 0, length: cell.length))
                    .map { match -> CGFloat in
                        let word = cell.attributedSubstring(from: match.range)
                        if ThreadDesign.uses3814, word.length > 16, word.attribute(.markdownExternalLink, at: 0, effectiveRange: nil) != nil {
                            return word.string.indices.map { index in
                                let end = word.string.index(after: index)
                                return natural(word.attributedSubstring(from: NSRange(index..<end, in: word.string)))
                            }.max() ?? 0
                        }
                        return natural(word)
                    }.max() ?? 0
                mins[c] = max(mins[c], min(cap, longest + padding))
            }
        }
        let maxSum = maxs.reduce(0, +), minSum = mins.reduce(0, +)
        var widths = maxs
        if maxSum < width, maxSum > 0 {
            widths = maxs.map { $0 + (width - maxSum) * $0 / maxSum }
        } else if fitsLane, maxSum > width {
            let room = max(0, width - minSum), spread = maxSum - minSum
            widths = zip(mins, maxs).map { lo, hi in spread > 0 ? lo + room * (hi - lo) / spread : lo }
        }
        return (widths, max(width, widths.reduce(0, +)))
    }
    /// The code of the cached colored blocks, oldest first (tests).
    static var coloredCodeKeys: [String] { Builder.coloredCodeLock.withLock { Builder.coloredCodeOrder.map(\.code) } }
}

private extension MarkdownLayout.Item {
    func moved(by p: CGPoint) -> MarkdownLayout.Item {
        switch self {
        case .text(let box, let o): .text(box, CGPoint(x: o.x + p.x, y: o.y + p.y))
        case .box(let r, let fill, let border, let radius): .box(r.offsetBy(dx: p.x, dy: p.y), fill: fill, border: border, radius: radius)
        case .glyphs(let s, let o): .glyphs(s, baselineRight: CGPoint(x: o.x + p.x, y: o.y + p.y))
        case .symbol(let kind, let r, let color): .symbol(kind, r.offsetBy(dx: p.x, dy: p.y), color)
        case .checkbox(let r, let checked): .checkbox(r.offsetBy(dx: p.x, dy: p.y), checked: checked)
        case .icon(let name, let r, let color): .icon(name, r.offsetBy(dx: p.x, dy: p.y), color)
        case .fileIcon(let path, let r): .fileIcon(path, r.offsetBy(dx: p.x, dy: p.y))
        case .fileChip(let chip):
            .fileChip(FileChip(frame: chip.frame.offsetBy(dx: p.x, dy: p.y), icon: chip.icon.offsetBy(dx: p.x, dy: p.y), meta: chip.meta, label: chip.label))
        case .contextChip(var chip): { chip.frame = chip.frame.offsetBy(dx: p.x, dy: p.y); return .contextChip(chip) }()
        case .clip(let r): .clip(r.offsetBy(dx: p.x, dy: p.y))
        case .scroll(let index, let r, let w): .scroll(codeIndex: index, viewport: r.offsetBy(dx: p.x, dy: p.y), contentWidth: w)
        case .endClip: .endClip
        case .link(let r, let url): .link(r.offsetBy(dx: p.x, dy: p.y), url)
        case .favicon(let host, let r): .favicon(host, r.offsetBy(dx: p.x, dy: p.y))
        case .math(let layout, let o, let color, let clip): .math(layout, CGPoint(x: o.x + p.x, y: o.y + p.y), color, clip: clip?.offsetBy(dx: p.x, dy: p.y))
        case .hiddenText: self
        case .image(let image, let r): .image(image, r.offsetBy(dx: p.x, dy: p.y))
        case .remoteImage(let url, let alt, let r): .remoteImage(url, alt, r.offsetBy(dx: p.x, dy: p.y))
        }
    }
}

/// Text boxes keyed by everything that shapes them, so a streaming answer's next layout takes the
/// ones whose text did not change (table cells and list items above the growing end) instead of
/// running TextKit again. A layout that does not record makes boxes as before.
final class TextBoxCache {
    struct Key: Hashable {
        var string: NSAttributedString
        var width: CGFloat
        var lineHeight: CGFloat
        var strut: NSFont
        var chipRanges: [NSRange]
        var chipFont: NSFont?
        var wraps: Bool
    }

    private let previous: [Key: MarkdownTextBox]
    private let records: Bool
    private(set) var made: [Key: MarkdownTextBox] = [:]
    private(set) var hits = 0

    init(previous: [Key: MarkdownTextBox]?, records: Bool) {
        self.previous = previous ?? [:]
        self.records = records
    }

    /// `inlineBoxes` follow from the string (its formulas), so they stay out of the key.
    func make(_ string: NSAttributedString, width: CGFloat, lineHeight: CGFloat, strut: NSFont,
              chipRanges: [NSRange] = [], chipFont: NSFont? = nil, wraps: Bool = true,
              inlineBoxes: [(index: Int, above: CGFloat, below: CGFloat)] = []) -> MarkdownTextBox {
        guard records else {
            return MarkdownTextBox(string, width: width, lineHeight: lineHeight, strut: strut, chipRanges: chipRanges, chipFont: chipFont, wraps: wraps,
                                   inlineBoxes: inlineBoxes)
        }
        let key = Key(string: string, width: width, lineHeight: lineHeight, strut: strut, chipRanges: chipRanges, chipFont: chipFont, wraps: wraps)
        // A lazy box from an earlier layout may be laying out on the main thread right now.
        if let box = made[key] ?? previous[key], Thread.isMainThread || !box.isLazy {
            hits += 1
            made[key] = box
            return box
        }
        let box = MarkdownTextBox(string, width: width, lineHeight: lineHeight, strut: strut, chipRanges: chipRanges, chipFont: chipFont, wraps: wraps,
                                  inlineBoxes: inlineBoxes)
        made[key] = box
        return box
    }
}
