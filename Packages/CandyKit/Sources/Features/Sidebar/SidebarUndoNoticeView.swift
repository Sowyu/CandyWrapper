import AppKit
import DesignSystem

/// `SidebarThreadUndoNotice` (T3 4928 components/sidebar/SidebarThreadUndoNotice.tsx:25-62): "Settled," and an
/// `InlineButton` reading "⌘Z to undo" (`font-medium text-foreground`, underline on hover).
///
/// In a footer with utility buttons it fills the free space of that row (`flex-1`, SidebarChrome.tsx:310), so it
/// never covers the list. It lays out from the right (`flex-row-reverse flex-wrap`): a summary that doesn't fit
/// beside the button disappears, and a button narrower than its label shows only the undo icon.
/// Redesign's account footer keeps the notice in its own row above the footer, inside the old alert surface.
final class SidebarUndoNoticeView: DSView {
    private let surface = AlertView(nil, variant: .sidebar)
    private let label = LabelView()
    let button = UndoLinkButton()
    /// True when the notice sits in the footer's utility row.
    var inFooterRow = true { didSet { if inFooterRow != oldValue { needsLayout = true } } }
    var onUndo: (@MainActor () -> Void)? { didSet { button.action = onUndo } }
    var text = "" { didSet { label.text = text; setAccessibilityLabel(text); needsLayout = true } }
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

    /// The footer row's notice is `h-6`; the stacked one is `px-2 py-1.5` inside a 1px border in Redesign.
    func height(forWidth width: CGFloat) -> CGFloat { !inFooterRow && DesignGeometry.usesClassic(self) ? 30 : 24 }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let classic = DesignGeometry.usesClassic(self)
        surface.isHidden = inFooterRow || !classic
        let y = (bounds.height - 16) / 2
        let lw = ceil(label.textWidth)
        if inFooterRow {
            let bw = button.preferredWidth
            let fits = bounds.width >= bw
            button.showsIcon = !fits
            button.frame = NSRect(x: max(0, bounds.width - bw), y: y, width: min(bw, bounds.width), height: 16)
            // `gap-x-1`; a summary that doesn't fit wraps to the hidden second line.
            let tx = button.frame.minX - 4 - lw
            label.isHidden = !fits || tx < 0
            label.frame = NSRect(x: max(0, tx), y: y, width: lw + 1, height: 16)
            return
        }
        button.showsIcon = false
        label.isHidden = false
        let x: CGFloat = classic ? 9 : 8
        label.frame = NSRect(x: x, y: y, width: min(lw + 1, bounds.width - 2 * x), height: 16)
        // The space between the sentence and the button.
        let space = classic ? ceil(NSAttributedString(string: " ", attributes: [.font: label.font]).size().width) : 4
        let bx = x + lw + space
        button.frame = NSRect(x: bx, y: y, width: max(0, min(button.preferredWidth, bounds.width - x - bx)), height: 16)
    }
}

/// The notice's inline button.
final class UndoLinkButton: ControlView {
    let label = LabelView("Undo", font: DSFont.ui(11, weight: .medium))
    /// `Undo2Icon` (`h-6 w-4`, right-aligned) replaces a label that no longer fits; hidden at 16 points or less.
    private let icon = IconView(name: .undo2, size: 16)
    var showsIcon = false { didSet { if showsIcon != oldValue { needsLayout = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 16
        addSubview(label)
        addSubview(icon)
        icon.isHidden = true
        restyle()
    }

    var preferredWidth: CGFloat { ceil(label.textWidth) + 1 }

    override func layout() {
        super.layout()
        label.frame = bounds
        label.isHidden = showsIcon
        icon.isHidden = !showsIcon || bounds.width <= 16
        icon.frame = NSRect(x: bounds.width - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override var acceptsFirstResponder: Bool { false }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func updateLayer() { restyle() }

    private func restyle() {
        label.color = Themed.color(\.foreground, sidebar: true)
        icon.strokeColor = label.color
        label.isUnderlined = state.hovered
        setAccessibilityLabel(label.text)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
