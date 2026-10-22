import AppKit
import CoreText
import DesignSystem
import T3Protocol
import T3Store

/// Sidebar colors. Everything here lives under `[data-app-sidebar]`, so it reads the sidebar palette.
@MainActor
enum SB {
    static func c(_ key: KeyPath<Palette, TokenColor>, _ alpha: Double = 1) -> NSColor { Themed.color(key, alpha, sidebar: true) }

    /// A Tailwind base color such as `indigo-600`, per theme.
    static func base(_ light: String, _ dark: String, _ alpha: CGFloat = 1) -> NSColor {
        let l = p3(Tokens.baseColors[light]), d = p3(Tokens.baseColors[dark])
        return NSColor(name: nil) { ($0.isDark ? d : l).withAlphaComponent(alpha) }
    }

    static func p3(_ t: TokenColor?) -> NSColor {
        guard let t else { return .gray }
        return NSColor(displayP3Red: t.displayP3.x, green: t.displayP3.y, blue: t.displayP3.z, alpha: t.displayP3.w)
    }

    /// `topStatus.className` (Sidebar.tsx:1293-1346).
    static func status(_ s: SidebarTopStatus) -> NSColor {
        switch s {
        case .working: c(\.info)
        case .waiting: c(\.mutedForeground)
        case .approval: c(\.warningForeground)
        case .input: base("indigo-600", "indigo-300")
        case .limited, .woke: c(\.warning)
        case .failed: c(\.error)
        case .done: c(\.success)
        }
    }

    static func statusIcon(_ s: SidebarTopStatus) -> IconName? {
        switch s {
        case .working: .circleDashed
        case .input: .messageCircleQuestion
        case .approval: .shieldQuestion
        case .failed, .limited: .circleAlert
        case .done: .circleCheck
        case .woke: .alarmClock
        case .waiting: .circleDotDashed
        }
    }

    static func font(_ px: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { DSFont.ui(px, weight: weight) }

    /// `tabular-nums`, for time and duration labels.
    static func tabular(_ px: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        DSFont.cached("tabular", px, weight) { makeTabular(px, weight) }
    }

    private static func makeTabular(_ px: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let f = DSFont.ui(px, weight: weight)
        let d = f.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: d, size: px) ?? f
    }
}

/// `ProjectFavicon` (ProjectFavicon.tsx): the project's chosen icon, else the icon file the server finds
/// in the project (`ProjectIconStore`), else `ProjectMonogram` (ProjectMonogram.tsx) with the generated
/// identity from projectIdentity.ts: a 16px tile, 25% radius, the color at 14% behind 8.25px bold
/// monospace text squeezed to 6 or 12 units. The monogram also shows while the icon loads.
public final class ProjectMonogramView: DSView {
    var projectTitle = "" { didSet { if projectTitle != oldValue { updateIdentity() } } }
    /// The whole project, for its chosen icon and its icon file. Without it only the title's monogram shows.
    public var source: ProjectIconSource? {
        didSet {
            guard source != oldValue else { return }
            if let source { projectTitle = source.title }
            updateIdentity()
        }
    }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    /// Draws the 16px favicon at another size (`size-3` in the hover card is 0.75).
    public var scale: CGFloat = 1 { didSet { if scale != oldValue { needsDisplay = true } } }
    private var identity = (monogram: "PR", color: "blue")
    private var observing = false

    /// A `size`-point favicon for `source` (`ProjectFavicon` with `size-3.5` is 14, `size-4` 16).
    public convenience init(_ source: ProjectIconSource, size: CGFloat = 16) {
        self.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        // Observers do not run inside an initializer, so this sets up what they would.
        self.source = source
        projectTitle = source.title
        scale = size / 16
        updateIdentity()
    }

