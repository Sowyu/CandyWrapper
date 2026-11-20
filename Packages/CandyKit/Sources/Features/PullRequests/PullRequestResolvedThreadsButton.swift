import AppKit
import DesignSystem
import T3Protocol

/// `InlineReviewThreads`' fold (4928 PullRequestReviewAnnotation.tsx, #34644): a line's resolved conversations hide
/// behind up to three of their authors' 16pt avatars (`-space-x-1`, `ring-1 ring-background`), drawn on the
/// commented line at the right (`absolute right-3 bottom-full`). A click shows or hides them.
public final class PullRequestResolvedThreadsButton: DSView, DiffAnnotationContent {
    private var avatars: [PullRequestAvatarView] = []
    private let rings: [CALayer]
    private var tooltip: TooltipController?
    let label: String
    let threadIds: [String]
    var expanded: Bool { didSet { setAccessibilityExpanded(expanded) } }
    var onToggle: (() -> Void)?

    init(threads: [PullRequestReviewThread], expanded: Bool) {
        var authors: [(String, PullRequestActor?)] = []
        for c in threads.flatMap(\.comments) {
            let login = c.author?.login ?? "ghost"
            if !authors.contains(where: { $0.0 == login }) { authors.append((login, c.author)) }
        }
        if authors.isEmpty { authors = [("ghost", nil)] }
        let shown = Array(authors.prefix(3))
        label = threads.count == 1 ? "Resolved conversation" : "\(threads.count) resolved conversations"
        self.expanded = expanded
        threadIds = threads.map(\.id)
        rings = shown.map { _ in CALayer() }
        super.init(frame: .zero)
        for (i, (_, actor)) in shown.enumerated() {
            rings[i].actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(rings[i])
            let a = PullRequestAvatarView()
            a.actor = actor
            addSubview(a)
            avatars.append(a)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityExpanded(expanded)
        tooltip = TooltipController.attach(to: self, text: label, placement: PopupPlacement(side: .left, align: .center, sideOffset: 4))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func height(forWidth width: CGFloat) -> CGFloat { 0 }
    public var lineOverlayWidth: CGFloat? { 16 + CGFloat(max(0, avatars.count - 1)) * 12 }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let y = (bounds.height - 16) / 2
        for (i, a) in avatars.enumerated() {
            let x = CGFloat(i) * 12
            a.frame = NSRect(x: x, y: y, width: 16, height: 16)
            rings[i].frame = CGRect(x: x - 1, y: y - 1, width: 18, height: 18)
            rings[i].cornerRadius = 9
        }
        CATransaction.commit()
    }

    public override func updateLayer() {
        for r in rings { r.backgroundColor = Themed.color(\.background).cgColor(in: self) }
    }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }
    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { onToggle?() } else { super.keyDown(with: event) }
    }
    public override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
}
