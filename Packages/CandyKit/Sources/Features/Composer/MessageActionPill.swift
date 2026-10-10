import AppKit
import DesignSystem

/// The composer's labeled primary action (`messageActionPillClassName`,
/// ComposerPrimaryActions.tsx:84): a full-round `message-action` pill with 14px medium white
/// text, `shadow-xs` at 24% of the fill, hover fill `message-action-hover`, and 64% opacity with
/// no shadow while disabled. The question footer uses it at 28px tall (`sm:h-7`), 12 or 16 padding.
final class MessageActionPill: ControlView {
    var title = "" { didSet { if title != oldValue { label.text = title; invalidateIntrinsicContentSize(); needsLayout = true } } }
    /// `px-3` compact, `px-4` otherwise.
    var compact = true { didSet { if compact != oldValue { invalidateIntrinsicContentSize(); needsLayout = true } } }
    static let height: CGFloat = 28

    private let label = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.messageActionForeground))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 20
        // Text on the composer's glass skips font smoothing, like Chromium (PROGRESS findings).
        label.smoothsFont = false
        addSubview(label)
        setAccessibilityRole(.button)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.textWidth) + 2 * (compact ? 12 : 16), height: Self.height)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let w = ceil(label.textWidth)
        label.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - 20) / 2).rounded(), width: w, height: 20)
        setAccessibilityLabel(title)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    override func updateLayer() {
        let enabled = state.enabled
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = Themed.color(state.hovered && enabled ? \.messageActionHover : \.messageAction).cgColor(in: self)
        layer?.shadowColor = Themed.color(\.messageAction).cgColor(in: self)
        layer?.shadowOpacity = enabled ? 0.24 : 0
        layer?.shadowRadius = 1
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        CATransaction.commit()
        alphaValue = enabled ? 1 : 0.64
    }

    override func resetCursorRects() { if state.enabled { addCursorRect(bounds, cursor: .pointingHand) } }
}