    public override var wantsUpdateLayer: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateIdentity() {
        identity = source.map(Self.identity) ?? Self.identity(projectTitle)
        if source != nil, !observing {
            observing = true
            NotificationCenter.default.addObserver(self, selector: #selector(iconsChanged), name: ProjectIconStore.didChange, object: nil)
        }
        needsDisplay = true
    }

    @objc private func iconsChanged() { needsDisplay = true }

    static let colors = ["gray", "red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal", "cyan",
                         "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose"]

    static func identity(_ name: String) -> (monogram: String, color: String) {
        let normalized = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalized.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        var monogram = "PR"
        if let first = words.first {
            let glyphs = first.map(String.init)
            let head = glyphs[0]
            let second = glyphs.dropFirst().first { $0.first?.isNumber == true }
                ?? (words.count > 1 ? words.last!.first.map(String.init) : glyphs.last) ?? head
            monogram = String((head + second).uppercased().prefix(2))
        }
        let seed = normalized.lowercased().isEmpty ? "project" : normalized.lowercased()
        var index = 0
        for scalar in seed.unicodeScalars { index = (index * 31 + Int(scalar.value)) % colors.count }
        return (monogram, colors[index])
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if scale != 1 { ctx.scaleBy(x: scale, y: scale) }
        Self.draw(source, identity: identity, dimmed: dimmed, ctx: ctx)
    }

    /// The 16px favicon in a flipped context at the origin, in the current drawing appearance. The
    /// monogram shows until `ProjectIconStore` has the icon file, which posts `didChange` once it does.
    static func draw(_ source: ProjectIconSource?, identity: (monogram: String, color: String), dimmed: Bool = false, ctx: CGContext) {
        let tileRect = CGRect(x: 0, y: 0, width: 16, height: 16)
        switch source?.override {
        case .emoji(let emoji)?:
            // `text-[length:80cqh]` in the 14px box: the emoji at 80% of the box height, centered.
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 16 * 0.8)]))
            let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: 8 - b.midX, y: 8 + b.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            return
        case .lucide(let name, let color)?:
            let icon = IconName.allCases.first { $0.lucideName == name } ?? .folderCode
            drawIcon(icon.definition, in: tileRect, color: SB.base("\(color)-600", "\(color)-400").cgColor, ctx: ctx)
            return
        default: break
        }
        if let source, let image = ProjectIconStore.shared.image(for: source, grayscale: dimmed) {
            // `size-4 rounded-[25%] object-contain`; the store already centered the image in its square.
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: tileRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: 16)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: tileRect)
            ctx.restoreGState()
            return
        }
        var color = SB.base("\(identity.color)-600", "\(identity.color)-400").cgColor
        if dimmed, let gray = color.converted(to: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, intent: .defaultIntent, options: nil) {
            color = gray // `grayscale` on settled favicons
        }
        let tile = CGRect(x: 0, y: 0, width: 16, height: 16)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.setFillColor(color.copy(alpha: color.alpha * 0.14)!)
        ctx.fillPath()
        let font = DSFont.mono(8.25, weight: .bold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: identity.monogram, attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: color) ?? .gray]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let target: CGFloat = identity.monogram.count == 1 ? 6 : 12 // `textLength` with spacingAndGlyphs
        ctx.saveGState()
        ctx.setShouldSmoothFonts(FontRuntime.smoothing)
        ctx.textMatrix = .identity
        ctx.translateBy(x: 8 - target / 2, y: 10.8)
        ctx.scaleBy(x: width > 0 ? target / width : 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// The identity a source draws: its chosen monogram, else the one generated from its title.
    static func identity(_ source: ProjectIconSource) -> (monogram: String, color: String) {
        if case .monogram(let text, let color)? = source.override { return (text, color) }
        return identity(source.title)
    }

    /// A lucide icon stroked into `rect` (`size-full` in the 14px box).
    private static func drawIcon(_ definition: IconDefinition, in rect: CGRect, color: CGColor, ctx: CGContext) {
        let scale = rect.width / definition.viewBox.width
        ctx.saveGState()
        ctx.translateBy(x: rect.minX - definition.viewBox.x * scale, y: rect.minY - definition.viewBox.y * scale)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for element in definition.elements {
            guard let path = try? element.cgPath() else { continue }
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

/// A small text-xs icon button that appears on row hover: `text-muted-foreground hover:text-foreground`.
final class RowActionButton: ControlView {
    let icon: IconView
    let label: LabelView?
    let iconSize: CGFloat
    var padding: CGFloat = 6

    init(icon name: IconName, size: CGFloat, title: String? = nil, accessibility: String) {
        icon = IconView(name: name, size: size)
        iconSize = size
        label = title.map { LabelView($0, font: SB.font(12)) }
        super.init(frame: .zero)
        scalesWhenPressed = false
        addSubview(icon)
        if let label { label.lineHeight = 16; addSubview(label) }
        setAccessibilityLabel(accessibility)
        toolTip = accessibility
        restyle()
    }

    var preferredWidth: CGFloat { padding * 2 + iconSize + (label.map { 4 + ceil($0.textWidth) } ?? 0) }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: padding, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        label?.frame = NSRect(x: padding + iconSize + 4, y: (bounds.height - 16) / 2, width: ceil(label!.textWidth) + 1, height: 16)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
        // The snooze menu pins the row's hover actions while it is open (Sidebar.tsx:1536-1539).
        if state.popupOpen != old.popupOpen, let row = superview as? SidebarRowBase {
            row.refresh()
            // `<Tooltip disabled={snoozeMenuOpen}>`: the menu takes the hover card away.
            if state.popupOpen { row.onHoverChange?(row, false) }
        }
    }
    override func updateLayer() { restyle() }

    private func restyle() {
        let color = state.hovered ? SB.c(\.foreground) : SB.c(\.mutedForeground)
        icon.strokeColor = color
        label?.color = color
    }
}

/// The Woke pill's button (Sidebar.tsx:1871-1888, 2036-2054): laid over the pill's icon and label, it dismisses
/// the wake and underlines the label on hover.
final class WokeDismissButton: ControlView {
    weak var label: LabelView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        setAccessibilityLabel("Dismiss Woke notification")
        toolTip = "Dismiss Woke notification"
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        label?.isUnderlined = state.hovered
    }
}

/// Base for recycled list rows: hover and press from ControlView, a reusable `configure`.
class SidebarRowBase: ControlView {
    /// T3's 8, or Capy's 6 under Dither.
    var rowRadius: CGFloat { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? DitherChrome.controlRadius : 8 }
    final var onOpen: (@MainActor () -> Void)? // final: see PROGRESS.md gotchas (Swift 6.4 link bug)
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { needsDisplay = true; refresh() } } }
    var item: SidebarItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
    }

    /// The list's shared rename field while this row's thread is being renamed.
    weak var renameField: SidebarRenameFieldView?

    /// The pointer entered or left the row (the hover card's trigger).
    final var onHoverChange: (@MainActor (SidebarRowBase, Bool) -> Void)?
    /// A press on a thread row moved `dragDistance`: the list starts a thread drag. The point is the
    /// press, in window coordinates.
    final var onBeginDrag: (@MainActor (SidebarRowBase, ThreadId, NSEvent, NSPoint) -> Void)?
    /// The lifted row of an in-list drag (Sidebar.tsx:1599-1640, 1755-1757), nil at rest.
    struct Lift: Equatable {
        /// What dropping here does (`dropVerb`), nil inside the row's own section.
        var verb: SidebarDropVerb?
        /// The lifted row is over the pinned block (`dragOverPinned`).
        var overPinned: Bool
    }
    var lift: Lift? {
        didSet {
            guard lift != oldValue else { return }
            // The shadow reaches past the row.
            clipsToBounds = lift == nil
            if let verb = lift?.verb {
                let badge = dropBadge ?? SidebarReorderDropBadge()
                if badge.superview == nil { addSubview(badge); dropBadge = badge }
                badge.verb = verb
            }
            dropBadge?.isHidden = lift?.verb == nil
            refresh()
            needsLayout = true
        }
    }
    /// The verb pill in the status slot while lifted (`dragDestination`).
    private(set) var dropBadge: SidebarReorderDropBadge?

    /// The pin glyph shows at rest, and on the lifted row only over the pinned block with no verb.
    func showsPin(_ r: SidebarRowModel) -> Bool {
        r.isPinned && (lift == nil || (lift?.overPinned == true && lift?.verb == nil))
    }

    /// The lifted row is an opaque card so the rows beneath never show through: `bg-sidebar` under the
    /// active row tint, with `shadow-lg`.
    func applyLift(_ surface: CALayer) {
        guard lift != nil else { surface.shadowOpacity = 0; return }
        surface.backgroundColor = SidebarRowBase.composite(SB.c(\.sidebarRowActive), over: SB.c(\.sidebar)).cgColor(in: self)
        // ponytail: one shadow layer for Tailwind's two (0 10 15 -3, 0 4 6 -4 at 10%); add the second if it reads flat
        surface.shadowColor = NSColor.black.cgColor
        surface.shadowOpacity = 0.14
        surface.shadowRadius = 7
        surface.shadowOffset = CGSize(width: 0, height: -6)
    }

    /// Classic Glass's edge and highlight on the open or selected row's pane.
    var paneEdge: GlassEdgeLayer?

    static func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        guard let t = top.usingColorSpace(.sRGB), let b = bottom.usingColorSpace(.sRGB) else { return bottom }
        let a = t.alphaComponent
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * a + y * (1 - a) }
        return NSColor(srgbRed: mix(t.redComponent, b.redComponent), green: mix(t.greenComponent, b.greenComponent),
                       blue: mix(t.blueComponent, b.blueComponent), alpha: 1)
    }
    /// Files dragged over the row (`isFileDragOver`: `ring-1 ring-inset ring-primary/70`).
    var isFileDragOver = false { didSet { if isFileDragOver != oldValue { refresh() } } }
    private var pressPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        pressPoint = event.locationInWindow
        // A press dismisses the hover card, as pressing a tooltip's trigger does.
        onHoverChange?(self, false)
    }

    override func mouseDragged(with event: NSEvent) {
        if let p = pressPoint, case .row(let r)? = item, !r.isRenaming, let onBeginDrag,
           hypot(event.locationInWindow.x - p.x, event.locationInWindow.y - p.y) >= SidebarListView.dragDistance {
            pressPoint = nil
            var released = state
            released.active = false
            previewState(released)
            onBeginDrag(self, r.id, event, p)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressPoint = nil
        super.mouseUp(with: event)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pressPoint = nil
        lift = nil
        isFileDragOver = false
        isKeyboardFocused = false
        func reset(_ view: NSView) {
            if let control = view as? ControlView {
                var clean = control.state
                clean.hovered = false
                clean.active = false
                clean.popupOpen = false
                clean.focusVisible = false
                control.previewState(clean)
            }
            for child in view.subviews { reset(child) }
        }
        reset(self)
    }

    func configure(_ item: SidebarItem) {
        guard self.item?.key == item.key else {
            // Another thread now: its hover reveals start at rest, with no fade.
            return HoverReveal.withoutAnimation { prepareForReuse(); self.item = item; refresh() }
        }
        self.item = item
        refresh()
    }
    func refresh() {}
    // The row surface is a CGColor, so it re-resolves here; it kept the old appearance's fill before.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        refresh()
        if state.hovered != old.hovered { onHoverChange?(self, state.hovered) }
    }
    override func performAction() { onOpen?(); super.performAction() }

    /// `rowSurfaceClassName`: the open thread, then a selected row, then hover (or files dragged over).
    static func surfaceColor(_ r: SidebarRowModel, hovered: Bool) -> NSColor? {
        r.isActive ? SB.c(\.sidebarRowActive) : r.isSelected ? SB.c(\.sidebarRowSelected) : hovered ? SB.c(\.sidebarRowHover) : nil
    }

    /// The surface's ring: the keyboard focus ring (2px), else the file drag ring (`ring-1 ring-primary/70`).
    func applyRing(_ surface: CALayer) {
        surface.borderWidth = isKeyboardFocused ? 2 : isFileDragOver ? 1 : 0
        surface.borderColor = (isKeyboardFocused ? SB.c(\.ring) : SB.c(\.primary, 0.7)).cgColor(in: self)
    }
    // The list owns keyboard focus; rows never take it from a click.
    override var acceptsFirstResponder: Bool { false }

    /// Thread rows open the thread menu (Sidebar.tsx:1410-1415); other rows have none.
    final var onContextMenu: (@MainActor (ThreadId, NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        guard case .row(let r)? = item, let onContextMenu else { return super.rightMouseDown(with: event) }
        onContextMenu(r.id, event)
    }
}

