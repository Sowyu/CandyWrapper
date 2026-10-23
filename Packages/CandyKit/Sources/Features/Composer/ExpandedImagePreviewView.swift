import AppKit
import DesignSystem
import T3Protocol

/// The media preview (chat/ExpandedImageDialog.tsx, ui/dialog.tsx `variant="media"`): a `bg-black/75`
/// backdrop over the window, the image at most `92vw - 96px` wide and `min(86vh, 100vh - 160px)`
/// tall in a `rounded-lg bg-background shadow-2xl ring-1 ring-border/70` frame, a `media-close`
/// button 40pt above its right edge, the name and "(i/n)" under it in `text-xs text-white/80`, and
/// `media-navigation` chevrons at the popup's sides when there is more than one image. Arrow keys
/// move, Escape and a click on the backdrop close. Each image decodes at the size it is shown.

public final class ExpandedImagePreviewView: DSView {
    public struct Item: Sendable {
        public var key: String
        public var name: String
        public var cacheable: Bool
        public var load: AsyncImageView.Loader
        /// Where the image lives, for its menu's copy items (MediaActions.tsx).
        public var reference: MediaReference?
        /// A SnapShot capture's `source`: the caption gets its accessibility data button.
        public var source: JSONValue?
        public init(key: String, name: String, source: JSONValue? = nil, cacheable: Bool = false, load: @escaping AsyncImageView.Loader, reference: MediaReference? = nil) {
            self.key = key; self.name = name; self.cacheable = cacheable; self.load = load; self.reference = reference; self.source = source
        }
    }

    public let items: [Item]
    public private(set) var index: Int
    public var onClose: (() -> Void)?

    private let frameView = DSView()
    private let image = AsyncImageView()
    private let caption = LabelView("", font: DSFont.ui(12), color: NSColor.white.withAlphaComponent(0.8))
    private let close = ButtonView(nil, icon: .x, variant: .mediaClose, size: .iconXs)
    private let previous = ButtonView(nil, icon: .chevronLeft, variant: .mediaNavigation, size: .icon)
    private let next = ButtonView(nil, icon: .chevronRight, variant: .mediaNavigation, size: .icon)
    /// `ZoomableImage` (chat/ZoomableImage.tsx:11-142): 1 to 8 times the fitted size. The frame grows with the zoom up
    /// to the media box, then scrolls; `scroll` is the frame's scroll offset into the zoomed image.
    private var naturalSize: CGSize?
    private var zoom: CGFloat = 1
    private var scroll = CGPoint.zero
    private var drag: (point: CGPoint, scroll: CGPoint)?
    private var dragged = false
    private weak var previousResponder: NSResponder?
    /// The caption's SnapShot button: the screenshot and data toggle when the capture has readable
    /// data, else the data popover (ExpandedImageDialog.tsx:162-170, 249-274).
    private var contents: ButtonView?
    private var details: SnapShotDetailsPane?
    private var showingDetails = false

