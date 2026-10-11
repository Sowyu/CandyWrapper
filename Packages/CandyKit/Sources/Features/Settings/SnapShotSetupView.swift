import AppKit
import DesignSystem

/// macOS Access and Shortcut steps (SnapShotSetupDialog.tsx:223-410).
@MainActor
public final class SnapShotSetupView {
    public let dialog = DialogView(title: "Set up snapshots")
    public var screenAllowed = false
    public var accessibilityAllowed = false
    public var includesText = true
    public var onScreenPermission: (() -> Void)?
    public var onAccessibilityPermission: (() -> Void)?
    public var onRefresh: (() -> Void)?
    public var onTest: (() -> Void)?
    public var onEnable: (() -> Void)?
    public var tested = false
    private var shortcutStep = false

    public init() { dialog.maxWidth = 576; dialog.footerVariant = .bare; render() }

    public func render() {
        let progress = WizardStepsView(steps: ["Access", "Shortcut"])
        progress.currentStep = shortcutStep ? 1 : 0
        progress.stepViews[1].isEnabled = shortcutStep
        progress.onStepChange = { [weak self] index in self?.shortcutStep = index == 1; self?.render() }
        let title = LabelView(shortcutStep ? "Choose your shortcut" : "Allow snapshots", font: DSFont.ui(16, weight: .semibold))
        let description = LabelView(shortcutStep ? "Use both Shift keys, or record a different shortcut." : "Allow each permission, then continue.", font: DSFont.ui(14))
        if shortcutStep {
            let keys = LabelView("Shift + Shift", font: DSFont.ui(14, weight: .medium))
            dialog.panelContent = [progress, title, description, keys]
            let back = ButtonView("Back", variant: .outline)
            back.action = { [weak self] in self?.shortcutStep = false; self?.render() }
            let enable = ButtonView("Enable snapshots")
            enable.action = { [weak self] in self?.onEnable?() }
            dialog.footerButtons = [back, enable]
        } else {
            let screen = ButtonView(screenAllowed ? "Screen Recording · Allowed" : "Allow Screen Recording", variant: .outline)
            screen.action = { [weak self] in self?.onScreenPermission?() }
            screen.isEnabled = !screenAllowed
            let access = ButtonView(accessibilityAllowed ? "Accessibility · Allowed" : "Allow Accessibility", variant: .outline)
            access.action = { [weak self] in self?.onAccessibilityPermission?() }
            access.isEnabled = !accessibilityAllowed
            dialog.panelContent = [progress, title, description, screen] + (includesText ? [access] : [])
            let refresh = ButtonView("Check again", variant: .outline)
            refresh.action = { [weak self] in self?.onRefresh?() }
            let next = ButtonView(tested ? "Continue" : "Test snapshot")
            next.isEnabled = screenAllowed && (!includesText || accessibilityAllowed)
            next.action = { [weak self] in
                guard let self else { return }
                if tested { shortcutStep = true; render() } else { onTest?() }
            }
            dialog.footerButtons = [refresh, next]
        }
    }
}