/// The pin glyph. Where pinning works it is the unpin button and shows pin-off on hover
/// (Sidebar.tsx:1756-1789); `size-3`, `text-muted-foreground/65`.
final class PinButton: ControlView {
    private let pin = IconView(name: .pin, size: 12)
    private let pinOff = IconView(name: .pinOff, size: 12)
    var isButton = true { didSet { restyle() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        transitions = .colors // transition-colors hover:text-foreground (Sidebar.tsx:1765)
        addSubview(pin)
        addSubview(pinOff)
        setAccessibilityLabel("Unpin thread")
        toolTip = "Unpin thread"
        restyle()
    }

    override func layout() {
        super.layout()
        pin.frame = bounds
        pinOff.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isButton ? super.hitTest(point) : nil }
    override var acceptsFirstResponder: Bool { false }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func updateLayer() { restyle() }

    private func restyle() {
        let hot = isButton && state.hovered
        let color = hot ? SB.c(\.foreground) : SB.c(\.mutedForeground, 0.65)
        pin.strokeColor = color
        pinOff.strokeColor = color
        pin.isHidden = hot
        pinOff.isHidden = !hot
        toolTip = isButton ? "Unpin thread" : nil
        setAccessibilityLabel(isButton ? "Unpin thread" : "Pinned")
    }
}

/// Callbacks a row can fire. The app wires them to server commands.
@MainActor
struct SidebarRowActions {
    var settle: (ThreadId) -> Void = { _ in }
    var unsettle: (ThreadId) -> Void = { _ in }
    var snooze: (ThreadId, NSView) -> Void = { _, _ in }
    var unsnooze: (ThreadId) -> Void = { _ in }
    var unpin: (ThreadId) -> Void = { _ in }
    /// The Woke pill, a button that dismisses the wake (Sidebar.tsx:1410-1418).
    var acknowledgeWake: (ThreadId) -> Void = { _ in }
    /// The pull request badge: one link opens it, a stack or several open the thread's list.
    var pullRequest: (ThreadId) -> Void = { _ in }
    /// A row of the badge's hover mini list: that pull request, beside the thread.
    var pullRequestURL: (ThreadId, String) -> Void = { _, _ in }
    var contextMenu: (ThreadId, NSEvent, NSView) -> Void = { _, _, _ in }
}

/// The card row (Sidebar.tsx:1955-2217): `li py-0.5`, a `rounded-md` surface 78px tall,
/// content `px-2.5 py-2`: project line (h-5), title (`mt-1`), branch line (`mt-0.5`).
final class SidebarCardRowView: SidebarRowBase {
    private let surface = CALayer()
    /// The visible card, 2pt below the row's top: the hover card's trigger in T3 (aligned to its top edge).
    var surfaceFrame: CGRect { surface.frame }
    private let monogram = ProjectMonogramView()
    private let capyIcon = IconView(name: .folder, size: 16)
    /// Dither: Capy's dot grid stands for "working", alone in the status slot.
    private let workingGrid = DotGridSpinnerView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let project = LabelView()
    let pin = PinButton()
    private let statusIcon = StatusIconSlot()
    private let statusLabel = LabelView()
    private let duration = LabelView()
    /// Dither's working and waiting timer: the duration's digits roll up as they change, like "Working for". Built on
    /// the first Dither row that shows one, so other themes never make it.
    private var rollingDuration: RollingTextView?
    private var rollingFor: String?
    private let title = LabelView()
    private let branchIcon = IconView(name: .folderGit2, size: 12)
    private let branch = LabelView()
    /// A scratch thread's machine on line 3 (`size-3 text-muted-foreground/40`).
    private let scratchMachine = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private let provider = ProviderGlyphView()
    /// A remote thread's machine (`size-3.5`, `text-sidebar-muted-foreground/70`, Sidebar.tsx:2196-2205).
    private let machine = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    let terminal = TerminalStatusGlyph()
    let prBadge = PullRequestBadgeView()
    let snoozeButton = RowActionButton(icon: .clock, size: 14, accessibility: "Snooze thread").menuTrigger()
    let settleButton = RowActionButton(icon: .check, size: 14, title: "Settle", accessibility: "Settle thread")
    let wokeButton = WokeDismissButton()
    var actions = SidebarRowActions()
    /// The actions hold the status slot (`static`); they keep fading out after this turns false.
    private var showsActions = false
    private var showsSnooze = false
    private var hidForLift = false
    /// Working duration ticks with the list's timer.
    var nowMs: Int64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "borderColor": NSNull()]
        surface.cornerRadius = 8
        layer?.addSublayer(surface)
        addSubview(workingGrid)
        workingGrid.isHidden = true
        for v in [monogram, capyIcon, project, pin, statusIcon, statusLabel, duration, title, branchIcon, branch, scratchMachine, provider, machine, terminal, prBadge] as [NSView] { addSubview(v) }
        prBadge.onClick = { [weak self] in if case .row(let r)? = self?.item { self?.actions.pullRequest(r.id) } }
        prBadge.onOpenURL = { [weak self] url in if case .row(let r)? = self?.item { self?.actions.pullRequestURL(r.id, url) } }
        project.font = SB.font(12, .medium); project.lineHeight = 16
        statusLabel.font = SB.font(12, .medium); statusLabel.lineHeight = 16
        duration.font = SB.tabular(12, .medium); duration.lineHeight = 16
        title.lineHeight = 20
        branch.font = SB.font(12); branch.lineHeight = 16
        settleButton.padding = 6
        addSubview(snoozeButton)
        addSubview(settleButton)
        addSubview(wokeButton)
        wokeButton.label = statusLabel
        wokeButton.action = { [weak self] in if case .row(let r)? = self?.item { self?.actions.acknowledgeWake(r.id) } }
        HoverReveal.snap([snoozeButton, settleButton], visible: false, hides: true)
        settleButton.action = { [weak self] in if case .row(let r)? = self?.item { self?.actions.settle(r.id) } }
        snoozeButton.action = { [weak self] in
            guard let self, case .row(let r)? = self.item else { return }
            self.actions.snooze(r.id, self.snoozeButton)
        }
        pin.action = { [weak self] in if case .row(let r)? = self?.item { self?.actions.unpin(r.id) } }
        onContextMenu = { [weak self] id, event in if let self { self.actions.contextMenu(id, event, self) } }
    }

    var row: SidebarRowModel? { if case .row(let r)? = item { r } else { nil } }
    /// Dither rounds the 78pt card as a card, not a control.
    private var cardRadius: CGFloat { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? DitherChrome.cardRadius : 8 }

    override func refresh() {
        surface.cornerRadius = cardRadius
        guard let r = row else { return }
        let hovered = state.hovered || isKeyboardFocused || snoozeButton.state.popupOpen
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // rowSurfaceClassName (Sidebar.tsx:1582-1605)
        surface.backgroundColor = SidebarRowBase.surfaceColor(r, hovered: state.hovered || isFileDragOver)?.cgColor(in: self)
        applyRing(surface)
        applyLift(surface)
        paneEdge = WindowGlass.syncEdge(paneEdge, on: surface, in: self, radius: cardRadius, show: r.isActive || r.isSelected)
        CATransaction.commit()
        // Background work fades as a whole row (`opacity-70 transition-opacity`, full on hover, Sidebar.tsx:1596-1598).
        HoverReveal.fade(self, to: r.recedes && r.status == .working && !hovered ? 0.7 : 1)

        monogram.projectTitle = r.projectTitle ?? r.projectLabel ?? ""
        monogram.source = r.projectIcon
        // Dither keeps the project icon at the row's lead, beside the title, and drops the provider glyph; under a
        // project section the header carries the icon.
        monogram.isHidden = r.projectTitle == nil && r.projectLabel == nil || r.inProjectSection
        capyIcon.isHidden = !capyRow || !monogram.isHidden || r.inProjectSection
        capyIcon.strokeColor = SB.c(\.sidebarMutedForeground)
        project.text = r.projectLabel ?? ""
        project.font = capyRow ? SB.font(11) : SB.font(12, r.recedes ? .regular : .medium)
        project.color = SB.c(\.secondaryLabel)
        pin.isHidden = !showsPin(r) || capyRow && r.inProjectSection

        let showActions = hovered
        if let top = r.topStatus {
            let color = SB.status(top)
            statusLabel.text = r.statusLabel ?? ""
            statusLabel.color = color
            statusIcon.set(SB.statusIcon(top), color: color)
            duration.text = (r.status == .working || r.status == .waiting) ? r.workingStartedMs.map {
                SidebarModel.formatWorkingDurationLabel(elapsedMs: Double(nowMs - $0)) } ?? "" : ""
            duration.color = color
            duration.font = SB.tabular(12, .medium)
        } else {
            statusIcon.set(nil, color: .clear)
            statusLabel.text = ""
            duration.text = r.timeLabel
            duration.color = SB.c(\.secondaryLabel)
            duration.font = SB.tabular(12)
        }
        // Working and waiting show the grid and a muted timer whose digits roll, without the word.
        let waitingGrid = capyRow && r.topStatus == .waiting
        let grid = capyRow && r.topStatus == .working || waitingGrid
        if grid {
            statusIcon.set(nil, color: .clear)
            statusLabel.text = ""
            workingGrid.color = waitingGrid ? SB.c(\.foreground) : SB.c(\.warning)
        }
        let rolls = grid && !duration.text.isEmpty
        if rolls {
            let v = rollingDuration ?? {
                let v = RollingTextView(font: SB.tabular(12, .medium), lineHeight: 16)
                addSubview(v)
                rollingDuration = v
                return v
            }()
            v.color = SB.status(.waiting)
            // Only a tick of the same thread rolls; a reused row shows its new thread's time at once.
            v.set(prefix: "", value: duration.text, animated: rollingFor == r.id.rawValue)
            rollingFor = r.id.rawValue
            duration.color = .clear
        } else {
            rollingFor = nil
        }
        if let v = rollingDuration, v.isHidden == rolls { v.isHidden = !rolls }
        if workingGrid.isHidden == grid { workingGrid.isHidden = !grid }
        HoverReveal.fade([workingGrid], visible: !showActions)
        let woke = r.topStatus == .woke
        wokeButton.isHidden = !woke || lift != nil
        if !woke { statusLabel.isUnderlined = false }
        // The status label and the actions cross-fade over 150 ms (`transition-opacity`, Sidebar.tsx:2027,2094);
        // the slot's width follows `showsActions` at once, as `absolute` and `static` flip without a transition.
        HoverReveal.fade([statusIcon, statusLabel, duration] + [rollingDuration].compactMap { $0 }, visible: !showActions || woke)
        let snoozes = r.action == .settle && r.canSnooze
        if !snoozes { HoverReveal.snap([snoozeButton], visible: false, hides: true) }
        HoverReveal.fade(snoozes ? [settleButton, snoozeButton] : [settleButton], visible: showActions, hides: true)
        if showsActions != showActions || showsSnooze != snoozes { showsActions = showActions; showsSnooze = snoozes; needsLayout = true }
        // The lifted row trades the status slot for the drop verb (Sidebar.tsx:2011-2013).
        if lift != nil {
            for v in [statusIcon, statusLabel, duration, settleButton, snoozeButton] as [NSView] { v.isHidden = true }
            hidForLift = true
        } else if hidForLift {
            hidForLift = false
            for v in [statusIcon, statusLabel, duration] as [NSView] { v.isHidden = false }
        }
        // Title (Sidebar.tsx:1658-1690), card variant.
        title.text = r.title
        title.font = SB.font(capyRow ? 13 : 14, r.recedes ? .regular : .medium)
        title.color = r.recedes ? SB.c(\.secondaryLabel)
            : r.isUnread || r.isWoke || r.status == .input ? SB.c(\.foreground)
            : r.status == .failed ? SB.c(\.foreground, 0.95) : SB.c(\.foreground, 0.9)
        title.alphaValue = r.isRegeneratingTitle ? 0.55 : 1
        let showsScratch = r.branch == nil && r.scratchMachineLabel != nil
        branch.text = r.branch ?? (showsScratch ? r.scratchMachineLabel ?? "" : "")
        // Dither sections (after Capy): the time joins the meta line, and the status slot keeps only the status.
        if capyRow && r.inProjectSection {
            branch.text = [branch.text, r.timeLabel].filter { !$0.isEmpty }.joined(separator: " · ")
            if r.topStatus == nil { duration.text = "" }
        }
        branch.color = capyRow ? SB.c(\.secondaryLabel) : SB.c(\.mutedForeground, 0.4)
        branch.font = SB.font(capyRow ? 11 : 12)
        branchIcon.isHidden = !(r.branch != nil && r.hasWorktree)
        branchIcon.strokeColor = SB.c(\.mutedForeground, 0.4)
        scratchMachine.kind = showsScratch ? r.scratchMachine : nil
        scratchMachine.isHidden = !showsScratch
        scratchMachine.color = SB.c(\.mutedForeground, 0.4)
        provider.driver = r.providerIcon
        provider.isHidden = capyRow
        machine.kind = r.environmentMachine
        // Dither drops the trailing machine glyph.
        machine.isHidden = r.environmentMachine == nil || showsScratch || capyRow
        machine.color = SB.c(\.sidebarMutedForeground, 0.7)
        terminal.count = r.terminalProcessCount
        prBadge.badge = r.pullRequestBadge
        setAccessibilityLabel([r.title, r.isRegeneratingTitle ? "Regenerating title" : nil, r.statusLabel, r.projectLabel]
            .compactMap { $0 }.joined(separator: ", "))
        setAccessibilitySelected(r.isActive) // `aria-current="page"` (Sidebar.logic.ts:59)
        needsLayout = true
    }

    /// Dither (after Capy): 48pt, the icon and title on the first line with the status at its right, then the
    /// project, branch and badges on a small gray line.
    private var capyRow: Bool { row?.dither == true }

    override func layout() {
        super.layout()
        let w = bounds.width
        let capy = capyRow
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = capy ? CGRect(x: 0, y: 1, width: w, height: bounds.height - 2) : CGRect(x: 0, y: 2, width: w, height: 78)
        CATransaction.commit()
        let left: CGFloat = capy ? 8 : 10, right = w - (capy ? 8 : 10), top: CGFloat = capy ? 5 : 10
        // Line 1: favicon, project, pin, status slot.
        var x = left
        if !monogram.isHidden { monogram.frame = NSRect(x: x, y: top + 2, width: 16, height: 16); x += 16 + 6 }
        if capy { capyIcon.frame = NSRect(x: left, y: top + 2, width: 16, height: 16) }
        var slotRight = right
        var slotLeft = right
        // `-mr-1` on Settle, buttons stretch to the 20px slot. Placed while hidden too, so a fade-out stays put.
        let sw = settleButton.preferredWidth
        settleButton.frame = NSRect(x: right + 4 - sw, y: top, width: sw, height: 20)
        let zw = snoozeButton.preferredWidth
        snoozeButton.frame = NSRect(x: settleButton.frame.minX - zw, y: top, width: zw, height: 20)
        let actionsLeft = (showsSnooze ? snoozeButton : settleButton).frame.minX
        if showsActions { slotLeft = actionsLeft }
        // Status label at rest (absolute and faded while actions show). Woke is itself an action, so it stays in
        // the flow beside the hover actions instead of under them (Sidebar.tsx:2023-2030).
        let wokeBeside = showsActions && !wokeButton.isHidden
        let statusRight = wokeBeside ? actionsLeft : slotRight
        var sx = statusRight
        if !duration.text.isEmpty {
            let dw = ceil(duration.textWidth)
            duration.frame = NSRect(x: sx - dw, y: top + 2, width: dw + 1, height: 16)
            rollingDuration?.frame = duration.frame
            sx -= dw + (statusLabel.text.isEmpty ? 0 : 4)
        }
        if !statusLabel.text.isEmpty {
            let lw = ceil(statusLabel.textWidth)
            statusLabel.frame = NSRect(x: sx - lw, y: top + 2, width: lw + 1, height: 16)
            sx -= lw
            if statusIcon.icon != nil { statusIcon.frame = NSRect(x: sx - 4 - 16, y: top + 2, width: 16, height: 16); sx -= 20 }
        }
        if !wokeButton.isHidden { wokeButton.frame = NSRect(x: sx, y: top, width: statusRight - sx, height: 20) }
        if wokeBeside { slotLeft = sx }
        if !workingGrid.isHidden {
            if statusLabel.text.isEmpty && duration.text.isEmpty {
                workingGrid.frame = NSRect(x: statusRight - 16, y: top + 2, width: 16, height: 16); sx = statusRight - 16
            } else {
                workingGrid.frame = NSRect(x: sx - 4 - 16, y: top + 2, width: 16, height: 16); sx -= 20
            }
        }
        let restWidth = max(32, slotRight - sx) // `min-w-8`
        if !showsActions { slotLeft = slotRight - restWidth }
        if lift != nil {
            let bw = lift?.verb == nil ? 0 : dropBadge?.preferredWidth ?? 0
            slotLeft = right - bw
            dropBadge?.frame = NSRect(x: slotLeft, y: top, width: bw, height: 20)
        }
        slotRight = slotLeft
        if !pin.isHidden { pin.frame = NSRect(x: slotRight - 6 - 12, y: top + 4, width: 12, height: 12); slotRight -= 18 }
        if capy {
            // Title beside the icon, before the status slot; the meta line under it starts with the project. In a
            // section the header carries the icon and the row sits flush with it.
            let tx = row?.inProjectSection == true ? left : left + 24
            title.frame = NSRect(x: tx, y: top, width: max(0, slotRight - 6 - tx), height: 20)
            placeRenameField(row?.isRenaming == true ? renameField : nil, over: title,
                             frame: NSRect(x: tx, y: top - 1, width: max(0, right - tx), height: 22))
        } else {
            project.isHidden = false
            project.frame = NSRect(x: x, y: top + 2, width: max(0, slotRight - 6 - x), height: 16)
            // Line 2: title, `mt-1`.
            title.frame = NSRect(x: left, y: top + 24, width: right - left, height: 20)
            placeRenameField(row?.isRenaming == true ? renameField : nil, over: title,
                             frame: NSRect(x: left, y: top + 23, width: right - left, height: 22))
        }
        // Line 3: branch and provider, `mt-0.5`, text-xs. Dither: the meta line under the title.
        let y3 = capy ? top + 21 : top + 46
        provider.frame = NSRect(x: right - 14, y: y3 + 1, width: 14, height: 14)
        // `ml-auto gap-1`: the machine sits 4pt left of the provider.
        var trailing = capy ? right + 4 : right - 14
        if !machine.isHidden { machine.frame = NSRect(x: trailing - 4 - 14, y: y3 + 1, width: 14, height: 14); trailing -= 18 }
        // The terminal glyph follows the branch, `gap-1.5` before the provider group.
        if !prBadge.isHidden {
            let pw = prBadge.preferredWidth
            prBadge.frame = NSRect(x: trailing - 6 - pw, y: y3, width: pw, height: 16); trailing -= pw + 6
        }
        if !terminal.isHidden { terminal.frame = NSRect(x: trailing - 6 - 14, y: y3 + 1, width: 14, height: 14); trailing -= 20 }
        var bx = left
        if capy {
            bx = row?.inProjectSection == true ? left : left + 24
            // The project icon names the project; the meta line spells it out only when there is no branch to show.
            let showsProject = !project.text.isEmpty && branch.text.isEmpty && row?.inProjectSection != true
            project.isHidden = !showsProject
            let pw = showsProject ? min(ceil(project.textWidth) + 1, max(0, trailing - bx)) : 0
            project.frame = NSRect(x: bx, y: y3, width: pw, height: 16)
            if pw > 0 { bx += pw + 8 }
        }
        if !branchIcon.isHidden { branchIcon.frame = NSRect(x: bx, y: y3 + 2, width: 12, height: 12); bx += 18 }
        if !scratchMachine.isHidden { scratchMachine.frame = NSRect(x: bx, y: y3 + 2, width: 12, height: 12); bx += 18 }
        branch.frame = NSRect(x: bx, y: y3, width: max(0, trailing - 6 - bx), height: 16)
    }
}

