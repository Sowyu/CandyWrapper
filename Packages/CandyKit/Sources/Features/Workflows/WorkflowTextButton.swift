import AppKit
import DesignSystem

/// A plain `<button>` of muted `text-xs` that turns `hover:text-foreground`: "Add a reason" and "Ask the agent first"
/// (WorkflowRunFeed.tsx:1998-2018), "Part of {title}" with `underline underline-offset-2` (:470-478) and "Show more".
final class WorkflowTextButton: ControlView {
    let label = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    var underlined = false { didSet { restyle() } }
    var title: String {
        get { label.text }
        set { label.text = newValue; setAccessibilityLabel(newValue); needsLayout = true }
    }

    init(_ title: String) {
        super.init(frame: .zero)
        scalesWhenPressed = false
        label.lineHeight = 16
        addSubview(label)
        setAccessibilityRole(.button)
        self.title = title
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat { ceil(label.textWidth) + 1 }
    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 16) }

    override func layout() { super.layout(); label.frame = bounds }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        label.color = state.hovered && state.enabled ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        label.isUnderlined = underlined
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// Muted `text-xs` words in a `flex items-center gap-x-1.5` row, each part its own span, so the "·" between them
/// sits 6pt from either side (WorkflowRunFeed.tsx:487-520).
// ponytail: one line, clipped; T3 wraps (`flex-wrap`), add it when a meta line overflows a real feed.
final class WorkflowWordsRow: DSView {
    private var labels: [LabelView] = []
    var parts: [String] = [] {
        didSet {
            guard parts != oldValue else { return }
            labels.forEach { $0.removeFromSuperview() }
            labels = parts.map {
                let l = LabelView($0, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
                l.lineHeight = 16
                addSubview(l)
                return l
            }
            setAccessibilityLabel(parts.filter { $0 != "·" }.joined(separator: ", "))
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for l in labels {
            let w = ceil(l.textWidth) + 1
            l.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: max(0, min(w, bounds.width - x)), height: 16)
            x += l.textWidth + 6
        }
    }
}
