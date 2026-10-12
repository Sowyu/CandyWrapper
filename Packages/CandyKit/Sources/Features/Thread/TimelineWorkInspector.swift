import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What an expanded entry shows: `V2ItemInspector` (V2ItemInspector.tsx:222-424) for projected items, the
/// plain expanded body for the rest. Blocks stack top to bottom; `gap` is the space above each one
/// (`space-y-2` between the inspector's parts, `space-y-1.5` inside a tool call, `space-y-1` in lists).
struct WorkDetail: Hashable {
    /// Mono text: `note` is the muted italic of "Loading output…" and "No output.".
    /// `pattern` is a search query: `foreground/85` like a command, without the shell highlighting.
    enum Tone: Hashable { case command, pattern, output, error, note, json }

    enum Action: Hashable {
        case openDiff(RunId, String?)
        case rollBack(checkpointId: String, scopeId: String)
        case openFork(ThreadId)
        case openSubagent(ThreadId)

        var title: String {
            switch self {
            case .openDiff: "Open diff"
            case .rollBack: "Roll back"
            case .openFork: "Open fork"
            case .openSubagent: "Open subagent thread"
            }
        }
        /// `size-3` glyphs before the label.
        var icon: IconName? {
            switch self {
            case .rollBack: .rotateCcw
            case .openFork: .gitBranch
            default: nil
            }
        }
    }

    enum Kind: Hashable {
        /// `monoClassName` text: a command, an output (`max-h-80`, scrolls), an error or a note.
        case mono(Tone)
        /// `toolCallLines` arguments: the key muted, then the value at `foreground/85`.
        case args([[String]])
        /// `text-xs text-muted-foreground` sans lines (a checkpoint's state, a handoff).
        case caption
        /// A file change's header: the path (mono muted) and the `+n -n` counts.
        case fileHeader(additions: Int?, deletions: Int?)
        /// One `font-mono text-muted-foreground` list line (a file change's operations).
        case listLine
        /// A file search hit: the path at `foreground/80`.
        case path
        /// A search hit's preview or snippet: `text-xs text-muted-foreground`, wrapping.
        case preview
        /// A web result's title: `font-medium text-foreground`, a link with the external icon when the URL is safe.
        case link(String?)
    }

    struct Block: Hashable {
        var text: String
        var kind: Kind
        var gap: CGFloat = 0
        /// A button after the text in the same `flex flex-wrap gap-2` row, or alone when `text` is empty.
        var action: Action?
    }

    var blocks: [Block] = []
    /// The stream left this entry's output out; it loads when the row opens, so the row expands
    /// even before anything is fetched (`turnItemHasDetail`, itemDetail.ts:227-248).
    var fetches = false
    var isEmpty: Bool { blocks.isEmpty && !fetches }

    /// Mono blocks of plain text (tests and the plain expanded body).
    init(_ blocks: [(String, Tone)] = []) {
        self.blocks = blocks.enumerated().map { i, b in Block(text: b.0, kind: .mono(b.1), gap: i == 0 ? 0 : 6) }
    }

    mutating func mono(_ text: String, _ tone: Tone, gap: CGFloat = 6) {
        blocks.append(Block(text: text, kind: .mono(tone), gap: blocks.isEmpty ? 0 : gap))
    }

