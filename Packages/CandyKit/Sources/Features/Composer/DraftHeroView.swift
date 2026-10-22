import AppKit
import CoreText
import DesignSystem
import T3Store

/// The new-thread headline (DraftHeroHeadline.tsx:331-385): "What should we build in {project}?"
/// at 30/36, weight 400, `tracking-tight`, centered, with the project as a picker (weight 500,
/// dotted underline in `foreground/30`, solid on hover), then "or start without a project" in
/// 14px medium `muted`, 8px below. J-composer-visuals section 9.
public final class DraftHeroView: DSView {
    /// 36 + 8 + 24.
    public static let height: CGFloat = 68

    /// The height at `width`: the headline wraps as T3's `h1` does when the column is narrower than it.
    public func height(forWidth width: CGFloat) -> CGFloat {
        if capy { return 28 }
        return isScratch ? Self.height : Self.height + CGFloat(headlineLines(width: width).count - 1) * 36
    }

    public var projectTitle = "" { didSet { if projectTitle != oldValue { updateChips(); needsDisplay = true; superview?.needsLayout = true } } }
    /// A draft in the scratch project: "What should we work on?" with the picker, "No project", on the
    /// line below (DraftHeroHeadline.tsx:244-246, 326, 366-383).
    public var isScratch = false { didSet { if isScratch != oldValue { updateChips(); needsDisplay = true; superview?.needsLayout = true } } }
    /// The project name was clicked; show the project menu under `anchor`.
    public var onPickProject: ((NSView) -> Void)?

    private let projectAnchor = NSView()
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    public override var wantsUpdateLayer: Bool { false }

    /// Dither (after Capy's new-thread page): no headline, the project and machine chips over the composer's left edge.
    private var capy: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    private let chipIcon = ProjectMonogramView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    private let scratchIcon = IconView(name: .folder, size: 14)
    /// The project chip; `onPickProject` gets it as the anchor.
    public private(set) lazy var projectChip = DitherChipView(icon: chipIcon, accessibilityLabel: "Project")
    /// The machine chip (`RunOnControl`'s machine); `onPickMachine` gets it as the anchor.
    public private(set) lazy var machineChip = DitherChipView(icon: IconView(name: .laptop, size: 14), accessibilityLabel: "Run on")
    /// The project's icon for the chip; set after `projectTitle`.
    public var projectIcon: ProjectIconSource? { didSet { chipIcon.source = projectIcon } }
    /// The machine chip was clicked; open the machine list under `anchor`.
    public var onPickMachine: ((NSView) -> Void)?

    /// The current machine for the Dither machine chip, nil to hide it. `interactive` with a choice of machines.
    public func setMachine(label: String?, kind: String, online: Bool, interactive: Bool) {
        machineChip.isHidden = label == nil || !capy
        machineChip.text = label ?? ""
        machineChip.online = online
        machineChip.interactive = interactive
        if machineKind != kind {
            machineKind = kind
            machineChip.replaceIcon(IconView(definition: EnvironmentMachineIcon.definition(kind), size: 14))
        }
        machineLabel = label
        needsLayout = true
    }
    private var machineKind = "laptop"
    private var machineLabel: String?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        addSubview(projectAnchor)
        chipIcon.scale = 14 / 16
        projectChip.action = { [weak self] in
            guard let self else { return }
            self.onPickProject?(self.projectChip)
        }
        machineChip.muted = true
        machineChip.action = { [weak self] in
            guard let self else { return }
            self.onPickMachine?(self.machineChip)
        }
        for chip in [projectChip, machineChip] { chip.isHidden = true; addSubview(chip) }
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

    public override func layout() {
        super.layout()
        projectChip.isHidden = !capy
        machineChip.isHidden = !capy || machineLabel == nil
        guard capy else { return }
        // Capy: the chips start 12 in from the composer's edge, 4 apart (`gap-1`).
        let project = projectChip.intrinsicContentSize
        projectChip.frame = NSRect(x: 12, y: (bounds.height - project.height) / 2, width: project.width, height: project.height)
        let machine = machineChip.intrinsicContentSize
        machineChip.frame = NSRect(x: projectChip.frame.maxX + 4, y: (bounds.height - machine.height) / 2,
                                   width: min(machine.width, max(0, bounds.width - projectChip.frame.maxX - 4)), height: machine.height)
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

        // ponytail: "or start without a project" is drawn but inert; scratch threads come with the project picker work
        let sub = TextLine(NSAttributedString(string: "or start without a project",
                                              attributes: [.font: Self.subFont, .foregroundColor: Themed.color(\.mutedForeground)]))
        draw(sub.line, at: CGPoint(x: ((bounds.width - sub.width) / 2).rounded(), y: sub.baseline(top: subTop, lineHeight: 24)), in: ctx)
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

    private func overProject(_ event: NSEvent) -> Bool {
        projectAnchor.frame.contains(convert(event.locationInWindow, from: nil))
    }

    public override func mouseMoved(with event: NSEvent) { hovered = !capy && overProject(event) }
    public override func mouseExited(with event: NSEvent) { hovered = false }
    public override func mouseDown(with event: NSEvent) {
        if !capy, overProject(event) { onPickProject?(projectAnchor) }
    }
    public override func resetCursorRects() { if !capy { addCursorRect(projectAnchor.frame, cursor: .pointingHand) } }
}

extension DraftHeroView {
    /// The searchable project picker (DraftHeroHeadline.tsx:271-356 in 2994, b744bded0): a `w-72` `ComboboxPopup`
    /// centered under the project name with "Search projects...", every project group, then "Add project", which
    /// filtering drops. `onSelect` gets a group key, or nil for "Add project". The sidebar's project scope popup is
    /// the same combobox, so both use `SidebarProjectScopeView`.
    public static func showProjectPicker(groups: [SidebarModel.ProjectGroup], selectedKey: String?, environments: SidebarEnvironments,
                                         from anchor: NSView, onSelect: @escaping @MainActor (String?) -> Void) {
        guard let host = anchor.popupHost else { return }
        let view = SidebarProjectScopeView(groups: groups, selectedKey: selectedKey, minimumWidth: 288,
                                           environments: environments, extra: .addProject)
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
