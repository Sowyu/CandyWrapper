import AppKit
import DesignSystem
import T3Protocol

/// What a sent message knows about its `t3-context://` links: the records of its `context`, its
/// attachments and the live titles of the threads it names. T3 renders each link with
/// `UserMessageContextReferenceChip` (MessagesTimeline.tsx:2305-2345, 4469-4709); without this a
/// link shows its label as plain text (ChatMarkdown.tsx:2930-2937).
public struct MarkdownContextChips: Equatable {
    public var records: [String: JSONValue]
    public var attachments: [String: JSONValue]
    /// The threads the message names that this machine knows (`useThreadShell`), by local id.
    public var threads: [String: LinkedThread]

    /// A known thread's shell title and its project's icon, nil when the project is unknown.
    public struct LinkedThread: Equatable, Sendable {
        public var title: String
        public var project: ProjectIconSource?
        public init(title: String, project: ProjectIconSource? = nil) { self.title = title; self.project = project }
    }

    public init(records: [String: JSONValue] = [:], attachments: [String: JSONValue] = [:], threads: [String: LinkedThread] = [:]) {
        self.records = records; self.attachments = attachments; self.threads = threads
    }

    /// The message's records by context id and its attachments by id; `thread` looks up live threads
    /// by local id, nil once a thread is gone. `document` adds the threads its `t3-thread://` links name.
    public static func message(context: JSONValue?, attachments: [JSONValue], document: MarkdownDocument = MarkdownDocument(blocks: []),
                               thread: (String) -> LinkedThread?) -> MarkdownContextChips {
        var out = links(in: document, thread: thread) ?? MarkdownContextChips()
        if case .array(let records)? = context?["records"] {
            for record in records {
                guard let id = record["contextId"]?.stringValue else { continue }
                out.records[id] = record
                if record["kind"]?.stringValue == "thread", let threadId = record["threadId"]?.stringValue, let live = thread(threadId) {
                    out.threads[threadId] = live
                }
            }
        }
        for attachment in attachments {
            if let id = attachment["id"]?.stringValue { out.attachments[id] = attachment }
        }
        return out
    }

    // MARK: Thread links

    static let threadLinkPrefix = "t3-thread://v1/"

    /// `parseThreadLinkHref` (packages/shared/src/threadLinks.ts:14-17): the id as written, not decoded.
    static func threadLinkId(_ href: String) -> String? {
        guard href.hasPrefix(threadLinkPrefix) else { return nil }
        let id = String(href.dropFirst(threadLinkPrefix.count))
        return id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : id
    }

    /// `percentDecodedThreadLinkId` (threadLinks.ts:19-26): nil when decoding changes nothing or fails.
    static func percentDecoded(_ id: String) -> String? {
        guard let decoded = id.removingPercentEncoding, decoded != id,
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return decoded
    }

