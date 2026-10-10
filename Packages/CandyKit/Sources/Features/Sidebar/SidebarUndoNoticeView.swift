import AppKit
import DesignSystem

/// `SidebarThreadUndoNotice` (apps/web/src/components/sidebar/SidebarThreadUndoNotice.tsx): a sidebar
/// Alert reading "Settled 1 thread, ⌘Z to undo", where the second part is an `InlineButton`
/// (`font-medium text-foreground`, underline on hover).
final class SidebarUndoNoticeView: DSView {
    private let surface = AlertView(nil, variant: .sidebar)
    private let label = LabelView()
    let button = UndoLinkButton()
    var onUndo: (@MainActor () -> Void)? { didSet { button.action = onUndo } }
    var text = "" { didSet { label.text = text; needsLayout = true } }
    var shortcut: String? { didSet { button.label.text = shortcut.map { "\($0) to undo" } ?? "Undo"; needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(surface)
        addSubview(label)
        addSubview(button)
        label.font = DSFont.ui(11)
        label.lineHeight = 16
        label.color = Themed.color(\.contrastSidebarMutedForeground)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("status")
    }

    /// `px-2 py-1.5` inside a 1px border, one 16px line.
    func height(forWidth width: CGFloat) -> CGFloat { 16 + 2 * (6 + 1) }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let x: CGFloat = 9, y = (bounds.height - 16) / 2
        let lw = ceil(label.textWidth)
        label.frame = NSRect(x: x, y: y, width: min(lw + 1, bounds.width - 2 * x), height: 16)
        // The space between the sentence and the button.
        let space = ceil(NSAttributedString(string: " ", attributes: [.font: label.font]).size().width)
        let bx = x + lw + space
        button.frame = NSRect(x: bx, y: y, width: max(0, min(button.preferredWidth, bounds.width - x - bx)), height: 16)
    }
}

/// The notice's inline button.
final class UndoLinkButton: ControlView {
    let label = LabelView("Undo", font: DSFont.ui(11, weight: .medium))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 16
        addSubview(label)
        restyle()
    }

    var preferredWidth: CGFloat { ceil(label.textWidth) + 1 }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    override var acceptsFirstResponder: Bool { false }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func updateLayer() { restyle() }

    private func restyle() {
        label.color = Themed.color(\.foreground, sidebar: true)
        label.isUnderlined = state.hovered
        setAccessibilityLabel(label.text)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
