import AppKit
import DesignSystem

extension NSAttributedString.Key {
    /// What find in thread matches in place of these characters, as T3 indexes the rendered page
    /// (packages/shared/src/threadFindText.ts): a chip's label, "" for what only draws (favicons, image
    /// alt text, code block titles), "\u{0}" where T3 starts a new text segment.
    static let markdownFindText = NSAttributedString.Key("CandyMarkdownFindText")
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
    static let chipFontSize: CGFloat = 12
    static let chipPaddingX: CGFloat = 5.6
    static let chipPaddingY: CGFloat = 1.6
    static let chipRadius: CGFloat = 6
    /// Code blocks: 13px mono at `leading-snug`, `padding: 0.8rem 0.9rem`, 30px header.
    static let codeFontSize: CGFloat = 13
    static var codeLineHeight: CGFloat { 13 * FontRuntime.codeScale * 1.375 }
    static let codePadding = (x: CGFloat(14.4), y: CGFloat(12.8))
    static let codeHeader: CGFloat = 30
    /// `.chat-markdown pre::-webkit-scrollbar { height: var(--app-scrollbar-width) }`, 6px (index.css:90, 2072-2074,
    /// T3 b5a0696a98): the lane an overflowing block adds below its padding.
    static let codeScrollbar: CGFloat = 6
    static let tableFontSize: CGFloat = 12
    static let tableLineHeight: CGFloat = 12 * 1.625
    static let imageMaxWidth: CGFloat = 480

    static var body: NSColor { Themed.color(\.foreground, 0.8) }
    static var strong: NSColor { Themed.color(\.contrastForeground) }
    static var muted: NSColor { Themed.color(\.contrastMutedForeground) }
    static var link: NSColor { Themed.color(\.infoForeground) }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let font = DSFont.ui(size, weight: weight)
        guard italic else { return font }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? font
    }

    /// CSS `font-weight: bolder` from a parent weight.
    static func bolder(_ weight: NSFont.Weight) -> NSFont.Weight { weight.rawValue >= NSFont.Weight.semibold.rawValue ? .black : .bold }

    @MainActor private static var noBreakSpaceWidths: [NSFont: CGFloat] = [:]
    /// A no-break space's advance in `font`, measured once per font.
    @MainActor static func noBreakSpaceWidth(_ font: NSFont) -> CGFloat {
        if let width = noBreakSpaceWidths[font] { return width }
        let width = TextLine(NSAttributedString(string: "\u{00A0}", attributes: [.font: font])).width
        noBreakSpaceWidths[font] = width
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
    }

    /// Inline runs as an attributed string. Inline code reserves its padding and border with kerning
    /// on the character before it and on its own last character; the ranges come back for the chips.
    /// With `files`, path-shaped inline code and file links become file chips (`FileChipStyle`).
    @MainActor static func inline(_ runs: [InlineRun], size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                       alignment: NSTextAlignment = .natural, headIndent: CGFloat = 0, firstLineIndent: CGFloat? = nil,
                       files: FileChipResolver? = nil, contexts: MarkdownContextChips? = nil,
                       maxChipWidth: CGFloat = .greatestFiniteMagnitude, findable: Bool = true) -> Inline {
        let out = NSMutableAttributedString()
        var contextChips: [(range: NSRange, chip: MarkdownContextChip)] = []
        var favicons: [(range: NSRange, host: String)] = []
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
                var chip = contexts.chip(kind: parsed.kind, contextId: parsed.contextId, label: label)
                let measured = ComposerChipAttachment.measure(chip.look, maxWidth: maxChipWidth)
                chip.label = measured.label
                chip.frame.size = measured.size
                // One no-break space as wide as the chip: the chip never wraps and the layout item draws it.
                let space = TextLine(NSAttributedString(string: "\u{00A0}", attributes: [.font: parent])).width
                let start = out.length
                // Find skips a user message's context reference and ends the text segment there (threadFindText.ts).
                out.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: parent, .foregroundColor: color,
                                                                                .kern: measured.size.width - space, .markdownFindText: "\u{0}"]))
                contextChips.append((NSRange(location: start, length: 1), chip))
                continue
            }
            var findText: String?
            if let url = run.link, let citation = ThreadAssistantCitation.parse(url.absoluteString) {
                run.text = "❝ " + citation.label
                run.code = true
                findText = citation.label
            }
            let index = i
            i += 1
            if let label = run.skillLabel {
                let attachment = ComposerChipAttachment(look: ComposerChipLook(kind: .skill, label: label), source: run.text, maxWidth: maxChipWidth)
                let chip = NSMutableAttributedString(attachment: attachment)
                chip.addAttribute(.markdownFindText, value: label, range: NSRange(location: 0, length: chip.length))
                out.append(chip)
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
        return Inline(string: out, code: chips, files: fileChips, links: webLinks, contexts: contextChips, favicons: favicons)
    }
}

