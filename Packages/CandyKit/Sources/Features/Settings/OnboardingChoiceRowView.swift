import AppKit
import DesignSystem

/// WelcomeWizard.tsx:350-377: computer and project choices inside bordered rows.
public final class OnboardingChoiceRowView: DSView {
    public let checkbox = CheckboxView()
    private let titleLabel: LabelView
    private let detailLabel: LabelView
    public init(title: String, detail: String, selected: Bool, changed: @escaping (Bool) -> Void) {
        titleLabel = LabelView(title, font: DSFont.ui(14, weight: .medium))
        detailLabel = LabelView(detail, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        checkbox.value = selected ? .on : .off
        checkbox.setAccessibilityLabel(title)
        checkbox.onChange = { changed($0 == .on) }
        [checkbox, titleLabel, detailLabel].forEach(addSubview)
    }
    /// A plain `label.flex.items-start.gap-3` with no border, as in RevokeConnectDeviceDialog.tsx:84-99.
    public var bare = false { didSet { layer?.borderWidth = bare ? 0 : 1; needsLayout = true } }
    public override var intrinsicContentSize: NSSize { NSSize(width: 480, height: bare ? 8 + 20 + 16 : 64) }
    public override func layout() {
        super.layout()
        if bare {
            layer?.backgroundColor = nil
            checkbox.frame = NSRect(x: 0, y: 8 + 2, width: 16, height: 16)
            titleLabel.frame = NSRect(x: 28, y: 8, width: max(0, bounds.width - 28), height: 20)
            detailLabel.frame = NSRect(x: 28, y: 28, width: max(0, bounds.width - 28), height: 16)
            return
        }
        layer?.backgroundColor = Themed.color(\.background).cgColor
        layer?.borderColor = Themed.color(\.border).cgColor
        checkbox.frame = NSRect(x: 12, y: 24, width: 16, height: 16)
        titleLabel.frame = NSRect(x: 40, y: 10, width: bounds.width - 52, height: 22)
        detailLabel.frame = NSRect(x: 40, y: 34, width: bounds.width - 52, height: 18)
    }
}