    /// The entry's inspector. `output` is the fetch state of an output the stream left out;
    /// `checkpointStatus` reads `useV2ItemSupport`'s checkpoint for its id.
    static func of(_ e: WorkLogEntry, label: String, workspaceRoot: String?, output: ToolOutputState? = nil,
                   checkpointStatus: ((String) -> String?)? = nil) -> WorkDetail {
        if let read = WorkLog.readOutput(e, workspaceRoot: workspaceRoot), WorkLog.toolGroupAction(e) == .read {
            // A read expands to its plain text, then the output fetched for it (MessagesTimeline.tsx:5512-5517, :5764-5770).
            var d = WorkDetail()
            d.fetches = e.projectedItem.map { TurnItemDetail.needsFetch($0.item) } ?? false
            if !read.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.mono(read, .output) }
            if d.fetches { d.addFetched(output) }
            return d
        }
        if let item = e.projectedItem?.item ?? e.structuredPayload, e.projectedItem != nil {
            return inspector(item, workspaceRoot: workspaceRoot, output: output, checkpointStatus: checkpointStatus)
        }
        return plain(e, label: label, workspaceRoot: workspaceRoot)
    }

    /// `ToolOutput` (V2ItemInspector.tsx:149-175): the text, else loading, error or empty.
    mutating func addFetched(_ output: ToolOutputState?) {
        switch output {
        case .loading: mono("Loading output…", .note)
        case .failed(let message): mono("Couldn't load output: " + message, .error)
        case .fetched(.gone): mono("Couldn't load output: Output is no longer available.", .error)
        case .fetched(.output(let text?)) where !text.isEmpty: mono(text, .output)
        case .fetched(.output): mono("No output.", .note)
        case .fetched(.mismatch), nil: break
        }
    }

    /// `formatToolValue`: a string as is, else pretty JSON (`{}` and `[]` show nothing).
    static func toolValue(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        if let text = value.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8), text != "{}", text != "[]" else { return nil }
        return text
    }

    /// `JSON.stringify(value)` for an argument that is not a non-empty string.
    private static func compact(_ value: JSONValue) -> String {
        if let s = value.stringValue, !s.isEmpty { return s }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func inspector(_ item: TurnItem, workspaceRoot: String?, output: ToolOutputState?, checkpointStatus: ((String) -> String?)?) -> WorkDetail {
        var d = WorkDetail()
        d.fetches = TurnItemDetail.needsFetch(item)
        func structured(_ text: String?) {
            guard let text, !text.isEmpty else { return }
            d.blocks.append(Block(text: text, kind: .mono(.output), gap: d.blocks.isEmpty ? 0 : 8))
        }
        /// `ToolCallBody` (:192-218): the call, the result, a failing exit code, `space-y-1.5`.
        func toolCall(command: String?, args: JSONValue?, exitCode: Int?) {
            if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
                d.mono(commandDisplayText(command), .command)
            } else if let args, case .object(let fields) = args, !(args["truncated"]?.boolValue == true && args["summary"]?.stringValue != nil) {
                let pairs = fields.keys.sorted().compactMap { key -> [String]? in fields[key].map { [key, compact($0)] } }
                if !pairs.isEmpty { d.blocks.append(Block(text: "", kind: .args(pairs), gap: d.blocks.isEmpty ? 0 : 6)) }
            } else if let text = toolValue(args) {
                d.mono(text, .json)
            }
            if d.fetches { d.addFetched(output) } else if let text = toolValue(item.output), !text.isEmpty { d.mono(text, .output) }
            if let code = exitCode, code != 0 { d.mono("exit \(code)", .error) }
        }
        switch item.type {
        case .commandExecution:
            toolCall(command: item.input?.stringValue ?? "", args: nil, exitCode: item.exitCode)
        case .dynamicTool:
            toolCall(command: nil, args: item.input, exitCode: nil)
        case .fileChange:
            let file = item["fileName"]?.stringValue ?? ""
            let action = item.runId.map { Action.openDiff($0, item["fileName"]?.stringValue) }
            d.blocks.append(Block(text: formatWorkspaceRelativePath(file, workspaceRoot: workspaceRoot),
                                  kind: .fileHeader(additions: item["additions"]?.intValue, deletions: item["deletions"]?.intValue), action: action))
            if item.status == .failed, let diff = item["diffStr"]?.stringValue, !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                structured(diff)
            }
            for (i, change) in (item["changes"]?.arrayValue ?? []).enumerated() {
                let operation = change["operation"]?.stringValue ?? ""
                let old = change["oldPath"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 + " → " } ?? ""
                let path = formatWorkspaceRelativePath(change["path"]?.stringValue ?? "", workspaceRoot: workspaceRoot)
                let types = [change["fileType"]?.stringValue, change["mimeType"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }
                let suffix = types.isEmpty ? "" : " (" + types.joined(separator: ", ") + ")"
                d.blocks.append(Block(text: operation + " " + old + path + suffix, kind: .listLine, gap: i == 0 ? 8 : 4))
            }
        case .fileSearch:
            if let pattern = item["pattern"]?.stringValue, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                d.blocks.append(Block(text: pattern, kind: .mono(.pattern)))
            }
            for (i, result) in (item["results"]?.arrayValue ?? []).enumerated() {
                let path = formatWorkspaceRelativePath(result["fileName"]?.stringValue ?? "", workspaceRoot: workspaceRoot)
                    + (result["line"]?.intValue.map { ":\($0)" } ?? "") + (result["column"]?.intValue.map { ":\($0)" } ?? "")
                d.blocks.append(Block(text: path, kind: .path, gap: d.blocks.isEmpty ? 0 : i == 0 ? 8 : 4))
                if let preview = result["preview"]?.stringValue, !preview.isEmpty { d.blocks.append(Block(text: preview, kind: .preview, gap: 2)) }
            }
        case .webSearch:
            let patterns = (item["patterns"]?.arrayValue ?? []).compactMap(\.stringValue)
            if !patterns.isEmpty { d.blocks.append(Block(text: patterns.joined(separator: "\n"), kind: .mono(.pattern))) }
            for (i, result) in (item["results"]?.arrayValue ?? []).enumerated() {
                let url = result["url"]?.stringValue
                let safe = url.flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? url : nil }
                let title = result["title"]?.stringValue ?? url ?? "Search result"
                d.blocks.append(Block(text: title, kind: .link(safe), gap: d.blocks.isEmpty ? 0 : i == 0 ? 8 : 6))
                if let snippet = result["snippet"]?.stringValue, !snippet.isEmpty { d.blocks.append(Block(text: snippet, kind: .preview)) }
            }
        case .approvalRequest: structured(item["prompt"]?.stringValue)
        case .userInputRequest:
            structured((item["questions"]?.arrayValue ?? []).compactMap { $0["question"]?.stringValue }.joined(separator: "\n\n"))
        case .notification: structured(item["detail"]?.stringValue)
        case .systemNotice: structured(item["message"]?.stringValue)
        case .error: structured(item["failure"]?["message"]?.stringValue)
        case .proposedPlan: structured(item["markdown"]?.stringValue)
        case .todoList:
            structured((item["steps"]?.arrayValue ?? []).map { ($0["status"]?.stringValue == "completed" ? "✓ " : "○ ") + ($0["text"]?.stringValue ?? "") }.joined(separator: "\n"))
        case .checkpoint:
            let id = item["checkpointId"]?.stringValue ?? ""
            let support = checkpointStatus?(id)
            let files = item["files"]?.arrayValue?.count ?? 0
            let action = support == "ready" ? Action.rollBack(checkpointId: id, scopeId: item["scopeId"]?.stringValue ?? "") : nil
            d.blocks.append(Block(text: "\(support ?? item.status.rawValue) · \(files) files", kind: .caption, action: action))
        case .fork:
            if let target = item["targetThreadId"]?.stringValue { d.blocks.append(Block(text: "", kind: .caption, action: .openFork(ThreadId(target)))) }
        case .subagent:
            if let child = item["childThreadId"]?.stringValue { d.blocks.append(Block(text: "", kind: .caption, action: .openSubagent(ThreadId(child)))) }
        case .handoff:
            // ponytail: the status reads the item; T3 prefers the projection's context handoff and transfer (useV2ItemSupport). Port with handoff support
            let from = (item["fromProviderInstanceIds"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
            let to = item["toProviderInstanceId"]?.stringValue ?? ""
            let strategy = (item["strategy"]?.stringValue ?? "").replacingOccurrences(of: "_", with: " ")
            d.blocks.append(Block(text: from + " → " + to, kind: .caption))
            d.blocks.append(Block(text: strategy + " · " + item.status.rawValue, kind: .caption, gap: 4))
        default: break
        }
        return d
    }

    /// Entries without a projected item: the command, the output, a failing exit code, changed files or the detail.
    static func plain(_ e: WorkLogEntry, label: String, workspaceRoot: String?) -> WorkDetail {
        var d = WorkDetail()
        let item = e.structuredPayload
        func add(_ text: String?, _ tone: Tone) {
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != label,
                  !d.blocks.contains(where: { $0.text == t }) else { return }
            d.mono(t, tone)
        }
        if e.itemType == .commandExecution || e.command != nil {
            add((e.command ?? item?.input?.stringValue).map(commandDisplayText), .command)
            add(item?.output?.stringValue ?? e.detail, .output)
            if let code = item?.exitCode, code != 0 { d.mono("exit \(code)", .error) }
            return d
        }
        if e.itemType == .fileChange, let files = e.changedFiles {
            add(files.map { formatWorkspaceRelativePath($0, workspaceRoot: workspaceRoot) }.joined(separator: "\n"), .output)
            return d
        }
        add(e.detail, .output)
        add(item?.output?.stringValue, .output)
        return d
    }
}