/// Everything a message's markdown draws at one width: positioned text, boxes, markers and the
/// frames of the code and table buttons. Built once per width and cached by `MarkdownView`.
@MainActor
public final class MarkdownLayout {
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
        public var dark: Bool
        public var showingCode: Set<Int>
        public init(enabled: Bool, dark: Bool, showingCode: Set<Int> = []) { self.enabled = enabled; self.dark = dark; self.showingCode = showingCode }
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

    /// What a later layout of the same message reuses: its top-level blocks, where the flow stood
    /// after each, and the inputs every block's layout depends on.
    fileprivate private(set) var rootBlocks: [MarkdownBlock] = []
    fileprivate private(set) var rootEnds: [RootEnd] = []
    private var reuseKey: ReuseKey?
    fileprivate var expandedTables: Set<Int> = []
    fileprivate var rootBoxes: [Box] = []
    /// The text boxes this layout made or took over for the blocks it laid out itself. Only a
    /// layout that reused an earlier one keeps them: that is a streaming answer, whose next update
    /// lays out its last block again and takes the boxes whose input did not change.
    fileprivate private(set) var textBoxes: [TextBoxCache.Key: MarkdownTextBox] = [:]
    /// How many text boxes came from `reusing` instead of TextKit (tests).
    private(set) var reusedTextBoxes = 0
    /// The flow after one top-level block: the items and controls so far, the y below the block,
    /// its own bottom margin (before the root zeroes the last one) and the next code block index.
    fileprivate struct RootEnd { var items: Int; var controls: Int; var y: CGFloat; var bottom: CGFloat; var codeIndex: Int; var tableIndex: Int; var innerBottom: CGFloat = 0 }
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
    public init(document: MarkdownDocument, width: CGFloat, wrapsCode: Bool = true, unwrappedCode: Set<Int> = [], bodyColor: NSColor? = nil, cwd: String? = nil,
                expandedTables: Set<Int> = [], diagrams: Diagrams? = nil, contexts: MarkdownContextChips? = nil, runsShell: Bool = false,
                fitsExpandedTables: Bool = false, reusing previous: MarkdownLayout? = nil) {
        self.width = width
        self.expandedTables = expandedTables
        let files = FileChipResolver(document: document, cwd: cwd)
        var builder = Builder(unwrapped: unwrappedCode, wrapsCode: wrapsCode, files: files.isEmpty ? nil : files,
                              boxes: TextBoxCache(previous: previous?.width == width ? previous?.textBoxes : nil, records: previous != nil))
        builder.expandedTables = expandedTables
        builder.contexts = contexts
        builder.diagrams = diagrams
        builder.cwd = cwd
        builder.runsShell = runsShell
        builder.fitsExpandedTables = fitsExpandedTables
        let key = ReuseKey(unwrapped: unwrappedCode, wrapsCode: wrapsCode, bodyColor: bodyColor, cwd: cwd, diagrams: diagrams, contexts: contexts, fileLabels: files.labelSuffixes,
                           runsShell: runsShell, fitsExpandedTables: fitsExpandedTables)
        if let previous, previous.width == width, previous.reuseKey == key { builder.previous = previous }
        let flow = builder.flow(document.blocks, width: width, context: .init(color: bodyColor ?? MarkdownStyle.body), root: true)
        reusedBlocks = builder.reusedBlocks
        rootBoxes = builder.rootBoxes
        reuseKey = key
        textBoxes = builder.boxes.made
        reusedTextBoxes = builder.boxes.hits
        rootBlocks = document.blocks
        rootEnds = builder.rootEnds
        items = flow.items
        controls = flow.controls
        fileChips = items.compactMap { if case .fileChip(let chip) = $0 { chip } else { nil } }
        contextChips = items.compactMap { if case .contextChip(let chip) = $0 { chip } else { nil } }
        links = items.compactMap { if case .link(let r, let url) = $0 { (r, url) } else { nil } }
        height = flow.height
        blockTops = builder.rootTops
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
    var expandedTables: Set<Int> = []
    var previous: MarkdownLayout?
    var rootBoxes: [Box] = []
    var reusedBlocks = 0
    var diagrams: MarkdownLayout.Diagrams?
    var contexts: MarkdownContextChips?
    var cwd: String?
    var runsShell = false
    var fitsExpandedTables = false
    var rootTops: [CGFloat] = []
    var rootEnds: [MarkdownLayout.RootEnd] = []

    let boxes: TextBoxCache

    init(unwrapped: Set<Int>, wrapsCode: Bool, files: FileChipResolver?, boxes: TextBoxCache) {
        self.unwrapped = unwrapped; self.wrapsCode = wrapsCode; self.files = files; self.boxes = boxes
    }

    /// Block children in normal flow. Margins between siblings collapse to the larger one; the first
    /// child's top and last child's bottom margin pass through to the parent (no border or padding
    /// stops them), except at the root, where T3 zeroes them (`.chat-markdown > :first-child`).
    /// Unchanged root blocks reuse their boxes, including blocks following a toggled table.
    @MainActor
    mutating func flow(_ blocks: [MarkdownBlock], width: CGFloat, context: Context, root: Bool = false, tight: Bool = false) -> Box {
        var out = Box()
        var y: CGFloat = 0
        var previousBottom: CGFloat?
        func canReuse(_ index: Int, _ code: Int, _ table: Int) -> Bool {
            guard root, let previous, index < previous.rootBlocks.count else { return false }
            let oldCode = index == 0 ? 0 : previous.rootEnds[index - 1].codeIndex
            let oldTable = index == 0 ? 0 : previous.rootEnds[index - 1].tableIndex
            guard code == oldCode, table == oldTable, blocks[index] == previous.rootBlocks[index] else { return false }
            let tables = table..<previous.rootEnds[index].tableIndex
            return expandedTables.intersection(tables) == previous.expandedTables.intersection(tables)
        }
        var first = 0
        if root, let previous {
            while first < blocks.count, canReuse(first, codeIndex, tableIndex) {
                codeIndex = previous.rootEnds[first].codeIndex
                tableIndex = previous.rootEnds[first].tableIndex
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
            if canReuse(index, codeIndex, tableIndex), let previous {
                box = previous.rootBoxes[index]
                codeIndex = previous.rootEnds[index].codeIndex
                tableIndex = previous.rootEnds[index].tableIndex
                reusedBlocks += 1
            } else {
                box = layout(blocks[index], width: width, context: context, tight: tight)
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
            if root { rootEnds.append(.init(items: out.items.count, controls: out.controls.count, y: y, bottom: ownBottom, codeIndex: codeIndex, tableIndex: tableIndex, innerBottom: box.innerBottom)) }
        }
        out.bottom = previousBottom ?? 0
        out.height = y + (root ? rootEnds.last?.innerBottom ?? 0 : 0)
        return out
    }

    @MainActor
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
            var inner = context
            inner.color = MarkdownStyle.muted
            let indent: CGFloat = 2 + 12.8
            let content = flow(children, width: width - indent, context: inner)
            var box = Box(top: max(MarkdownStyle.blockMargin, content.top), bottom: max(MarkdownStyle.blockMargin, content.bottom), height: content.height)
            box.items.append(.box(CGRect(x: 0, y: 0, width: 2, height: content.height), fill: Themed.color(\.contrastBorder), border: nil, radius: 0))
            box.add(content, at: CGPoint(x: indent, y: 0))
            return box
        case .alert(let kind, let children):
            return alert(kind, children, width: width, context: context)
        case .code(let language, let title, let code):
            let index = codeIndex
            codeIndex += 1
            let mermaid = language.lowercased() == "mermaid" && diagrams?.enabled == true
            if mermaid, let diagrams, !diagrams.showingCode.contains(index), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return diagramBlock(code: code, index: index, dark: diagrams.dark, width: width)
            }
            var box = codeBlock(language: language, title: title, code: code, width: width, wraps: wrapsCode != unwrapped.contains(index))
            if mermaid {
                // "Show diagram" leads the header's actions, before wrap and copy (`gap-0.5`).
                box.controls.append(.init(frame: CGRect(x: width - 1 - 6 - 24 - 2 - 24 - 2 - 24, y: 1 + 6, width: 24, height: 24),
                                          icon: .workflow, variant: .ghostMuted, action: .toggleDiagram(index)))
            }
            return box
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
            if let natural = MarkdownImages.sizes[source.key], !MarkdownImages.failed.contains(source.key) {
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
        }
    }

    @MainActor
    func text(_ runs: [InlineRun], width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, lineHeight: CGFloat,
              color: NSColor, alignment: NSTextAlignment = .natural, headIndent: CGFloat = 0, firstLineIndent: CGFloat? = nil,
              findable: Bool = true) -> Box {
        let inline = MarkdownStyle.inline(runs, size: size, weight: weight, color: color, alignment: alignment,
                                          headIndent: headIndent, firstLineIndent: firstLineIndent, files: files, contexts: contexts,
                                          maxChipWidth: width, findable: findable)
        let textBox = boxes.make(inline.string, width: width, lineHeight: lineHeight, strut: MarkdownStyle.font(size, weight: weight),
                                 chipRanges: inline.code, chipFont: DSFont.mono(MarkdownStyle.chipFontSize))
        var box = Box(height: textBox.height, baseline: textBox.firstBaseline)
        for chip in textBox.chips {
            box.items.append(.box(chip, fill: Themed.color(\.muted), border: Themed.color(\.contrastBorder), radius: MarkdownStyle.chipRadius))
        }
        box.items += Self.fileChips(inline, in: textBox, size: size, weight: weight)
        box.items += Self.contextChips(inline, in: textBox, size: size, weight: weight)
        box.items += Self.links(inline, in: textBox, lineHeight: lineHeight, size: size)
        box.items.append(.text(textBox, .zero))
        return box
    }

    /// Each favicon in its reserved space: `ms-[0.25em]`, 14px square, `vertical-align: -0.125em`.
    @MainActor
    static func favicons(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, size: CGFloat) -> [MarkdownLayout.Item] {
        inline.favicons.compactMap { favicon in
            guard let span = textBox.spans(favicon.range).first else { return nil }
            return .favicon(favicon.host, CGRect(x: span.x0 + 0.25 * size, y: span.baseline + 0.125 * size - 14, width: 14, height: 14))
        }
    }

    @MainActor
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
    @MainActor
    static func contextChips(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, size: CGFloat, weight: NSFont.Weight) -> [MarkdownLayout.Item] {
        let top = FileChipStyle.top(parent: MarkdownStyle.font(size, weight: weight), size: size)
        return inline.contexts.compactMap { entry in
            guard let span = textBox.spans(entry.range).first else { return nil }
            var chip = entry.chip
            chip.frame.origin = CGPoint(x: span.x0, y: span.baseline + top)
            return .contextChip(chip)
        }
    }

    @MainActor
    static func fileChips(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, size: CGFloat, weight: NSFont.Weight) -> [MarkdownLayout.Item] {
        let parent = MarkdownStyle.font(size, weight: weight)
        let top = FileChipStyle.top(parent: parent, size: size), height = FileChipStyle.height(size)
        let em = FileChipStyle.em(size), iconSize = 1.17 * em
        return inline.files.compactMap { file in
            guard let span = textBox.spans(file.range).first else { return nil }
            let frame = CGRect(x: span.x0, y: span.baseline + top, width: span.x1 - span.x0, height: height)
            let icon = CGRect(x: frame.minX + 1 + 0.5 * em, y: frame.midY - iconSize / 2, width: iconSize, height: iconSize)
            return .fileChip(FileChip(frame: frame, icon: icon, meta: file.meta, label: file.label))
        }
    }

    // MARK: Lists

    @MainActor
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
    @MainActor
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

    @MainActor
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
    @MainActor private static var coloredCodeCache: [ColoredCodeKey: NSAttributedString] = [:]
    @MainActor private static var coloredCodeOrder: [ColoredCodeKey] = []
    struct ColoredCodeKey: Hashable { var code: String; var language: String; var font: NSFont }

    @MainActor
    static func coloredCode(_ code: String, language: String, font: NSFont) -> NSAttributedString {
        let cached = code.utf16.count >= 2_000
        let key = ColoredCodeKey(code: code, language: language, font: font)
        if cached, let hit = coloredCodeCache[key] { return hit }
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
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for token in CodeHighlighter.tokens(code, language: language) {
            string.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            if token.kind == .emphasis { string.addAttribute(.font, value: italic, range: token.range) }
        }
        guard cached else { return string }
        let frozen = string.copy() as! NSAttributedString
        coloredCodeCache[key] = frozen
        coloredCodeOrder.append(key)
        if coloredCodeOrder.count > 16 { coloredCodeCache[coloredCodeOrder.removeFirst()] = nil }
        return frozen
    }

    // MARK: Code blocks

    @MainActor
    mutating func codeBlock(language: String, title: String?, code: String, width: CGFloat, wraps: Bool) -> Box {
        let p = MarkdownStyle.codePadding
        let font = DSFont.mono(MarkdownStyle.codeFontSize)
        let string = Self.coloredCode(code, language: language, font: font)
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
                              radius: 10))
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
        let actions: CGFloat = command == nil ? 50 : 76
        if label.length > 0 {
            let titleBox = boxes.make(label, width: width - labelX - 6 - actions - 8, lineHeight: labelLine, strut: titleFont, wraps: false)
            box.items.append(.text(titleBox, CGPoint(x: labelX, y: 1 + 6 + (24 - labelLine) / 2)))
        }
        let copyX = width - 1 - 6 - 24
        // Wrap, "Run in terminal", copy (ChatMarkdown.tsx:960-1010), 24px buttons 2px apart.
        if let command {
            box.controls.append(.init(frame: CGRect(x: copyX - 2 - 24, y: 1 + 6, width: 24, height: 24), icon: .play, variant: .ghostMuted,
                                      action: .runShell(command)))
        }
        box.controls.append(.init(frame: CGRect(x: copyX - (command == nil ? 1 : 2) * 26, y: 1 + 6, width: 24, height: 24), icon: .textWrap,
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

    /// The diagram face of `MarkdownCodeBlock` (ChatMarkdown.tsx:928-938): `my-[0.65rem]`, the diagram centered at
    /// most the message's width (`max-w-full h-auto`), then a `mt-0.5` row with "Show code" and copy. While it renders,
    /// "Rendering diagram" holds a 144pt box; a failure shows the parser message above the source.
    @MainActor
    func diagramBlock(code: String, index: Int, dark: Bool, width: CGFloat) -> Box {
        var box = Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin)
        var y: CGFloat = 0
        // Find counts the source, not the diagram's own labels (MermaidDiagram.tsx:195-200).
        box.items.append(.hiddenText(code, codeIndex: index))
        let ignored: [NSAttributedString.Key: Any] = [.markdownFindText: ""]
        switch MermaidDiagrams.shared.result(code, dark: dark) {
        case .rendered(let image, let size)?:
            let w = min(size.width, width), h = size.width > 0 ? (size.height * w / size.width).rounded() : 0
            box.items.append(.image(image, CGRect(x: ((width - w) / 2).rounded(), y: 0, width: w, height: h)))
            y = h
        case .failed(let message, let retryable)?:
            let font = DSFont.ui(12)
            let line = NSAttributedString(string: "Unable to render diagram: \(message)", attributes: [.font: font, .foregroundColor: Themed.color(\.destructive)].merging(ignored) { $1 })
            let error = MarkdownTextBox(line, width: width - (retryable ? 64 : 0), lineHeight: 16, strut: font)
            box.items.append(.text(error, .zero))
            if retryable {
                box.controls.append(.init(frame: CGRect(x: width - 56, y: 0, width: 56, height: 24), icon: nil, variant: .ghost,
                                          action: .retryDiagram(code), title: "Retry"))
            }
            let mono = DSFont.mono(12)
            let source = MarkdownTextBox(NSAttributedString(string: code, attributes: [.font: mono, .foregroundColor: MarkdownStyle.body].merging(ignored) { $1 }),
                                         width: width, lineHeight: 16, strut: mono)
            let top = max(error.height, retryable ? 24 : 0) + 8
            box.items.append(.text(source, CGPoint(x: 0, y: top)))
            y = top + source.height
        case nil:
            let font = DSFont.ui(12)
            let label = MarkdownTextBox(NSAttributedString(string: "Rendering diagram", attributes: [.font: font, .foregroundColor: MarkdownStyle.muted].merging(ignored) { $1 }),
                                        width: width, lineHeight: 16, strut: font, wraps: false)
            let lw = ceil(TextLine(NSAttributedString(string: "Rendering diagram", attributes: [.font: font])).width)
            box.items.append(.text(label, CGPoint(x: ((width - lw) / 2).rounded(), y: 64)))
            y = 144
        }
        y += 2
        box.controls.append(.init(frame: CGRect(x: 0, y: y, width: 24, height: 24), icon: .code, variant: .ghostMuted, action: .toggleDiagram(index)))
        box.controls.append(.init(frame: CGRect(x: width - 24, y: y, width: 24, height: 24), icon: .copy, variant: .ghostMuted, action: .copy(code)))
        box.height = y + 24
        return box
    }

    // MARK: Tables

    /// `MarkdownTable`: 12px cells with `0.45rem 0.75rem` padding (header `0.55rem` block padding, weight 600),
    /// a 1px bottom rule at 60% border under every row, then the expand and copy buttons 2px below.
    @MainActor
    mutating func table(_ table: MarkdownTable, width: CGFloat, context: Context) -> Box {
        let index = tableIndex
        tableIndex += 1
        let expanded = expandedTables.contains(index)
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
        var naturals: [(column: Int, width: CGFloat)] = []
        for row in [table.header] + table.rows {
            for (c, runs) in row.enumerated() where c < columns {
                let n = natural(cellString(runs, header: row == table.header, column: c).string)
                naturals.append((c, n))
                widths[c] = max(widths[c], min(384, n + 24))
            }
        }
        let total = widths.reduce(0, +)
        if total < width, total > 0 { widths = widths.map { $0 + (width - total) * $0 / total } }
        // T3 shows the wrap toggle only when a header or body cell is clipped unwrapped (ChatMarkdown.tsx:540-560, :665).
        // Columns stop at 384pt, so a cell clips when its text outgrows its column. Expanding keeps the same widths.
        let clipped = naturals.contains { $0.width + 24 > widths[$0.column] }
        var tableWidth = max(width, total)
        let wraps = expanded && fitsExpandedTables
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
                let textBox = boxes.make(displayed, width: widths[c] - 24, lineHeight: line, strut: MarkdownStyle.font(size),
                                         chipRanges: chips, chipFont: DSFont.mono(MarkdownStyle.chipFontSize))
                var cell = Box(height: textBox.height)
                for chip in textBox.chips {
                    cell.items.append(.box(chip, fill: Themed.color(\.muted), border: Themed.color(\.contrastBorder), radius: MarkdownStyle.chipRadius))
                }
                cell.items += Self.fileChips(inline, in: textBox, size: size, weight: r == 0 ? .semibold : .regular)
                cell.items += Self.contextChips(inline, in: textBox, size: size, weight: r == 0 ? .semibold : .regular)
                cell.items += Self.favicons(inline, in: textBox, size: size)
                cell.items.append(.text(textBox, .zero))
                rowHeight = max(rowHeight, textBox.height)
                cells.append((cell, x + 12))
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
        if clipped {
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

    static func expandedTableWidths(_ rows: [[NSAttributedString]], columns: Int, width: CGFloat, fitsLane: Bool,
                                    natural: (NSAttributedString) -> CGFloat) -> (widths: [CGFloat], tableWidth: CGFloat) {
        var mins = [CGFloat](repeating: 0, count: columns), maxs = mins
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() where c < columns {
                let cap: CGFloat = r == 0 ? .infinity : 384
                maxs[c] = max(maxs[c], min(cap, natural(cell) + 24))
                guard fitsLane else { continue }
                // ponytail: breaks only at spaces, not after hyphens, add UAX 14 opportunities if a column comes out wide
                let longest = Self.unbroken.matches(in: cell.string, range: NSRange(location: 0, length: cell.length))
                    .map { natural(cell.attributedSubstring(from: $0.range)) }.max() ?? 0
                mins[c] = max(mins[c], min(cap, longest + 24))
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
        case .hiddenText: self
        case .image(let image, let r): .image(image, r.offsetBy(dx: p.x, dy: p.y))
        case .remoteImage(let url, let alt, let r): .remoteImage(url, alt, r.offsetBy(dx: p.x, dy: p.y))
        }
    }
}

/// Text boxes keyed by everything that shapes them, so a streaming answer's next layout takes the
/// ones whose text did not change (table cells and list items above the growing end) instead of
/// running TextKit again. A layout that does not record makes boxes as before.
@MainActor
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

    func make(_ string: NSAttributedString, width: CGFloat, lineHeight: CGFloat, strut: NSFont,
              chipRanges: [NSRange] = [], chipFont: NSFont? = nil, wraps: Bool = true) -> MarkdownTextBox {
        guard records else {
            return MarkdownTextBox(string, width: width, lineHeight: lineHeight, strut: strut, chipRanges: chipRanges, chipFont: chipFont, wraps: wraps)
        }
        let key = Key(string: string, width: width, lineHeight: lineHeight, strut: strut, chipRanges: chipRanges, chipFont: chipFont, wraps: wraps)
        if let box = made[key] ?? previous[key] {
            hits += 1
            made[key] = box
            return box
        }
        let box = MarkdownTextBox(string, width: width, lineHeight: lineHeight, strut: strut, chipRanges: chipRanges, chipFont: chipFont, wraps: wraps)
        made[key] = box
        return box
    }
}