    /// The threads a reply's `t3-thread://v1/<id>` links name, written and percent-decoded, or nil when it has
    /// none (`hasThreadLinks`, threadLinks.ts:60-62), so plain replies carry no chips. It reads the parsed links,
    /// as T3 dispatches on the parsed href (ChatMarkdown.tsx:1067), so titled and reference-style links resolve too.
    public static func links(in document: MarkdownDocument, thread: (String) -> LinkedThread?) -> MarkdownContextChips? {
        var out: MarkdownContextChips?
        // Remember misses too: repeated links to an unavailable or encoded id need one lookup.
        // This stays local to the pass, so a later shell update can resolve a missing thread.
        var visited = Set<String>()
        func visit(_ runs: [InlineRun]) {
            for run in runs {
                guard let url = run.link, let written = threadLinkId(url.absoluteString) else { continue }
                if out == nil { out = MarkdownContextChips() }
                for id in [written, percentDecoded(written)].compactMap({ $0 }) where visited.insert(id).inserted {
                    if let live = thread(id) { out?.threads[id] = live }
                }
            }
        }
        func visit(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .paragraph(let r), .heading(_, let r): visit(r)
                case .list(let list): list.items.forEach { visit($0.blocks) }
                case .blockquote(let b), .alert(_, let b): visit(b)
                case .table(let t): ([t.header] + t.rows).forEach { $0.forEach(visit) }
                case .code, .rule, .image: break
                }
            }
        }
        visit(document.blocks)
        return out
    }

    /// `MarkdownThreadLink` (MarkdownThreadLink.tsx:12-39): the thread as written, else its percent-decoded
    /// id, drawn as `ThreadContextChip` with the link text as its recorded title.
    // ponytail: same machine only; T3 also finds a thread with that id on exactly one other machine
    // (`resolveThreadLinkRef`, threadLinks.ts:28-50). Add it with a scoped open action if links cross machines.
    @MainActor
    func threadLinkChip(threadId written: String, label: String) -> MarkdownContextChip {
        let decoded = threads[written] == nil ? Self.percentDecoded(written).flatMap { threads[$0] != nil ? $0 : nil } : nil
        return threadChip(threadId: decoded ?? written, recordTitle: label)
    }

    /// `ThreadContextChip` (ThreadContextChip.tsx:11-50): the live title, else the recorded one; the project's
    /// favicon once the shell names a known project. Since 15dc7b0130 the chip keeps its own colors inside
    /// markdown (`.chat-markdown a:not(:has([data-slot="context-chip-label"]))`, index.css:1958-1979).
    @MainActor
    func threadChip(threadId: String, recordTitle: String) -> MarkdownContextChip {
        let live = threads[threadId]
        let trimmed = live?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmed.isEmpty ? recordTitle : trimmed
        return MarkdownContextChip(look: ComposerChipLook(kind: .thread, label: title, project: live?.project), action: .openThread(threadId),
                                   tooltip: live != nil ? "Open thread" : "Thread no longer available", accessibility: "Thread, \(title)")
    }

    /// The chip for one reference, as the presentation registry dispatches it.
    @MainActor
    func chip(kind: String, contextId: String, label: String) -> MarkdownContextChip {
        let unavailable = MarkdownContextChip(look: ComposerChipLook(kind: .unresolved, label: label), action: .none,
                                              tooltip: "This context is no longer available.", accessibility: "Unavailable context, \(label)")
        // `asKnownContextRecord` plus each handler's `record.kind === kind` check.
        guard let record = records[contextId], record["kind"]?.stringValue == kind else { return unavailable }
        let recordLabel = record["label"]?.stringValue ?? label
        switch kind {
        case "mention":
            guard let path = record["path"]?.stringValue else { return unavailable }
            return MarkdownContextChip(look: ComposerChipLook(kind: .mention(path: path), label: recordLabel), action: .openFile(path),
                                       tooltip: path, accessibility: "Preview \(path)")
        case "skill":
            let name = record["name"]?.stringValue ?? ""
            let text = recordLabel.isEmpty ? name : recordLabel
            return MarkdownContextChip(look: ComposerChipLook(kind: .skill, label: text), action: .none, tooltip: "$\(name)", accessibility: "Skill, \(text)")
        case "thread":
            return threadChip(threadId: record["threadId"]?.stringValue ?? "", recordTitle: record["title"]?.stringValue ?? recordLabel)
        case "image":
            guard let id = record["attachmentId"]?.stringValue, let attachment = attachments[id], attachment["type"]?.stringValue == "image" else { return unavailable }
            let name = record["name"]?.stringValue ?? recordLabel
            let size = ComposerFileRow.formatSize(record["sizeBytes"]?.intValue ?? 0)
            return MarkdownContextChip(look: ComposerChipLook(kind: .image, label: ComposerAttachmentRules.middleTruncate(name), detail: size),
                                       action: .expandImage(id), tooltip: nil, accessibility: "Image attachment, \(name), \(size)", imageAttachmentId: id)
        case "file":
            guard let id = record["attachmentId"]?.stringValue, let attachment = attachments[id], attachment["type"]?.stringValue == "file" else { return unavailable }
            let name = record["name"]?.stringValue ?? recordLabel
            let size = ComposerFileRow.formatSize(record["sizeBytes"]?.intValue ?? 0)
            let mime = attachment["mimeType"]?.stringValue ?? ""
            let video = mime.hasPrefix("video/")
            // ponytail: a video chip opens the file like any other; T3 plays it in the media viewer (`onExpandVideo`)
            let disabled: Bool = if case .bool(false)? = attachment["downloadable"] { !video } else { false }
            return MarkdownContextChip(look: ComposerChipLook(kind: video ? .video : .file(name: name), label: ComposerAttachmentRules.middleTruncate(name), detail: size),
                                       action: disabled ? .none : .openAttachment(id), tooltip: "\(name)\n\(size)",
                                       accessibility: "\(video ? "Video" : "File") attachment, \(name), \(size)")
        case "terminal":
            let text = record["text"]?.stringValue ?? ""
            let look = ComposerChipLook(kind: .terminal, label: recordLabel)
            guard !text.isEmpty else { return MarkdownContextChip(look: look, action: .none, tooltip: nil, accessibility: "Terminal excerpt, \(recordLabel)") }
            return MarkdownContextChip(look: look, action: .terminal(record), tooltip: nil, accessibility: "Terminal excerpt, \(recordLabel). Show details")
        case "review-comment":
            if let pr = ComposerContext.pullRequest(in: record) {
                return MarkdownContextChip(look: ComposerChipLook(kind: .pullRequest(state: pr.displayState), label: "#\(pr.number)"),
                                           action: .openURL(pr.url), tooltip: pr.title, accessibility: "Open pull request #\(pr.number): \(pr.title)")
            }
            // ponytail: a review comment shows its text as a tooltip; T3 opens UserMessageReviewCommentCard in a popover. Port it when review comments are sent from here
            return MarkdownContextChip(look: ComposerChipLook(kind: .reviewComment, label: recordLabel), action: .none,
                                       tooltip: record["text"]?.stringValue, accessibility: "Review comment, \(recordLabel)")
        default:
            // ponytail: element and preview-annotation records (desktop browser only) show as unavailable; port their popovers with the browser picker
            return unavailable
        }
    }

    /// `![label](t3-context://…)` parses as an image; T3 renders it through the same chip (ChatMarkdown.tsx:3180-3199).
    static func document(_ document: MarkdownDocument) -> MarkdownDocument {
        func isContext(_ url: URL?) -> Bool { url?.scheme == "t3-context" }
        func runs(_ runs: [InlineRun]) -> [InlineRun] {
            guard runs.contains(where: { isContext($0.image) }) else { return runs }
            return runs.map { run in
                guard isContext(run.image) else { return run }
                var r = run; r.link = run.image; r.image = nil; return r
            }
        }
        func block(_ b: MarkdownBlock) -> MarkdownBlock {
            switch b {
            case .image(let alt, let url) where isContext(url): return .paragraph([InlineRun(text: alt, link: url)])
            case .paragraph(let r): return .paragraph(runs(r))
            case .heading(let level, let r): return .heading(level: level, runs(r))
            case .blockquote(let children): return .blockquote(children.map(block))
            case .alert(let kind, let children): return .alert(kind, children.map(block))
            case .list(var list): list.items = list.items.map { var item = $0; item.blocks = item.blocks.map(block); return item }; return .list(list)
            case .table(var table): table.header = table.header.map(runs); table.rows = table.rows.map { $0.map(runs) }; return .table(table)
            default: return b
            }
        }
        return MarkdownDocument(blocks: document.blocks.map(block))
    }

    // MARK: Image chips

    /// Loaded image chip thumbnails and their average colors, by attachment id.
    // ponytail: unbounded, one 32px bitmap per sent image chip seen this session; cap it if threads with hundreds of images show up
    @MainActor static var thumbnails: [String: (image: CGImage, accent: NSColor?)] = [:]
    @MainActor static var loading: Set<String> = []
    /// Attachments whose thumbnail failed: never asked for again, so relayouts cost no requests.
    @MainActor static var failed: Set<String> = []

    /// `averageImageColor` (contextChipParts.tsx:136-168): the picture drawn at 16x16, each pixel weighted
    /// by its alpha so transparent pixels do not darken the accent. Nil when every pixel is transparent.
    static func averageColor(_ image: CGImage) -> NSColor? {
        var data = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard drawn else { return nil }
        // Canvas `getImageData` returns unpremultiplied values; the bitmap holds premultiplied ones, which
        // already carry the alpha weight.
        var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
        for i in stride(from: 0, to: data.count, by: 4) {
            red += Double(data[i]) * 255; green += Double(data[i + 1]) * 255; blue += Double(data[i + 2]) * 255
            alpha += Double(data[i + 3])
        }
        guard alpha > 0 else { return nil }
        func channel(_ v: Double) -> CGFloat { CGFloat((v / alpha).rounded()) / 255 }
        return NSColor(srgbRed: channel(red), green: channel(green), blue: channel(blue), alpha: 1)
    }
}

