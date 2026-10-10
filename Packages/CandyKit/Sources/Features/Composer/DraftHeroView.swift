import AppKit
import CoreText
import DesignSystem

/// The new-thread headline (DraftHeroHeadline.tsx:331-385): "What should we build in {project}?"
/// at 30/36, weight 400, `tracking-tight`, centered, with the project as a picker (weight 500,
/// dotted underline in `foreground/30`, solid on hover), then "or start without a project" in
/// 14px medium `muted`, 8px below. J-composer-visuals section 9.
public final class DraftHeroView: DSView {
    /// 36 + 8 + 24.
    public static let height: CGFloat = 68

    public var projectTitle = "" { didSet { if projectTitle != oldValue { needsDisplay = true } } }
    /// The project name was clicked; show the project menu under `anchor`.
    public var onPickProject: ((NSView) -> Void)?

    private let projectAnchor = NSView()
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    public override var wantsUpdateLayer: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        addSubview(projectAnchor)
    }

    static let sentence = DSFont.ui(30)
    static let projectFont = DSFont.ui(30, weight: .medium)
    static let subFont = DSFont.ui(14, weight: .medium)

    private func pieces() -> (NSAttributedString, NSRange) {
        let kern = -0.025 * 30
        let fg = Themed.color(\.foreground)
        let s = NSMutableAttributedString(string: "What should we build in ", attributes: [.font: Self.sentence, .foregroundColor: fg, .kern: kern])
        let start = s.length
        s.append(NSAttributedString(string: Self.truncated(projectTitle, kern: kern), attributes: [.font: Self.projectFont, .foregroundColor: fg, .kern: kern]))
        let range = NSRange(location: start, length: s.length - start)
        s.append(NSAttributedString(string: "?", attributes: [.font: Self.sentence, .foregroundColor: fg, .kern: kern]))
        return (s, range)
    }

    /// The picker is `max-w-64` with `truncate`: a name wider than 256 ends in an ellipsis.
    static func truncated(_ title: String, kern: Double) -> String {
        func width(_ s: String) -> CGFloat {
            TextLine(NSAttributedString(string: s, attributes: [.font: projectFont, .kern: kern])).width
        }
        guard width(title) > 256 else { return title }
        var chars = Array(title)
        while !chars.isEmpty, width(String(chars) + "…") > 256 { chars.removeLast() }
        return String(chars) + "…"
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldSmoothFonts(true)
        let (string, range) = pieces()
        let line = TextLine(string)
        let x = ((bounds.width - line.width) / 2).rounded()
        let baseline = line.baseline(top: 0, lineHeight: 36)
        draw(line.line, at: CGPoint(x: x, y: baseline), in: ctx)
        // The project name's extent and its underline (`underline-offset-4`, `decoration-from-font`).
        let x0 = CTLineGetOffsetForStringIndex(line.line, range.location, nil)
        let x1 = CTLineGetOffsetForStringIndex(line.line, range.location + range.length, nil)
        projectAnchor.frame = NSRect(x: x + x0, y: 0, width: x1 - x0, height: 36)
        let thickness = max(1, (Self.projectFont.underlineThickness * 2).rounded() / 2)
        let y = baseline + 4 + thickness / 2
        ctx.setStrokeColor(Themed.color(\.foreground, hovered ? 1 : 0.3).cgColor(in: self))
        ctx.setLineWidth(thickness)
        if !hovered {
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [0, thickness * 2])
        }
        ctx.move(to: CGPoint(x: x + x0 + thickness / 2, y: y))
        ctx.addLine(to: CGPoint(x: x + x1 - (hovered ? thickness / 2 : 0), y: y))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // ponytail: "or start without a project" is drawn but inert; scratch threads come with the project picker work
        let sub = TextLine(NSAttributedString(string: "or start without a project",
                                              attributes: [.font: Self.subFont, .foregroundColor: Themed.color(\.mutedForeground)]))
        draw(sub.line, at: CGPoint(x: ((bounds.width - sub.width) / 2).rounded(), y: sub.baseline(top: 44, lineHeight: 24)), in: ctx)
    }

    private func draw(_ line: CTLine, at point: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: point.x, y: point.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func overProject(_ event: NSEvent) -> Bool {
        projectAnchor.frame.contains(convert(event.locationInWindow, from: nil))
    }

    public override func mouseMoved(with event: NSEvent) { hovered = overProject(event) }
    public override func mouseExited(with event: NSEvent) { hovered = false }
    public override func mouseDown(with event: NSEvent) {
        if overProject(event) { onPickProject?(projectAnchor) }
    }
    public override func resetCursorRects() { addCursorRect(projectAnchor.frame, cursor: .pointingHand) }
}
