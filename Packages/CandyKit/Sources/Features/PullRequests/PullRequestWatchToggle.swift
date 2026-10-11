import AppKit
import DesignSystem

/// The eye on a watched pull request's details row (ThreadDetailsPrRow.tsx:347-382): an eye that turns
/// into eye-off on hover, "Watching: the agent wakes when checks finish, someone comments, or the
/// branch conflicts. Click to stop." A click stops the watch.
// ponytail: sits in the row's trailing slot without T3's split separator and 32pt cell; give
// DetailsRowControl a secondary part if the split look matters
public final class PullRequestWatchToggle: ControlView {
    private let eye = IconView(name: .eye, size: 16)
    private let eyeOff = IconView(name: .eyeOff, size: 16)

    public init(number: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        scalesWhenPressed = false
        addSubview(eye)
        addSubview(eyeOff)
        setAccessibilityLabel("Stop watching #\(number)")
        _ = TooltipController.attach(to: self, text: "Watching: the agent wakes when checks finish, someone comments, or the branch conflicts. Click to stop.",
                                     placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    public override func layout() {
        super.layout()
        eye.frame = bounds
        eyeOff.frame = bounds
    }

    public override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        eye.isHidden = state.hovered
        eyeOff.isHidden = !state.hovered
        let color = state.hovered ? Themed.color(\.contrastForeground, 0.8) : Themed.color(\.contrastMutedForeground)
        eye.strokeColor = color
        eyeOff.strokeColor = color
    }
}