/// One context chip in a laid-out message: what it looks like, what a click does and its tooltip.
public struct MarkdownContextChip {
    public enum Action: Equatable {
        case none
        /// A mention: the path in the files panel.
        case openFile(String)
        /// A thread by local id.
        case openThread(String)
        /// An image attachment in the media viewer.
        case expandImage(String)
        /// A file attachment by id.
        case openAttachment(String)
        /// A pull request link.
        case openURL(String)
        /// A terminal excerpt's popover (TerminalContextInlineChip.tsx:19-47).
        case terminal(JSONValue)
    }
    public var look: ComposerChipLook
    public var action: Action
    public var tooltip: String?
    public var accessibility: String
    public var imageAttachmentId: String?
    /// Border box relative to the markdown view, and the label after truncation.
    public var frame: CGRect = .zero
    var label = ""

    init(look: ComposerChipLook, action: Action, tooltip: String?, accessibility: String, imageAttachmentId: String? = nil) {
        self.look = look; self.action = action; self.tooltip = tooltip; self.accessibility = accessibility; self.imageAttachmentId = imageAttachmentId
    }

    /// The border box on device pixels, each edge rounded as Blink snaps boxes (`drawBox` does the same for file chips).
    // ponytail: 2x device pixels, like the other markdown boxes
    var snappedFrame: CGRect {
        let x = (frame.minX * 2).rounded() / 2, y = (frame.minY * 2).rounded() / 2
        return CGRect(x: x, y: y, width: ((frame.maxX * 2).rounded() / 2) - x, height: frame.height)
    }