/// The inspector's body. Mono blocks are `font-mono` at the code size with `leading-relaxed`, outputs clip
/// at 320pt and scroll (`max-h-80 overflow-auto`); sans blocks are `text-xs`. Buttons are `size="xs" variant="outline"`.
final class WorkDetailView: DSView {
    static var font: NSFont { DSFont.mono(13) }
    static let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    static let lineHeight: CGFloat = 13 * 1.625
    static let captionLineHeight: CGFloat = 16
    static let maxBlock: CGFloat = 320

    var detail = WorkDetail() { didSet { if detail != oldValue { cache = nil; rebuildButtons(); updateTrackingAreas(); needsDisplay = true; needsLayout = true } } }
    var onAction: ((WorkDetail.Action) -> Void)?

    /// One block placed at a width: its text layout, where the text and the button sit, its height.
    private struct Laid {
        var text: TextBlockLayout?
        var counts: TextBlockLayout?
        var textOrigin = CGPoint.zero
        var countsOrigin = CGPoint.zero
        var button: CGRect?
        var icon: CGRect?
        var height: CGFloat = 0
        var capped = false
    }
    private var cache: (width: CGFloat, laid: [Laid])?
    private var blockScrollers: [Int: NSScrollView] = [:]
    private var buttons: [Int: ButtonView] = [:]
    private var icons: [Int: IconView] = [:]
    private var hoveredLink: Int?

