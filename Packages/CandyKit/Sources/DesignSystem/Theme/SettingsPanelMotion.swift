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
}
