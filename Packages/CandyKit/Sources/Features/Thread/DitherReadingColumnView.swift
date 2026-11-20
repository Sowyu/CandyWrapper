import AppKit
import DesignSystem

/// Redesign's reading column: one resting glass surface behind the thread's lane, so assistant text, tool rows, command
/// output, code and tables read over any picture while the picture shows on both sides (docs/research/redesign-system.md,
/// "Reading column"). One blur for the whole column replaces a blur per user bubble.
///
/// The rows fade out over the column's top (the thread panel's timeline mask), so no message reads under the header
/// pill and no header bar shows (the user removed header bars in every theme, 324b6bcf). The thread's project and
/// title sit in that clear top.
final class DitherReadingColumnView: DSView {
    let title = DitherThreadTitleView()
    private let surface = DitherPillSurface()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.radius = RedesignTokens.Radius.panel
        addSubview(surface)
        addSubview(title)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        surface.frame = bounds
    }

    override func accessibilityChildren() -> [Any]? { title.isHidden ? [] : [title] }
}

/// The thread's project and title at the top of the reading column: the project in the muted color, a slash, then the title in the
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
    }

    var isEmpty: Bool { name.text.isEmpty }

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
    }
}
