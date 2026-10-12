import AppKit

/// The panel-duration preference is resolved on change. Only explicit transitions allocate work.
@MainActor public enum SettingsPanelMotion {
    public static var durationMs = 0
    public static var duration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Double(min(400, max(0, durationMs))) / 1000
    }
    // ponytail: transform-only transitions, replace with layout interpolation for complete panel parity.
    public static func reveal(_ view: NSView, offset: CGSize) {
        guard duration > 0, view.window != nil, let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation")
        animation.fromValue = NSValue(size: offset); animation.toValue = NSValue(size: .zero)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "settings-panel-motion")
    }

    /// The closing half (T3's width and grid-row transitions run both ways, ChatView.tsx:1325, 11284;
    /// PreviewPanelShell.tsx:119): call before hiding `view`. A still image of it slides by `offset` over
    /// the duration, then goes, so a closed panel keeps no live content and nothing runs afterwards.
    public static func dismiss(_ view: NSView, offset: CGSize) {
        guard duration > 0, view.window != nil, !view.isHidden, view.bounds.width > 0, view.bounds.height > 0,
              let host = view.superview?.layer, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let ghost = CALayer()
        ghost.contents = bitmap.cgImage
        ghost.contentsScale = view.window?.backingScaleFactor ?? 2
        ghost.frame = view.frame
        ghost.zPosition = 30
        host.addSublayer(ghost)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let animation = CABasicAnimation(keyPath: "transform.translation")
        animation.fromValue = NSValue(size: .zero); animation.toValue = NSValue(size: offset)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
        ghost.add(animation, forKey: "settings-panel-dismiss")
        CATransaction.commit()
    }
}
