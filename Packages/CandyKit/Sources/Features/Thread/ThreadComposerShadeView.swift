import AppKit
import DesignSystem

/// Redesign: what lies over a thread's rows from a little above the composer to the panel's bottom, after Capy (the
/// user, 2026-11-27: "do the fade like capy does it"). The rows fade into the panel's ground over `fade` points above
/// the composer's top, and the ground is solid from there down, so no text shows beside or under the composer or
/// behind the row under it.
final class ThreadComposerShadeView: DSView {
    /// How far above the composer's top the rows start to fade.
    static let fade: CGFloat = 40

    private let gradient = CAGradientLayer()
    private let solid = CALayer()

    /// Smoothstep from 0 at `t = 0` to 1 at `t = 1`: the ground's opacity at `t` of the way down the fade.
    static func cover(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [gradient, solid] as [CALayer] {
            l.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(l)
        }
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeRuntime.didChange, object: nil)
    }

    @objc private func themeChanged() { needsDisplay = true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let f = min(Self.fade, bounds.height)
        gradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: f)
        solid.frame = CGRect(x: 0, y: f, width: bounds.width, height: max(0, bounds.height - f))
        CATransaction.commit()
    }

    override func updateLayer() {
        super.updateLayer()
        let ground = Themed.color(\.background).cgColor(in: self)
        let ts = (0...8).map { Double($0) / 8 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The layer is flipped with the view, so location 0 is the fade's top.
        gradient.locations = ts.map { NSNumber(value: $0) }
        gradient.colors = ts.map { ground.copy(alpha: Self.cover($0))! }
        solid.backgroundColor = ground
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
