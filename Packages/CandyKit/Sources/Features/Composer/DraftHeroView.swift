import AppKit
import CoreText
import DesignSystem
import T3Store

/// The new-thread headline (DraftHeroHeadline.tsx:331-385): "What should we build in {project}?"
/// at 30/36, weight 400, `tracking-tight`, centered, with the project as a picker (weight 500,
/// dotted underline in `foreground/30`, solid on hover), then "or start without a project" in
/// 14px medium `muted`, 8px below. J-composer-visuals section 9.
public final class DraftHeroView: DSView, HoverSyncPointerClient {
    /// 36 + 8 + 24.
    public static let height: CGFloat = 68

    /// The height at `width`: the headline wraps as T3's `h1` does when the column is narrower than it.
    public func height(forWidth width: CGFloat) -> CGFloat {
        if capy { return DitherPill.height }
        return isScratch ? Self.height : Self.height + CGFloat(headlineLines(width: width).count - 1) * 36
    }

    public var projectTitle = "" { didSet { if projectTitle != oldValue { updateChips(); needsDisplay = true; superview?.needsLayout = true } } }
    /// A draft in the scratch project: "What should we work on?" with the picker, "No project", on the
    /// line below (DraftHeroHeadline.tsx:244-246, 326, 366-383).
    public var isScratch = false { didSet { if isScratch != oldValue { updateChips(); needsDisplay = true; superview?.needsLayout = true } } }
    /// The project name was clicked; show the project menu under `anchor`.
    public var onPickProject: ((NSView) -> Void)?
    /// "or start without a project" was clicked: open the scratch project as this draft's project
    /// (DraftHeroHeadline.tsx:189-203, 323-346 at 4928).
    public var onStartWithoutProject: (() -> Void)?
    /// A machine offers a scratch folder (`scratchWorkspaceRoot`); without one T3 leaves the line out.
    public var offersScratch = true {
        didSet {
            guard offersScratch != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            // Redesign's starter row under the composer follows it.
            superview?.needsLayout = true
        }
    }

