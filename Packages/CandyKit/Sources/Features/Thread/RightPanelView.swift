import AppKit
import DesignSystem

/// The inline right panel (RightPanelTabs.tsx, PreviewPanelShell.tsx) with its only surface so
/// far, the diff: a 52px tab bar (`pl-2`, the tab, the add button) over the surface. The window's
/// panel controls sit at the bar's right edge while it is open; `ThreadPanelView` places them.
final class RightPanelView: DSView {
    static let tabBarHeight: CGFloat = 52
    /// `PREVIEW_PANEL_DEFAULT_WIDTH`, `_MIN_WIDTH` and the sibling column's floor
    /// (usePreviewPanelInlineSize.ts).
    static let defaultWidth: CGFloat = 540
    static let minWidth: CGFloat = 360

    /// The inline width: the default, at most 70% of the viewport and leaving the chat column
    /// 360px, never under 360 (`getPreviewPanelMaxWidth`).
    // ponytail: no resize handle, so the width is always the default; add the left-edge drag and
    // T3's `t3code:preview-panel-width` memory when someone wants a wider diff
    static func width(viewport: CGFloat, container: CGFloat) -> CGFloat {
        let maxWidth = max(minWidth, min((viewport * 0.7).rounded(.down), container.rounded(.down) - 360))
        return min(max(defaultWidth, minWidth), maxWidth)
    }

    let diff = DiffPanelView()
    let tab = PanelTabView(title: "Diff", icon: .fileDiff)
    /// Opens the add-surface menu in T3.
    // ponytail: inert, the diff is the only surface; give it the menu when files or terminal surfaces land
    let add = ButtonView(nil, icon: .plus, variant: .ghostMuted, size: .iconXs)
    private let border = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        add.iconSize = 14
        add.setAccessibilityLabel("Add panel surface")
        border.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(border)
        [diff, tab, add].forEach(addSubview)
        clipsToBounds = true
    }

    override func layout() {
        super.layout()
        // `border-l border-border`; the content is `width - 1` wide right of it.
        border.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        let tabWidth = tab.preferredWidth
        tab.frame = NSRect(x: 1 + 8, y: (Self.tabBarHeight - 24) / 2, width: tabWidth, height: 24)
        add.frame = NSRect(x: tab.frame.maxX + 4, y: (Self.tabBarHeight - 24) / 2, width: 24, height: 24)
        diff.frame = NSRect(x: 1, y: Self.tabBarHeight, width: max(0, bounds.width - 1), height: max(0, bounds.height - Self.tabBarHeight))
    }

    override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        border.backgroundColor = Themed.color(\.border).cgColor(in: self)
    }
}

/// One panel tab: `h-6 rounded-md pl-1.5 pr-2 gap-0.5 text-xs`, the identity glyph that turns into
/// a close button on hover, the title; `bg-accent` when active.
final class PanelTabView: DSView {
    let close: PanelTabCloseButton
    private let title: LabelView
    var isActive = true { didSet { restyle() } }
    private var hovered = false { didSet { if hovered != oldValue { close.isTabHovered = hovered; restyle() } } }
    private var tracking: NSTrackingArea?
    var onSelect: (@MainActor () -> Void)?

    init(title text: String, icon: IconName) {
        title = LabelView(text, font: DSFont.ui(12))
        close = PanelTabCloseButton(identity: IconView(name: icon, size: 12, strokeColor: Themed.color(\.foreground)), label: "Close \(text)")
        super.init(frame: .zero)
        layer?.cornerRadius = 8
        title.lineHeight = 16
        addSubview(close)
        addSubview(title)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(text)
        restyle()
    }

    var preferredWidth: CGFloat { min(144, 6 + 16 + 2 + ceil(title.textWidth) + 8) }

    private func restyle() {
        title.color = Themed.color(isActive || hovered ? \.foreground : \.mutedForeground)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        close.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16)
        title.frame = NSRect(x: 24, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 24 - 8), height: 16)
    }

    override func updateLayer() {
        let fill: NSColor? = isActive ? Themed.color(\.accent) : hovered ? Themed.color(\.accent, 0.6) : nil
        layer?.backgroundColor = fill?.cgColor(in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onSelect?() }
}
