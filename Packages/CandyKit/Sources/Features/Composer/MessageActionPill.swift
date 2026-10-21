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
    /// One half of the plan's Implement split (ComposerPrimaryActions.tsx:225-258): `rounded-r-none` on the
    /// label, `rounded-l-none border-l border-message-action-foreground/20 px-2` on the chevron.
    enum Half { case whole, leading, trailing }
    var half = Half.whole { didSet { if half != oldValue { invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true } } }
    /// `px-4` regardless of `compact` (the Implement half).
    var widePadding = false { didSet { if widePadding != oldValue { invalidateIntrinsicContentSize() } } }

    private let label = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.messageActionForeground))
    private lazy var chevron = IconView(name: .chevronDown, size: 14, strokeColor: Themed.color(\.messageActionForeground))
    /// The fill, `shadow-xs` and, on the chevron half, the divider; halves square their inner corners.
    private lazy var decoration: BoxDecorationLayer = {
        let d = BoxDecorationLayer()
        d.host = self
        layer?.insertSublayer(d, at: 0)
        return d
    }()

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
        if half == .trailing { return NSSize(width: 14 + 2 * 8, height: Self.height) }
        return NSSize(width: ceil(label.textWidth) + 2 * (compact && !widePadding ? 12 : 16), height: Self.height)
    }

    override func layout() {
        super.layout()
        restyle()
        if half == .trailing {
            if chevron.superview == nil { addSubview(chevron) }
            label.isHidden = true
            chevron.isHidden = false
            chevron.frame = NSRect(x: ((bounds.width - 14) / 2).rounded(), y: ((bounds.height - 14) / 2).rounded(), width: 14, height: 14)
            return
        }
        label.isHidden = false
        let w = ceil(label.textWidth)
        label.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - 20) / 2).rounded(), width: w, height: 20)
        setAccessibilityLabel(title)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
        restyle()
    }

    private var fill: NSColor { Themed.color(state.hovered && state.enabled ? \.messageActionHover : \.messageAction) }

    private func restyle() {
        var box = BoxStyle()
        // Dither: Capy's rounded square, like its send button.
        box.radius = ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? DitherChrome.controlRadius : bounds.height / 2
        box.corners = switch half { case .whole: .all; case .leading: .leading; case .trailing: .trailing }
        box.fill = fill
        // `shadow-xs shadow-message-action/24`.
        if state.enabled { box.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.color(\.messageAction, 0.24))] }
        if half == .trailing {
            box.border = Themed.color(\.messageActionForeground, 0.2)
            box.borderEdges = .init(left: 1)
            box.backgroundClip = .border
        }
        decoration.boxStyle = box
        decoration.layout(boxSize: bounds.size)
    }

    override func updateLayer() {
        restyle()
        alphaValue = state.enabled ? 1 : 0.64
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }

    override func resetCursorRects() { if state.enabled { addCursorRect(bounds, cursor: .pointingHand) } }
}