    public init(items: [Item], index: Int) {
        self.items = items
        self.index = items.isEmpty ? 0 : ((index % items.count) + items.count) % items.count
        super.init(frame: .zero)
        image.cover = false
        frameView.layer?.cornerRadius = 11
        image.layer?.cornerRadius = 10
        frameView.layer?.masksToBounds = true
        frameView.layer?.borderWidth = 1
        frameView.addSubview(image)
        addSubview(frameView)
        caption.alignment = .center
        caption.lineHeight = 16
        addSubview(caption)
        for b in [previous, next] { b.iconSize = 20; b.isHidden = items.count < 2; addSubview(b) }
        previous.setAccessibilityLabel("Previous media")
        next.setAccessibilityLabel("Next media")
        close.setAccessibilityLabel("Close image preview")
        addSubview(close)
        close.action = { [weak self] in self?.dismiss() }
        previous.action = { [weak self] in self?.move(-1) }
        next.action = { [weak self] in self?.move(1) }
        image.onLoad = { [weak self] in
            guard let self else { return }
            // A sharper decode changes pixels, never the fitted geometry or the pan anchor.
            if self.naturalSize == nil, let cg = self.image.image,
               self.image.loadedSide >= (self.image.decodeSide ?? 0) {
                self.naturalSize = MarkdownImages.sizes[self.items[self.index].key]
                    ?? CGSize(width: cg.width, height: cg.height)
            }
            self.needsLayout = true
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Expanded image preview")
        show()
    }

    /// Shows the preview over `window`'s content.
    public func present(in window: NSWindow) {
        guard let content = window.contentView else { return }
        previousResponder = window.firstResponder
        frame = content.bounds
        autoresizingMask = [.width, .height]
        // Decode for the largest box the image can take (`--media-width`, `--media-height`).
        requestPixels(scale: window.backingScaleFactor)
        content.addSubview(self)
        window.makeFirstResponder(self)
    }

    public func dismiss() {
        let window = window
        removeFromSuperview()
        if let previousResponder { window?.makeFirstResponder(previousResponder) }
        onClose?()
    }

    public func move(_ step: Int) {
        guard items.count > 1 else { return }
        index = ((index + step) % items.count + items.count) % items.count
        show()
    }

    private func show() {
        guard items.indices.contains(index) else { return }
        zoom = 1; scroll = .zero; naturalSize = nil
        let item = items[index]
        caption.text = item.name + (items.count > 1 ? " (\(index + 1)/\(items.count))" : "")
        showingDetails = false
        details?.removeFromSuperview(); details = nil
        contents?.removeFromSuperview(); contents = nil
        frameView.isHidden = false
        if let source = item.source {
            if SnapShotSource.details(source) != nil {
                let toggle = ButtonView(nil, icon: .text, variant: .overlay, size: .iconMicro)
                toggle.iconSize = 12
                toggle.action = { [weak self] in self?.toggleDetails() }
                contents = toggle
                syncToggle()
            } else {
                contents = SnapShotContents.button(source)
            }
            if let contents { addSubview(contents) }
        }
        image.onContextMenu = { event, view in MediaAttachmentContextMenu.show(name: item.name, load: item.load, event: event, view: view, reference: item.reference) }
        requestPixels(mediaBox)
        image.cacheable = item.cacheable
        image.set(key: item.key, fallbackText: "Image unavailable. The file may have been moved or deleted.", loader: item.load)
        needsLayout = true
    }


    /// `contentsLabel` and the MorphIcon glyph: the data shows in place of the screenshot.
    // ponytail: the glyph swaps at once; T3's MorphIcon morphs the paths. Morph it if the swap reads as a jump
    private func syncToggle() {
        guard let contents, let source = items[index].source else { return }
        let label = showingDetails ? "Show screenshot"
            : source["accessibility"]?["format"]?.stringValue == "element-tree" ? "Show accessibility JSON" : "Show extracted text"
        contents.icon = showingDetails ? .image : .text
        contents.toolTip = label
        contents.setAccessibilityLabel(label)
        contents.setAccessibilityValue(showingDetails ? "on" : "off")
    }

    private func toggleDetails() {
        guard let source = items[index].source, let text = SnapShotSource.details(source) else { return }
        showingDetails.toggle()
        details?.removeFromSuperview(); details = nil
        if showingDetails {
            zoom = 1; scroll = .zero
            let pane = SnapShotDetailsPane(text: text, isJSON: source["accessibility"]?["format"]?.stringValue == "element-tree")
            pane.onEscape = { [weak self] in self?.dismiss() }
            addSubview(pane, positioned: .below, relativeTo: close)
            details = pane
            // `transition-opacity duration-140 ease-out starting:opacity-0`.
            if !Motion.reduced {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.14
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                pane.layer?.add(fade, forKey: "enter")
            }
        }
        frameView.isHidden = showingDetails
        syncToggle()
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    public override var acceptsFirstResponder: Bool { true }

    /// Enter or Space toggles 2x, + and - zoom by 1.5, 0 fits; arrows pan a zoomed image 40pt and otherwise move
    /// through the gallery (a vertical scroll alone does not take Left and Right).
    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let key = event.charactersIgnoringModifiers ?? ""
        if flags.isEmpty, showingDetails, ["\r", " ", "+", "=", "-", "0"].contains(key) { return }
        if flags.isEmpty {
            switch key {
            case "\r", " ": if !event.isARepeat { changeZoom(zoom > 1 ? 1 : 2) }; return
            case "+", "=": changeZoom(zoom * 1.5); return
            case "-": changeZoom(zoom / 1.5); return
            case "0": changeZoom(1); return
            default: break
            }
        }
        if zoom > 1, [123, 124, 125, 126].contains(event.keyCode),
           ![123, 124].contains(event.keyCode) || zoomedSize.width > frameView.bounds.width - 2 {
            if event.keyCode == 123 { scroll.x -= 40 }
            if event.keyCode == 124 { scroll.x += 40 }
            if event.keyCode == 125 { scroll.y += 40 }
            if event.keyCode == 126 { scroll.y -= 40 }
            needsLayout = true; return
        }
        switch event.keyCode {
        case 53: dismiss()         // Escape
        case 123: move(-1)         // ArrowLeft
        case 124: move(1)          // ArrowRight
        default: super.keyDown(with: event)
        }
    }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        frameView.layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        frameView.layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
    }

