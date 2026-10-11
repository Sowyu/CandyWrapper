import AppKit
import DesignSystem

/// T3's `.chat-markdown` values (`apps/web/src/index.css:1759-2073`, ChatMarkdown.tsx), research note H section 4.
enum MarkdownStyle {
    static let fontSize: CGFloat = 14
    static let lineHeight: CGFloat = 14 * 1.625
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
    static let codeLineHeight: CGFloat = 13 * 1.375
    static let codePadding = (x: CGFloat(14.4), y: CGFloat(12.8))
    static let codeHeader: CGFloat = 30
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
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: size) ?? font
    }

    /// CSS `font-weight: bolder` from a parent weight.
    static func bolder(_ weight: NSFont.Weight) -> NSFont.Weight { weight.rawValue >= NSFont.Weight.semibold.rawValue ? .black : .bold }

    /// Inline text: the attributed string, the inline code ranges and the file chips in it.
    struct Inline {
        var string: NSAttributedString
        var code: [NSRange]
        var files: [(range: NSRange, meta: FileLinkMeta, label: String)]
        /// Web links (not file links), for hit testing.
        var links: [(range: NSRange, url: URL)] = []
    }

    /// Inline runs as an attributed string. Inline code reserves its padding and border with kerning
    /// on the character before it and on its own last character; the ranges come back for the chips.
    /// With `files`, path-shaped inline code and file links become file chips (`FileChipStyle`).
    static func inline(_ runs: [InlineRun], size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                       alignment: NSTextAlignment = .natural, headIndent: CGFloat = 0, firstLineIndent: CGFloat? = nil,
                       files: FileChipResolver? = nil, maxChipWidth: CGFloat = .greatestFiniteMagnitude) -> Inline {
        let out = NSMutableAttributedString()
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
            fileChips.append((NSRange(location: start, length: out.length - start), meta, label))
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
            i += 1
            let start = out.length
            var attributes: [NSAttributedString.Key: Any] = [:]
            if run.code {
                attributes[.font] = DSFont.mono(chipFontSize)
                attributes[.foregroundColor] = strong
            } else {
                attributes[.font] = font(size, weight: run.bold ? bolder(weight) : weight, italic: run.italic)
                attributes[.foregroundColor] = run.link != nil ? link : color
            }
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
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
            if run.code, out.length > start {
                chips.append(NSRange(location: start, length: out.length - start))
                if start > 0 {
                    let previous = (out.attribute(.kern, at: start - 1, effectiveRange: nil) as? CGFloat) ?? 0
                    out.addAttribute(.kern, value: previous + pad, range: NSRange(location: start - 1, length: 1))
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
        return Inline(string: out, code: chips, files: fileChips, links: webLinks)
    }
}

/// Everything a message's markdown draws at one width: positioned text, boxes, markers and the
/// frames of the code and table buttons. Built once per width and cached by `MarkdownView`.
@MainActor
public final class MarkdownLayout {
    public let width: CGFloat
    public private(set) var height: CGFloat = 0

    enum Item {
        case text(MarkdownTextBox, CGPoint)
        /// A filled rounded rect, optionally with a 1px inside border (`sides` limits the border).
        case box(CGRect, fill: NSColor?, border: NSColor?, radius: CGFloat)
        case glyphs(NSAttributedString, baselineRight: CGPoint)
        /// `disc`, `circle` or `square` list markers, which Blink paints as shapes, not glyphs.
        case symbol(Int, CGRect, NSColor)
        case checkbox(CGRect, checked: Bool)
        case icon(IconName, CGRect, NSColor)
        /// A file path chip's box and icon; its label is part of the text item drawn after it.
        case fileChip(FileChip)
        /// A web link's area on one line (not drawn; hit tested by `MarkdownView`).
        case link(CGRect, URL)
        /// Clips the items until the matching `.endClip` (code blocks with wrapping off).
        case clip(CGRect)
        case endClip
    }

    struct Control {
        enum Action { case copy(String), toggleWrap(Int), toggleTable }
        var frame: CGRect
        var icon: IconName
        var variant: ButtonView.Variant
        var action: Action
    }

    private(set) var items: [Item] = []
    private(set) var controls: [Control] = []
    /// File chips in drawing order, for hit testing.
    public private(set) var fileChips: [FileChip] = []
    /// Web link areas, one per line a link touches.
    public private(set) var links: [(frame: CGRect, url: URL)] = []

    /// `unwrappedCode`: indices of code blocks whose wrap toggle is off. `bodyColor` replaces the
    /// 80% foreground of body text (user bubbles and plan cards draw at 100%). `cwd` anchors relative file
    /// paths (T3's `markdownCwd`: the thread's worktree or the project root); without it only absolute paths chip.
    public init(document: MarkdownDocument, width: CGFloat, unwrappedCode: Set<Int> = [], bodyColor: NSColor? = nil, cwd: String? = nil) {
        self.width = width
        let files = FileChipResolver(document: document, cwd: cwd)
        var builder = Builder(unwrapped: unwrappedCode, files: files.isEmpty ? nil : files)
        let flow = builder.flow(document.blocks, width: width, context: .init(color: bodyColor ?? MarkdownStyle.body), root: true)
        items = flow.items
        controls = flow.controls
        fileChips = items.compactMap { if case .fileChip(let chip) = $0 { chip } else { nil } }
        links = items.compactMap { if case .link(let r, let url) = $0 { (r, url) } else { nil } }
        height = flow.height
    }
}

// MARK: - Block layout

/// A laid-out block: CSS margins (to collapse with neighbours), its border-box height, and its
/// content relative to its top-left.
private struct Box {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
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
    let files: FileChipResolver?
    var codeIndex = 0

    init(unwrapped: Set<Int>, files: FileChipResolver?) { self.unwrapped = unwrapped; self.files = files }

    /// Block children in normal flow. Margins between siblings collapse to the larger one; the first
    /// child's top and last child's bottom margin pass through to the parent (no border or padding
    /// stops them), except at the root, where T3 zeroes them (`.chat-markdown > :first-child`).
    @MainActor
    mutating func flow(_ blocks: [MarkdownBlock], width: CGFloat, context: Context, root: Bool = false, tight: Bool = false) -> Box {
        var out = Box()
        var y: CGFloat = 0
        var previousBottom: CGFloat?
        for (index, block) in blocks.enumerated() {
            var box = layout(block, width: width, context: context, tight: tight)
            if root, index == 0 { box.top = 0 }
            if root, index == blocks.count - 1 { box.bottom = 0 }
            if let previousBottom { y += max(previousBottom, box.top) } else { out.top = box.top }
            out.add(box, at: CGPoint(x: 0, y: y))
            y += box.height
            previousBottom = box.bottom
        }
        out.bottom = previousBottom ?? 0
        out.height = y
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
            return codeBlock(language: language, title: title, code: code, width: width, wraps: !unwrapped.contains(index))
        case .table(let table):
            return self.table(table, width: width, context: context)
        case .rule:
            // Preflight's hr: a 1px top border in --border, no margin.
            return Box(height: 1, items: [.box(CGRect(x: 0, y: 0, width: width, height: 1), fill: Themed.color(\.border), border: nil, radius: 0)])
        case .image:
            // The loading slot of a standalone image: 16:9, at most 30rem wide, on the paragraph's baseline.
            let w = min(width, MarkdownStyle.imageMaxWidth), h = w * 9 / 16
            let strut = TextLine(NSAttributedString(string: " ", attributes: [.font: MarkdownStyle.font(MarkdownStyle.fontSize)]))
            let below = MarkdownStyle.lineHeight - strut.baseline(top: 0, lineHeight: MarkdownStyle.lineHeight)
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            return Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin, height: h + below,
                       items: [.box(rect, fill: Themed.color(\.muted, 0.6), border: Themed.color(\.border, 0.4), radius: 10)])
        }
    }

    @MainActor
    func text(_ runs: [InlineRun], width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, lineHeight: CGFloat,
              color: NSColor, alignment: NSTextAlignment = .natural, headIndent: CGFloat = 0, firstLineIndent: CGFloat? = nil) -> Box {
        let inline = MarkdownStyle.inline(runs, size: size, weight: weight, color: color, alignment: alignment,
                                          headIndent: headIndent, firstLineIndent: firstLineIndent, files: files, maxChipWidth: width)
        let textBox = MarkdownTextBox(inline.string, width: width, lineHeight: lineHeight, strut: MarkdownStyle.font(size, weight: weight),
                                      chipRanges: inline.code, chipFont: DSFont.mono(MarkdownStyle.chipFontSize))
        var box = Box(height: textBox.height, baseline: textBox.firstBaseline)
        for chip in textBox.chips {
            box.items.append(.box(chip, fill: Themed.color(\.muted), border: Themed.color(\.contrastBorder), radius: MarkdownStyle.chipRadius))
        }
        box.items += Self.fileChips(inline, in: textBox, size: size, weight: weight)
        box.items += Self.links(inline, in: textBox, lineHeight: lineHeight)
        box.items.append(.text(textBox, .zero))
        return box
    }

    @MainActor
    static func links(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, lineHeight: CGFloat) -> [MarkdownLayout.Item] {
        inline.links.flatMap { link in
            textBox.spans(link.range).map { span in
                MarkdownLayout.Item.link(CGRect(x: span.x0, y: span.baseline - lineHeight * 0.75, width: span.x1 - span.x0, height: lineHeight), link.url)
            }
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
                content = flow(item.blocks, width: width - gutter, context: inner, tight: true)
            }
            // `li + li { margin-top: 0.25rem }`, collapsing with whatever the item's first child brings.
            content.top = max(index == 0 ? 0 : MarkdownStyle.itemGap, content.top)
            if let previousBottom { y += max(previousBottom, content.top) } else { out.top = max(out.top, content.top) }
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
        var title = text([InlineRun(text: label)], width: width - indent - 14 - 6, size: MarkdownStyle.fontSize, weight: .medium,
                         lineHeight: MarkdownStyle.lineHeight, color: titleColor)
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

    // MARK: Code blocks

    @MainActor
    mutating func codeBlock(language: String, title: String?, code: String, width: CGFloat, wraps: Bool) -> Box {
        let p = MarkdownStyle.codePadding
        let font = DSFont.mono(MarkdownStyle.codeFontSize)
        let string = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: CodeTokenKind.plain.color])
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for token in CodeHighlighter.tokens(code, language: language) {
            string.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            if token.kind == .emphasis { string.addAttribute(.font, value: italic, range: token.range) }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = []
        // Chromium's default tab-size is 8 spaces.
        paragraph.defaultTabInterval = 8 * TextLine(NSAttributedString(string: " ", attributes: [.font: font])).width
        paragraph.tabStops = []
        string.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
        let inner = width - 2 - 2 * p.x
        let textBox = MarkdownTextBox(string, width: inner, lineHeight: MarkdownStyle.codeLineHeight, strut: font, wraps: wraps)
        let height = 1 + MarkdownStyle.codeHeader + p.y + textBox.height + p.y + 1
        var box = Box(top: MarkdownStyle.blockMargin, bottom: MarkdownStyle.blockMargin, height: height)
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        // Light: 1px border at 70% on --secondary. Dark: a transparent border on --input at 32%.
        box.items.append(.box(frame, fill: Themed.color(light: \.secondary, 1, dark: \.input, 0.32),
                              border: Themed.color(light: \.border, 0.7, dark: \.border, 0), radius: 10))
        // Header: `pt-1.5 pr-1.5 pl-3`, the 24px buttons set its height; title 11px mono at 72% foreground.
        let titleFont = DSFont.mono(11)
        let label = NSAttributedString(string: title ?? language, attributes: [
            .font: titleFont, .foregroundColor: Themed.color(\.contrastForeground, 0.72)])
        let labelLine = 11 * 1.375
        let titleBox = MarkdownTextBox(label, width: width - 2 - 12 - 6 - 50 - 8, lineHeight: labelLine, strut: titleFont, wraps: false)
        box.items.append(.text(titleBox, CGPoint(x: 1 + 12, y: 1 + 6 + (24 - labelLine) / 2)))
        let copyX = width - 1 - 6 - 24
        box.controls.append(.init(frame: CGRect(x: copyX - 2 - 24, y: 1 + 6, width: 24, height: 24), icon: .textWrap,
                                  variant: wraps ? .secondary : .ghostMuted, action: .toggleWrap(codeIndex - 1)))
        box.controls.append(.init(frame: CGRect(x: copyX, y: 1 + 6, width: 24, height: 24), icon: .copy, variant: .ghostMuted, action: .copy(code)))
        let body = CGRect(x: 1, y: 1 + MarkdownStyle.codeHeader, width: width - 2, height: height - 2 - MarkdownStyle.codeHeader)
        if !wraps { box.items.append(.clip(body)) }
        box.items.append(.text(textBox, CGPoint(x: 1 + p.x, y: 1 + MarkdownStyle.codeHeader + p.y)))
        if !wraps { box.items.append(.endClip) }
        return box
    }

    // MARK: Tables

    /// `MarkdownTable`: 12px cells with `0.45rem 0.75rem` padding (header `0.55rem` block padding, weight 600),
    /// a 1px bottom rule at 60% border under every row, then the expand and copy buttons 2px below.
    // ponytail: columns get their max-content width plus a proportional share of the slack, and cells never
    // wrap; a table wider than the message is clipped, not scrolled. Add the ScrollArea when wide tables show up.
    @MainActor
    mutating func table(_ table: MarkdownTable, width: CGFloat, context: Context) -> Box {
        let columns = table.alignments.count
        let size = MarkdownStyle.tableFontSize, line = MarkdownStyle.tableLineHeight
        func cellString(_ runs: [InlineRun], header: Bool, column: Int) -> MarkdownStyle.Inline {
            let alignment: NSTextAlignment = switch table.alignments[column] {
            case .center: .center
            case .right: .right
            default: .left
            }
            return MarkdownStyle.inline(runs, size: size, weight: header ? .semibold : .regular, color: context.color, alignment: alignment, files: files)
        }
        func natural(_ s: NSAttributedString) -> CGFloat {
            MarkdownTextBox(s, width: 0, lineHeight: line, strut: MarkdownStyle.font(size), wraps: false).usedWidth
        }
        var widths = [CGFloat](repeating: 0, count: columns)
        for row in [table.header] + table.rows {
            for (c, runs) in row.enumerated() where c < columns {
                widths[c] = max(widths[c], natural(cellString(runs, header: row == table.header, column: c).string) + 24)
            }
        }
        let total = widths.reduce(0, +)
        if total < width, total > 0 { widths = widths.map { $0 + (width - total) * $0 / total } }
        let tableWidth = max(width, total)

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
                // Columns are at least max-content wide, so the cell never wraps; it must still wrap at its width
                // for TextKit to place centered and right-aligned text inside the column.
                let textBox = MarkdownTextBox(s, width: widths[c] - 24, lineHeight: line, strut: MarkdownStyle.font(size),
                                              chipRanges: chips, chipFont: DSFont.mono(MarkdownStyle.chipFontSize))
                var cell = Box(height: textBox.height)
                for chip in textBox.chips {
                    cell.items.append(.box(chip, fill: Themed.color(\.muted), border: Themed.color(\.contrastBorder), radius: MarkdownStyle.chipRadius))
                }
                cell.items += Self.fileChips(inline, in: textBox, size: size, weight: r == 0 ? .semibold : .regular)
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
        if tableWidth > width {
            box.items.insert(.clip(CGRect(x: 0, y: 0, width: width, height: y)), at: 0)
            box.items.append(.endClip)
        }
        box.controls.append(.init(frame: CGRect(x: 0, y: y + 2, width: 24, height: 24), icon: .minimize2, variant: .secondary, action: .toggleTable))
        box.controls.append(.init(frame: CGRect(x: width - 24, y: y + 2, width: 24, height: 24), icon: .copy, variant: .ghostMuted,
                                  action: .copy(Self.markdown(table))))
        box.height = y + 2 + 24
        return box
    }

    /// "Copy as Markdown" for a table.
    static func markdown(_ table: MarkdownTable) -> String {
        func row(_ cells: [[InlineRun]]) -> String {
            "| " + cells.map { $0.map(\.text).joined().replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        let rule = "| " + table.alignments.map { a -> String in
            switch a {
            case .left: ":---"
            case .center: ":---:"
            case .right: "---:"
            case .none: "---"
            }
        }.joined(separator: " | ") + " |"
        return ([row(table.header), rule] + table.rows.map(row)).joined(separator: "\n")
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
        case .fileChip(let chip):
            .fileChip(FileChip(frame: chip.frame.offsetBy(dx: p.x, dy: p.y), icon: chip.icon.offsetBy(dx: p.x, dy: p.y), meta: chip.meta, label: chip.label))
        case .clip(let r): .clip(r.offsetBy(dx: p.x, dy: p.y))
        case .endClip: .endClip
        case .link(let r, let url): .link(r.offsetBy(dx: p.x, dy: p.y), url)
        }
    }
}
