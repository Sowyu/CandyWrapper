import AppKit
import DesignSystem

/// Redesign: the thread's project and title as a pill at the left end of the header row (the user, 2026-11-22: "turn
/// this into a pill like the other crap then put it at the very left"). The header pill's twin: as tall as the tabs,
/// its corner, its surface (`DitherPillSurface`, frosted over the Flower like the rest), and 10pt in, which is the
/// header pill's 2pt inset plus the cost's 8pt padding. The project is muted, then a slash, then the title in the text
/// color at 500, 13pt on a 20pt line. It hugs its text. Short of room the title truncates in its middle while it keeps
/// `minTitle`, then the project drops and the title truncates alone. The full text is the tooltip when cut short.
/// Clicks pass through, so the band under it still drags the window as the bare breadcrumb did.
final class DitherThreadTitleView: DSView, DitherStripLeading {
    private let frost = DitherPillSurface()
    let project = LabelView("", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private let slash = LabelView("/", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    let name = LabelView("", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    static let height: CGFloat = DitherTabStripView.tabHeight
    static let lineHeight: CGFloat = 20
    static let padX: CGFloat = 10
    static let gap: CGFloat = RedesignTokens.Space.xs + 2
    /// The least of the title kept beside the project before the project drops.
    static let minTitle: CGFloat = 96

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        frost.radius = RedesignTokens.Radius.control
        addSubview(frost)
        name.truncation = .middle
        for l in [project, slash, name] { l.lineHeight = Self.lineHeight; addSubview(l) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setLiveTooltip { [weak self] in self?.cutShort == true ? self?.fullText : nil }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(project p: String, title t: String) {
        guard p != project.text || t != name.text else { return }
        project.text = p
        name.text = t
        setAccessibilityValue(fullText)
        resized()
        TitleTypingOverlay.sync(&typing, over: name, phase: titleTyping)
        typing?.onTextWidth = { [weak self] in self?.typingWidth = $0 }
    }

    private var fullText: String { project.text.isEmpty ? name.text : "\(project.text) / \(name.text)" }

    /// Rewrite title's typing effect on the title while it runs.
    var titleTyping: TitleTyping.Phase? {
        didSet {
            guard titleTyping != oldValue else { return }
            TitleTypingOverlay.sync(&typing, over: name, phase: titleTyping)
            typing?.onTextWidth = { [weak self] in self?.typingWidth = $0 }
        }
    }
    private var typing: TitleTypingOverlay?
    /// The typed text's width while the effect runs, which the pill hugs instead of the title's.
    private var typingWidth: CGFloat? { didSet { if typingWidth != oldValue { resized() } } }

    var isEmpty: Bool { name.text.isEmpty }

    private func resized() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    /// What shows in `width`: whether the project does, and the title's width.
    private func plan(_ width: CGFloat) -> (project: Bool, title: CGFloat, width: CGFloat) {
        let title = typingWidth ?? ceil(name.textWidth) + 1
        let crumb = project.text.isEmpty ? 0 : ceil(project.textWidth) + 1 + Self.gap + ceil(slash.textWidth) + 1 + Self.gap
        let room = max(0, width - 2 * Self.padX)
        let shown: (Bool, CGFloat)
        if crumb + title <= room { shown = (crumb > 0, title) }
        else if crumb > 0, room - crumb >= min(title, Self.minTitle) { shown = (true, room - crumb) }
        else { shown = (false, min(title, room)) }
        return (shown.0, shown.1, 2 * Self.padX + (shown.0 ? crumb : 0) + shown.1)
    }

    func fittingWidth(max width: CGFloat) -> CGFloat { plan(width).width }
    override var intrinsicContentSize: NSSize { NSSize(width: plan(.greatestFiniteMagnitude).width, height: Self.height) }

    /// Whether the pill shows less than the whole breadcrumb.
    private var cutShort: Bool { project.isHidden && !project.text.isEmpty || name.isTruncated }

    override func layout() {
        super.layout()
        frost.frame = bounds
        let p = plan(bounds.width)
        let y = ((bounds.height - Self.lineHeight) / 2).rounded()
        var x = Self.padX
        project.isHidden = !p.project
        slash.isHidden = !p.project
        if p.project {
            let w = ceil(project.textWidth) + 1
            project.frame = NSRect(x: x, y: y, width: w, height: Self.lineHeight)
            x += w + Self.gap
            let sw = ceil(slash.textWidth) + 1
            slash.frame = NSRect(x: x, y: y, width: sw, height: Self.lineHeight)
            x += sw + Self.gap
        }
        name.frame = NSRect(x: x, y: y, width: max(0, p.title), height: Self.lineHeight)
        typing?.follow()
    }
}
