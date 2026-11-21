import AppKit
import QuartzCore

/// Redesign's motion patterns on `RedesignTokens.Motion` (docs/research/redesign-motion-2026-11-21.md). Each one runs
/// on layer properties the window server animates, removes its animations when it ends, starts from what is on screen
/// when it interrupts another, and snaps under Reduce Motion. None of them holds events back.
@MainActor
public enum RedesignMotion {
    typealias Tokens = RedesignTokens.Motion

    /// Ends a run: on a finish, not on a later run replacing it, it calls `done` and takes the run's animations off.
    // Core Animation calls its delegate on the main thread.
    private nonisolated final class End: NSObject, CAAnimationDelegate, @unchecked Sendable {
        let done: @MainActor @Sendable () -> Void
        init(_ done: @escaping @MainActor @Sendable () -> Void) { self.done = done }
        func animationDidStop(_ anim: CAAnimation, finished: Bool) {
            guard finished else { return }
            let done = done
            MainActor.assumeIsolated { done() }
        }
    }

    /// Moves `layer` along `axis` from `offset` (entering) or to it (leaving) and fades it, starting from what is on
    /// screen when it interrupts an earlier run.
    private static func run(_ layer: CALayer, key: String, axis: String, offset: CGFloat, entering: Bool,
                            duration: CFTimeInterval, completion: (@MainActor () -> Void)?) {
        let moveKey = key + "." + axis, fadeKey = key + ".opacity"
        let shown = layer.presentation()
        let interrupted = layer.animation(forKey: fadeKey) != nil
        let move = CABasicAnimation(keyPath: "transform.translation." + axis)
        move.fromValue = interrupted ? (shown?.value(forKeyPath: "transform.translation." + axis) as? CGFloat ?? 0) : (entering ? offset : 0)
        move.toValue = entering ? 0 : offset
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = interrupted ? shown?.opacity ?? 1 : (entering ? 0 : layer.opacity)
        fade.toValue = entering ? layer.opacity : 0
        fade.delegate = End { [weak layer] in
            completion?()
            layer?.removeAnimation(forKey: moveKey); layer?.removeAnimation(forKey: fadeKey)
        }
        for a in [move, fade] {
            a.duration = duration
            a.timingFunction = Tokens.timing(entering: entering)
            a.fillMode = .both
            a.isRemovedOnCompletion = false
        }
        layer.add(move, forKey: moveKey)
        layer.add(fade, forKey: fadeKey)
    }

    /// Hover shows at once and clears over `fast`. Nil when the change is not a hover alone, which keeps the
    /// control's own transitions.
    public static func hoverTransition(from old: ControlView.State, to new: ControlView.State) -> (Motion.Transition, CFTimeInterval)? {
        var same = new
        same.hovered = old.hovered
        guard same == old, old.hovered != new.hovered else { return nil }
        return new.hovered ? ([], Tokens.fast) : (.colors, Tokens.fast)
    }

    /// A modal's backdrop fades over `large`, its dialog over `standard`; both leave over `fast`.
    public static func modal(backdrop: Bool, entering: Bool) -> CFTimeInterval {
        entering ? (backdrop ? Tokens.large : Tokens.standard) : Tokens.fast
    }

    /// A pill or toast that appears rises from `rise` and fades in over `standard`; one that leaves sinks back and
    /// fades out over `fast`. `completion` runs when a leave ends (at once under Reduce Motion), after which the
    /// layer holds no animation.
    public static func pill(_ layer: CALayer, entering: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard !Motion.reduced else {
            layer.removeAnimation(forKey: "redesign.pill.y"); layer.removeAnimation(forKey: "redesign.pill.opacity")
            completion?()
            return
        }
        run(layer, key: "redesign.pill", axis: "y", offset: Tokens.rise, entering: entering,
            duration: entering ? Tokens.standard : Tokens.fast, completion: completion)
    }

    /// A backdrop fades in over `large`. Also the Reduce Motion form of the panel: a fade has no travel.
    public static func fade(_ layer: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = layer.opacity
        fade.duration = Tokens.large
        fade.timingFunction = Tokens.curve
        layer.add(fade, forKey: "redesign.fade")
    }

    /// The right panel: slides `panelShift` in from its edge and fades in as one flattened layer over `large`, so no
    /// text shows through other text, or leaves the same way over `fast`. `edge` is +1 for a panel on the right.
    public static func panel(_ layer: CALayer, entering: Bool, edge: CGFloat = 1, completion: (@MainActor () -> Void)? = nil) {
        // Reduce Motion: a plain fade, no travel.
        guard !Motion.reduced else {
            if entering { fade(layer) }
            completion?()
            return
        }
        // One flattened image fades, never the panel's text over what lies behind it.
        layer.allowsGroupOpacity = true
        run(layer, key: "redesign.panel", axis: "x", offset: edge * Tokens.panelShift, entering: entering,
            duration: entering ? Tokens.large : Tokens.fast, completion: completion)
    }
}
