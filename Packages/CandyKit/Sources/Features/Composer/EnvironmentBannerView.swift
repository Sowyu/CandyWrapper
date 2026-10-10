import AppKit
import DesignSystem

/// "<label> is reconnecting" or "<label> is offline" over the composer while the thread's environment
/// is not connected (ChatView.tsx:3091-3142, a `ComposerBannerStack` item with `density="comfortable"`):
/// a WifiOff icon, the title, and `Reconnect` and `Disconnect server` ghost buttons.
public final class EnvironmentBannerView: ComposerBannerView {
    private let icon = IconView(name: .wifiOff, size: 12)
    private let title: LabelView
    public let reconnect = ButtonView("Reconnect", variant: .ghost, size: .xs)
    public let disconnect = ButtonView("Disconnect server", variant: .ghost, size: .xs)

    public var text: String { get { title.text } set { title.text = newValue; needsLayout = true } }
    public var isError: Bool { get { variant == .error } set { variant = newValue ? .error : .warning } }
    public var showsReconnect = true { didSet { reconnect.isHidden = !showsReconnect; needsLayout = true } }
    public var showsDisconnect = false { didSet { disconnect.isHidden = !showsDisconnect; needsLayout = true } }

    public init() {
        title = glassLabel(font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground), lineHeight: 24)
        super.init(variant: .warning)
        icon.strokeColor = Themed.color(\.mutedForeground)
        for b in [reconnect, disconnect] { b.smoothsFont = false }
        disconnect.toolTip = "Hide this server's threads. Switch it on again in Connections."
        disconnect.isHidden = true
        for v in [icon, title, reconnect, disconnect] as [NSView] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("alert")
    }

    /// `py-1.25` around the 24pt row, plus the overlap under the composer.
    public static let height: CGFloat = 5 + 24 + 5 + ComposerBannerView.overlap

    public override func layout() {
        super.layout()
        let rowY: CGFloat = 5
        // `px-1`, a 24pt icon column, `gap-x-1`.
        icon.frame = NSRect(x: 4 + 6, y: rowY + 6, width: 12, height: 12)
        var right = bounds.width - 4
        for b in [disconnect, reconnect] where !b.isHidden {
            let s = b.intrinsicContentSize
            right -= s.width
            b.frame = NSRect(x: right, y: rowY + (24 - s.height) / 2, width: s.width, height: s.height)
            right -= 4
        }
        let x: CGFloat = 4 + 24 + 4
        title.frame = NSRect(x: x, y: rowY, width: max(0, min(ceil(title.textWidth) + 1, right - x)), height: 24)
    }
}
