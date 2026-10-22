import AppKit
import DesignSystem
import T3Protocol
import T3Store
import T3Protocol

/// T3's `ChatMarkdown` for one message: all text, rules and boxes drawn into one layer, plus the
/// code block and table buttons as real controls. Height follows the width: `height(forWidth:)`
/// lays out once per width and caches the result until the document changes, so the virtualized
/// timeline can measure rows cheaply. Reuse a view for another message by setting `document`.
// ponytail: one backing layer per message; a very long message gets a large layer. Switch to tiled drawing if memory shows it.
public final class MarkdownView: DSView {
    /// Search changes only the paint of visible rows, never their Markdown layout.
    public var threadFindOccurrence: Int? { didSet { if threadFindOccurrence != oldValue { needsDisplay = true } } }
    public var threadFindQuery = "" { didSet { if threadFindQuery != oldValue { needsDisplay = true } } }
    /// "Run in terminal" on shell code blocks (`onRunShellCommand`, ChatView.tsx:5105-5116): set for a finished assistant
    /// answer in a thread with a project, nil elsewhere.
    public var onRunShellCommand: ((String) -> Void)? {
        didSet { if (oldValue == nil) != (onRunShellCommand == nil) { invalidate() } }
    }

    /// The owner changes this before recycling the view for a different message.
    public var messageID: String? {
        didSet {
            guard messageID != oldValue else { return }
            expandedTables = []; unwrappedCode = []; diagramCode = []; codeOffsets = [:]
            for reset in copiedResets.values { reset.cancel() }
            copiedResets = [:]
            scrollLatch = nil; thumbDrag = nil
            invalidate()
        }
    }
    public var onHeightChange: (() -> Void)?
    private(set) var expandedTables: Set<Int> = []

    public var document = MarkdownDocument(blocks: []) {
        didSet {
            // T3 reads the wrap setting when a code block mounts (`readInitialWordWrapSetting`, ChatMarkdown.tsx:555-557); a
            // view shown again after the setting changed counts as mounted again.
            let wraps = ClientSettingsStore.shared.current.bool("wordWrap")
            guard document != oldValue || wraps != wrapsCode else { return }
            if fadesNewBlocks, document.blocks.count > oldValue.blocks.count {
                fadeIn(blocks: oldValue.blocks.count..<document.blocks.count)
            }
            clearAssistantSelection()
            if messageID == nil && !fadesNewBlocks {
                unwrappedCode = []; diagramCode = []; expandedTables = []; codeOffsets = [:]
            }
            let previous = wraps == wrapsCode ? cache[bounds.width] : nil
            wrapsCode = wraps
            invalidate(redraw: previous == nil)
            reusable = previous
            if let previous { redrawChanges(from: previous, oldBlocks: oldValue.blocks) }
            observeDiagrams()
        }
    }

    // VoiceOver reads a message as its plain text; code block buttons and chips stay reachable as children.
    public override func isAccessibilityElement() -> Bool { !document.blocks.isEmpty }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityValue() -> Any? {
        document.blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A streaming answer grows at its end: redraw from the first top-level block that changed
    /// down to the lower of the old and new bottoms, not the whole message.
    private func redrawChanges(from previous: MarkdownLayout, oldBlocks: [MarkdownBlock]) {
        let width = bounds.width
        guard width > 0, let rect = Self.changedRect(previous: previous, oldBlocks: oldBlocks,
                                                      current: layout(forWidth: width), blocks: document.blocks)
        else { needsDisplay = true; return }
        setNeedsDisplay(rect)
    }

    /// Nil when the change moved earlier content (diagrams, wrap toggles, images, a new width), so all of it redraws.
    static func changedRect(previous: MarkdownLayout, oldBlocks: [MarkdownBlock], current: MarkdownLayout, blocks: [MarkdownBlock]) -> NSRect? {
        let first = zip(oldBlocks, blocks).enumerated().first { $1.0 != $1.1 }?.offset ?? min(oldBlocks.count, blocks.count)
        guard previous.width == current.width, previous.blockTops.count == oldBlocks.count, current.blockTops.count == blocks.count,
              previous.blockTops.prefix(first) == current.blockTops.prefix(first)
        else { return nil }
        let top = min(first < oldBlocks.count ? previous.blockTops[first] : previous.height,
                      first < blocks.count ? current.blockTops[first] : current.height)
        // Glyphs and box borders reach a little past a block's top; 8 pt covers descenders and focus rings.
        let y = max(0, top - 8)
        return NSRect(x: 0, y: y, width: current.width, height: max(previous.height, current.height) - y + 8)
    }

    /// Body text color; nil is T3's 80% foreground. Headings, links and code keep their own colors.
    public var bodyColor: NSColor? {
        didSet { if bodyColor != oldValue { invalidate() } }
    }

    /// The directory relative file paths resolve against: T3's `markdownCwd`, the thread's worktree
    /// or else the project's workspace root. Path-shaped inline code and file links render as chips.
    public var cwd: String? {
        didSet { if cwd != oldValue { invalidate() } }
    }

    /// A plain click on a file chip (`inEditor` false) or a Cmd-click (`inEditor` true). T3 opens the file
    /// in its right files panel (`panelPath`; media in the media viewer, PDF and HTML in the browser
    /// preview when one is available) and Cmd-click opens it in the preferred editor. Without a
    /// handler a click shows the chip's menu, as T3 does when no open action is available.
    public var onOpenFile: ((FileLinkMeta, _ inEditor: Bool) -> Void)?

    /// Mermaid fences render as diagrams once the response settles (false while it streams).
    public var diagramsEnabled = true {
        didSet { if diagramsEnabled != oldValue { invalidate() } }
    }
    private var diagramCode: Set<Int> = []
    private var diagramObserver: NSObjectProtocol?
    private var hasDiagrams: Bool { document.blocks.contains { if case .code(let l, _, _) = $0 { l.lowercased() == "mermaid" } else { false } } }

    /// Parses and shows `markdown`. User messages pass `preservesLineBreaks`.
    public func setMarkdown(_ markdown: String, preservesLineBreaks: Bool = false) {
        document = MarkdownDocument(parsing: markdown, preservesLineBreaks: preservesLineBreaks)
    }

    public var inlineSkills: [ServerProviderSkill] = [] { didSet { if inlineSkills != oldValue { invalidate() } } }
    /// Draws `t3-context://` links as T3's context chips (user messages); nil shows their labels as text.
    public var contextChips: MarkdownContextChips? { didSet { if contextChips != oldValue { invalidate() } } }
    /// A click on an interactive context chip other than a terminal excerpt, which opens its own popover.
    public var onContextChip: ((MarkdownContextChip.Action, NSView) -> Void)?
    /// An image attachment decoded at a pixel side, for the image chip's thumbnail and accent.
    public var contextImageLoader: (@Sendable (_ attachmentId: String, _ side: Int) async -> CGImage?)?
    private var contextChipViews: [ContextChipHitView] = []
    private var hoveredContextChip: Int? {
        didSet {
            guard hoveredContextChip != oldValue else { return }
            if window != nil, !Motion.reduced, let layer { Motion.crossfade(layer) }
            needsDisplay = true
        }
    }
    /// Indices of code blocks whose wrap toggle flipped `wrapsCode`.
    private var unwrappedCode: Set<Int> = []
    private var wrapsCode = true
    /// `scrollLeft` of each code block body with wrapping off, by code block index. Clamped where it is read, so a
    /// narrower width or shorter code needs no fix-up.
    private(set) var codeOffsets: [Int: CGFloat] = [:]
    private var cache: [CGFloat: MarkdownLayout] = [:]
    /// Measuring and drawing can alternate widths. Keep those two, and release widths a panel slide passed.
    private var cachedWidths: [CGFloat] = []
    /// The layout before the last document change, whose unchanged leading blocks the next layout
    /// at its width keeps. Only a document change sets it; any other invalidation drops it.
    private var reusable: MarkdownLayout?
    private var buttons: [ButtonView] = []
    private var chipViews: [FileChipHitView] = []
    private var imageViews: [AsyncImageView] = []
    private var imageTooltips: [TooltipController] = []
    private var imageItems: [ExpandedImagePreviewView.Item] = []
    private var linkViews: [MarkdownLinkHitView] = []

    /// Opens, menus and previews web links for every Markdown view (the app sets it: it knows the
    /// open thread, the browser panel and the pull request reads). Without one a click opens the
    /// system browser and the menu offers that and Copy Link.
    public static var onOpenCitation: ((ThreadAssistantCitation) -> Void)?
    /// The file chip menu's shell items for the open thread (ChatMarkdown.tsx:2335-2397): the preferred editor's
    /// "Open in ..." and the reveal label, each nil when the environment cannot run it. Set by the app.
    public static var fileChipShell: (() -> (openLabel: String?, revealLabel: String?))?
    /// "Open in <editor>": the chip's target path in the preferred editor (`openInPreferredEditor`).
    public static var onOpenFileInEditor: ((FileLinkMeta) -> Void)?
    /// "Reveal in Finder": the chip's file in the server's file manager (`revealMarkdownFileInFileManager`).
    public static var onRevealFile: ((FileLinkMeta) -> Void)?
    /// Whether the open thread can show a browser tab (`canOperatePreview && isPreviewAvailableFor`).
    public static var canOpenFileInBrowser: (() -> Bool)?
    /// "Open in integrated browser": an HTML or PDF file as a signed asset URL in a new tab (`openFileInPreview`).
    public static var onOpenFileInBrowser: ((FileLinkMeta) -> Void)?
    public static weak var linkHandler: MarkdownLinkHandler?
    private var hoveredChip: Int? {
        didSet {
            guard hoveredChip != oldValue else { return }
            // `[a&]:transition-colors` (ContextChip.tsx:26): the chip's border fades. Only the chip differs
            // between the two images, so a cross-fade of the text layer fades just its border.
            if window != nil, !Motion.reduced, let layer { Motion.crossfade(layer) }
            needsDisplay = true
        }
    }
    private var copiedResets: [Int: DispatchWorkItem] = [:]

    public override var wantsUpdateLayer: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
    }

