import AppKit
import DesignSystem

/// Redesign: what lies over a thread's rows where they run up through the header row (the user, 2026-11-22: "i want
/// no fade up here except at the very very top"). The rows draw at full strength up to the window's top edge, with a
/// fade of the band's color over the top `edgeFade` points, so a row doesn't meet the window's edge hard. The art
/// already fades from the band color there (`DitherChrome.bandColor`), so the strip doesn't cut it. The breadcrumb
/// over the rows is a solid pill (`DitherThreadTitleView`) and needs nothing behind it.
final class ThreadHeaderShadeView: DSView {
    /// How tall the fade at the window's top edge is: band color at the edge to none at this depth.
    static let edgeFade: CGFloat = 8

    private let edge = CAGradientLayer()

    /// Smoothstep from 0 at `t = 0` to 1 at `t = 1`.
    private static func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

    /// The edge fade's opacity at `t`, 0 at the window's top edge to 1 at `edgeFade` below it.
    static func edge(_ t: Double) -> Double { 1 - ease(t) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        edge.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
        layer?.addSublayer(edge)
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
        edge.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.edgeFade)
        CATransaction.commit()
    }

    override func updateLayer() {
        super.updateLayer()
        let band = DitherChrome.bandColor(in: self)
        let ts = (0...6).map { Double($0) / 6 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        edge.locations = ts.map { NSNumber(value: $0) }
        edge.colors = ts.map { band.copy(alpha: Self.edge($0))! }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
