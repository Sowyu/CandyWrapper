import AppKit
import QuartzCore

/// T3's `Skeleton` (`apps/web/src/components/ui/skeleton.tsx`): a `--muted-foreground` 15% block
/// that pulses with T3's stepped `skeleton` keyframes. The consumer sets the size.
/// Spec: docs/research/recovered/ui-components-b.md section 10.
public final class SkeletonView: DSView {
    public enum Shape: String, CaseIterable, Sendable { case block, card, pill }

    public var shape: Shape { didSet { needsDisplay = true } }
    private lazy var loop = LoopingAnimation(view: self, key: "skeleton", layer: { [weak self] in self?.layer }) {
        Self.pulse()
    }

    public init(shape: Shape = .block) {
        self.shape = shape
        super.init(frame: .zero)
    }

    public override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = Themed.color(\.contrastMutedForeground, 0.15).cgColor(in: self)
        layer.cornerRadius = switch shape {
        case .block: 6
        case .card: 10
        case .pill: min(bounds.width, bounds.height) / 2
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if shape == .pill { needsDisplay = true }
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loop.windowChanged() }
    public override func viewDidHide() { super.viewDidHide(); loop.update() }
    public override func viewDidUnhide() { super.viewDidUnhide(); loop.update() }

    /// `animation: 2.4s infinite skeleton`: hold 1, four steps down to .55 over 192ms, hold, four steps back.
    static func pulse() -> CAAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.calculationMode = .discrete
        a.values = [1, 0.8875, 0.775, 0.6625, 0.55, 0.6625, 0.775, 0.8875, 1]
        a.keyTimes = [0, 1.056, 1.104, 1.152, 1.2, 2.256, 2.304, 2.352, 2.4, 2.4].map { NSNumber(value: $0 / 2.4) }
        a.duration = 2.4
        a.repeatCount = .infinity
        return a
    }
}