    /// `--media-width: calc(92vw - 96px)` from `sm`, `--media-height: min(86vh, 100vh - 160px)`.
    private var mediaBox: CGSize {
        let w = bounds.width, h = bounds.height
        return CGSize(width: max(0, w * 0.92 - (w >= 640 ? 96 : 0)), height: max(0, min(h * 0.86, h - 160)))
    }

    /// The image at zoom 1: its pixel size scaled down to fit the media box. The decode is capped at the box
    /// times the screen scale, so a capped image still fills it. Before it loads, a 672 by 640 placeholder.
    private var fittedSize: CGSize {
        let box = mediaBox
        guard let cg = image.image else { return CGSize(width: min(box.width, 672), height: min(box.height, 640)) }
        let natural = naturalSize ?? MarkdownImages.sizes[items[index].key] ?? CGSize(width: cg.width, height: cg.height)
        let fit = min(1, box.width / max(1, natural.width), box.height / max(1, natural.height))
        return CGSize(width: natural.width * fit, height: natural.height * fit)
    }

    private var captionHeight: CGFloat { contents == nil ? 16 : 20 }

    private var zoomedSize: CGSize { CGSize(width: fittedSize.width * zoom, height: fittedSize.height * zoom) }

    /// The frame's inside at a zoom: the zoomed image up to the media box, centered with the caption under it.
    private func viewport(zoom: CGFloat) -> CGRect {
        let fitted = fittedSize, box = mediaBox
        // The data pane is `h-[min(var(--media-height),40rem)] w-[min(var(--media-width),42rem)]`.
        let size = showingDetails ? CGSize(width: min(box.width, 672), height: min(box.height, 640))
            : CGSize(width: min(fitted.width * zoom, box.width), height: min(fitted.height * zoom, box.height))
        // The caption row is `items-center`: the 20pt micro button sets its height.
        let block = size.height + 8 + captionHeight
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - block) / 2, width: size.width, height: size.height)
    }

    /// Zooms keeping the image point under `point` (or the frame's center) where it is (`changeZoom`).
    private func changeZoom(_ next: CGFloat, at point: CGPoint? = nil) {
        let clamped = min(8, max(1, next))
        guard clamped != zoom else { return }
        let old = viewport(zoom: zoom)
        let local = point.map { CGPoint(x: $0.x - old.minX, y: $0.y - old.minY) } ?? CGPoint(x: old.width / 2, y: old.height / 2)
        let anchor = CGPoint(x: (scroll.x + local.x) / zoom, y: (scroll.y + local.y) / zoom)
        let client = CGPoint(x: old.minX + local.x, y: old.minY + local.y)
        zoom = clamped
        let new = viewport(zoom: zoom)
        scroll = CGPoint(x: anchor.x * zoom - (client.x - new.minX), y: anchor.y * zoom - (client.y - new.minY))
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let popupWidth = (w * 0.92).rounded()
        let inner = viewport(zoom: zoom), scaled = zoomedSize
        scroll.x = min(max(0, scaled.width - inner.width), max(0, scroll.x))
        scroll.y = min(max(0, scaled.height - inner.height), max(0, scroll.y))
        requestPixels()
        // `ring-1` sits outside the image's box.
        frameView.frame = inner.insetBy(dx: -1, dy: -1)
        image.frame = NSRect(x: 1 - scroll.x, y: 1 - scroll.y, width: scaled.width, height: scaled.height)
        details?.frame = inner
        close.frame = NSRect(x: inner.maxX - 24, y: inner.minY - 40, width: 24, height: 24)
        // `flex items-center justify-center gap-1.5`: the name, then the button, centered as a pair.
        let row = inner.maxY + 8
        if let contents {
            let textWidth = min(caption.textWidth, max(0, inner.width - 26))
            let x = inner.midX - (textWidth + 6 + 20) / 2
            caption.frame = NSRect(x: x, y: row + 2, width: textWidth, height: 16)
            contents.frame = NSRect(x: x + textWidth + 6, y: row, width: 20, height: 20)
        } else {
            caption.frame = NSRect(x: inner.minX, y: row, width: inner.width, height: 16)
        }
        let popupX = ((w - popupWidth) / 2).rounded()
        previous.frame = NSRect(x: popupX, y: (h / 2 - 16).rounded(), width: 32, height: 32)
        next.frame = NSRect(x: popupX + popupWidth - 32, y: (h / 2 - 16).rounded(), width: 32, height: 32)
    }

    /// Decode only the pixels this zoom can show, in 128px steps while a wheel gesture grows.
    /// Panning reuses the layer's pixels and performs no image work.
    private func requestPixels(_ initial: CGSize? = nil, scale: CGFloat? = nil) {
        let size = initial ?? (image.image == nil ? mediaBox : zoomedSize)
        let side = max(size.width, size.height) * (scale ?? window?.backingScaleFactor ?? 2)
        image.requestedSide = min(4096, max(128, Int(ceil(side / 128)) * 128))
    }

    /// A new window size fits the image again (`resize` resets the zoom).
    public override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size, zoom != 1 { zoom = 1; scroll = .zero }
        super.setFrameSize(newSize)
    }

    /// `cursor: zoom-in` at fit, `grab` zoomed, `grabbing` while dragging.
    public override func resetCursorRects() {
        let cursor: NSCursor
        if zoom > 1 { cursor = drag != nil ? .closedHand : .openHand }
        else if #available(macOS 15, *) { cursor = .zoomIn } else { cursor = .pointingHand }
        if !showingDetails { addCursorRect(frameView.frame.insetBy(dx: 1, dy: 1), cursor: cursor) }
    }

    /// A click outside the image and its controls closes the preview. On the image a click toggles 2x at the
    /// pointer; a drag (more than 4pt) pans a zoomed image and leaves it zoomed.
    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard frameView.frame.contains(p) || details?.frame.contains(p) == true else { dismiss(); return }
        guard !showingDetails else { return }
        dragged = false
        drag = zoom > 1 ? (p, scroll) : nil
        if drag != nil { NSCursor.closedHand.set() }
    }
    public override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - drag.point.x, point.y - drag.point.y) > 4 { dragged = true }
        scroll = CGPoint(x: drag.scroll.x - (point.x - drag.point.x), y: drag.scroll.y - (point.y - drag.point.y))
        needsLayout = true
    }
    public override func mouseUp(with event: NSEvent) {
        let wasDragging = drag != nil
        drag = nil
        let p = convert(event.locationInWindow, from: nil)
        if !dragged, !showingDetails, event.clickCount == 1, frameView.frame.contains(p) { changeZoom(zoom > 1 ? 1 : 2, at: p) }
        if wasDragging { window?.invalidateCursorRects(for: self) }
    }
    /// Scrolling zooms around the pointer, pinching ten times faster (`exp(-deltaY * 0.002)`, 0.01 with Control).
    public override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 16)
        guard delta != 0, !showingDetails else { return }
        changeZoom(zoom * exp(delta * (event.modifierFlags.contains(.control) ? 0.01 : 0.002)), at: convert(event.locationInWindow, from: nil))
    }
    public override func magnify(with event: NSEvent) {
        guard !showingDetails else { return }
        changeZoom(zoom * (1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }
}

/// `SnapShotAccessibilityData` in the preview: a `pre` with `rounded-lg border border-border/70
/// bg-background p-4 text-xs leading-5 shadow-2xl`, JSON highlighted, the rest plain.
private final class SnapShotDetailsPane: DSView {
    var onEscape: (() -> Void)? {
        get { text.onEscape }
        set { text.onEscape = newValue }
    }
    private let scroll = NSScrollView()
    private let text = EscapingTextView(frame: NSRect(x: 0, y: 0, width: 672, height: 640))

    init(text string: String, isJSON: Bool) {
        super.init(frame: .zero)
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20; paragraph.maximumLineHeight = 20
        text.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: [
            .font: DSFont.mono(12), .foregroundColor: Themed.color(\.foreground), .paragraphStyle: paragraph]))
        if isJSON {
            for token in CodeHighlighter.tokens(string, language: "json") {
                text.textStorage?.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            }
        }
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        addSubview(scroll)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        text.frame.size.width = scroll.contentSize.width
    }

    override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
    }
}

/// Escape closes the preview from inside the text too (T3 listens on the window).
private final class EscapingTextView: NSTextView {
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }
}
