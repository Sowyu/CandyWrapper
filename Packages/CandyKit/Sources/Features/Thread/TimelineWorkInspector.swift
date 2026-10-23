import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// An image in an open work row, loaded through a signed asset URL on the open thread's environment.
enum WorkImage: Hashable {
    /// A tool's output image (`ToolOutput`, V2ItemInspector.tsx:149-158), alt "Tool output image".
    case toolOutput(ToolOutputImage)
    /// The host file a read viewed (`resolveViewedImageAsset`, presentation.ts:501-523), a `media-file`.
    /// `kept` names the tool item, whose copy CandyWrapper kept (`AgentImageCache`) loads once the file is gone.
    case file(String, workspaceRoot: String?, kept: KeptItem? = nil)

    struct KeptItem: Hashable { var thread: ThreadId; var item: TurnItemId }

    /// The cache key: a file shares its measured size with Markdown images of the same path.
    var key: String {
        switch self {
        case .toolOutput(let image): image.key
        case .file(let path, _, _): MarkdownImageSource.workspaceFile(path).key
        }
    }

    /// `media.name` is the file's basename (mediaSource.ts:68-88).
    var alt: String {
        switch self {
        case .toolOutput: "Tool output image"
        case .file(let path, _, _): (path as NSString).lastPathComponent
        }
    }

    var reference: MediaReference? {
        switch self {
        case .toolOutput: nil
        case .file(let path, let root, _): MediaReference.file(path, workspaceRoot: root)
        }
    }

    var cacheable: Bool { if case .toolOutput = self { true } else { false } }

