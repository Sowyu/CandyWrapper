import AppKit
import DesignSystem

/// Redesign: the thread's project and title at the top of an open thread, straight on the picture: the project in the muted color, a slash, then the title in the
/// text color at 500, 13pt on a 20pt line, the title truncating first.
final class DitherThreadTitleView: DSView {
    private let project = LabelView("", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private let slash = LabelView("/", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private let name = LabelView("", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    static let height: CGFloat = 20

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [project, slash, name] { l.lineHeight = Self.height; addSubview(l) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(project p: String, title t: String) {
        guard p != project.text || t != name.text else { return }
        project.text = p
        name.text = t
        setAccessibilityValue(p.isEmpty ? t : "\(p) / \(t)")
        needsLayout = true
        TitleTypingOverlay.sync(&typing, over: name, phase: titleTyping)
    }

    /// Rewrite title's typing effect on the title while it runs.
    var titleTyping: TitleTyping.Phase? {
        didSet { if titleTyping != oldValue { TitleTypingOverlay.sync(&typing, over: name, phase: titleTyping) } }
    }
    private var typing: TitleTypingOverlay?

    var isEmpty: Bool { name.text.isEmpty }
    /// How wide the drawn text runs from the left edge, project, slash and title, once laid out.
    var textWidth: CGFloat { layoutSubtreeIfNeeded(); return name.isHidden ? 0 : name.frame.maxX }

    override func layout() {
        super.layout()
        let gap = RedesignTokens.Space.xs + 2
        var x: CGFloat = 0
        let shown = !project.text.isEmpty
        project.isHidden = !shown
        slash.isHidden = !shown
        if shown {
            // The project gives way to at most a third of the room before the title truncates.
            let w = min(ceil(project.textWidth) + 1, (bounds.width / 3).rounded())
            project.frame = NSRect(x: x, y: 0, width: w, height: Self.height)
            x += w + gap
            let sw = ceil(slash.textWidth) + 1
            slash.frame = NSRect(x: x, y: 0, width: sw, height: Self.height)
            x += sw + gap
        }
        name.frame = NSRect(x: x, y: 0, width: max(0, min(ceil(name.textWidth) + 1, bounds.width - x)), height: Self.height)
        typing?.follow()
    }
}