/// The status icon slot: a 16px lucide glyph swapped per status.
final class StatusIconSlot: NSView {
    private(set) var icon: IconName?
    private var view: IconView?
    func set(_ name: IconName?, color: NSColor) {
        if name != icon {
            view?.removeFromSuperview()
            view = name.map { IconView(name: $0, size: 16) }
            if let view { view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view) }
            icon = name
        }
        view?.strokeColor = color
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `SidebarProviderStack` reduced to the current provider: a 14px glyph at 60% opacity.
// ponytail: one glyph; draw the earlier owners small and grayscale once providerInstanceHistory has rows that need it
final class ProviderGlyphView: NSView {
    var driver = "" { didSet { if driver != oldValue { rebuild() } } }
    private var glyph: IconView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func rebuild() {
        glyph?.removeFromSuperview()
        let name: IconName = driver == "codex" ? (IconName(rawValue: "brandOpenAI") ?? .brandClaudeAI) : .brandClaudeAI
        let v = IconView(name: name, size: 14, strokeColor: Themed.color(\.foreground))
        v.alphaValue = 0.6
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
        addSubview(v)
        glyph = v
    }
}

/// The slim row (Sidebar.tsx:1791-1953): `h-9 px-2.5 gap-2.5`, used on the snoozed and settled shelves.
final class SidebarSlimRowView: SidebarRowBase {
    private let surface = CALayer()
    private let monogram = ProjectMonogramView()
    private let title = LabelView()
    let pin = PinButton()
    let terminal = TerminalStatusGlyph()
    let prBadge = PullRequestBadgeView()
    private let time = LabelView()
    /// The Woke pill's `size-3` alarm clock, before "Woke" in the time slot (Sidebar.tsx:1871-1888).
    private let wokeIcon = IconView(name: .alarmClock, size: 12)
    let wokeButton = WokeDismissButton()
    /// Hovered with the Woke pill showing: the action sits beside the pill instead of over it.
    private var wokeBeside = false
    private var actionButton: RowActionButton?
    private var actionKind: SidebarRowModel.Action?
    var actions = SidebarRowActions()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "borderColor": NSNull()]
        surface.cornerRadius = 8
        layer?.addSublayer(surface)
        for v in [monogram, title, pin, terminal, prBadge, time, wokeIcon, wokeButton] as [NSView] { addSubview(v) }
        prBadge.onClick = { [weak self] in if case .row(let r)? = self?.item { self?.actions.pullRequest(r.id) } }
        prBadge.onOpenURL = { [weak self] url in if case .row(let r)? = self?.item { self?.actions.pullRequestURL(r.id, url) } }
        wokeButton.label = time
        wokeButton.action = { [weak self] in if case .row(let r)? = self?.item { self?.actions.acknowledgeWake(r.id) } }
        title.lineHeight = 20
        time.font = SB.tabular(12); time.lineHeight = 16
        pin.action = { [weak self] in if case .row(let r)? = self?.item { self?.actions.unpin(r.id) } }
        onContextMenu = { [weak self] id, event in if let self { self.actions.contextMenu(id, event, self) } }
    }

    var row: SidebarRowModel? { if case .row(let r)? = item { r } else { nil } }

    override func refresh() {
        surface.cornerRadius = rowRadius
        guard let r = row else { return }
        let hovered = state.hovered || isKeyboardFocused
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.backgroundColor = SidebarRowBase.surfaceColor(r, hovered: state.hovered || isFileDragOver)?.cgColor(in: self)
        applyRing(surface)
        applyLift(surface)
        paneEdge = WindowGlass.syncEdge(paneEdge, on: surface, in: self, radius: rowRadius, show: r.isActive || r.isSelected)
        CATransaction.commit()
        let unsettle = r.action == .unsettle
        // Dimmed favicon at rest, restored on hover.
        let dim = (!r.isActive || unsettle) && !hovered
        monogram.projectTitle = r.projectTitle ?? r.projectLabel ?? ""
        monogram.source = r.projectIcon
        monogram.dimmed = dim
        HoverReveal.fade(monogram, to: dim ? 0.4 : 1) // `transition-opacity` (Sidebar.tsx:1827-1830)
        title.text = r.title
        title.font = SB.font(14, r.recedes ? .regular : .medium)
        if hovered {
            title.color = SB.c(\.foreground)
        } else if unsettle {
            title.color = SB.c(\.secondaryLabel, 0.7) // `[&:not(:hover)_*]:text-secondary-label/70`
        } else {
            title.color = r.recedes ? SB.c(\.secondaryLabel, 0.7)
                : r.isActive || r.isWoke || r.status == .input ? SB.c(\.foreground)
                : r.isUnread ? SB.c(\.mutedForeground) : SB.c(\.secondaryLabel, 0.7)
        }
        title.alphaValue = r.isRegeneratingTitle ? 0.55 : 1 // `opacity-55` (Sidebar.tsx:1691)
        pin.isHidden = !showsPin(r)
        terminal.count = r.terminalProcessCount
        prBadge.badge = r.pullRequestBadge
        let woke = r.isWoke && r.snoozeLabel == nil
        if let snooze = r.snoozeLabel {
            time.text = snooze
            time.color = SB.c(\.infoForeground)
            time.font = SB.tabular(12)
        } else if woke {
            // A wake can land straight in the settled tail, so the pill shows there too (Sidebar.tsx:1871-1873).
            time.text = "Woke"
            time.color = SB.c(\.warningForeground)
            time.font = SB.font(12, .medium)
            wokeIcon.strokeColor = SB.c(\.warningForeground)
        } else {
            time.text = r.timeLabel
            time.color = unsettle && !hovered ? SB.c(\.secondaryLabel, 0.7) : SB.c(\.secondaryLabel)
            time.font = SB.tabular(12)
        }
        wokeIcon.isHidden = !woke || lift != nil
        wokeButton.isHidden = wokeIcon.isHidden
        if !woke { time.isUnderlined = false }
        HoverReveal.fade([time, wokeIcon], visible: !hovered || r.isWoke) // Sidebar.tsx:1857-1860
        if actionKind != r.action {
            actionButton?.removeFromSuperview()
            let b: RowActionButton
            switch r.action {
            case .unsnooze: b = RowActionButton(icon: .alarmClockOff, size: 12, accessibility: "Wake thread now")
            case .unsettle: b = RowActionButton(icon: .undo2, size: 14, accessibility: "Un-settle thread")
            case .settle: b = RowActionButton(icon: .check, size: 12, accessibility: "Settle thread")
            }
            b.action = { [weak self] in
                guard let self, let r = self.row else { return }
                switch r.action {
                case .unsnooze: self.actions.unsnooze(r.id)
                case .unsettle: self.actions.unsettle(r.id)
                case .settle: self.actions.settle(r.id)
                }
            }
            addSubview(b)
            HoverReveal.snap([b], visible: false, hides: true)
            actionButton = b
            actionKind = r.action
        }
        // `opacity-0 transition-opacity group-any-hover/sidebar-row:opacity-100` (Sidebar.tsx:1903,1920,1937).
        if let actionButton { HoverReveal.fade([actionButton], visible: hovered, hides: true) }
        wokeBeside = hovered && woke && actionButton != nil
        // The lifted row trades the time and action for the drop verb (Sidebar.tsx:1847-1849).
        if lift != nil {
            time.isHidden = true
            actionButton?.isHidden = true
        } else if time.isHidden {
            time.isHidden = false
        }
        // The `sr-only` "Regenerating title" status (Sidebar.tsx:1838-1842).
        setAccessibilityLabel([r.title, r.isRegeneratingTitle ? "Regenerating title" : nil].compactMap { $0 }.joined(separator: ", "))
        setAccessibilitySelected(r.isActive) // `aria-current="page"` (Sidebar.logic.ts:59)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        CATransaction.commit()
        var x: CGFloat = 10
        monogram.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
        x += 16 + 10
        let tw = ceil(time.textWidth)
        let pill = wokeIcon.isHidden ? tw : 12 + 4 + tw // `size-3` icon, `gap-1`
        // While hovered, a woke row's action joins the flow (`static`) right of the pill (Sidebar.tsx:1907-1941).
        var timeRight = w - 10
        if let b = actionButton {
            let bw = b.preferredWidth
            b.frame = NSRect(x: w - 10 + 4 - bw, y: (h - 24) / 2, width: bw, height: 24) // `-mr-1`
            if wokeBeside { timeRight = b.frame.minX }
        }
        let slot = lift == nil ? max(32, w - 10 - timeRight + pill) : lift?.verb == nil ? -10 : dropBadge?.preferredWidth ?? 0 // `min-w-8`
        let slotX = w - 10 - slot
        if lift != nil { dropBadge?.frame = NSRect(x: slotX, y: (h - 20) / 2, width: max(0, slot), height: 20) }
        time.frame = NSRect(x: timeRight - tw, y: (h - 16) / 2, width: tw + 1, height: 16)
        if !wokeIcon.isHidden {
            wokeIcon.frame = NSRect(x: timeRight - pill, y: (h - 12) / 2, width: 12, height: 12)
            wokeButton.frame = NSRect(x: timeRight - pill, y: (h - 20) / 2, width: pill, height: 20)
        }
        var right = slotX - 10
        // `{title}{pin}{terminal}{prBadge}` in a `gap-2.5` row.
        if !prBadge.isHidden {
            let pw = prBadge.preferredWidth
            prBadge.frame = NSRect(x: right - pw, y: (h - 16) / 2, width: pw, height: 16); right -= pw + 10
        }
        if !terminal.isHidden { terminal.frame = NSRect(x: right - 14, y: (h - 14) / 2, width: 14, height: 14); right -= 14 + 10 }
        if !pin.isHidden { pin.frame = NSRect(x: right - 12, y: (h - 12) / 2, width: 12, height: 12); right -= 12 + 10 }
        title.frame = NSRect(x: x, y: (h - 20) / 2, width: max(0, right - x), height: 20)
        placeRenameField(row?.isRenaming == true ? renameField : nil, over: title,
                         frame: NSRect(x: x, y: (h - 22) / 2, width: max(0, right - x), height: 22))
    }
}