    let projectAnchor = NSView()
    private(set) var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    /// The "or start without a project" button's extent, empty while it is not drawn.
    private(set) var scratchLink = NSRect.zero
    private(set) var scratchHovered = false { didSet { if scratchHovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    public override var wantsUpdateLayer: Bool { false }

    /// Dither (after Capy's new-thread page): no headline, the project chip over the composer's left edge; the machine shows in the row under the composer.
    private var capy: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    private let chipIcon = ProjectMonogramView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    private let scratchIcon = IconView(name: .folder, size: 14)
    /// The project chip; `onPickProject` gets it as the anchor.
    public private(set) lazy var projectChip = DitherChipView(icon: chipIcon, accessibilityLabel: "Project")
    /// The project's icon for the chip; set after `projectTitle`.
    public var projectIcon: ProjectIconSource? { didSet { chipIcon.source = projectIcon } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        addSubview(projectAnchor)
        // The chip is always the context row's quiet control, at the row's glyph size.
        chipIcon.scale = RedesignTokens.Draft.rowGlyph / 16
        projectChip.action = { [weak self] in
            guard let self else { return }
            self.onPickProject?(self.projectChip)
        }
        projectChip.isHidden = true
        addSubview(projectChip)
        updateChips()
    }

    private func updateChips() {
        chipIcon.projectTitle = projectTitle
        projectChip.text = isScratch ? "No project" : projectTitle
        projectChip.replaceIcon(isScratch ? scratchIcon : chipIcon)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        superview?.needsLayout = true
    }

    /// Redesign: where the chips end. The machine shows in the row under the composer, so only the project chip
    /// sits here.
    public var chipsWidth: CGFloat {
        guard capy else { return 0 }
        return projectChip.intrinsicContentSize.width
    }

    public override func layout() {
        super.layout()
        projectChip.isHidden = !capy
        guard capy else { return }
        // Redesign: floating pills from the composer's left edge, `DitherPill.spacing` apart.
        let project = projectChip.intrinsicContentSize
        projectChip.frame = NSRect(x: 0, y: (bounds.height - project.height) / 2, width: project.width, height: project.height)
        window?.invalidateCursorRects(for: self)
    }

    static var sentence: NSFont { DSFont.ui(30) }
    static var projectFont: NSFont { DSFont.ui(30, weight: .medium) }
    static var subFont: NSFont { DSFont.ui(14, weight: .medium) }

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
        ctx.setShouldSmoothFonts(FontRuntime.smoothing)
        if capy { return }
        if isScratch { drawScratch(ctx); return }
        let (_, range) = pieces()
        let lines = headlineLines(width: bounds.width)
        for (i, piece) in lines.enumerated() {
            let line = piece.line
            let top = CGFloat(i) * 36
            let x = ((bounds.width - line.width) / 2).rounded()
            let baseline = line.baseline(top: top, lineHeight: 36)
            draw(line.line, at: CGPoint(x: x, y: baseline), in: ctx)
            // The project name's extent and its underline (`underline-offset-4`, `decoration-from-font`).
            guard range.location >= piece.start, range.location < piece.start + piece.length else { continue }
            let x0 = CTLineGetOffsetForStringIndex(line.line, range.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(line.line, min(range.location + range.length, piece.start + piece.length), nil)
            projectAnchor.frame = NSRect(x: x + x0, y: top, width: x1 - x0, height: 36)
            drawUnderline(ctx, font: Self.projectFont, from: x + x0, to: x + x1, baseline: baseline)
        }
        let subTop = CGFloat(lines.count - 1) * 36 + 44

        // `InlineButton tone="muted"` (button.tsx:103-113): muted, foreground and underlined 2pt below on hover.
        guard offersScratch else { scratchLink = .zero; return }
        let sub = TextLine(NSAttributedString(string: "or start without a project",
                                              attributes: [.font: Self.subFont, .foregroundColor: Themed.color(scratchHovered ? \.foreground : \.mutedForeground)]))
        let subX = ((bounds.width - sub.width) / 2).rounded(), subBaseline = sub.baseline(top: subTop, lineHeight: 24)
        draw(sub.line, at: CGPoint(x: subX, y: subBaseline), in: ctx)
        let link = NSRect(x: subX, y: subTop, width: sub.width, height: 24)
        if link != scratchLink { scratchLink = link; window?.invalidateCursorRects(for: self) }
        if scratchHovered {
            let thickness = max(1, (Self.subFont.underlineThickness * 2).rounded() / 2)
            ctx.setFillColor(Themed.color(\.foreground).cgColor(in: self))
            ctx.fill(CGRect(x: subX, y: subBaseline + 2, width: sub.width, height: thickness))
        }
    }

    /// The headline as one line when it fits, or broken at spaces as the browser wraps it, never inside the
    /// project picker (an `inline-flex` box). Each line's width leaves out its trailing space, so it centers.
    func headlineLines(width: CGFloat) -> [(line: TextLine, start: Int, length: Int)] {
        let (string, project) = pieces()
        let whole = TextLine(string)
        guard whole.width > width, width > 0 else { return [(whole, 0, string.length)] }
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var result: [(line: TextLine, start: Int, length: Int)] = []
        var start = 0
        while start < string.length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { count = string.length - start }
            let end = start + count, projectEnd = project.location + project.length
            if end > project.location, end < projectEnd {
                // The picker moves whole to the next line, or, starting this one, keeps its "?" with it.
                count = project.location > start ? project.location - start : min(string.length, projectEnd + 1) - start
            }
            let piece = string.attributedSubstring(from: NSRange(location: start, length: count))
            let trimmed = piece.string.hasSuffix(" ") ? piece.attributedSubstring(from: NSRange(location: 0, length: piece.length - 1)) : piece
            result.append((TextLine(trimmed), start, trimmed.length))
            start += count
        }
        return result
    }

    private func drawScratch(_ ctx: CGContext) {
        let fg = Themed.color(\.foreground)
        let title = TextLine(NSAttributedString(string: "What should we work on?",
                                                attributes: [.font: Self.sentence, .foregroundColor: fg, .kern: -0.025 * 30]))
        draw(title.line, at: CGPoint(x: ((bounds.width - title.width) / 2).rounded(), y: title.baseline(top: 0, lineHeight: 36)), in: ctx)
        let picker = TextLine(NSAttributedString(string: "No project", attributes: [.font: Self.subFont, .foregroundColor: fg]))
        let x = ((bounds.width - picker.width) / 2).rounded()
        let baseline = picker.baseline(top: 44, lineHeight: 24)
        draw(picker.line, at: CGPoint(x: x, y: baseline), in: ctx)
        projectAnchor.frame = NSRect(x: x, y: 44, width: picker.width, height: 24)
        drawUnderline(ctx, font: Self.subFont, from: x, to: x + picker.width, baseline: baseline)
    }

    /// The picker's underline (`underline-offset-4`): dotted `foreground/30`, solid `foreground` on hover.
    private func drawUnderline(_ ctx: CGContext, font: NSFont, from x0: CGFloat, to x1: CGFloat, baseline: CGFloat) {
        let thickness = max(1, (font.underlineThickness * 2).rounded() / 2)
        let y = baseline + 4 + thickness / 2
        ctx.setStrokeColor(Themed.color(\.foreground, hovered ? 1 : 0.3).cgColor(in: self))
        ctx.setLineWidth(thickness)
        if !hovered {
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [0, thickness * 2])
        }
        ctx.move(to: CGPoint(x: x0 + thickness / 2, y: y))
        ctx.addLine(to: CGPoint(x: x1 - (hovered ? thickness / 2 : 0), y: y))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
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

    private func overProject(_ event: NSEvent) -> Bool { overProject(convert(event.locationInWindow, from: nil)) }
    private func overProject(_ point: NSPoint) -> Bool { projectAnchor.frame.contains(point) }

    private func overScratchLink(_ event: NSEvent) -> Bool { overScratchLink(convert(event.locationInWindow, from: nil)) }
    private func overScratchLink(_ point: NSPoint) -> Bool {
        !capy && !isScratch && onStartWithoutProject != nil && scratchLink.contains(point)
    }

    /// The two links' hover inside the headline's area. HoverSync owns the area's enter and exit, and AppKit sends
    /// `mouseMoved` only to an area it considers entered, so a real window never called `mouseMoved` here; HoverSync
    /// forwards each pointer move to entered pointer clients instead (HoverSync.swift).
    func hover(at point: NSPoint) {
        hovered = !capy && overProject(point)
        scratchHovered = overScratchLink(point)
    }
    private var pointerInside = false
    public func hoverPointerMoved() {
        guard pointerInside, let window else { return }
        hover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    public override func mouseEntered(with event: NSEvent) { pointerInside = true; hover(at: convert(event.locationInWindow, from: nil)) }
    public override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    public override func mouseExited(with event: NSEvent) { pointerInside = false; hovered = false; scratchHovered = false }
    public override func mouseDown(with event: NSEvent) {
        if !capy, overProject(event) { onPickProject?(projectAnchor) }
        else if overScratchLink(event) { scratchHovered = false; onStartWithoutProject?() }
    }
    public override func resetCursorRects() {
        guard !capy else { return }
        addCursorRect(projectAnchor.frame, cursor: .pointingHand)
        if !isScratch, offersScratch, onStartWithoutProject != nil { addCursorRect(scratchLink, cursor: .pointingHand) }
    }
}

extension DraftHeroView {
    /// The searchable project picker (DraftHeroHeadline.tsx:271-356 in 2994, b744bded0): a `w-72` `ComboboxPopup`
    /// centered under the project name with "Search projects...", every project group, then "Add project", which
    /// filtering drops. `onSelect` gets a group key, or nil for "Add project". The sidebar's project scope popup is
    /// the same combobox, so both use `SidebarProjectScopeView`.
    /// `canPin` and `onTogglePin`: each row's pin button and the pin shortcut (DraftHeroHeadline.tsx:262-299 at 4928, #26154).
    public static func showProjectPicker(groups: [SidebarModel.ProjectGroup], selectedKey: String?, environments: SidebarEnvironments,
                                         from anchor: NSView, canPin: (SidebarModel.ProjectGroup) -> Bool = { _ in false },
                                         onTogglePin: (@MainActor (SidebarModel.ProjectGroup, Bool) -> Void)? = nil,
                                         onSelect: @escaping @MainActor (String?) -> Void) {
        guard let host = anchor.popupHost else { return }
        let view = SidebarProjectScopeView(groups: groups, selectedKey: selectedKey, minimumWidth: 288,
                                           environments: environments, extra: .addProject, canPin: canPin)
        view.onTogglePin = { key, pinned in
            if let group = groups.first(where: { $0.key == key }) { onTogglePin?(group, pinned) }
        }
        // Weak: the host holds the open popup, and a strong capture would make popup -> view -> onSelect -> popup a cycle.
        weak var popup: OpenPopup?
        view.onSelect = { key in
            if let popup { host.close(popup, returnFocus: false) }
            onSelect(key)
        }
        popup = host.open(PickerPopupView(view), trigger: anchor, placement: .popover, swallowsOutsideClick: true)
        anchor.window?.makeFirstResponder(view.search)
    }
}