    public override func fontRuntimeDidChange() {
        super.fontRuntimeDidChange()
        invalidate()
    }

    private func invalidate(redraw: Bool = true) {
        cache.removeAll()
        cachedWidths.removeAll()
        reusable = nil
        invalidateIntrinsicContentSize()
        needsLayout = true
        if redraw { needsDisplay = true }
    }

    /// Height changes follow the document, which redraws what moved; a new width redraws everything.
    public override var redrawsOnResize: Bool { false }

    /// Re-lays out when a diagram this message shows finished rendering.
    private func observeDiagrams() {
        guard hasDiagrams else {
            if let diagramObserver { NotificationCenter.default.removeObserver(diagramObserver); self.diagramObserver = nil }
            return
        }
        guard diagramObserver == nil else { return }
        diagramObserver = NotificationCenter.default.addObserver(forName: MermaidDiagrams.didRender, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if hasDiagrams { invalidate() }
    }

    public func layout(forWidth width: CGFloat) -> MarkdownLayout {
        if let hit = cache[width] {
            if cachedWidths.last != width {
                cachedWidths.removeAll { $0 == width }
                cachedWidths.append(width)
            }
            return hit
        }
        let diagrams = hasDiagrams ? MarkdownLayout.Diagrams(enabled: diagramsEnabled, dark: effectiveAppearance.isDark, showingCode: diagramCode) : nil
        let made = MarkdownLayout(document: MarkdownContextChips.document(MarkdownInlineSkills.document(document, skills: inlineSkills)), width: width,
                                  wrapsCode: wrapsCode, unwrappedCode: unwrappedCode, bodyColor: bodyColor, cwd: cwd, expandedTables: expandedTables, diagrams: diagrams, contexts: contextChips,
                                  runsShell: onRunShellCommand != nil, reusing: reusable?.width == width ? reusable : nil)
        if reusable?.width == width { reusable = nil }
        cache[width] = made
        cachedWidths.append(width)
        if cachedWidths.count > 2 { cache[cachedWidths.removeFirst()] = nil }
        return made
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        document.blocks.isEmpty ? 0 : layout(forWidth: width).height
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width, oldHeight = frame.height
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize(); needsDisplay = true }
        // The strip a taller frame uncovers; the document change already marked what moved.
        else if newSize.height > oldHeight { setNeedsDisplay(NSRect(x: 0, y: oldHeight, width: newSize.width, height: newSize.height - oldHeight)) }
    }

    // MARK: Streaming fade