/// `SidebarSectionHeader` (Sidebar.tsx:789-830): `mx-0.5 h-8` around a CollapsibleSectionHeader.
final class SidebarShelfRowView: SidebarRowBase {
    let header = CollapsibleSectionHeaderView("")
    var onToggle: (@MainActor (SidebarShelf) -> Void)?
    /// While a row is dragged the settled header reads at full strength, and takes the accent while
    /// the lifted row is over it (Sidebar.tsx:800-818).
    var dragTone: CollapsibleSectionHeaderView.Tone? { didSet { if dragTone != oldValue { refresh() } } }

    override func prepareForReuse() {
        super.prepareForReuse()
        dragTone = nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(header)
        header.onToggle = { [weak self] _ in
            if case .shelfHeader(let shelf, _, _)? = self?.item { self?.onToggle?(shelf) }
        }
    }

    override func refresh() {
        guard case .shelfHeader(let shelf, let label, let expanded)? = item else { return }
        header.title = label
        header.tone = dragTone ?? (shelf == .snoozed ? .info : .muted)
        if header.isExpanded != expanded { header.isExpanded = expanded }
        var st = header.state; st.focusVisible = isKeyboardFocused; header.previewState(st)
    }

    override func performAction() { header.performAction() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : header }

    override func layout() {
        super.layout()
        header.frame = bounds.insetBy(dx: 2, dy: 0)
    }
}

