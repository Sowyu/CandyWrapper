import AppKit
import QuartzCore

/// Layer-backed vector icon: one CAShapeLayer per SVG element, scaled from the icon's viewBox to the view size.
/// lucide strokes are 2 viewBox units wide, so they scale with the size (1.33 px at 16 px), as in T3.
public final class IconView: NSView {
    /// Nil for an icon built from a definition, such as a file type icon.
    public let name: IconName?
    private let definition: IconDefinition
    /// Fixed-color glyph: unfilled shapes stay unfilled.
    private let isBrand: Bool
    private var shapes: [(layer: CAShapeLayer, element: IconElement, path: CGPath)] = []

    public var strokeColor: NSColor { didSet { applyColors() } }
    /// Fills `currentColor` fills, and the otherwise unfilled shapes of lucide icons.
    public var fillColor: NSColor? { didSet { applyColors() } }

    private let nominalSize: CGFloat

    public convenience init(name: IconName, size: CGFloat = 16, strokeColor: NSColor = .labelColor, fillColor: NSColor? = nil) {
        self.init(name: name, definition: name.definition, brand: name.isBrand, size: size, strokeColor: strokeColor, fillColor: fillColor)
    }

    /// An icon outside the generated set. `currentColor` resolves to `strokeColor` (or `fillColor` for fills).
    public convenience init(definition: IconDefinition, size: CGFloat = 16, color: NSColor = .labelColor) {
        self.init(name: nil, definition: definition, brand: true, size: size, strokeColor: color, fillColor: nil)
    }

    private init(name: IconName?, definition: IconDefinition, brand: Bool, size: CGFloat, strokeColor: NSColor, fillColor: NSColor?) {
        self.name = name
        self.definition = definition
        self.isBrand = brand
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.nominalSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        for element in definition.elements {
            guard let path = try? element.cgPath() else { continue }
            let l = CAShapeLayer()
            l.actions = ["path": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "opacity": NSNull()]
            layer?.addSublayer(l)
            shapes.append((l, element, path))
        }
        relayout()
        applyColors()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: nominalSize, height: nominalSize) }

    /// Decoration: clicks go to the control or bar underneath.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    public override func layout() {
        super.layout()
        relayout()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        withoutActions { for s in shapes { s.layer.contentsScale = scale } }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func relayout() {
        let vb = definition.viewBox
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0, vb.width > 0, vb.height > 0 else { return }
        let scale = min(w / vb.width, h / vb.height)
        let ox = (w - vb.width * scale) / 2, oy = (h - vb.height * scale) / 2
        withoutActions {
            for s in shapes {
                // viewBox (y down) -> layer (y up)
                var t = CGAffineTransform(translationX: ox, y: h - oy)
                    .scaledBy(x: scale, y: -scale)
                    .translatedBy(x: -vb.x + s.element.paint.offsetX, y: -vb.y + s.element.paint.offsetY)
                s.layer.frame = bounds
                s.layer.path = s.path.copy(using: &t)
                s.layer.lineWidth = s.element.paint.strokeWidth * scale
            }
        }
    }

    private func resolve(_ c: IconColor, fillSlot: Bool) -> CGColor? {
        let color: NSColor?
        switch c {
        case .none: color = (fillSlot && !isBrand) ? fillColor : nil
        case .current: color = fillSlot ? (fillColor ?? strokeColor) : strokeColor
        case .rgba(let v):
            color = NSColor(
                srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        }
        guard let color else { return nil }
        var out: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }

    private func applyColors() {
        withoutActions {
            for s in shapes {
                let p = s.element.paint
                let l = s.layer
                l.fillColor = resolve(p.fill, fillSlot: true)
                l.strokeColor = resolve(p.stroke, fillSlot: false)
                l.fillRule = p.evenOdd ? .evenOdd : .nonZero
                l.opacity = Float(p.opacity)
                l.lineCap = switch p.lineCap { case .butt: .butt; case .round: .round; case .square: .square }
                l.lineJoin = switch p.lineJoin { case .miter: .miter; case .round: .round; case .bevel: .bevel }
            }
        }
    }
}