    /// T3 fades each top-level block a streaming answer adds, opacity 0 to 1 over 600ms `ease-out`
    /// (`index.css:2007-2020`, gated on `data-streaming` so history never replays it). The owner sets
    /// this only while the same message streams. The fade is a mask: one opaque band above the new
    /// blocks and one band per new block whose opacity animates, so chips and buttons fade with it.
    public var fadesNewBlocks = false
    private(set) var fadeMask: CALayer?
    private(set) var fadeBands: [(block: Int, layer: CALayer)] = []
    private var fadeEnd: CFTimeInterval = 0
    /// CSS `ease-out`.
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)

    private func fadeIn(blocks: Range<Int>) {
        guard window != nil, !Motion.reduced, let layer else { return }
        let mask: CALayer
        if let fadeMask { mask = fadeMask } else {
            mask = CALayer()
            mask.addSublayer(CALayer()) // the settled band above the fading blocks
            fadeMask = mask
            layer.mask = mask
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for block in blocks {
            let band = CALayer()
            band.backgroundColor = CGColor(gray: 0, alpha: 1)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.6
            fade.timingFunction = Self.easeOut
            band.add(fade, forKey: "opacity")
            mask.addSublayer(band)
            fadeBands.append((block, band))
        }
        fadeEnd = CACurrentMediaTime() + 0.6
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, CACurrentMediaTime() >= self.fadeEnd else { return }
                self.cancelBlockFades()
            }
        }
        needsLayout = true
    }

    /// Drops any running fade at once, for a recycled view that now shows another message.
    public func cancelBlockFades() {
        guard fadeMask != nil else { return }
        layer?.mask = nil
        fadeMask = nil
        fadeBands = []
    }

    private func layoutFadeMask() {
        guard let mask = fadeMask, let first = fadeBands.first else { return }
        let tops = bounds.width > 0 ? layout(forWidth: bounds.width).blockTops : []
        guard tops.count == document.blocks.count, first.block < tops.count else { cancelBlockFades(); return }
        // Wide margins: glyphs, rings and shadows that reach past the bounds stay visible.
        let margin: CGFloat = 400
        let x = -margin, w = bounds.width + 2 * margin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.sublayers?.first?.backgroundColor = CGColor(gray: 0, alpha: 1)
        mask.sublayers?.first?.frame = CGRect(x: x, y: -margin, width: w, height: tops[first.block] + margin)
        for (i, band) in fadeBands.enumerated() {
            let top = band.block < tops.count ? tops[band.block] : bounds.height
            let bottom = i + 1 < fadeBands.count ? min(tops.count > fadeBands[i + 1].block ? tops[fadeBands[i + 1].block] : bounds.height, bounds.height + margin)
                                                 : bounds.height + margin
            band.layer.frame = CGRect(x: x, y: top, width: w, height: max(0, bottom - top))
        }
        CATransaction.commit()
    }

    // MARK: Controls

    public override func layout() {
        super.layout()
        layoutFadeMask()
        layoutChips()
        layoutContextChips()
        layoutLinks()
        layoutImages()
        let controls = bounds.width > 0 ? layout(forWidth: bounds.width).controls : []
        while buttons.count < controls.count {
            let button = ButtonView(icon: .copy, variant: .ghostMuted, size: .iconXs)
            button.iconSize = 12
            addSubview(button)
            buttons.append(button)
        }
        for (i, button) in buttons.enumerated() {
            guard i < controls.count else { button.isHidden = true; continue }
            let control = controls[i]
            button.isHidden = false
            button.frame = control.frame
            if button.title != control.title { button.title = control.title }
            if copiedResets[i] == nil, button.icon != control.icon { button.icon = control.icon }
            if button.variant != control.variant { button.variant = control.variant }
            button.toolTip = nil
            switch control.action {
            case .copy(let text):
                button.setAccessibilityLabel("Copy")
                button.action = { [weak self] in self?.copy(text, button: i) }
            case .copyTable(let table):
                let label = copiedResets[i] == nil ? "Copy table" : "Copied"
                button.setAccessibilityLabel(label)
                button.toolTip = label
                button.action = { [weak self] in self?.showTableCopy(table, button: i) }
            case .runShell(let command):
                button.setAccessibilityLabel("Run in terminal")
                button.toolTip = "Run in terminal"
                button.action = { [weak self] in self?.onRunShellCommand?(command) }
            case .toggleWrap(let index):
                button.setAccessibilityLabel(wrapsCode != unwrappedCode.contains(index) ? "Disable line wrap" : "Wrap lines")
                button.action = { [weak self] in self?.toggleWrap(index) }
            case .toggleDiagram(let index):
                let label = diagramCode.contains(index) ? "Show diagram" : "Show code"
                button.setAccessibilityLabel(label)
                button.toolTip = label
                button.action = { [weak self] in self?.toggleDiagram(index) }
            case .retryDiagram(let code):
                button.setAccessibilityLabel("Retry")
                button.action = { [weak self] in
                    guard let self else { return }
                    MermaidDiagrams.shared.retry(code, dark: self.effectiveAppearance.isDark)
                }
            case .toggleTable(let index):
                let label = expandedTables.contains(index) ? "Collapse table cells" : "Expand table cells"
                button.setAccessibilityLabel(label)
                button.toolTip = label
                button.action = { [weak self] in self?.toggleTable(index) }
            }
        }
    }

    /// Hit regions move and clip with the table content, including after a scroll without relayout.
    private func visibleFrame(_ frame: CGRect) -> CGRect {
        for scroller in codeScrollers where scroller.index < 0 {
            let viewport = scroller.viewport
            if frame.midY >= viewport.minY && frame.midY < viewport.maxY {
                let moved = frame.offsetBy(dx: -codeOffset(scroller.index, viewport, scroller.contentWidth), dy: 0)
                let clipped = moved.intersection(viewport)
                return clipped.isNull ? .zero : clipped
            }
        }
        return frame
    }

    /// One transparent view per file chip: pointer cursor, hover, tooltip, click and context menu.
    private func layoutChips() {
        let chips = bounds.width > 0 ? layout(forWidth: bounds.width).fileChips : []
        while chipViews.count < chips.count {
            let view = FileChipHitView(owner: self, index: chipViews.count)
            addSubview(view)
            chipViews.append(view)
        }
        for (i, view) in chipViews.enumerated() {
            guard i < chips.count else { view.isHidden = true; continue }
            view.isHidden = false
            view.frame = visibleFrame(chips[i].frame)
            view.chip = chips[i]
        }
        if let hovered = hoveredChip, hovered >= chips.count { hoveredChip = nil }
    }

    /// One transparent view per context chip: cursor and hover for interactive chips, tooltip, click.
    private func layoutContextChips() {
        let chips = bounds.width > 0 ? layout(forWidth: bounds.width).contextChips : []
        while contextChipViews.count < chips.count {
            let view = ContextChipHitView(owner: self, index: contextChipViews.count)
            addSubview(view)
            contextChipViews.append(view)
        }
        for (i, view) in contextChipViews.enumerated() {
            guard i < chips.count else { view.isHidden = true; continue }
            view.isHidden = false
            view.frame = visibleFrame(chips[i].frame)
            view.chip = chips[i]
        }
        if let hovered = hoveredContextChip, hovered >= chips.count { hoveredContextChip = nil }
        loadContextThumbnails(chips)
    }

    /// Loads each image chip's thumbnail once, then redraws with the picture and its average color.
    private func loadContextThumbnails(_ chips: [MarkdownContextChip]) {
        guard let loader = contextImageLoader else { return }
        for id in chips.compactMap(\.imageAttachmentId) where MarkdownContextChips.thumbnails[id] == nil
            && !MarkdownContextChips.loading.contains(id) && !MarkdownContextChips.failed.contains(id) {
            MarkdownContextChips.loading.insert(id)
            Task { [weak self] in
                let image = await loader(id, 32)
                MarkdownContextChips.loading.remove(id)
                guard let image else { MarkdownContextChips.failed.insert(id); return }
                MarkdownContextChips.thumbnails[id] = (image, MarkdownContextChips.averageColor(image))
                self?.needsDisplay = true
            }
        }
    }

    fileprivate func contextChipHover(_ index: Int, _ inside: Bool) {
        if inside { hoveredContextChip = index } else if hoveredContextChip == index { hoveredContextChip = nil }
    }

    fileprivate func contextChipClicked(_ chip: MarkdownContextChip, view: NSView) {
        if case .terminal(let record) = chip.action {
            PopoverView(content: TerminalContextDetailsView(record: record), padding: .compact, width: .lg)
                .show(from: view, placement: PopupPlacement(side: .top, align: .center, sideOffset: 4, fallbackAxisSide: .end))
            return
        }
        onContextChip?(chip.action, view)
    }

    /// One transparent view per line a web link touches: pointer cursor, click, menu, hover.
    private func layoutLinks() {
        let links = bounds.width > 0 ? layout(forWidth: bounds.width).links : []
        while linkViews.count < links.count {
            let view = MarkdownLinkHitView(owner: self)
            addSubview(view)
            linkViews.append(view)
        }
        for (i, view) in linkViews.enumerated() {
            guard i < links.count else { view.isHidden = true; continue }
            view.isHidden = false
            view.frame = visibleFrame(links[i].frame)
            view.url = links[i].url
        }
    }

    /// ChatMarkdown.tsx:1320-1347, 3180-3297 and MermaidDiagram.tsx:204-216: images share the gallery. Web and
    /// `data:` sources load directly, host paths through a signed asset URL (`media-file`), others never load.
    /// A decoded image reports its natural size, and the message lays out again around its own box.
    private func layoutImages() {
        imageItems = []
        var placed: [(frame: CGRect, radius: CGFloat, fallback: String, tooltip: String?)] = []
        imageKeys = []
        if bounds.width > 0 {
            for item in layout(forWidth: bounds.width).items {
                switch item {
                case .remoteImage(let url, let alt, let rect):
                    let source = MarkdownImageSource.classify(url.absoluteString, workspaceRoot: cwd)
                    let key = source.key
                    let reference: MediaReference? = switch source {
                    case .workspaceFile(let path): MediaReference.file(path, workspaceRoot: cwd)
                    case .direct(let uri): MediaReference.link(uri)
                    case .blocked: nil
                    }
                    let failed = source == .blocked || MarkdownImages.failed.contains(key)
                    imageItems.append(.init(key: key.isEmpty ? "blocked-\(imageItems.count)" : key, name: alt.isEmpty ? "image" : alt,
                                            load: MarkdownImages.loader(source), reference: reference))
                    imageKeys.insert(key)
                    let sized = MarkdownImages.sizes[key] != nil && !failed
                    placed.append((rect, sized ? (source.framed ? 9 : 0) : 10, failed ? MarkdownImages.unavailableLabel(alt, detail: MarkdownImages.missingFileAccess.contains(key) ? MarkdownImages.missingFileAccessMessage : nil) : "", reference?.tooltip ?? (alt.isEmpty ? "image" : alt)))
                case .image(let image, let rect):
                    imageItems.append(.init(key: "diagram-\(imageItems.count)-\(ObjectIdentifier(image))", name: "Diagram", load: { _ in image }))
                    placed.append((rect, 10, "Image unavailable. The file may have been moved or deleted.", nil))
                default: break
                }
            }
        }
        observeImageSizes()
        while imageViews.count > placed.count { imageViews.removeLast().removeFromSuperview(); imageTooltips.removeLast() }
        while imageViews.count < placed.count {
            let view = AsyncImageView(); view.cover = false
            // `text-xs text-muted-foreground`
            view.fallback.color = Themed.color(\.mutedForeground)
            view.fallback.font = DSFont.ui(12)
            imageTooltips.append(TooltipController.attach(to: view, text: "", variant: .code))
            view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(expandMarkdownImage(_:))))
            view.onLoad = { [weak self, weak view] in
                // A failed source keeps its slot and says so (ChatMarkdown.tsx:1455-1475).
                guard let self, let view, view.image == nil, let key = view.key, self.imageKeys.contains(key), !key.hasPrefix("diagram-") else { return }
                MarkdownImages.failed.insert(key)
                self.needsLayout = true
            }
            addSubview(view); imageViews.append(view)
        }
        for (index, view) in imageViews.enumerated() {
            let item = imageItems[index], place = placed[index]
            view.frame = place.frame
            view.layer?.cornerRadius = place.radius
            view.set(key: item.key, fallbackText: place.fallback, loader: item.load)
            view.setAccessibilityLabel("Preview " + item.name)
            imageTooltips[index].text = place.tooltip ?? ""
            view.onContextMenu = { [weak self] event, source in
                MediaAttachmentContextMenu.show(name: item.name, load: item.load, event: event, view: source,
                                                reference: item.reference, openFile: self?.openInFileViewer(item.reference))
            }
        }
    }

    /// Sources of the images this message shows, to relayout when one of them reports its size.
    private var imageKeys: Set<String> = []
    private var imageSizeObserver: NSObjectProtocol?

    private func observeImageSizes() {
        guard !imageKeys.isEmpty else {
            if let imageSizeObserver { NotificationCenter.default.removeObserver(imageSizeObserver); self.imageSizeObserver = nil }
            return
        }
        guard imageSizeObserver == nil else { return }
        imageSizeObserver = NotificationCenter.default.addObserver(forName: MarkdownImages.didMeasure, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated {
                guard let self, let key, self.imageKeys.contains(key) else { return }
                self.invalidate()
            }
        }
    }

    /// "Open in file viewer" for a workspace image (MediaActions.tsx `onOpenFile`).
    private func openInFileViewer(_ reference: MediaReference?) -> (() -> Void)? {
        guard case .file(_, let relative?)? = reference, let open = MarkdownImages.openInFileViewer else { return nil }
        return { open(relative) }
    }
    @objc private func expandMarkdownImage(_ gesture: NSClickGestureRecognizer) {
        guard let window, let index = imageViews.firstIndex(where: { $0 === gesture.view }) else { return }
        ExpandedImagePreviewView(items: imageItems, index: index).present(in: window)
    }

    fileprivate func chipHover(_ index: Int, _ inside: Bool) {
        if inside { hoveredChip = index } else if hoveredChip == index { hoveredChip = nil }
    }

    /// A chip's primary action (ChatMarkdown.tsx:2197-2245): Cmd-click opens the preferred editor; a PDF, or any
    /// browser document nothing else opens, goes to the integrated browser; else the files panel, else the media
    /// preview, else the editor. With none of them the click shows the menu.
    fileprivate func chipClicked(_ chip: FileChip, event: NSEvent, view: NSView) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let actions = chipActions(chip.meta)
        guard actions.editor || actions.browser || actions.panel || actions.media else { chipMenu(chip, event: event, view: view); return }
        if modifiers.contains(.command), !modifiers.contains(.control), actions.editor {
            if let onOpenFile { onOpenFile(chip.meta, true) } else { Self.onOpenFileInEditor?(chip.meta) }
            return
        }
        if actions.browser, chip.meta.filePath.lowercased().hasSuffix(".pdf") || (!actions.editor && !actions.panel) {
            Self.onOpenFileInBrowser?(chip.meta)
        } else if actions.panel {
            onOpenFile?(chip.meta, false)
        } else if actions.media {
            previewMedia(chip.meta)
        } else {
            Self.onOpenFileInEditor?(chip.meta)
        }
    }

    /// Which of T3's file actions this chip has (`fileLinkChip`, ChatMarkdown.tsx:2639-2690). A thread is open
    /// when the owner handles clicks (`onOpenFile`).
    private func chipActions(_ meta: FileLinkMeta) -> (editor: Bool, browser: Bool, panel: Bool, media: Bool) {
        let thread = onOpenFile != nil
        let kind = FilePreviewKind.of(meta.filePath)
        return (Self.fileChipShell?().openLabel != nil,
                thread && (kind == .html || kind == .pdf) && Self.canOpenFileInBrowser?() == true && Self.onOpenFileInBrowser != nil,
                thread && meta.panelPath != nil,
                thread && FileLinks.isMedia(meta.basename))
    }

    /// "Preview media" (`openMarkdownMedia`): an image in the media preview through a signed asset URL. A video
    /// opens in the file viewer, which plays it.
    // ponytail: the preview shows images only; videos outside the workspace do nothing. Add video to ExpandedImagePreviewView when T3's player lands
    private func previewMedia(_ meta: FileLinkMeta) {
        if FilePreviewKind.of(meta.filePath) == .video {
            if meta.panelPath != nil { onOpenFile?(meta, false) }
            return
        }
        guard let window else { return }
        let reference = MediaReference.file(meta.filePath, workspaceRoot: cwd)
        let item = ExpandedImagePreviewView.Item(key: "media-file:" + meta.filePath, name: meta.basename,
                                                 load: MarkdownImages.loader(.workspaceFile(meta.filePath)), reference: reference)
        ExpandedImagePreviewView(items: [item], index: 0).present(in: window)
    }

    /// T3's native file menu (ChatMarkdown.tsx:2115-2160 `showFileContextMenu`): "Preview media" for images and video,
    /// "Open in <editor>" where the environment runs shell actions, "Open in integrated browser" for HTML and PDF,
    /// the reveal item, then the copies. "Copy relative path" shows only inside the workspace and keeps the position
    /// (`markdownFileCopyMenuItems`, a81961d756, MarkdownFileLink.logic.ts:32-49).
    fileprivate func chipMenu(_ chip: FileChip, event: NSEvent, view: NSView) {
        let relative = chip.meta.workspaceRelativePath.map { FileLinks.format($0, chip.meta.line, chip.meta.column) }
        let shell = Self.fileChipShell?()
        let actions = chipActions(chip.meta)
        var items: [ThreadMenuItem] = []
        if actions.media { items.append(ThreadMenuItem("preview-media", "Preview media")) }
        if let open = shell?.openLabel { items.append(ThreadMenuItem("open", open)) }
        if actions.browser { items.append(ThreadMenuItem("open-in-browser", "Open in integrated browser")) }
        if let reveal = shell?.revealLabel { items.append(ThreadMenuItem("reveal", reveal)) }
        if relative != nil { items.append(ThreadMenuItem("relative", "Copy relative path")) }
        items.append(ThreadMenuItem("full", "Copy full path"))
        let menu = NativeItemContextMenu.make(items) { [weak self, weak view] action in
            if action == "preview-media" { self?.previewMedia(chip.meta); return }
            if action == "open" { Self.onOpenFileInEditor?(chip.meta); return }
            if action == "open-in-browser" { Self.onOpenFileInBrowser?(chip.meta); return }
            if action == "reveal" { Self.onRevealFile?(chip.meta); return }
            NSPasteboard.general.clearContents()
            let copied = NSPasteboard.general.setString(action == "relative" ? relative ?? chip.meta.targetPath : chip.meta.targetPath, forType: .string)
            if let view { AnchoredCopyToast.show(from: view, success: copied) }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func showTableCopy(_ table: MarkdownTable, button index: Int) {
        MenuPopupView.show([
            MenuItem("Copy as Markdown") { [weak self] in self?.copy(MarkdownLayout.tableMarkdown(table), button: index) },
            MenuItem("Copy as CSV") { [weak self] in self?.copy(MarkdownLayout.tableCSV(table), button: index) }
        ], from: buttons[index], placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4))
    }

    func toggleTable(_ index: Int) {
        let previous = cache[bounds.width]
        if expandedTables.contains(index) { expandedTables.remove(index) } else { expandedTables.insert(index) }
        invalidate()
        reusable = previous
        onHeightChange?()
    }

    private func copy(_ text: String, button index: Int) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return }
        needsLayout = true
        // T3 swaps the icon to a check for 1.2s.
        buttons[index].icon = .check
        copiedResets[index]?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copiedResets[index] = nil
            self.needsLayout = true
        }
        copiedResets[index] = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
    }

    private func toggleDiagram(_ index: Int) {
        if diagramCode.contains(index) { diagramCode.remove(index) } else { diagramCode.insert(index) }
        invalidate()
        NotificationCenter.default.post(name: MermaidDiagrams.didRender, object: nil)
    }

    private func toggleWrap(_ index: Int) {
        if unwrappedCode.contains(index) { unwrappedCode.remove(index) } else { unwrappedCode.insert(index) }
        // A wrapped `pre` has nothing to scroll, so Chromium clamps its scrollLeft to 0.
        codeOffsets[index] = nil
        invalidate()
    }

    // MARK: Code block scrolling

    /// Code block bodies with wrapping off, in layout order.
    private var codeScrollers: [(index: Int, viewport: CGRect, contentWidth: CGFloat)] {
        guard bounds.width > 0 else { return [] }
        return layout(forWidth: bounds.width).items.compactMap {
            if case .scroll(let index, let viewport, let width) = $0 { (index, viewport, width) } else { nil }
        }
    }

    private func codeOffset(_ index: Int, _ viewport: CGRect, _ contentWidth: CGFloat) -> CGFloat {
        min(max(0, codeOffsets[index] ?? 0), max(0, contentWidth - viewport.width))
    }

    /// Sets a block's scroll offset, clamped and snapped to device pixels, and redraws the block when it moved.
    @discardableResult
    private func setCodeOffset(_ index: Int, _ value: CGFloat, _ viewport: CGRect, _ contentWidth: CGFloat) -> CGFloat {
        let old = codeOffset(index, viewport, contentWidth)
        codeOffsets[index] = min(max(0, contentWidth - viewport.width), (max(0, value) * 2).rounded() / 2)
        let new = codeOffset(index, viewport, contentWidth)
        if new != old { setNeedsDisplay(viewport); needsLayout = true }
        return new
    }

    /// The scrollbar thumb of an overflowing body (index.css:2072-2079): a 6px pill along the bottom lane, as long as the
    /// visible share of the scroll width and at least as long as it is thick; nil when the code fits.
    static func codeThumb(_ viewport: CGRect, _ contentWidth: CGFloat, _ offset: CGFloat) -> CGRect? {
        guard contentWidth > viewport.width else { return nil }
        let t = MarkdownStyle.codeScrollbar, track = viewport.width
        let length = min(track, max(t, track * viewport.width / contentWidth))
        let x = viewport.minX + (track - length) * offset / (contentWidth - viewport.width)
        return CGRect(x: x, y: viewport.maxY - t, width: length, height: t)
    }

    /// The code block a trackpad gesture scrolls sideways, from its first event to the end of its momentum.
    private var scrollLatch: Int?

    /// Chromium scrolls the code block under the pointer sideways and the timeline for everything else: a gesture whose
    /// first movement is mostly sideways, over a block that overflows, stays with that block; any other gesture goes up the
    /// responder chain untouched, so vertical scrolling never stops at a code block. A mouse wheel with Shift (which macOS
    /// already turns sideways) decides per event.
    public override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        // Chromium scrolls 40px per mouse wheel tick on macOS (`kScrollbarPixelsPerCocoaTick`).
        var dx = precise ? event.scrollingDeltaX : event.deltaX * 40
        var dy = precise ? event.scrollingDeltaY : event.deltaY * 40
        if !precise, dx == 0, event.modifierFlags.contains(.shift) { swap(&dx, &dy) }
        let gesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if !gesture || event.phase.contains(.began) {
            scrollLatch = nil
            let point = convert(event.locationInWindow, from: nil)
            if abs(dx) > abs(dy), let hit = codeScrollers.first(where: { $0.viewport.contains(point) }), hit.contentWidth > hit.viewport.width {
                scrollLatch = hit.index
            }
        }
        guard let index = scrollLatch, let s = codeScrollers.first(where: { $0.index == index }) else {
            super.scrollWheel(with: event)
            return
        }
        if !gesture { scrollLatch = nil }
        setCodeOffset(index, codeOffset(index, s.viewport, s.contentWidth) - dx, s.viewport, s.contentWidth)
    }

    /// A drag that started on a code block's thumb: the block, the pointer's x and the offset at the start.
    private var thumbDrag: (index: Int, x: CGFloat, offset: CGFloat)?

    /// A press on a code block's scrollbar lane: the thumb drags, the track pages toward the pointer. True when it hit one.
    private func pressCodeScrollbar(at point: CGPoint) -> Bool {
        guard let s = codeScrollers.first(where: { $0.viewport.contains(point) }),
              let thumb = Self.codeThumb(s.viewport, s.contentWidth, codeOffset(s.index, s.viewport, s.contentWidth)),
              point.y >= thumb.minY else { return false }
        let offset = codeOffset(s.index, s.viewport, s.contentWidth)
        if thumb.contains(point) {
            thumbDrag = (s.index, point.x, offset)
        } else {
            // Chromium's page step is 87.5% of the visible width (ScrollableArea::PageStep).
            // ponytail: one page per press; Chromium repeats while the button is held, add a timer if that is missed
            setCodeOffset(s.index, offset + (point.x < thumb.minX ? -1 : 1) * s.viewport.width * 0.875, s.viewport, s.contentWidth)
        }
        return true
    }

    private func dragCodeThumb(to point: CGPoint) {
        guard let drag = thumbDrag, let s = codeScrollers.first(where: { $0.index == drag.index }),
              let thumb = Self.codeThumb(s.viewport, s.contentWidth, 0), s.viewport.width > thumb.width else { return }
        let perPoint = (s.contentWidth - s.viewport.width) / (s.viewport.width - thumb.width)
        setCodeOffset(drag.index, drag.offset + (point.x - drag.x) * perPoint, s.viewport, s.contentWidth)
    }

    // MARK: Assistant selection (AssistantSelectionToolbar.tsx)
    // ponytail: selection uses layout text and a local toolbar; add chip text mapping and viewport dismissal with full selection parity

    public var citationSourceID: String? { didSet { if citationSourceID != oldValue { clearAssistantSelection() } } }
    public var onCiteSelection: ((AssistantSelectionText, AssistantSelectionAnchor) -> Void)? {
        didSet { if onCiteSelection == nil { clearAssistantSelection() } }
    }
    private var selectionAnchor: Int?
    private var assistantRange: NSRange?
    private var citeButton: ButtonView?
    public override var acceptsFirstResponder: Bool { onCiteSelection != nil }

    private var selectionBoxes: [(box: MarkdownTextBox, origin: CGPoint, offset: Int)] {
        var offset = 0, dx: CGFloat = 0
        return layout(forWidth: bounds.width).items.compactMap { item in
            if case .scroll(let index, let viewport, let width) = item { dx = codeOffset(index, viewport, width) }
            if case .endClip = item { dx = 0 }
            guard case .text(let box, let origin) = item else { return nil }
            defer { offset += (box.text as NSString).length + 1 }
            return (box, CGPoint(x: origin.x - dx, y: origin.y), offset)
        }
    }
    private var selectionText: String { selectionBoxes.map { $0.box.text }.joined(separator: "\n") }
    private func selectionIndex(_ point: CGPoint) -> Int? {
        let boxes = selectionBoxes
        guard let hit = boxes.min(by: {
            abs($0.origin.y + $0.box.height / 2 - point.y) < abs($1.origin.y + $1.box.height / 2 - point.y)
        }) else { return nil }
        return hit.offset + hit.box.character(at: CGPoint(x: point.x - hit.origin.x, y: point.y - hit.origin.y))
    }
    public func clearAssistantSelection() {
        let hadSelection = assistantRange != nil
        selectionAnchor = nil; assistantRange = nil
        citeButton?.removeFromSuperview(); citeButton = nil
        if hadSelection { needsDisplay = true }
    }
    public override func mouseDown(with event: NSEvent) {
        if pressCodeScrollbar(at: convert(event.locationInWindow, from: nil)) { return }
        guard onCiteSelection != nil else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        clearAssistantSelection()
        selectionAnchor = selectionIndex(convert(event.locationInWindow, from: nil))
    }
    public override func mouseDragged(with event: NSEvent) {
        if thumbDrag != nil { dragCodeThumb(to: convert(event.locationInWindow, from: nil)); return }
        guard let anchor = selectionAnchor, let end = selectionIndex(convert(event.locationInWindow, from: nil)) else { return }
        assistantRange = NSRange(location: min(anchor, end), length: abs(end - anchor))
        needsDisplay = true
    }
    public override func mouseUp(with event: NSEvent) {
        if thumbDrag != nil { thumbDrag = nil; return }
        guard let range = assistantRange, let captured = AssistantSelectionText.capture(selectionText, range: range) else { return }
        let tooLong = captured.text.utf16.count > 8000
        let button = AssistantSelectionToolbar.button(tooLong: tooLong)
        let point = convert(event.locationInWindow, from: nil), size = button.intrinsicContentSize
        let last = lastLineRect(range)
        // The pointer anchors the button only when it let go on the selected text; past it (a drag that ended in the
        // margin) the button sits under the selection's last line (AssistantSelectionToolbar.tsx:64-81, T3 3105 55fc13ff6;
        // `resolveSelectionActionPosition`, lib/selectionActions.ts:5-26).
        let onText = selectedLineRects(range).contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
        let preferred = onText || last == nil ? NSPoint(x: point.x + 8, y: point.y + 8) : NSPoint(x: last!.maxX, y: last!.maxY + 4)
        button.frame = NSRect(x: max(0, min(preferred.x, bounds.width - size.width)),
                              y: max(0, min(preferred.y, bounds.height - size.height)), width: size.width, height: size.height)
        let anchor = AssistantSelectionAnchor(view: self, rect: last ?? NSRect(origin: point, size: .zero))
        button.action = { [weak self] in self?.clearAssistantSelection(); self?.onCiteSelection?(captured, anchor) }
        citeButton?.removeFromSuperview(); citeButton = button; addSubview(button)
    }
    /// Every line box the selection covers (`range.getClientRects()`).
    private func selectedLineRects(_ range: NSRange) -> [NSRect] {
        var rects: [NSRect] = []
        for (box, origin, offset) in selectionBoxes {
            let overlap = NSIntersectionRange(range, NSRange(location: offset, length: (box.text as NSString).length))
            guard overlap.length > 0 else { continue }
            for span in box.spans(NSRange(location: overlap.location - offset, length: overlap.length)) {
                rects.append(NSRect(x: origin.x + span.x0, y: origin.y + box.lineTop(baseline: span.baseline),
                                    width: max(1, span.x1 - span.x0), height: box.lineHeight))
            }
        }
        return rects
    }

    /// The selection's last line box: a multi-line selection anchors its comment where the pointer let go
    /// (AssistantCitationChip.tsx:92-102).
    private func lastLineRect(_ range: NSRange) -> NSRect? {
        var last: NSRect?
        for (box, origin, offset) in selectionBoxes {
            let overlap = NSIntersectionRange(range, NSRange(location: offset, length: (box.text as NSString).length))
            guard overlap.length > 0 else { continue }
            if let span = box.lastSpan(NSRange(location: overlap.location - offset, length: overlap.length)) {
                last = NSRect(x: origin.x + span.x0, y: origin.y + box.lineTop(baseline: span.baseline),
                              width: max(1, span.x1 - span.x0), height: box.lineHeight)
            }
        }
        return last
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { clearAssistantSelection(); return }
        if event.keyCode == 48, let citeButton, citeButton.isEnabled { window?.makeFirstResponder(citeButton); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", let range = assistantRange {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString((selectionText as NSString).substring(with: range), forType: .string)
            return
        }
        super.keyDown(with: event)
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clearAssistantSelection() }
    }

    /// The active find match's first line box, counted as `draw` counts. A match in a diagram's source switches the
    /// block to its code first (`revealSource`, ChatMarkdown.tsx:1029-1031).
    public func activeFindRect() -> CGRect? {
        guard let active = threadFindOccurrence, !threadFindQuery.isEmpty, bounds.width > 0 else { return nil }
        var seen = 0
        var scroller: (index: Int, viewport: CGRect, contentWidth: CGFloat)?
        for item in layout(forWidth: bounds.width).items {
            switch item {
            case .scroll(let index, let viewport, let width): scroller = (index, viewport, width)
            case .endClip: scroller = nil
            case .text(let box, let origin):
                let ranges = box.findRanges(threadFindQuery)
                if active < seen + ranges.count, let span = box.spans(ranges[active - seen]).first {
                    let area = box.contentArea(at: ranges[active - seen].location, baseline: MarkdownTextBox.snappedBaseline(origin.y + span.baseline))
                    var x = origin.x + span.x0
                    let w = max(1, span.x1 - span.x0)
                    if let s = scroller {
                        // A match in a scrolled code block comes into its viewport with 16px to spare (useThreadFindNavigation.ts:185-193).
                        let old = codeOffset(s.index, s.viewport, s.contentWidth)
                        var left = old
                        if x - left < s.viewport.minX { left += x - left - s.viewport.minX - 16 }
                        else if x + w - left > s.viewport.maxX { left += x + w - left - s.viewport.maxX + 16 }
                        left = setCodeOffset(s.index, left, s.viewport, s.contentWidth)
                        x -= left
                    }
                    return CGRect(x: x, y: area.y, width: w, height: area.height)
                }
                seen += ranges.count
            case .hiddenText(let code, let index):
                let count = ThreadFindText.count(code, threadFindQuery)
                if active < seen + count, !diagramCode.contains(index) {
                    toggleDiagram(index)
                    layoutSubtreeIfNeeded()
                    return activeFindRect()
                }
                seen += count
            default: break
            }
        }
        return nil
    }

    /// How many find matches this message shows (the plan card's preview decides whether to open).
    public func findMatchCount() -> Int {
        guard !threadFindQuery.isEmpty, bounds.width > 0 else { return 0 }
        return layout(forWidth: bounds.width).items.reduce(0) { sum, item in
            switch item {
            case .text(let box, _): sum + box.findRanges(threadFindQuery).count
            case .hiddenText(let code, _): sum + ThreadFindText.count(code, threadFindQuery)
            default: sum
            }
        }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 0, !document.blocks.isEmpty else { return }
        ctx.setShouldSmoothFonts(FontRuntime.smoothing)
        ctx.setAllowsFontSmoothing(FontRuntime.smoothing)
        let dark = effectiveAppearance.isDark
        var chipIndex = -1
        var contextIndex = -1
        var findOccurrence = 0
        var selectionOffset = 0
        var tableFade: (CGRect, CGFloat, CGFloat)?
        for item in layout(forWidth: bounds.width).items {
            switch item {
            case .text(let box, let origin):
                // A long code block lays out only the lines near what this pass paints.
                let boxClip = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
                if let range = assistantRange {
                    let overlap = NSIntersectionRange(range, NSRange(location: selectionOffset, length: (box.text as NSString).length))
                    if overlap.length > 0 {
                        ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5).cgColor)
                        for span in box.spans(NSRange(location: overlap.location - selectionOffset, length: overlap.length), clip: boxClip) {
                            ctx.fill(CGRect(x: origin.x + span.x0, y: origin.y + box.lineTop(baseline: span.baseline),
                                            width: max(1, span.x1 - span.x0), height: box.lineHeight))
                        }
                    }
                }
                selectionOffset += (box.text as NSString).length + 1
                // T3 indexes the rendered text: chip labels, not code block titles or image alt text (threadFindText.ts).
                // Matches paint as CSS highlights (index.css:376-394): a background behind the font's content area
                // and the text inside it in the highlight's foreground.
                let visible = origin.y <= dirtyRect.maxY && origin.y + box.height >= dirtyRect.minY
                if visible { box.draw(in: ctx, at: origin, clip: dirtyRect) }
                if !threadFindQuery.isEmpty {
                    for range in box.findRanges(threadFindQuery) {
                        let active = findOccurrence == threadFindOccurrence
                        findOccurrence += 1
                        guard visible else { continue }
                        ctx.setFillColor(SearchMatchColors.background(active: active, dark: dark).cgColor)
                        for span in box.spans(range, clip: boxClip) {
                            let area = box.contentArea(at: range.location, baseline: MarkdownTextBox.snappedBaseline(origin.y + span.baseline))
                            ctx.fill(CGRect(x: origin.x + span.x0, y: area.y, width: span.x1 - span.x0, height: area.height))
                        }
                        box.draw(range, color: SearchMatchColors.foreground(active: active, dark: dark), in: ctx, at: origin, clip: dirtyRect)
                    }
                }
            case .box(let rect, let fill, let border, let radius):
                drawBox(rect, fill: fill, border: border, radius: radius, in: ctx)
            case .glyphs(let string, let point):
                let line = CTLineCreateWithAttributedString(string)
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: point.x - width, y: point.y)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            case .symbol(let kind, let rect, let color):
                ctx.setFillColor(color.cgColor(in: self))
                ctx.setStrokeColor(color.cgColor(in: self))
                switch kind {
                case 0: ctx.fillEllipse(in: rect)
                case 1: ctx.setLineWidth(1); ctx.strokeEllipse(in: rect)
                default: ctx.fill(rect)
                }
            case .checkbox(let rect, let checked):
                drawCheckbox(rect, checked: checked, dark: dark, in: ctx)
            case .icon(let name, let rect, let color):
                Self.drawIcon(name.definition, in: rect, color: color.cgColor(in: self), ctx: ctx)
            case .fileIcon(let path, let rect):
                let (icon, color) = FileTypeIcon.icon(for: path)
                Self.drawIcon(icon, in: rect, color: color.cgColor(in: self), ctx: ctx)
            case .fileChip(let chip):
                chipIndex += 1
                let hovered = hoveredChip == chipIndex
                drawBox(chip.frame, fill: hovered ? FileChipStyle.hoverFill : FileChipStyle.fill,
                        border: hovered ? FileChipStyle.hoverBorder : FileChipStyle.border, radius: chip.frame.height / 1.41 * 0.5,
                        fillUnderBorder: true, in: ctx)
                let (icon, color) = FileChipStyle.icon(for: chip.meta)
                Self.drawIcon(icon, in: chip.icon, color: color.cgColor(in: self), ctx: ctx)
            case .contextChip(let chip):
                contextIndex += 1
                var look = chip.look
                let thumbnail = chip.imageAttachmentId.flatMap { MarkdownContextChips.thumbnails[$0] }
                if let accent = thumbnail?.accent { look.accentOverride = accent }
                let (icon, iconColor) = look.icon
                ComposerChipAttachment.draw(look: look, label: chip.label, icon: icon, iconColor: iconColor, in: chip.snappedFrame, ctx: ctx,
                                            hovered: chip.isInteractive && hoveredContextChip == contextIndex, thumbnail: thumbnail?.image)
            case .remoteImage:
                break
            case .link:
                break
            case .hiddenText(let code, _):
                if !threadFindQuery.isEmpty { findOccurrence += ThreadFindText.count(code, threadFindQuery) }
            case .favicon(let host, let rect):
                guard rect.intersects(dirtyRect) else { break }
                let color = MarkdownStyle.link.cgColor(in: self)
                switch MarkdownFavicons.face(host, ready: { [weak self] in self?.needsDisplay = true }) {
                case .brand(let icon): Self.drawIcon(icon.definition, in: rect, color: color, ctx: ctx)
                case .globe: Self.drawIcon(IconName.globe.definition, in: rect, color: color, ctx: ctx)
                case .loading: break
                case .image(let image):
                    // `rounded-sm` (6px).
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                    ctx.clip()
                    ctx.translateBy(x: rect.minX, y: rect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
                    ctx.restoreGState()
                }
            case .clip(let rect):
                ctx.saveGState()
                ctx.clip(to: rect)
            case .scroll(let index, let viewport, let width):
                if index < 0, width > viewport.width {
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    tableFade = (viewport, codeOffset(index, viewport, width), width)
                }
                ctx.saveGState()
                if let thumb = Self.codeThumb(viewport, width, codeOffset(index, viewport, width)) {
                    // The frame's `overflow-hidden rounded-lg` clips the bar at the block's bottom corners.
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: CGRect(x: viewport.minX, y: viewport.minY - 10, width: viewport.width, height: viewport.height + 10),
                                       cornerWidth: 9, cornerHeight: 9, transform: nil))
                    ctx.clip()
                    ctx.setFillColor(Themed.color(\.contrastBorder, 0.78).cgColor(in: self))
                    ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: thumb.height / 2, cornerHeight: thumb.height / 2, transform: nil))
                    ctx.fillPath()
                    ctx.restoreGState()
                }
                ctx.clip(to: viewport)
                ctx.translateBy(x: -codeOffset(index, viewport, width), y: 0)
            case .endClip:
                ctx.restoreGState()
                if let (viewport, offset, width) = tableFade {
                    Self.drawTableFade(viewport, offset: offset, contentWidth: width, in: ctx)
                    ctx.endTransparencyLayer()
                    tableFade = nil
                }
            case .image(let image, let rect):
                // The view is flipped; CGImage draws bottom up.
                ctx.saveGState()
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            }
        }
    }

    /// ScrollArea's 1.5rem mask, shortened to the remaining overflow at either edge.
    private static func drawTableFade(_ viewport: CGRect, offset: CGFloat, contentWidth: CGFloat, in ctx: CGContext) {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1])!
        let edges: [(CGFloat, CGFloat)] = [(viewport.minX, min(24, offset)), (viewport.maxX, -min(24, contentWidth - viewport.width - offset))]
        for (x, length) in edges where length != 0 {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: min(x, x + length), y: viewport.minY, width: abs(length), height: viewport.height - MarkdownStyle.codeScrollbar))
            ctx.setBlendMode(.destinationIn)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: x, y: 0), end: CGPoint(x: x + length, y: 0), options: [])
            ctx.restoreGState()
        }
    }

    /// CSS box: the border is drawn inside the rect, the fill inside the border.
    /// Blink snaps box edges to device pixels (`PixelSnappedIntRect`): each edge rounds on its own.
    // ponytail: 2x device pixels, like TextLine.baseline
    /// `fillUnderBorder`: the CSS default `background-clip: border-box`, visible under a translucent border.
    private func drawBox(_ unsnapped: CGRect, fill: NSColor?, border: NSColor?, radius: CGFloat, fillUnderBorder: Bool = false, in ctx: CGContext) {
        func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        let x0 = snap(unsnapped.minX), y0 = snap(unsnapped.minY)
        let rect = CGRect(x: x0, y: y0, width: max(0.5, snap(unsnapped.maxX) - x0), height: max(0.5, snap(unsnapped.maxY) - y0))
        func path(_ r: CGRect, _ radius: CGFloat) -> CGPath {
            radius > 0 ? CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
                       : CGPath(rect: r, transform: nil)
        }
        let inner = border == nil ? rect : rect.insetBy(dx: 1, dy: 1)
        if let fill {
            ctx.setFillColor(fill.cgColor(in: self))
            if fillUnderBorder { ctx.addPath(path(rect, radius)) } else { ctx.addPath(path(inner, max(0, radius - (border == nil ? 0 : 1)))) }
            ctx.fillPath()
        }
        if let border {
            ctx.setFillColor(border.cgColor(in: self))
            ctx.addPath(path(rect, radius))
            ctx.addPath(path(inner, max(0, radius - 1)))
            ctx.fillPath(using: .evenOdd)
        }
        // Classic Glass: a pane (code block, table) catches light along its top edge.
        if radius >= 8, rect.height >= 24, let fill, fill.cgColor(in: self).alpha > 0, WindowGlass.isActive(for: self) {
            ctx.saveGState()
            ctx.addPath(path(inner, max(0, radius - 1)))
            ctx.clip()
            ctx.setFillColor(WindowGlass.highlight.cgColor(in: self))
            ctx.fill(CGRect(x: inner.minX, y: isFlipped ? inner.minY : inner.maxY - 1, width: inner.width, height: 1))
            ctx.restoreGState()
        }
    }

    /// Chromium's disabled checkbox, sampled from the reference renders: 13px, 2px radius, 1px border;
    /// checked is a solid box with a check stroked at 16% of its size.
    private func drawCheckbox(_ rect: CGRect, checked: Bool, dark: Bool, in ctx: CGContext) {
        func gray(_ v: CGFloat) -> CGColor { CGColor(srgbRed: v / 255, green: v / 255, blue: v / 255, alpha: 1) }
        let outer = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        if checked {
            ctx.setFillColor(gray(dark ? 0x88 : 0xd9))
            ctx.addPath(outer)
            ctx.fillPath()
            let w = rect.width, h = rect.height
            ctx.move(to: CGPoint(x: rect.minX + w * 0.2, y: rect.minY + h * 0.5))
            ctx.addLine(to: CGPoint(x: rect.minX + w * 0.4, y: rect.minY + h * 0.7))
            ctx.addLine(to: CGPoint(x: rect.minX + w * 0.8, y: rect.minY + h * 0.3))
            ctx.setStrokeColor(gray(dark ? 0x4c : 0xf0))
            ctx.setLineWidth(h * 0.16)
            ctx.strokePath()
        } else {
            ctx.setFillColor(gray(dark ? 0x75 : 0xd9))
            ctx.addPath(outer)
            ctx.fillPath()
            ctx.setFillColor(gray(dark ? 0x4c : 0xf9))
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.fillPath()
        }
    }

    /// An icon scaled from its view box: lucide strokes, pierre fills. `currentColor` is `color`.
    static func drawIcon(_ definition: IconDefinition, in rect: CGRect, color: CGColor, ctx: CGContext) {
        let scale = rect.width / definition.viewBox.width
        ctx.saveGState()
        ctx.translateBy(x: rect.minX - definition.viewBox.x * scale, y: rect.minY - definition.viewBox.y * scale)
        ctx.scaleBy(x: scale, y: scale)
        func resolve(_ c: IconColor) -> CGColor? {
            switch c {
            case .none: nil
            case .current: color
            case .rgba(let v): CGColor(srgbRed: CGFloat(v >> 24 & 0xFF) / 255, green: CGFloat(v >> 16 & 0xFF) / 255,
                                       blue: CGFloat(v >> 8 & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
            }
        }
        for element in definition.elements {
            guard let path = try? element.cgPath() else { continue }
            let paint = element.paint
            ctx.saveGState()
            ctx.translateBy(x: paint.offsetX, y: paint.offsetY)
            ctx.setAlpha(paint.opacity)
            if let fill = resolve(paint.fill) {
                ctx.setFillColor(fill)
                ctx.addPath(path)
                ctx.fillPath(using: paint.evenOdd ? .evenOdd : .winding)
            }
            if let stroke = resolve(paint.stroke) {
                ctx.setStrokeColor(stroke)
                ctx.setLineWidth(paint.strokeWidth)
                let cap: CGLineCap = switch paint.lineCap { case .butt: .butt; case .round: .round; case .square: .square }
                let join: CGLineJoin = switch paint.lineJoin { case .miter: .miter; case .round: .round; case .bevel: .bevel }
                ctx.setLineCap(cap)
                ctx.setLineJoin(join)
                ctx.addPath(path)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}

/// The interactive part of a file chip; the chip itself is drawn by `MarkdownView`.
private final class FileChipHitView: NSView, HoverSyncClient {
    weak var owner: MarkdownView?
    let index: Int
    var chip: FileChip? { didSet { tooltip.text = chip?.meta.targetPath ?? ""; window?.invalidateCursorRects(for: self) } }
    private lazy var tooltip = TooltipController.attach(to: self, text: "", variant: .code)

    init(owner: MarkdownView, index: Int) {
        self.owner = owner
        self.index = index
        super.init(frame: .zero)
        _ = tooltip
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityRole(.link)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { owner?.chipHover(index, true) }
    override func mouseExited(with event: NSEvent) { owner?.chipHover(index, false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let chip, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        tooltip.hide()
        owner?.chipClicked(chip, event: event, view: self)
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let chip else { return }
        tooltip.hide()
        owner?.chipMenu(chip, event: event, view: self)
    }
    override func accessibilityLabel() -> String? { chip?.label }

    @objc func copyPath(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// The interactive part of a context chip; the chip itself is drawn by `MarkdownView`.
private final class ContextChipHitView: NSView, HoverSyncClient {
    weak var owner: MarkdownView?
    let index: Int
    var chip: MarkdownContextChip? {
        didSet {
            tooltip.text = chip?.tooltip ?? ""
            setAccessibilityRole(chip?.isInteractive == true ? .button : .staticText)
            window?.invalidateCursorRects(for: self)
        }
    }
    private lazy var tooltip = TooltipController.attach(to: self, text: "")

    init(owner: MarkdownView, index: Int) {
        self.owner = owner
        self.index = index
        super.init(frame: .zero)
        _ = tooltip
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { if chip?.isInteractive == true { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseEntered(with event: NSEvent) { owner?.contextChipHover(index, true) }
    override func mouseExited(with event: NSEvent) { owner?.contextChipHover(index, false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let chip, chip.isInteractive, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        tooltip.hide()
        owner?.contextChipClicked(chip, view: self)
    }
    override func accessibilityLabel() -> String? { chip?.accessibility }
    override func accessibilityPerformPress() -> Bool {
        guard let chip, chip.isInteractive else { return false }
        owner?.contextChipClicked(chip, view: self)
        return true
    }
}

/// What the app does with a web link in Markdown (ChatMarkdown.tsx:2990-3125): open it, show T3's
/// link menu (with Link to thread or Unlink for a pull request), and the pull request preview card.
@MainActor
public protocol MarkdownLinkHandler: AnyObject {
    func openLink(_ url: URL, from markdown: MarkdownView)
    func showLinkMenu(_ url: URL, event: NSEvent, in view: NSView, from markdown: MarkdownView)
    /// True when the link gets a preview card instead of the URL tooltip.
    func previewsLink(_ url: URL, from markdown: MarkdownView) -> Bool
    func showLinkPreview(_ url: URL, anchor: NSView, from markdown: MarkdownView)
    func hideLinkPreview(anchor: NSView)
}

/// The interactive part of a web link; the text is drawn by `MarkdownView`. The hover waits 350 ms
/// and leaves after 120 ms (`PreviewCardTrigger delay={350} closeDelay={120}`).
private final class MarkdownLinkHitView: NSView, HoverSyncClient {
    weak var owner: MarkdownView?
    var url: URL? {
        didSet {
            // A pull request link shows its card instead of the URL.
            tooltip.text = hasPreview ? "" : url?.absoluteString ?? ""
            window?.invalidateCursorRects(for: self)
        }
    }
    private var tooltip: TooltipController!
    private var pending: DispatchWorkItem?
    private var previewing = false

    init(owner: MarkdownView) {
        self.owner = owner
        super.init(frame: .zero)
        tooltip = TooltipController.attach(to: self, text: "")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityRole(.link)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var handler: MarkdownLinkHandler? { MarkdownView.linkHandler }
    private var hasPreview: Bool {
        guard let url, let owner, let handler else { return false }
        return handler.previewsLink(url, from: owner)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseEntered(with event: NSEvent) {
        guard hasPreview else { return }
        tooltip.hide()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.url, let owner = self.owner else { return }
            self.previewing = true
            self.handler?.showLinkPreview(url, anchor: self, from: owner)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        pending?.cancel()
        pending = nil
        guard previewing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewing = false
            self.handler?.hideLinkPreview(anchor: self)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let url, let owner, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        tooltip.hide()
        pending?.cancel()
        if previewing { previewing = false; handler?.hideLinkPreview(anchor: self) }
        if let citation = ThreadAssistantCitation.parse(url.absoluteString), let window {
            ThreadAssistantCitationEditor.present(citation, in: window, openSource: { MarkdownView.onOpenCitation?(citation) })
        } else if !SafeExternalURL.isSafe(url) {
            // T3 opens only http and https from a message (`parseSafeExternalUrl`); a `file:` or app link does nothing.
        } else if let handler { handler.openLink(url, from: owner) } else { NSWorkspace.shared.open(url) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let url, let owner else { return }
        tooltip.hide()
        if let handler {
            handler.showLinkMenu(url, event: event, in: self, from: owner)
            return
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open in system browser", action: #selector(openExternal), keyEquivalent: "")
        open.target = self
        let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink), keyEquivalent: "")
        copy.target = self
        menu.addItem(open)
        menu.addItem(copy)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openExternal() { if let url, SafeExternalURL.isSafe(url) { NSWorkspace.shared.open(url) } }
    @objc private func copyLink() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    override func accessibilityLabel() -> String? { url?.absoluteString }
    override func accessibilityPerformPress() -> Bool {
        guard let url, let owner else { return false }
        if let citation = ThreadAssistantCitation.parse(url.absoluteString), let window {
            ThreadAssistantCitationEditor.present(citation, in: window, openSource: { MarkdownView.onOpenCitation?(citation) })
        } else if !SafeExternalURL.isSafe(url) {
            // T3 opens only http and https from a message (`parseSafeExternalUrl`); a `file:` or app link does nothing.
        } else if let handler { handler.openLink(url, from: owner) } else { NSWorkspace.shared.open(url) }
        return true
    }
}