/// "Show N more" (Sidebar.tsx:5531-5542): `h-9 px-2.5 gap-2.5 text-sm text-sidebar-muted-foreground/55`, plus icon.
final class SidebarShowMoreRowView: SidebarRowBase {
    private let surface = CALayer()
    private let icon = IconView(name: .plus, size: 16)
    private let label = LabelView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.cornerRadius = 8
        surface.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(surface)
        addSubview(icon)
        addSubview(label)
        label.font = SB.font(14); label.lineHeight = 20
    }

    override func refresh() {
        surface.cornerRadius = rowRadius
        guard case .showMore(let count)? = item else { return }
        label.text = "Show \(count) more"
        let hovered = state.hovered || isKeyboardFocused
        let color = hovered ? SB.c(\.sidebarForeground) : SB.c(\.sidebarMutedForeground, 0.55)
        label.color = color
        icon.strokeColor = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.backgroundColor = state.hovered ? SB.c(\.sidebarRowHover).cgColor(in: self) : nil
        surface.borderWidth = isKeyboardFocused ? 2 : 0
        surface.borderColor = SB.c(\.ring).cgColor(in: self)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        icon.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 36, y: (bounds.height - 20) / 2, width: bounds.width - 46, height: 20)
    }
}

/// The thread's terminal indicator (Sidebar.tsx:1722-1734, `terminalStatusFromRunningIds`): a 14pt
/// terminal glyph, `text-teal-600 dark:text-teal-300/90`, pulsing with `status-pulse` (2s: full for
/// 40%, six steps down to half, half until 90%, six steps back). The pulse is a Core Animation
/// keyframe animation, so it runs in the render server without waking the app. It stops while the
/// glyph can't be seen (hidden, occluded window) or Reduce Motion is on, since a terminal process
/// may run for hours.
final class TerminalStatusGlyph: DSView {
    private let icon = IconView(name: .terminal, size: 14)
    private lazy var loop = LoopingAnimation(view: self, key: "pulse", layer: { [weak self] in self?.icon.layer }) { Self.pulse() }

    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            isHidden = count == 0
            setAccessibilityLabel("\(count) terminal \(count == 1 ? "process" : "processes") running")
            loop.update()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityRole(.image)
        addSubview(icon)
    }

    override func layout() {
        super.layout()
        icon.frame = bounds
    }

    override func updateLayer() {
        icon.strokeColor = Themed.base("teal-600", dark: "teal-300", 0.9)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        loop.windowChanged()
    }
    override func viewDidHide() { super.viewDidHide(); loop.update() }
    override func viewDidUnhide() { super.viewDidUnhide(); loop.update() }

    static func pulse() -> CAKeyframeAnimation {
        var times: [NSNumber] = [0], values: [Double] = [1]
        // `steps(6)` from 40% to 50% and from 90% to 100%.
        for (start, from, to) in [(0.4, 1.0, 0.5), (0.9, 0.5, 1.0)] {
            for step in 0..<6 {
                times.append(NSNumber(value: start + 0.1 * Double(step) / 6))
                values.append(from + (to - from) * Double(step) / 6)
            }
            times.append(NSNumber(value: start + 0.1))
            values.append(to)
        }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.keyTimes = times
        animation.values = values
        animation.calculationMode = .discrete
        animation.duration = 2
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }
}

