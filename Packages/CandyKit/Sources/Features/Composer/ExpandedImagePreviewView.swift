import AppKit
import DesignSystem

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
        public var load: AsyncImageView.Loader
        public init(key: String, name: String, load: @escaping AsyncImageView.Loader) {
            self.key = key; self.name = name; self.load = load
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
    private weak var previousResponder: NSResponder?

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
        image.onLoad = { [weak self] in self?.needsLayout = true }
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
        let box = max(frame.width * 0.92 - 96, min(frame.height * 0.86, frame.height - 160))
        image.requestedSide = Int((box * window.backingScaleFactor).rounded(.up))
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
        let item = items[index]
        caption.text = item.name + (items.count > 1 ? " (\(index + 1)/\(items.count))" : "")
        image.set(key: item.key, fallbackText: "Image unavailable. The file may have been moved or deleted.", loader: item.load)
        needsLayout = true
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
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

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // `w-[92vw]`, `--media-width: calc(92vw - 96px)` from `sm`, `--media-height: min(86vh, 100vh - 160px)`.
        let popupWidth = (w * 0.92).rounded()
        let maxW = max(0, w * 0.92 - (w >= 640 ? 96 : 0)), maxH = max(0, min(h * 0.86, h - 160))
        var size = CGSize(width: min(maxW, 672), height: min(maxH, 640))
        if let cg = image.image {
            // An image's CSS size is its pixel size, scaled down to fit (`max-w`/`max-h`). The decode
            // is capped at the box times the screen scale, so a capped image still fills the box.
            let natural = CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
            let fit = min(1, maxW / max(1, natural.width), maxH / max(1, natural.height))
            size = CGSize(width: natural.width * fit, height: natural.height * fit)
        }
        let block = size.height + 8 + 16
        let x = (w - size.width) / 2, y = (h - block) / 2
        // `ring-1` sits outside the image's box.
        frameView.frame = NSRect(x: x - 1, y: y - 1, width: size.width + 2, height: size.height + 2)
        image.frame = frameView.bounds.insetBy(dx: 1, dy: 1)
        close.frame = NSRect(x: x + size.width - 24, y: y - 40, width: 24, height: 24)
        caption.frame = NSRect(x: x, y: y + size.height + 8, width: size.width, height: 16)
        let popupX = ((w - popupWidth) / 2).rounded()
        previous.frame = NSRect(x: popupX, y: (h / 2 - 16).rounded(), width: 32, height: 32)
        next.frame = NSRect(x: popupX + popupWidth - 32, y: (h / 2 - 16).rounded(), width: 32, height: 32)
    }

    /// A click outside the image and its controls closes the preview.
    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !frameView.frame.contains(p) { dismiss() }
    }
}
