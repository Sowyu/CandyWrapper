import AppKit
import DesignSystem

/// Redesign, on a delegated task thread: "Back to <parent>" at the left of the pill row above the composer, so the
/// way back stays in reach while the timeline scrolls. The header link over the timeline opens the same parent.
public final class DitherParentPillView: ControlView {
    public private(set) var parentTitle = ""
    private let surface = DitherPillSurface()
    private let hoverFill = DSView()
    private let icon = IconView(name: .arrowUpLeft, size: 14, strokeColor: Themed.color(\.contrastSecondaryLabel))
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.contrastSecondaryLabel))
    private var tooltip: TooltipController?

    static let padding: CGFloat = 10, gap: CGFloat = 6, maxLabel: CGFloat = 180

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        layer?.masksToBounds = false
        addSubview(surface)
        hoverFill.layer?.cornerRadius = DitherPill.radius
        hoverFill.isHidden = true
        addSubview(hoverFill)
        addSubview(icon)
        label.lineHeight = 16
        label.truncation = .end
        addSubview(label)
        setAccessibilityRole(.button)
        tooltip = TooltipController.attach(to: self, text: "", placement: PopupPlacement(side: .top, align: .start, sideOffset: 4))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func configure(parentTitle: String) {
        guard parentTitle != self.parentTitle else { return }
        self.parentTitle = parentTitle
        label.text = "Back to " + parentTitle
        tooltip?.text = "Back to " + parentTitle
        setAccessibilityLabel("Back to parent thread: " + parentTitle)
        needsLayout = true
        superview?.needsLayout = true
    }

    /// The label stops at `maxLabel` and ends in an ellipsis.
    public var preferredWidth: CGFloat {
        ceil(2 * Self.padding + 14 + Self.gap + min(Self.maxLabel, label.textWidth))
    }

    public override func layout() {
        super.layout()
        surface.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverFill.frame = bounds
        hoverFill.layer?.backgroundColor = Themed.color(\.foreground, 0.07).cgColor(in: self)
        CATransaction.commit()
        icon.frame = NSRect(x: Self.padding, y: ((bounds.height - 14) / 2).rounded(), width: 14, height: 14)
        let lx = Self.padding + 14 + Self.gap
        label.frame = NSRect(x: lx, y: ((bounds.height - 16) / 2).rounded(), width: max(0, bounds.width - lx - Self.padding), height: 16)
    }

    public override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = nil
        let color = state.hoverOrPressed ? Themed.color(\.contrastForeground) : Themed.color(\.contrastSecondaryLabel)
        label.color = color
        icon.strokeColor = color
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
        hoverFill.isHidden = !state.hoverOrPressed
    }
}