/// Dither (after Capy): a section's header, quiet so the threads lead. A 14pt project icon (a pin for Pinned), the name
/// in the muted 12pt of the "Threads" label, the count a step lighter, and a chevron after the count that shows on
/// hover or while the section is folded. It sits on the lower part of its 32pt, so sections breathe above.
final class SidebarProjectHeaderRowView: SidebarRowBase {
    private let icon = ProjectMonogramView()
    private let pinIcon = IconView(name: .pin, size: 14)
    private let label = LabelView("", font: SB.font(12, .medium), color: SB.c(\.sidebarMutedForeground))
    private let count = LabelView("", font: SB.tabular(12), color: SB.c(\.sidebarMutedForeground, 0.6))
    private let chevron = IconView(name: .chevronRight, size: 12)
    private var expanded = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        count.lineHeight = 16
        icon.scale = 14 / 16
        [icon, pinIcon, label, count, chevron].forEach(addSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        refresh()
    }

    override func refresh() {
        guard case .projectHeader(let h)? = item else { return }
        expanded = h.expanded
        icon.isHidden = h.isPinned
        pinIcon.isHidden = !h.isPinned
        if !h.isPinned { icon.projectTitle = h.projectTitle; icon.source = h.projectIcon }
        let hovered = state.hovered || isKeyboardFocused
        label.text = h.label
        label.color = SB.c(hovered ? \.sidebarForeground : \.sidebarMutedForeground)
        count.text = "\(h.count)"
        pinIcon.strokeColor = SB.c(\.sidebarMutedForeground)
        chevron.strokeColor = SB.c(\.sidebarMutedForeground)
        chevron.setRotation(h.expanded ? 90 : 0, motion: window == nil ? .none : .ease(0.15))
        chevron.alphaValue = hovered || !h.expanded ? 1 : 0
        setAccessibilityLabel("\(h.label), \(h.count) threads")
        setAccessibilityExpanded(h.expanded)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The content row is the bottom 22pt.
        let mid = bounds.height - 11
        icon.frame = NSRect(x: 8, y: (mid - 7).rounded(), width: 14, height: 14)
        pinIcon.frame = icon.frame
        let lw = min(ceil(label.textWidth) + 1, max(0, bounds.width - 30 - 60))
        label.frame = NSRect(x: 30, y: (mid - 8).rounded(), width: lw, height: 16)
        let cw = ceil(count.textWidth) + 1
        count.frame = NSRect(x: label.frame.maxX + 5, y: label.frame.minY, width: cw, height: 16)
        chevron.frame = NSRect(x: count.frame.maxX + 4, y: (mid - 6).rounded(), width: 12, height: 12)
    }
}
