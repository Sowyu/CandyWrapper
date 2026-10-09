import AppKit

/// T3's `QRCodeSvg` (`apps/web/src/components/ui/qr-code.tsx`): a background square and one dark run per
/// row segment, drawn `crispEdges` (no antialiasing, edges on device pixels).
/// Spec: docs/research/recovered/ui-components-b.md section 25.
public final class QRCodeView: DSView {
    public var value: String { didSet { rebuild() } }
    public var level: QRCode.Ecc { didSet { rebuild() } }
    public var marginSize: Int { didSet { needsDisplay = true } }
    public var size: CGFloat { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var foregroundColor: NSColor = .black { didSet { needsDisplay = true } }
    public var backgroundColor: NSColor = .white { didSet { needsDisplay = true } }
    public private(set) var code: QRCode?

    public init(value: String, size: CGFloat = 128, level: QRCode.Ecc = .low, marginSize: Int = 0, title: String? = nil) {
        self.value = value
        self.size = size
        self.level = level
        self.marginSize = marginSize
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        rebuild()
        if let title {
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel(title)
        }
    }

    private func rebuild() {
        code = QRCode.encodeText(value, ecc: level)
        needsDisplay = true
    }

    public override var wantsUpdateLayer: Bool { false }
    public override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        ctx.setShouldAntialias(false)
        ctx.setFillColor(backgroundColor.cgColor(in: self))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let code else { return }
        let unit = size / CGFloat(code.size + 2 * marginSize)
        func snap(_ v: Int) -> CGFloat { (CGFloat(v) * unit * scale).rounded() / scale }
        ctx.setFillColor(foregroundColor.cgColor(in: self))
        for y in 0..<code.size {
            var start = -1
            for x in 0...code.size {
                if x < code.size, code.module(x, y) {
                    if start < 0 { start = x }
                    continue
                }
                guard start >= 0 else { continue }
                let x0 = snap(start + marginSize), x1 = snap(x + marginSize)
                let y0 = snap(y + marginSize), y1 = snap(y + 1 + marginSize)
                ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                start = -1
            }
        }
    }
}
