import AppKit
import DesignSystem
import T3Protocol

/// The version popover of a provider (providerStatus.ts:107-172, ProviderInstanceCard.tsx:596-801,
/// ProviderSettingsPanel.tsx:682-728 and 1088-1108, ProviderUpdateLaunchNotification.logic.ts:162-173).
public enum ProviderVersionAdvisoryLogic {
    public struct Presentation: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var updateCommand: String?
        /// `strong` draws the detail in the warning color.
        public var strong: Bool
        public var targetVersion: String?
        /// A compatibility warning: the alert triangle instead of the arrow.
        public var warning: Bool
    }

    static let compatibilityTitles = ["graceful": "Limited support", "unsupported": "Unsupported version", "broken": "Known broken version"]

    /// `getProviderVersionAdvisoryPresentation`, with the compatibility advisory shown only for enabled providers.
    public static func presentation(_ p: ServerProvider?, enabled: Bool) -> Presentation? {
        guard let p else { return nil }
        let advisory = p.versionAdvisory, compatibility = p.compatibilityAdvisory
        let latestStatus = compatibility?["latestVersionStatus"]?.stringValue
        let latestIsIncompatible = latestStatus == "broken" || latestStatus == "unsupported"
        if enabled, let status = compatibility?["status"]?.stringValue, let title = compatibilityTitles[status] {
            let target = compatibility?["recommendedVersion"]?.stringValue
            let recommendation = ProvidersLogic.versionLabel(target) ?? compatibility?["recommendedRange"]?.stringValue
            return Presentation(title: title,
                                detail: compatibility?["message"]?.stringValue ?? (recommendation.map { "Use \($0) for full support." } ?? "Update for full support."),
                                updateCommand: target != nil || latestIsIncompatible ? nil : advisory?["updateCommand"]?.stringValue,
                                strong: status != "graceful", targetVersion: target, warning: status != "supported" && status != "unknown")
        }
        guard let advisory, let status = advisory["status"]?.stringValue, status != "current", status != "unknown", !latestIsIncompatible else { return nil }
        let label = "Update available"
        let version = ProvidersLogic.versionLabel(advisory["latestVersion"]?.stringValue)
        return Presentation(title: label,
                            detail: advisory["message"]?.stringValue ?? (version.map { "\(label): install \($0)." } ?? "\(label): install the latest provider version."),
                            updateCommand: advisory["updateCommand"]?.stringValue, strong: false, targetVersion: nil, warning: false)
    }

    /// `isProviderSettingsUpdateCandidate`: one click may update it.
    public static func canUpdate(_ p: ServerProvider) -> Bool {
        let latest = p.compatibilityAdvisory?["latestVersionStatus"]?.stringValue
        return p.enabled && latest != "broken" && latest != "unsupported" && p.versionAdvisory?["status"]?.stringValue == "behind_latest"
            && p.versionAdvisory?["canUpdate"]?.boolValue == true && p.versionAdvisory?["updateCommand"]?.stringValue != nil
    }

    /// `onInstallRecommended`: the compatibility advisory names a version the server can install.
    public static func canInstallRecommended(_ p: ServerProvider) -> Bool {
        p.compatibilityAdvisory?["message"]?.stringValue != nil && p.compatibilityAdvisory?["recommendedVersion"]?.stringValue != nil
            && p.versionAdvisory?["canInstallVersion"]?.boolValue == true
    }

    /// `isProviderUpdateActive`.
    public static func isUpdating(_ p: ServerProvider?) -> Bool { p?.updateState?.status == "queued" || p?.updateState?.status == "running" }
}

/// The advisory button (`icon-xs ghost-muted`: the arrow, the warning triangle, or a spinner while updating) that
/// opens the popover: title, detail, Update now or Install, progress, the manual command with Copy.
@MainActor
func providerVersionAdvisoryButton(_ presentation: ProviderVersionAdvisoryLogic.Presentation, updating: Bool, progress: String?, problem: String?,
                                   run: (@MainActor () -> Void)?, micro: Bool = false, copy: @escaping @MainActor (String) -> Void) -> ButtonView {
    let b = ButtonView(nil, icon: updating ? .loaderCircle : presentation.warning ? .triangleAlert : .circleArrowUp, variant: .ghostMuted, size: micro ? .iconMicro : .iconXs)
    if micro { b.iconSize = 14 }
    if presentation.warning, !updating { b.iconColor = Themed.color(\.warning) }
    b.setAccessibilityLabel("\(updating ? "Updating" : presentation.title), view details")
    _ = TooltipController.attach(to: b, text: updating ? "Updating" : presentation.title)
    b.action = { [weak b] in
        guard let b else { return }
        let body = ProviderVersionAdvisoryPopover(presentation, updating: updating, progress: progress, problem: problem, run: run, copy: copy)
        body.onClose = { [weak b] in b?.popupHost?.closeAll() }
        PopoverView(content: body, padding: .default, width: .md).show(from: b, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4))
    }
    return b
}

