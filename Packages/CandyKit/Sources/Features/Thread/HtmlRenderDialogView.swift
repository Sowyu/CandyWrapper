import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `HtmlRenderDialog` (chat/HtmlRenderDialog.tsx, T3 3105 aba3a6ddc): a visual reply full screen in the media dialog.
/// The page fills a `w-[92vw] h-[min(86vh,100vh-160px)]` box (`rounded-lg bg-background shadow-2xl ring-1
/// ring-border/70`) that scrolls when zoomed; under it the title and the zoom controls, 50% to 200% in 25% steps.
/// The page lays out at the box's size and the zoom scales it (`zoom` on a `100cqw` by `100cqh` wrapper), which
/// WebKit's page zoom on a frame of the zoomed size reproduces. Escape, the close button or a click outside closes it.
@MainActor
final class HtmlRenderDialogView: DSView {
    var onClose: (() -> Void)?

    private let box = DSView()
    private let scroll = NSScrollView()
    private let frameView = ThreadWebFrameView()
    private let page: ThreadWebFrameView.Page
    private let caption: LabelView
    private let close = ButtonView(nil, icon: .x, variant: .mediaClose, size: .iconXs)
    private let zoomOut = ButtonView(nil, icon: .minus, variant: .overlay, size: .iconSm)
    private let reset = ButtonView("100%", variant: .overlay, size: .sm)
    private let zoomIn = ButtonView(nil, icon: .plus, variant: .overlay, size: .iconSm)
    private(set) var zoom: CGFloat = 1
    private weak var previousResponder: NSResponder?

    init(page: ThreadWebFrameView.Page, onMessage: @escaping (JSONValue, ThreadWebFrameView) -> Void) {
        self.page = page
        caption = LabelView(page.title, font: DSFont.ui(12), color: NSColor.white.withAlphaComponent(0.8))
        super.init(frame: .zero)
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.masksToBounds = true
        // ponytail: no `shadow-2xl` around the box, which barely shows on the 75% black backdrop; add a shadow layer if it reads flat
        scroll.contentView = FlippedClipView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = frameView
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
        frameView.onMessage = { [weak self] data in
            guard let self else { return }
            onMessage(data, self.frameView)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Expanded \(page.title) preview")
        syncZoom()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the dialog over `window`'s content with the close button focused (`initialFocus`).
    func present(in window: NSWindow) {
        guard let content = window.contentView else { return }
        previousResponder = window.firstResponder
        frame = content.bounds
        autoresizingMask = [.width, .height]
        content.addSubview(self)
        layoutSubtreeIfNeeded()
        frameView.activate(page)
        frameView.webView?.forwardsScroll = false
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
        syncZoom()
    }

    private func syncZoom() {
        zoomOut.isEnabled = zoom != 0.5
        zoomIn.isEnabled = zoom != 2
        reset.title = "\(Int((zoom * 100).rounded()))%"
        frameView.webView?.pageZoom = zoom
        // Past 100% the wrapper outgrows the box, which scrolls; the page itself scrolls at 100% and below.
        frameView.webView?.forwardsScroll = zoom > 1
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
        let size = CGSize(width: (w * 0.92).rounded(), height: max(0, min(h * 0.86, h - 160)).rounded())
        // The controls row is `mt-2`, as tall as its 28pt buttons (`sm:h-7`).
        let block = size.height + 8 + 28
        let origin = CGPoint(x: ((w - size.width) / 2).rounded(), y: ((h - block) / 2).rounded())
        box.frame = NSRect(origin: origin, size: size).insetBy(dx: -1, dy: -1)
        scroll.frame = box.bounds.insetBy(dx: 1, dy: 1)
        frameView.frame = NSRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom)
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

/// Keeps a page smaller than the box (zoomed out) at the top left, as the web wrapper sits.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
