import AppKit
import DesignSystem

/// DevicePanel.tsx:233-310: centered, 24px smartphone, 24px gaps and a 384px paragraph.
public final class DevicePanelEmptyView: DSView {
    private let icon = IconView(name: .smartphone, size: 24, strokeColor: Themed.color(\.mutedForeground, 0.6))
    private let message = TextBlockView("No simulators or emulators were found on this environment.", font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.mutedForeground))
    public let refresh = ButtonView("Refresh devices", variant: .outline, size: .sm)
    public var detail: String { get { message.text } set { message.text = newValue; needsLayout = true } }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        message.alignment = .center
        [icon, message, refresh].forEach(addSubview)
    }
    public override func layout() {
        super.layout()
        let width = min(384, max(0, bounds.width - 40))
        let textHeight = message.height(forWidth: width)
        let button = refresh.intrinsicContentSize
        let total = 24 + 24 + textHeight + 24 + button.height
        let y = max(32, (bounds.height - total) / 2)
        icon.frame = NSRect(x: (bounds.width - 24) / 2, y: y, width: 24, height: 24)
        message.frame = NSRect(x: (bounds.width - width) / 2, y: y + 48, width: width, height: textHeight)
        refresh.frame = NSRect(x: (bounds.width - button.width) / 2, y: y + 72 + textHeight, width: button.width, height: button.height)
    }
    public override func updateLayer() { layer?.backgroundColor = WindowGlass.ground.cgColor(in: self) }
}