final class ProviderVersionAdvisoryPopover: DSView {
    var onClose: (() -> Void)?
    private let title = LabelView("", font: DSFont.ui(14, weight: .semibold), color: Themed.color(\.popoverForeground))
    private let detail = TextBlockView()
    private let action: ButtonView?
    private let status = TextBlockView()
    private let divider = LabelView("OR, UPDATE MANUALLY USING", font: DSFont.ui(10, weight: .medium), color: Themed.color(\.mutedForeground))
    private let leftRule = CALayer(), rightRule = CALayer()
    private let commandBox = BoxView(frame: .zero)
    private let command = LabelView("", font: DSFont.mono(11), color: Themed.color(\.foreground))
    private let copyButton = ButtonView(nil, icon: .copy, variant: .ghostMuted, size: .iconXs)
    private let hasCommand: Bool
    private let showsDivider: Bool
    private let width: CGFloat = 320 - 32 - 2

    init(_ p: ProviderVersionAdvisoryLogic.Presentation, updating: Bool, progress: String?, problem: String?,
         run: (@MainActor () -> Void)?, copy: @escaping @MainActor (String) -> Void) {
        if let run {
            let label = updating ? "Updating" : p.targetVersion.map { "Install \(ProvidersLogic.versionLabel($0) ?? $0)" } ?? "Update now"
            let b = ButtonView(label, icon: updating ? .loaderCircle : .download, variant: .outline, size: .xs)
            b.isEnabled = !updating
            b.action = { run() }
            action = b
        } else {
            action = nil
        }
        hasCommand = p.updateCommand != nil
        showsDivider = run != nil && p.updateCommand != nil
        super.init(frame: .zero)
        title.text = p.title
        title.lineHeight = 17.5
        detail.text = p.detail
        detail.font = DSFont.ui(12)
        detail.lineHeight = 16.5
        detail.color = p.strong ? Themed.color(\.warning) : Themed.color(\.mutedForeground)
        status.text = progress ?? problem ?? ""
        status.font = DSFont.ui(12)
        status.lineHeight = 16.5
        status.color = problem != nil && progress == nil ? Themed.color(\.warning) : Themed.color(\.mutedForeground)
        status.isHidden = status.text.isEmpty
        divider.lineHeight = 14
        divider.tracking = 0.5
        divider.isHidden = !showsDivider
        leftRule.isHidden = !showsDivider
        rightRule.isHidden = !showsDivider
        layer?.addSublayer(leftRule)
        layer?.addSublayer(rightRule)
        command.text = p.updateCommand ?? ""
        command.lineHeight = 16
        commandBox.boxStyle.radius = 8
        commandBox.isHidden = !hasCommand
        copyButton.iconSize = 12
        copyButton.setAccessibilityLabel("Copy update command")
        _ = TooltipController.attach(to: copyButton, text: "Copy command")
        copyButton.action = { [weak self] in copy(p.updateCommand ?? ""); self?.onClose?() }
        commandBox.addSubview(command)
        commandBox.addSubview(copyButton)
        for v in [title, detail, status, divider, commandBox] as [NSView] { addSubview(v) }
        action.map(addSubview)
    }

    override func updateLayer() {
        for r in [leftRule, rightRule] { r.backgroundColor = Themed.color(\.border).cgColor(in: self) }
        commandBox.boxStyle.fill = Themed.color(\.muted, 0.4)
        commandBox.boxStyle.border = Themed.color(\.border, 0.7)
    }

    /// `grid gap-3`; the header block is `gap-0.5`.
    private func place(_ apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        if apply { title.frame = NSRect(x: 0, y: 0, width: width, height: 18) }
        y += 18 + 2
        let dh = detail.height(forWidth: width)
        if apply { detail.frame = NSRect(x: 0, y: y, width: width, height: dh) }
        y += dh
        if let action {
            y += 12
            if apply { action.frame = NSRect(x: 0, y: y, width: width, height: 24) }
            y += 24
        }
        if !status.isHidden {
            y += 12
            let sh = status.height(forWidth: width)
            if apply { status.frame = NSRect(x: 0, y: y, width: width, height: sh) }
            y += sh
        }
        if showsDivider {
            y += 12
            if apply {
                let dw = ceil(divider.textWidth) + 1
                divider.frame = NSRect(x: (width - dw) / 2, y: y, width: dw, height: 14)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                leftRule.frame = CGRect(x: 0, y: y + 7, width: max(0, (width - dw) / 2 - 8), height: 1)
                rightRule.frame = CGRect(x: (width + dw) / 2 + 8, y: y + 7, width: max(0, (width - dw) / 2 - 8), height: 1)
                CATransaction.commit()
            }
            y += 14
        }
        if hasCommand {
            y += 12
            if apply {
                commandBox.frame = NSRect(x: 0, y: y, width: width, height: 30)
                command.frame = NSRect(x: 9, y: 7, width: width - 9 - 2 - 24 - 4, height: 16)
                copyButton.frame = NSRect(x: width - 2 - 24 - 1, y: 3, width: 24, height: 24)
            }
            y += 30
        }
        return y
    }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: place(false)) }
    override func layout() { super.layout(); _ = place(true) }
}