    /// `button` and `a` chips take the pointer and the hover tint; static ones keep their tooltip.
    var isInteractive: Bool { action != .none }
}

/// The popover a terminal chip opens (TerminalContextInlineChip.tsx:26-46): the terminal's name and line
/// range over the captured text in `bg-muted p-3 font-mono text-xs leading-relaxed whitespace-pre`, which
/// scrolls past 320pt (`max-h-80 overflow-auto`).
final class TerminalContextDetailsView: DSView {
    private let frameLayer = BoxDecorationLayer()
    private let rule = CALayer()
    private let icon = IconView(name: .terminal, size: 16)
    private let name = LabelView("", font: DSFont.ui(14, weight: .medium))
    private let lines = LabelView("", font: DSFont.ui(12))
    private let text: PreformattedTextView
    private let scroll: ScrollAreaView
    /// `width="lg"` (384) inside `padding="compact"` (12 each side) and the popup's 1px border.
    static let width: CGFloat = 384 - 2 - 24

    init(record: JSONValue) {
        text = PreformattedTextView(record["text"]?.stringValue ?? "")
        scroll = ScrollAreaView(documentView: text, scrollbars: .native) // `max-h-80 overflow-auto` (TerminalContextInlineChip.tsx:38)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        frameLayer.host = self
        layer?.addSublayer(frameLayer)
        layer?.addSublayer(rule)
        rule.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        name.text = record["terminalLabel"]?.stringValue ?? ""
        name.lineHeight = 20
        let start = record["lineStart"]?.intValue ?? 1, end = record["lineEnd"]?.intValue ?? start
        lines.text = start == end ? "Line \(start)" : "Lines \(start)–\(end)"
        lines.lineHeight = 16
        text.setAccessibilityLabel("Captured terminal output")
        [icon, name, lines, scroll].forEach(addSubview)
        setAccessibilityLabel("Terminal excerpt, \(record["label"]?.stringValue ?? "")")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: 1 + 36 + 1 + min(320, text.contentSize.height) + 1)
    }

    override func layout() {
        super.layout()
        frameLayer.layout(boxSize: bounds.size)
        let w = bounds.width
        // `px-3 py-2` header, `gap-2`.
        icon.frame = NSRect(x: 1 + 12, y: 1 + 10, width: 16, height: 16)
        let linesWidth = ceil(lines.textWidth)
        lines.frame = NSRect(x: w - 1 - 12 - linesWidth, y: 1 + 10, width: linesWidth, height: 16)
        name.frame = NSRect(x: icon.frame.maxX + 8, y: 1 + 8, width: max(0, lines.frame.minX - 8 - icon.frame.maxX - 8), height: 20)
        rule.frame = CGRect(x: 1, y: 1 + 36, width: w - 2, height: 1)
        scroll.frame = NSRect(x: 1, y: 1 + 37, width: w - 2, height: max(0, bounds.height - 1 - 37 - 1))
        let size = text.contentSize
        text.frame = NSRect(x: 0, y: 0, width: max(scroll.frame.width, size.width), height: size.height)
    }

    override func updateLayer() {
        var box = BoxStyle()
        box.radius = 6
        box.fill = Themed.color(\.background, 0.8)
        box.border = Themed.color(\.border, 0.7)
        frameLayer.boxStyle = box
        rule.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
        text.layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self)
        icon.strokeColor = Themed.color(\.success)
        name.color = Themed.color(\.foreground)
        lines.color = Themed.color(\.secondaryLabel)
        text.needsDisplay = true
    }
}

/// Monospaced text that never wraps, with `p-3`, drawn line by line.
final class PreformattedTextView: DSView {
    private let lines: [String]
    static let font = DSFont.mono(12)
    static let lineHeight: CGFloat = 19.5 // `text-xs leading-relaxed`

    init(_ text: String) {
        lines = text.components(separatedBy: "\n")
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { false }

    var contentSize: CGSize {
        let width = lines.map { TextLine(NSAttributedString(string: $0, attributes: [.font: Self.font])).width }.max() ?? 0
        return CGSize(width: ceil(width) + 24, height: CGFloat(lines.count) * Self.lineHeight + 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Themed.color(\.foreground)]
        for (i, line) in lines.enumerated() {
            let top = 12 + CGFloat(i) * Self.lineHeight
            guard top + Self.lineHeight >= dirtyRect.minY, top <= dirtyRect.maxY else { continue }
            let t = TextLine(NSAttributedString(string: line, attributes: attributes))
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: 12, y: t.baseline(top: top, lineHeight: Self.lineHeight))
            CTLineDraw(t.line, ctx)
            ctx.restoreGState()
        }
    }
}

