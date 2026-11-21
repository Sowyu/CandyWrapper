import AppKit
import DesignSystem

/// FirstRunGate.tsx:199-237. An opaque gate prevents workspace interaction until evidence settles.
public final class FirstRunRecoveryView: DSView {
    public enum Reason { case connecting, settings, pending }
    public var reason: Reason = .pending { didSet { render() } }
    public var onRetry: (() -> Void)?
    private let title = LabelView("", font: DSFont.ui(18, weight: .semibold))
    private let message = LabelView("", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    private let retry = ButtonView("Reload", icon: .refreshCw, variant: .outline, size: .sm)
    /// Redesign's state view in place of the title, message and button.
    let state = EmptyView(title: "", size: .default)
    public override init(frame: NSRect) {
        super.init(frame: frame)
        title.alignment = .center
        message.alignment = .center
        [title, message, retry, state].forEach(addSubview)
        retry.action = { [weak self] in self?.onRetry?() }
        render()
    }
    private func render() {
        title.text = reason == .settings ? "Could not read settings" : "Still connecting"
        message.text = reason == .settings ? "Your saved settings could not be loaded." : "T3 Code could not confirm this workspace."
        retry.title = reason == .settings ? "Retry" : "Reload"
        let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        [title, message, retry].forEach { $0.isHidden = reason == .pending || redesign }
        state.isHidden = reason == .pending || !redesign
        state.redesign = reason == .settings
            ? StateCopy(title: "Could not read settings", detail: "Your saved settings could not be loaded. Retry to read them again.", icon: .settings)
            : StateCopy(title: "Still connecting", detail: "This workspace could not be confirmed yet. Check that its server is running, then reload.", icon: .unplug)
        state.action = StateAction(retry.title ?? "Retry", icon: .refreshCw) { [weak self] in self?.onRetry?() }
        needsLayout = true
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); render() }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); render() }
    public override func updateLayer() { layer?.backgroundColor = WindowGlass.ground.cgColor(in: self) }
    public override func layout() {
        super.layout()
        let y = (bounds.height - 112) / 2
        title.frame = NSRect(x: 24, y: y, width: max(0, bounds.width - 48), height: 28)
        message.frame = NSRect(x: 24, y: y + 36, width: max(0, bounds.width - 48), height: 20)
        retry.frame = NSRect(x: (bounds.width - 92) / 2, y: y + 76, width: 92, height: 32)
        state.frame = bounds
    }
}
