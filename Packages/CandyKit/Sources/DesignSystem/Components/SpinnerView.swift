import AppKit
import QuartzCore

/// T3's `Spinner` (`apps/web/src/components/ui/spinner.tsx`): lucide `loader-circle` turning once a second.
/// It turns only while visible and Reduce Motion is off; otherwise it is a still arc.
/// Spec: docs/research/recovered/ui-components-b.md section 11.
public final class SpinnerView: NSView {
    public enum Size: String, CaseIterable, Sendable {
        case xs, sm, md, lg
        var points: CGFloat { switch self { case .xs: 12; case .sm: 14; case .md: 16; case .lg: 20 } }
    }

    public enum Tone: String, CaseIterable, Sendable { case current, muted }

    public var size: Size { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    public var tone: Tone { didSet { applyColor() } }
    /// The `current` tone's color (CSS `currentColor`).
    public var color: NSColor = Themed.color(\.contrastForeground) { didSet { applyColor() } }

    private let arc = CAShapeLayer()
    private lazy var loop = LoopingAnimation(view: self, key: "spin", layer: { [weak self] in self?.arc }) {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi  // layer space is y-up, so negative turns clockwise like CSS rotate
        spin.duration = 1
        spin.repeatCount = .infinity
        return spin
    }

    public init(size: Size = .md, tone: Tone = .current) {
        self.size = size
        self.tone = tone
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        arc.fillColor = nil
        arc.lineCap = .round
        arc.lineJoin = .round
        arc.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
        layer?.addSublayer(arc)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading")
        applyColor()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: size.points, height: size.points) }

    public override func layout() {
        super.layout()
        let s = bounds.width > 0 ? min(bounds.width, bounds.height) : size.points
        let scale = s / 24
        // viewBox (y down) to layer space (y up), like IconView.
        var t = CGAffineTransform(translationX: 0, y: s).scaledBy(x: scale, y: -scale)
        guard let path = try? IconName.loaderCircle.definition.elements.first?.cgPath() else { return }
        arc.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        arc.path = path.copy(using: &t)
        arc.lineWidth = 2 * scale
        arc.contentsScale = window?.backingScaleFactor ?? 2
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loop.windowChanged() }
    public override func viewDidHide() { super.viewDidHide(); loop.update() }
    public override func viewDidUnhide() { super.viewDidUnhide(); loop.update() }

    private func applyColor() {
        let c = tone == .muted ? Themed.color(\.contrastMutedForeground) : color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeColor = c.cgColor(in: self)
        CATransaction.commit()
    }
}
