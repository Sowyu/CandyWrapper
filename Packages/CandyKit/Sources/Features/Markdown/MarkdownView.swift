import AppKit
import DesignSystem

/// T3's `ChatMarkdown` for one message: all text, rules and boxes drawn into one layer, plus the
/// code block and table buttons as real controls. Height follows the width: `height(forWidth:)`
/// lays out once per width and caches the result until the document changes, so the virtualized
/// timeline can measure rows cheaply. Reuse a view for another message by setting `document`.
// ponytail: one backing layer per message; a very long message gets a large layer. Switch to tiled drawing if memory shows it.
public final class MarkdownView: DSView {
    public var document = MarkdownDocument(blocks: []) {
        didSet { if document != oldValue { unwrappedCode = []; diagramCode = []; invalidate(); observeDiagrams() } }
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

    private var unwrappedCode: Set<Int> = []
    private var cache: [CGFloat: MarkdownLayout] = [:]
    private var buttons: [ButtonView] = []
    private var chipViews: [FileChipHitView] = []
    private var linkViews: [MarkdownLinkHitView] = []

    /// Opens, menus and previews web links for every Markdown view (the app sets it: it knows the
    /// open thread, the browser panel and the pull request reads). Without one a click opens the
    /// system browser and the menu offers that and Copy Link.
    public static weak var linkHandler: MarkdownLinkHandler?
    private var hoveredChip: Int? {
        didSet { if hoveredChip != oldValue { needsDisplay = true } }
    }
    private var copiedResets: [Int: DispatchWorkItem] = [:]

    public override var wantsUpdateLayer: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
    }

    private func invalidate() {
        cache.removeAll()
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

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
        if let hit = cache[width] { return hit }
        // ponytail: unbounded per-width cache, cleared on document change; cap it if live resizing measures many widths
        let diagrams = hasDiagrams ? MarkdownLayout.Diagrams(enabled: diagramsEnabled, dark: effectiveAppearance.isDark, showingCode: diagramCode) : nil
        let made = MarkdownLayout(document: document, width: width, unwrappedCode: unwrappedCode, bodyColor: bodyColor, cwd: cwd, diagrams: diagrams)
        cache[width] = made
        return made
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        document.blocks.isEmpty ? 0 : layout(forWidth: width).height
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    // MARK: Controls

    public override func layout() {
        super.layout()
        layoutChips()
        layoutLinks()
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
            switch control.action {
            case .copy(let text):
                button.setAccessibilityLabel("Copy")
                button.action = { [weak self] in self?.copy(text, button: i) }
            case .toggleWrap(let index):
                button.setAccessibilityLabel(unwrappedCode.contains(index) ? "Wrap lines" : "Disable line wrap")
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
            case .toggleTable:
                button.setAccessibilityLabel("Collapse table cells")
                // ponytail: cells never truncate yet, so the toggle has nothing to collapse; wire it with cell truncation
                button.action = nil
            }
        }
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
            view.frame = chips[i].frame
            view.chip = chips[i]
        }
        if let hovered = hoveredChip, hovered >= chips.count { hoveredChip = nil }
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
            view.frame = links[i].frame
            view.url = links[i].url
        }
    }

    fileprivate func chipHover(_ index: Int, _ inside: Bool) {
        if inside { hoveredChip = index } else if hoveredChip == index { hoveredChip = nil }
    }

    fileprivate func chipClicked(_ chip: FileChip, event: NSEvent, view: NSView) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let onOpenFile {
            onOpenFile(chip.meta, modifiers.contains(.command) && !modifiers.contains(.control))
        } else {
            chipMenu(chip, event: event, view: view)
        }
    }

    /// T3's native file menu (ChatMarkdown.tsx `showFileContextMenu`). Open, browser and reveal items
    /// appear only once the app supplies those actions.
    // ponytail: copy items only, and no "copied" toast; add Open in editor and Reveal in Finder with the shell actions
    fileprivate func chipMenu(_ chip: FileChip, event: NSEvent, view: NSView) {
        let menu = NSMenu()
        let relative = chip.meta.workspaceRelativePath.map { FileLinks.format($0, chip.meta.line, chip.meta.column) } ?? chip.meta.targetPath
        for (title, value) in [("Copy relative path", relative), ("Copy full path", chip.meta.targetPath)] {
            let item = NSMenuItem(title: title, action: #selector(FileChipHitView.copyPath(_:)), keyEquivalent: "")
            item.target = view
            item.representedObject = value
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func copy(_ text: String, button index: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        invalidate()
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 0, !document.blocks.isEmpty else { return }
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        let dark = effectiveAppearance.isDark
        var chipIndex = -1
        for item in layout(forWidth: bounds.width).items {
            switch item {
            case .text(let box, let origin):
                guard origin.y <= dirtyRect.maxY, origin.y + box.height >= dirtyRect.minY else { continue }
                box.draw(in: ctx, at: origin)
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
            case .fileChip(let chip):
                chipIndex += 1
                let hovered = hoveredChip == chipIndex
                drawBox(chip.frame, fill: hovered ? FileChipStyle.hoverFill : FileChipStyle.fill,
                        border: hovered ? FileChipStyle.hoverBorder : FileChipStyle.border, radius: chip.frame.height / 1.41 * 0.5,
                        fillUnderBorder: true, in: ctx)
                let (icon, color) = FileChipStyle.icon(for: chip.meta)
                Self.drawIcon(icon, in: chip.icon, color: color.cgColor(in: self), ctx: ctx)
            case .link:
                break
            case .clip(let rect):
                ctx.saveGState()
                ctx.clip(to: rect)
            case .endClip:
                ctx.restoreGState()
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
private final class FileChipHitView: NSView {
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
private final class MarkdownLinkHitView: NSView {
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
        if let handler { handler.openLink(url, from: owner) } else { NSWorkspace.shared.open(url) }
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

    @objc private func openExternal() { if let url { NSWorkspace.shared.open(url) } }
    @objc private func copyLink() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    override func accessibilityLabel() -> String? { url?.absoluteString }
    override func accessibilityPerformPress() -> Bool {
        guard let url, let owner else { return false }
        if let handler { handler.openLink(url, from: owner) } else { NSWorkspace.shared.open(url) }
        return true
    }
}
