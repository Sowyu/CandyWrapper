import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `HtmlRenderDialog` (chat/HtmlRenderDialog.tsx, T3 3105 aba3a6ddc): a visual reply full screen in the media dialog.
/// The page sits in a `w-[min(92vw,1176px)] max-h-[min(86vh,100vh-160px)] p-4` card (`rounded-lg bg-background
/// shadow-2xl ring-1 ring-border/70`) that scrolls vertically; under it the title and the zoom controls, 50% to 200%
/// in 25% steps. Since 4928 (HtmlRenderDialog.tsx, #22349) the zoom divides the page's layout width, so the page
/// reflows to fill the card at every level, and the frame is as tall as the page (`htmlRenderFrameHeight` at that
/// width with the height the page reports), so only the card scrolls. WebKit's page zoom on a frame of the card's
/// width does the same. Escape, the close button or a click outside closes it.
@MainActor
final class HtmlRenderDialogView: DSView {
    var onClose: (() -> Void)?

    private let box = DSView()
    private let scroll = NSScrollView()
    /// The card's padded content: the frame at `p-4`.
    private let content = FlippedView()
    private let frameView = ThreadWebFrameView()
    private let reference: HtmlRenderReference?
    /// The height the page reported for itself (`onContentHeight`), at its current layout width.
    private var contentHeight: Double?
    private let page: ThreadWebFrameView.Page
    private let caption: LabelView
    private let close = ButtonView(nil, icon: .x, variant: .mediaClose, size: .iconXs)
    private let zoomOut = ButtonView(nil, icon: .minus, variant: .overlay, size: .iconSm)
    private let reset = ButtonView("100%", variant: .overlay, size: .sm)
    private let zoomIn = ButtonView(nil, icon: .plus, variant: .overlay, size: .iconSm)
    private(set) var zoom: CGFloat = 1
    private weak var previousResponder: NSResponder?

    init(page: ThreadWebFrameView.Page, reference: HtmlRenderReference? = nil, onMessage: @escaping (JSONValue, ThreadWebFrameView) -> Void) {
        self.page = page
        self.reference = reference
        caption = LabelView(page.title, font: DSFont.ui(12), color: NSColor.white.withAlphaComponent(0.8))
        super.init(frame: .zero)
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.masksToBounds = true
        // ponytail: no `shadow-2xl` around the box, which barely shows on the 75% black backdrop; add a shadow layer if it reads flat
        scroll.contentView = FlippedClipView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        content.addSubview(frameView)
        scroll.documentView = content
        box.addSubview(scroll)
        addSubview(box)
        caption.lineHeight = 16
        addSubview(caption)
        close.setAccessibilityLabel("Close")
        close.action = { [weak self] in self?.dismiss() }
        addSubview(close)
        zoomOut.setAccessibilityLabel("Zoom out")
        reset.setAccessibilityLabel("Reset zoom")
        zoomIn.setAccessibilityLabel("Zoom in")
        zoomOut.action = { [weak self] in self?.setZoom((self?.zoom ?? 1) - 0.25) }
        reset.action = { [weak self] in self?.setZoom(1) }
        zoomIn.action = { [weak self] in self?.setZoom((self?.zoom ?? 1) + 0.25) }
        for b in [zoomOut, reset, zoomIn] { addSubview(b) }
        frameView.budgeted = false
        frameView.onMessage = { [weak self] data in
            guard let self else { return }
            if let height = HtmlRenderTheme.contentHeight(data), height != self.contentHeight {
                self.contentHeight = height
                self.needsLayout = true
            }
            onMessage(data, self.frameView)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Expanded \(page.title) preview")
        syncZoom()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { frameView.release() }
    }

    /// Shows the dialog over `window`'s content with the close button focused (`initialFocus`).
    func present(in window: NSWindow) {
        guard let content = window.contentView else { return }
        previousResponder = window.firstResponder
        frame = content.bounds
        autoresizingMask = [.width, .height]
        content.addSubview(self)
        layoutSubtreeIfNeeded()
        frameView.activate(page)
        // The frame is as tall as the page, so the card scrolls, never the page.
        frameView.webView?.forwardsScroll = true
        frameView.webView?.pageZoom = zoom
        window.makeFirstResponder(self)
    }

    func dismiss() {
        let window = window
        frameView.release()
        removeFromSuperview()
        if let previousResponder { window?.makeFirstResponder(previousResponder) }
        onClose?()
    }

    private func setZoom(_ next: CGFloat) {
        let clamped = min(2, max(0.5, next))
        guard clamped != zoom else { return }
        zoom = clamped
        // The page reflows at the new layout width and reports its height there.
        contentHeight = nil
        syncZoom()
    }

    private func syncZoom() {
        zoomOut.isEnabled = zoom != 0.5
        zoomIn.isEnabled = zoom != 2
        reset.title = "\(Int((zoom * 100).rounded()))%"
        frameView.webView?.pageZoom = zoom
        needsLayout = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss(); return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !box.frame.contains(p) { dismiss() }
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        box.layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        box.layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let maxHeight = max(0, min(h * 0.86, h - 160)).rounded()
        // 1144px is the widest the server measures a page, plus the card's padding.
        let width = min((w * 0.92).rounded(), 1176)
        let inner = max(0, width - 32)
        let pageHeight = reference.map { CGFloat($0.frameHeight(width: Double(inner / zoom), contentHeight: contentHeight)) }
            ?? max(0, maxHeight - 32) / zoom
        let frameHeight = (pageHeight * zoom).rounded()
        let size = CGSize(width: width, height: min(maxHeight, frameHeight + 32))
        // The controls row is `mt-2`, as tall as its 28pt buttons (`sm:h-7`).
        let block = size.height + 8 + 28
        let origin = CGPoint(x: ((w - size.width) / 2).rounded(), y: ((h - block) / 2).rounded())
        box.frame = NSRect(origin: origin, size: size).insetBy(dx: -1, dy: -1)
        scroll.frame = box.bounds.insetBy(dx: 1, dy: 1)
        content.frame = NSRect(x: 0, y: 0, width: size.width, height: frameHeight + 32)
        frameView.frame = NSRect(x: 16, y: 16, width: inner, height: frameHeight)
        close.frame = NSRect(x: origin.x + size.width - 24, y: origin.y - 40, width: 24, height: 24)
        // `flex items-center justify-center gap-3`: the title, then the buttons with `gap-1`.
        let rw = max(reset.intrinsicContentSize.width, 28)
        let buttons = 28 + 4 + rw + 4 + 28
        let tw = min(ceil(caption.textWidth), max(0, size.width - buttons - 12))
        var x = (w - (tw + 12 + buttons)) / 2
        let row = origin.y + size.height + 8
        caption.frame = NSRect(x: x, y: row + 6, width: tw, height: 16)
        x += tw + 12
        zoomOut.frame = NSRect(x: x, y: row, width: 28, height: 28); x += 32
        reset.frame = NSRect(x: x, y: row, width: rw, height: 28); x += rw + 4
        zoomIn.frame = NSRect(x: x, y: row, width: 28, height: 28)
    }
}

/// Keeps the card's content at the top as it scrolls.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
