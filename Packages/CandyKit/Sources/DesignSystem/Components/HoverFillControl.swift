import AppKit

/// A clickable area behind a row's content with `transition-colors hover:bg-*`: the fill fades in
/// and out over 150 ms. For rows whose label, checkbox or text are sibling views.
public final class HoverFillControl: ControlView {
    public var fill: NSColor { didSet { needsDisplay = true } }

    public init(fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        scalesWhenPressed = false
        transitions = .colors
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    public override func updateLayer() {
        Motion.setBackground(layer, state.hovered && state.enabled ? fill.cgColor(in: self) : nil)
    }
}
