import AppKit
import QuartzCore

/// Redesign's loading placeholder: quiet bars shaped like the content that is coming, in the hover fill. It breathes
/// once every 2.4 s only while it can be seen and Reduce Motion is off (`LoopingAnimation`), and its owner removes it
/// the moment the content arrives, so nothing animates at rest.
public final class StateSkeletonView: DSView {
    /// What the bars stand in for.
    public enum Shape: String, CaseIterable, Sendable {
        /// File headers with code lines under them: the Diff panel.
        case diff
        /// Rows with an icon and a name: the file tree, lists.
        case list
        /// A conversation: a short user bubble at the right, then reply paragraphs.
        case thread
    }

    /// One bar: from `x` (points from the leading edge) across `width` of what is left, on the row's line.
    struct Bar { let x: CGFloat; let width: CGFloat; let height: CGFloat; let trailing: Bool }

    public var shape: Shape { didSet { if shape != oldValue { rebuild() } } }
    private var bars: [CALayer] = []
    private lazy var loop = LoopingAnimation(view: self, key: "breathe", layer: { [weak self] in self?.layer }) { Self.breathe() }

    public init(shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading")
    }

    /// Rows of bars, each row 20 points tall, a blank row between groups.
    static func rows(_ shape: Shape) -> [[Bar]] {
        let line: CGFloat = 8
        switch shape {
        case .diff:
            let header = [Bar(x: 0, width: 0.45, height: 10, trailing: false)]
            let code: [[Bar]] = [0.7, 0.55, 0.8, 0.4, 0.62].map { [Bar(x: 28, width: $0, height: line, trailing: false)] }
            return [header] + code + [[]] + [header] + code.prefix(3)
        case .list:
            return [0.5, 0.35, 0.6, 0.42, 0.3, 0.55, 0.38].map {
                [Bar(x: 0, width: 0, height: 12, trailing: false), Bar(x: 20, width: $0, height: line, trailing: false)]
            }
        case .thread:
            let reply: [[Bar]] = [0.92, 0.86, 0.95, 0.5].map { [Bar(x: 0, width: $0, height: line, trailing: false)] }
            return [[Bar(x: 0, width: 0.38, height: 24, trailing: true)], []] + reply + [[]] + reply.prefix(3)
        }
    }

    private func rebuild() {
        bars.forEach { $0.removeFromSuperlayer() }
        bars = Self.rows(shape).flatMap { $0 }.map { _ in
            let l = CALayer()
            l.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(l)
            return l
        }
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        if bars.isEmpty { rebuild() }
        let rows = Self.rows(shape), rowHeight: CGFloat = 20
        let pad = RedesignTokens.Space.l, width = max(0, bounds.width - 2 * pad)
        var i = 0, y = pad
        for row in rows {
            for bar in row where i < bars.count {
                let w = bar.width == 0 ? bar.height : max(bar.height, (width - bar.x) * bar.width).rounded()
                let x = bar.trailing ? pad + width - w : pad + bar.x
                bars[i].frame = CGRect(x: x, y: y + ((rowHeight - bar.height) / 2).rounded(), width: w, height: bar.height)
                // A bubble-sized bar takes the card corner, a text line round ends.
                let block = bar.height > 12
                bars[i].cornerRadius = block ? RedesignTokens.Radius.card : RedesignTokens.Radius.capsule(bar.height)
                i += 1
            }
            y += rowHeight + (row.first?.height ?? 0 > 12 ? RedesignTokens.Space.s : 0)
            if y > bounds.height { break }
        }
        for l in bars[i...] { l.frame = .zero }
    }

    public override func updateLayer() {
        let fill = RedesignTokens.State.fill(RedesignTokens.State.pressed, dark: effectiveAppearance.isDark).cgColor(in: self)
        bars.forEach { $0.backgroundColor = fill }
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loop.windowChanged() }
    public override func viewDidHide() { super.viewDidHide(); loop.update() }
    public override func viewDidUnhide() { super.viewDidUnhide(); loop.update() }

    /// Whether the breathing loop is on the layer now, for tests.
    public var isAnimating: Bool { layer?.animation(forKey: "breathe") != nil }

    /// The lowest the bars fade to, in the middle of a breath.
    static let dim: Float = 0.5

    static func breathe() -> CAAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = dim
        a.duration = RedesignTokens.Motion.loop
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }
}
