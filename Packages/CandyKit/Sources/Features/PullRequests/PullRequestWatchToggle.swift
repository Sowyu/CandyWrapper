import AppKit
import DesignSystem

/// The eye on a watched pull request's details row (ThreadDetailsPrRow.tsx:347-382): an eye that turns
/// into eye-off on hover, "Watching: the agent wakes when checks finish, someone comments, or the
/// branch conflicts. Click to stop." A click stops the watch. It is the split group's secondary part
/// (`THREAD_DETAILS_PANEL_SPLIT_SECONDARY_CLASS`): it fills on hover with the trailing corners rounded, and
/// the eye keeps the control's `text-foreground/80`.
public final class PullRequestWatchToggle: ControlView {
    private let eye = IconView(name: .eye, size: 16)
    private let eyeOff = IconView(name: .eyeOff, size: 16)
    private let fill = BoxDecorationLayer()

    public init(number: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        scalesWhenPressed = false
        fill.host = self
        layer?.addSublayer(fill)
        addSubview(eye)
        addSubview(eyeOff)
        setAccessibilityLabel("Stop watching #\(number)")
        _ = TooltipController.attach(to: self, text: "Watching: the agent wakes when checks finish, someone comments, or the branch conflicts. Click to stop.",
                                     placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }

    public override func layout() {
        super.layout()
        eye.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        eyeOff.frame = eye.frame
        fill.layout(boxSize: bounds.size)
    }

    public override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        eye.isHidden = state.hovered
        eyeOff.isHidden = !state.hovered
        eye.strokeColor = Themed.color(\.contrastForeground, 0.8)
        eyeOff.strokeColor = Themed.color(\.contrastForeground, 0.8)
        var box = BoxStyle()
        box.radius = 10
        box.corners = .trailing
        box.fill = state.hoverOrPressed ? detailsHoverFill() : nil
        fill.boxStyle = box
        superview?.needsDisplay = true // the group's primary fill follows the mouse
    }
}