    override var wantsUpdateLayer: Bool { false }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
        clipsToBounds = true
    }

    private func rebuildButtons() {
        buttons.values.forEach { $0.removeFromSuperview() }
        icons.values.forEach { $0.removeFromSuperview() }
        buttons = [:]; icons = [:]
        for (i, block) in detail.blocks.enumerated() {
            if let action = block.action {
                let button = ButtonView(action.title, icon: action.icon, variant: .outline, size: .xs)
                button.iconSize = 12
                button.action = { [weak self] in self?.onAction?(action) }
                addSubview(button)
                buttons[i] = button
            }
            if case .link(let url?) = block.kind, !url.isEmpty {
                let icon = IconView(name: .externalLink, size: 12, strokeColor: TL.c(\.foreground))
                addSubview(icon)
                icons[i] = icon
            }
        }
    }

    private static func attributed(_ block: WorkDetail.Block, underline: Bool = false) -> (NSAttributedString, CGFloat) {
        let mono = WorkDetailView.font, sans = DSFont.ui(12)
        switch block.kind {
        case .mono(let tone):
            let color: NSColor = switch tone {
            case .command, .pattern: TL.c(\.foreground, 0.85)
            case .output, .note, .json: TL.c(\.mutedForeground)
            case .error: TL.c(\.destructive)
            }
            let text = tone == .command ? MarkdownShellCommand.visible(block.text) : block.text
            let s = NSMutableAttributedString(string: text, attributes: [.font: tone == .note ? italic : mono, .foregroundColor: color])
            if tone == .json || tone == .command {
                for token in CodeHighlighter.tokens(text, language: tone == .json ? "json" : "bash") { s.addAttribute(.foregroundColor, value: token.kind.color, range: token.range) }
            }
            return (s, lineHeight)
        case .args(let pairs):
            let s = NSMutableAttributedString()
            for (i, pair) in pairs.enumerated() {
                if i > 0 { s.append(NSAttributedString(string: "\n", attributes: [.font: mono])) }
                s.append(NSAttributedString(string: (pair.first ?? "") + " ", attributes: [.font: mono, .foregroundColor: TL.c(\.mutedForeground)]))
                s.append(NSAttributedString(string: pair.count > 1 ? pair[1] : "", attributes: [.font: mono, .foregroundColor: TL.c(\.foreground, 0.85)]))
            }
            return (s, lineHeight)
        // Plain `font-mono` inside the `text-xs` root: 12px on 16px lines, not the code size.
        case .fileHeader, .listLine:
            return (NSAttributedString(string: block.text, attributes: [.font: DSFont.mono(12), .foregroundColor: TL.c(\.mutedForeground)]), captionLineHeight)
        case .path:
            return (NSAttributedString(string: block.text, attributes: [.font: DSFont.mono(12), .foregroundColor: TL.c(\.foreground, 0.8)]), captionLineHeight)
        case .caption, .preview:
            return (NSAttributedString(string: block.text, attributes: [.font: sans, .foregroundColor: TL.c(\.mutedForeground)]), captionLineHeight)
        case .link:
            var attributes: [NSAttributedString.Key: Any] = [.font: DSFont.ui(12, weight: .medium), .foregroundColor: TL.c(\.foreground)]
            if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            return (NSAttributedString(string: block.text, attributes: attributes), captionLineHeight)
        }
    }

    /// `+n -n` in `text-xs`: success then destructive.
    private static func counts(additions: Int?, deletions: Int?) -> NSAttributedString? {
        guard additions != nil || deletions != nil else { return nil }
        let font = DSFont.ui(12)
        let s = NSMutableAttributedString(string: "+\(additions ?? 0)", attributes: [.font: font, .foregroundColor: TL.c(\.success)])
        s.append(NSAttributedString(string: " ", attributes: [.font: font]))
        s.append(NSAttributedString(string: "-\(deletions ?? 0)", attributes: [.font: font, .foregroundColor: TL.c(\.destructive)]))
        return s
    }

    private func laid(_ width: CGFloat) -> [Laid] {
        if let cache, cache.width == width { return cache.laid }
        var out: [Laid] = []
        for (i, block) in detail.blocks.enumerated() {
            var l = Laid()
            let (string, lineHeight) = Self.attributed(block, underline: hoveredLink == i)
            let buttonSize = buttons[i].map { CGSize(width: $0.intrinsicContentSize.width, height: 24) }
            switch block.kind {
            case .mono:
                var text = TextBlockLayout(string, width: width, lineHeight: lineHeight)
                l.capped = text.height > Self.maxBlock
                // The scrollbar takes its 6px lane from the text.
                if l.capped { text = TextBlockLayout(string, width: width - ScrollAreaScroller.laneWidth, lineHeight: lineHeight) }
                l.text = text
                l.height = min(text.height, Self.maxBlock)
            case .link(let url):
                let iconRoom: CGFloat = url == nil ? 0 : 16
                let text = TextBlockLayout(string, width: max(1, width - iconRoom), lineHeight: lineHeight)
                l.text = text
                l.height = text.height
                if url != nil {
                    let w = text.widths.max() ?? 0
                    l.icon = CGRect(x: ceil(w) + 4, y: (text.height - 12) / 2, width: 12, height: 12)
                }
            default:
                // `flex flex-wrap items-center gap-2`: the text, the counts, then the button.
                var items: [(size: CGSize, kind: Int)] = []
                var text: TextBlockLayout?
                if !block.text.isEmpty {
                    let t = TextBlockLayout(string, width: width, lineHeight: lineHeight)
                    text = t
                    items.append((CGSize(width: t.lines.count > 1 ? width : ceil(t.widths.first ?? 0), height: t.height), 0))
                }
                if case .fileHeader(let a, let d) = block.kind, let c = Self.counts(additions: a, deletions: d) {
                    let t = TextBlockLayout(c, width: width, lineHeight: Self.captionLineHeight)
                    l.counts = t
                    items.append((CGSize(width: ceil(t.widths.first ?? 0), height: t.height), 1))
                }
                if let buttonSize { items.append((buttonSize, 2)) }
                var x: CGFloat = 0, y: CGFloat = 0, lineHeightMax: CGFloat = 0
                var line: [(CGRect, Int)] = []
                func flush() {
                    for (rect, kind) in line {
                        let origin = CGPoint(x: rect.minX, y: y + (lineHeightMax - rect.height) / 2)
                        switch kind {
                        case 0: l.textOrigin = origin
                        case 1: l.countsOrigin = origin
                        default: l.button = CGRect(origin: origin, size: rect.size)
                        }
                    }
                    y += lineHeightMax
                    line = []; x = 0; lineHeightMax = 0
                }
                for item in items {
                    if !line.isEmpty, x + 8 + item.size.width > width { flush(); y += 8 }
                    if !line.isEmpty { x += 8 }
                    line.append((CGRect(x: x, y: 0, width: item.size.width, height: item.size.height), item.kind))
                    x += item.size.width
                    lineHeightMax = max(lineHeightMax, item.size.height)
                }
                if !line.isEmpty { flush() }
                l.text = text
                l.height = y
            }
            out.append(l)
        }
        cache = (width, out)
        return out
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let laid = laid(width)
        return zip(detail.blocks, laid).reduce(0) { $0 + $1.0.gap + $1.1.height }
    }

    override func layout() {
        super.layout()
        let laid = laid(bounds.width)
        var y: CGFloat = 0
        for (i, (block, l)) in zip(detail.blocks, laid).enumerated() {
            y += block.gap
            if let rect = l.button { buttons[i]?.frame = rect.offsetBy(dx: 0, dy: y) }
            if let rect = l.icon { icons[i]?.frame = rect.offsetBy(dx: 0, dy: y) }
            if l.capped, let text = l.text {
                let scroll = blockScrollers[i] ?? {
                    let s = NSScrollView(); s.drawsBackground = false
                    s.useT3Scrollbars(.native) // `max-h-80 overflow-auto` (V2ItemInspector.tsx:85, :161)
                    s.documentView = ThreadWorkDetailBlockView()
                    addSubview(s); blockScrollers[i] = s
                    return s
                }()
                scroll.isHidden = false
                scroll.frame = NSRect(x: 0, y: y, width: bounds.width, height: l.height)
                if let body = scroll.documentView as? ThreadWorkDetailBlockView {
                    body.textLayout = text
                    body.frame = NSRect(x: 0, y: 0, width: bounds.width - ScrollAreaScroller.laneWidth, height: text.height)
                }
            } else {
                blockScrollers[i]?.isHidden = true
            }
            y += l.height
        }
        for (i, scroll) in blockScrollers where i >= laid.count { scroll.isHidden = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldSmoothFonts(true)
        var y: CGFloat = 0
        for (block, l) in zip(detail.blocks, laid(bounds.width)) {
            y += block.gap
            if !l.capped {
                l.text?.draw(in: ctx, origin: CGPoint(x: l.textOrigin.x, y: y + l.textOrigin.y), width: bounds.width, alignment: .left)
                l.counts?.draw(in: ctx, origin: CGPoint(x: l.countsOrigin.x, y: y + l.countsOrigin.y), width: bounds.width, alignment: .left)
            }
            y += l.height
        }
    }

    // MARK: Links

    private func link(at point: CGPoint) -> Int? {
        var y: CGFloat = 0
        for (i, (block, l)) in zip(detail.blocks, laid(bounds.width)).enumerated() {
            y += block.gap
            if case .link(let url?) = block.kind, !url.isEmpty, let text = l.text {
                let w = ceil(text.widths.max() ?? 0) + (l.icon == nil ? 0 : 16)
                if CGRect(x: 0, y: y, width: w, height: l.height).contains(point) { return i }
            }
            y += l.height
        }
        return nil
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard detail.blocks.contains(where: { if case .link(let u?) = $0.kind { !u.isEmpty } else { false } }) else { tracking = nil; return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseMoved(with event: NSEvent) { setHovered(link(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }
    override func cursorUpdate(with event: NSEvent) {
        if link(at: convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }
    /// `hover:underline` on a result link.
    private func setHovered(_ index: Int?) {
        guard index != hoveredLink else { return }
        hoveredLink = index
        if index != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        cache = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = link(at: convert(event.locationInWindow, from: nil)), case .link(let href?) = detail.blocks[i].kind,
              let url = URL(string: href) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Only expanded blocks larger than the source's 320pt viewport own a scroller.
private final class ThreadWorkDetailBlockView: DSView {
    var textLayout: TextBlockLayout? { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        textLayout?.draw(in: ctx, origin: .zero, width: bounds.width, alignment: .left)
    }
}