    var loader: AsyncImageView.Loader {
        switch self {
        case .toolOutput(let image): MarkdownImages.assetLoader(key: image.key, resource: image.resource)
        case .file(let path, _, let kept): MarkdownImages.viewedLoader(path, thread: kept?.thread, item: kept?.item)
        }
    }
}

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
        /// An image in a `ChatMarkdownAssetImage` box at most 16rem tall.
        case image(WorkImage)
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
    @MainActor static func of(_ e: WorkLogEntry, label: String, workspaceRoot: String?, output: ToolOutputState? = nil,
                   checkpointStatus: ((String) -> String?)? = nil) -> WorkDetail {
        var d = body(e, label: label, workspaceRoot: workspaceRoot, output: output, checkpointStatus: checkpointStatus)
        // The image a read viewed sits above the rest in `WorkLogDetails kind="media"` (`mt-1`, MessagesTimeline.tsx:5504-5520,
        // :5723-5734); the panel below keeps its `mt-0.5`. The detail box starts 2pt below the line.
        // T3 also shows the tool result's own images (:5764-5770), so a read of an image shows it twice, and when the
        // file is gone the preview keeps a large "Image unavailable" slot (ChatMarkdown.tsx:1491-1510). Here the
        // result's image wins: the file preview waits for the fetched output and shows only when that has no image,
        // and a preview that failed takes no space.
        if let path = WorkLog.viewedImagePath(e), case .workspaceFile(let file) = MarkdownImageSource.classify(path, workspaceRoot: workspaceRoot),
           !d.showsImageOutput(output), !MarkdownImages.failed.contains(MarkdownImageSource.workspaceFile(file).key) {
            if !d.blocks.isEmpty { d.blocks[0].gap = 2 }
            d.blocks.insert(Block(text: "", kind: .image(.file(file, workspaceRoot: workspaceRoot, kept: e.projectedItem.map { .init(thread: $0.sourceThreadId, item: $0.sourceItemId) })), gap: 2), at: 0)
        }
        return d
    }

    private static func body(_ e: WorkLogEntry, label: String, workspaceRoot: String?, output: ToolOutputState?,
                             checkpointStatus: ((String) -> String?)?) -> WorkDetail {
        if let read = WorkLog.readOutput(e, workspaceRoot: workspaceRoot), WorkLog.toolGroupAction(e) == .read {
            // A read expands to its plain text, then the output fetched for it (MessagesTimeline.tsx:5512-5517, :5764-5770).
            var d = WorkDetail()
            d.fetches = e.projectedItem.map { TurnItemDetail.needsFetch($0.item) } ?? false
            if !read.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.mono(read, .output) }
            if d.fetches, let row = e.projectedItem { d.addFetched(output, row: row) }
            return d
        }
        if let item = e.projectedItem?.item ?? e.structuredPayload, e.projectedItem != nil {
            return inspector(item, row: e.projectedItem, workspaceRoot: workspaceRoot, output: output, checkpointStatus: checkpointStatus)
        }
        return plain(e, label: label, workspaceRoot: workspaceRoot)
    }

    /// `ToolOutput` (V2ItemInspector.tsx:149-175): the images, then the text, else loading, error or empty.
    /// The images are the fetched item's (`useFetchedTurnItem`, :103-137), which the row's source ids name.
    mutating func addFetched(_ output: ToolOutputState?, row: ProjectedTurnItem) {
        if case .fetched(.output(_, let count))? = output {
            images(ToolOutputImage.list(threadId: row.sourceThreadId, itemId: row.sourceItemId, count: count))
        }
        switch output {
        case .live(let text, let truncated, let running):
            if !text.isEmpty { mono(text, .output) }
            else if !running { mono("No output.", .note) }
            if truncated { mono("Earlier output was truncated.", .note) }
        case .loading: mono("Loading output…", .note)
        case .failed(let message): mono("Couldn't load output: " + message, .error)
        case .fetched(.gone): mono("Couldn't load output: Output is no longer available.", .error)
        case .fetched(.output(let text?, _)) where !text.isEmpty: mono(text, .output)
        case .fetched(.output(_, let count)): if count == 0 { mono("No output.", .note) }
        case .fetched(.mismatch), nil: break
        }
    }

    /// The tool result carries an image, or may once its withheld output arrives.
    func showsImageOutput(_ output: ToolOutputState?) -> Bool {
        if blocks.contains(where: { if case .image(.toolOutput) = $0.kind { true } else { false } }) { return true }
        switch output {
        case .fetched?, .failed?, .live?: return false
        case .loading?, nil: return fetches
        }
    }

    mutating func images(_ images: [ToolOutputImage]) {
        for image in images { blocks.append(Block(text: "", kind: .image(.toolOutput(image)), gap: blocks.isEmpty ? 0 : 6)) }
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

    static func inspector(_ item: TurnItem, row: ProjectedTurnItem? = nil, workspaceRoot: String?, output: ToolOutputState?,
                          checkpointStatus: ((String) -> String?)?) -> WorkDetail {
        var d = WorkDetail()
        d.fetches = TurnItemDetail.needsFetch(item) || (item.type == .commandExecution && output != nil)
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
            if d.fetches, let row {
                d.addFetched(output, row: row)
            } else {
                d.images(ToolOutputImage.list(threadId: item.threadId, itemId: item.id, count: TurnItemDetail.outputImageCount(item)))
                if let text = toolValue(item.output), !text.isEmpty { d.mono(text, .output) }
            }
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
        /// A tool output image's box, and whether it holds the decoded image's own size.
        var image: CGRect?
        var settled = false
    }
    /// `images` is what the image boxes were laid from: each one's measured size and whether it failed.
    private var cache: (width: CGFloat, images: [String], laid: [Laid])?
    /// Tool output images by key, while the view is shown. Hiding or closing the row releases them.
    private var imageViews: [String: AsyncImageView] = [:]
    private var imageTooltips: [String: TooltipController] = [:]
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
        case .image:
            return (NSAttributedString(), captionLineHeight)
        }
    }

    // MARK: Images

    /// `maxHeightRem={16}`.
    static let imageMaxHeight: CGFloat = 256

    /// What the image boxes depend on besides the width.
    private func imageSignature() -> [String] {
        detail.blocks.compactMap { block in
            guard case .image(let image) = block.kind else { return nil }
            let size = MarkdownImages.sizes[image.key].map { "\($0.width)x\($0.height)" } ?? "?"
            return size + (MarkdownImages.failed.contains(image.key) ? "!" : "")
        }
    }

    /// `ChatMarkdownImage` (ChatMarkdown.tsx:1391-1520): a `bg-muted/60` 16:9 slot in the workspace frame until the
    /// size is known, then the image's own box at most 30rem wide and 16rem tall. A failure keeps the slot.
    private static func imageBox(_ image: WorkImage, width: CGFloat) -> (rect: CGRect, settled: Bool) {
        if let natural = MarkdownImages.sizes[image.key], !MarkdownImages.failed.contains(image.key) {
            let size = MarkdownImages.displaySize(natural: natural, maxWidth: width, border: 1, maxHeight: imageMaxHeight)
            return (CGRect(origin: .zero, size: size), true)
        }
        let w = min(width, MarkdownStyle.imageMaxWidth)
        return (CGRect(x: 0, y: 0, width: w, height: min(w * 9 / 16, imageMaxHeight)), false)
    }

    private func imageItem(_ image: WorkImage) -> ExpandedImagePreviewView.Item {
        .init(key: image.key, name: image.alt, cacheable: image.cacheable, load: image.loader, reference: image.reference)
    }

    private func placeImages(_ laid: [Laid]) {
        guard !isHiddenOrHasHiddenAncestor else { releaseImages(); return }
        var y: CGFloat = 0, kept: Set<String> = []
        for (block, l) in zip(detail.blocks, laid) {
            y += block.gap
            defer { y += l.height }
            guard case .image(let image) = block.kind, let rect = l.image else { continue }
            kept.insert(image.key)
            let view = imageViews[image.key] ?? makeImageView(image)
            imageViews[image.key] = view
            view.frame = (l.settled ? rect.insetBy(dx: 1, dy: 1) : rect).offsetBy(dx: 0, dy: y)
            view.layer?.cornerRadius = l.settled ? 9 : 10
            // Decode for the largest box the image can take: 30rem wide or 16rem tall.
            view.requestedSide = Int((max(min(bounds.width, MarkdownStyle.imageMaxWidth), Self.imageMaxHeight) * (window?.backingScaleFactor ?? 2)).rounded(.up))
            let failed = MarkdownImages.failed.contains(image.key)
            view.set(key: image.key, fallbackText: failed ? MarkdownImages.unavailableLabel(image.alt) : "", loader: image.loader)
            view.setAccessibilityLabel("Preview " + image.alt)
            imageTooltips[image.key]?.text = image.reference?.tooltip ?? ""
        }
        for (key, view) in imageViews where !kept.contains(key) {
            view.removeFromSuperview(); imageViews[key] = nil; imageTooltips[key] = nil
        }
        window?.invalidateCursorRects(for: self)
    }

    private func makeImageView(_ image: WorkImage) -> AsyncImageView {
        let view = AsyncImageView()
        view.cover = false
        view.cacheable = image.cacheable
        // `text-xs text-muted-foreground`
        view.fallback.color = Themed.color(\.mutedForeground)
        view.fallback.font = DSFont.ui(12)
        view.setAccessibilityRole(.button)
        // The file's path in a code tooltip (MediaActions.tsx), as Markdown images do.
        if image.reference != nil { imageTooltips[image.key] = TooltipController.attach(to: view, text: "", variant: .code) }
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(expandImage(_:))))
        view.onLoad = { [weak self, weak view] in
            // A failed load keeps its slot and says so (ChatMarkdown.tsx:1497-1520).
            guard let self, let view, let key = view.key, self.imageViews[key] === view else { return }
            guard view.image == nil else { self.window?.invalidateCursorRects(for: self); return }
            MarkdownImages.failed.insert(key)
            // A viewed file that failed leaves the row: the timeline measures and configures it again.
            if case .file? = self.image(for: key) { NotificationCenter.default.post(name: MarkdownImages.didMeasure, object: nil, userInfo: ["key": key]) }
            self.cache = nil
            self.needsLayout = true
            self.needsDisplay = true
        }
        view.onContextMenu = { [weak self, weak view] event, source in
            guard let self, let key = view?.key, let image = self.image(for: key) else { return }
            let item = self.imageItem(image)
            var openFile: (() -> Void)?
            if case .file(_, let relative?)? = image.reference, let open = MarkdownImages.openInFileViewer { openFile = { open(relative) } }
            MediaAttachmentContextMenu.show(name: item.name, load: item.load, event: event, view: source, reference: image.reference, openFile: openFile)
        }
        addSubview(view)
        return view
    }

    private func image(for key: String) -> WorkImage? {
        for block in detail.blocks { if case .image(let image) = block.kind, image.key == key { return image } }
        return nil
    }

    private func releaseImages() {
        imageViews.values.forEach { $0.removeFromSuperview() }
        imageViews = [:]
        imageTooltips = [:]
    }

    /// The tool output is not in a Markdown gallery, so the preview holds this one image (markdownImageGallery.ts:11-50).
    @objc private func expandImage(_ gesture: NSClickGestureRecognizer) {
        guard let window, let view = gesture.view as? AsyncImageView, view.image != nil, let key = view.key, let image = image(for: key) else { return }
        ExpandedImagePreviewView(items: [imageItem(image).withPreview(from: view, sharingLoader: true)], index: 0).present(in: window)
    }

    /// `cursor-zoom-in` on a loaded image.
    override func resetCursorRects() {
        super.resetCursorRects()
        var cursor = NSCursor.pointingHand
        if #available(macOS 15, *) { cursor = .zoomIn }
        for view in imageViews.values where view.image != nil { addCursorRect(view.frame, cursor: cursor) }
    }

    override func viewDidHide() {
        super.viewDidHide()
        releaseImages()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
    }

    /// `+n -n` in `text-xs`, in the diff palette (ba1907e8e0, V2ItemInspector.tsx).
    private static func counts(additions: Int?, deletions: Int?) -> NSAttributedString? {
        guard additions != nil || deletions != nil else { return nil }
        let font = DSFont.ui(12)
        let s = NSMutableAttributedString(string: "+\(additions ?? 0)", attributes: [.font: font, .foregroundColor: TL.c(\.diffAddition)])
        s.append(NSAttributedString(string: " ", attributes: [.font: font]))
        s.append(NSAttributedString(string: "-\(deletions ?? 0)", attributes: [.font: font, .foregroundColor: TL.c(\.diffDeletion)]))
        return s
    }

    private func laid(_ width: CGFloat) -> [Laid] {
        let images = imageSignature()
        if let cache, cache.width == width, cache.images == images { return cache.laid }
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
            case .image(let image):
                let box = Self.imageBox(image, width: width)
                l.image = box.rect
                l.settled = box.settled
                l.height = box.rect.height
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
        // An image measured or failed: its box moves even when the row keeps its height.
        if let cache, cache.images != images { needsLayout = true; needsDisplay = true }
        cache = (width, images, out)
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
        placeImages(laid)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldSmoothFonts(FontRuntime.smoothing)
        var y: CGFloat = 0
        for (block, l) in zip(detail.blocks, laid(bounds.width)) {
            y += block.gap
            if let rect = l.image {
                // The slot's `bg-muted/60` until the size is known, the `border-border/40` frame always.
                let box = rect.offsetBy(dx: 0, dy: y)
                if !l.settled {
                    ctx.setFillColor(TL.c(\.muted, 0.6).cgColor)
                    ctx.addPath(CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil))
                    ctx.fillPath()
                }
                ctx.setStrokeColor(TL.c(\.border, 0.4).cgColor)
                ctx.setLineWidth(1)
                ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 9.5, cornerHeight: 9.5, transform: nil))
                ctx.strokePath()
            }
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
