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
        case .waiting: nil
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
final class ProjectMonogramView: DSView {
    var projectTitle = "" { didSet { if projectTitle != oldValue { updateIdentity() } } }
    /// The whole project, for its chosen icon and its icon file. Without it only the title's monogram shows.
    var source: ProjectIconSource? {
        didSet {
            guard source != oldValue else { return }
            if let source { projectTitle = source.title }
            updateIdentity()
        }
    }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    private var identity = (monogram: "PR", color: "blue")
    private var observing = false

    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateIdentity() {
        if case .monogram(let text, let color)? = source?.override {
            identity = (text, color)
        } else {
            identity = Self.identity(projectTitle)
        }
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
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
            drawIcon(icon.definition, in: tileRect, color: SB.base("\(color)-600", "\(color)-400").cgColor(in: self), ctx: ctx)
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
        var color = SB.base("\(identity.color)-600", "\(identity.color)-400").cgColor(in: self)
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
        ctx.setShouldSmoothFonts(true)
        ctx.textMatrix = .identity
        ctx.translateBy(x: 8 - target / 2, y: 10.8)
        ctx.scaleBy(x: width > 0 ? target / width : 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// A lucide icon stroked into `rect` (`size-full` in the 14px box).
    private func drawIcon(_ definition: IconDefinition, in rect: CGRect, color: CGColor, ctx: CGContext) {
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
        if state.popupOpen != old.popupOpen { (superview as? SidebarRowBase)?.refresh() }
    }
    override func updateLayer() { restyle() }

    private func restyle() {
        let color = state.hovered ? SB.c(\.foreground) : SB.c(\.mutedForeground)
        icon.strokeColor = color
        label?.color = color
    }
}

/// Base for recycled list rows: hover and press from ControlView, a reusable `configure`.
class SidebarRowBase: ControlView {
    final var onOpen: (@MainActor () -> Void)? // final: see PROGRESS.md gotchas (Swift 6.4 link bug)
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { needsDisplay = true; refresh() } } }
    var item: SidebarItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
    }

    func configure(_ item: SidebarItem) { self.item = item; refresh() }
    func refresh() {}
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); refresh() }
    override func performAction() { onOpen?(); super.performAction() }
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
    /// The pull request badge: one link opens it, a stack or several open the thread's list.
    var pullRequest: (ThreadId) -> Void = { _ in }
    var contextMenu: (ThreadId, NSEvent, NSView) -> Void = { _, _, _ in }
}

/// The card row (Sidebar.tsx:1955-2217): `li py-0.5`, a `rounded-md` surface 78px tall,
/// content `px-2.5 py-2`: project line (h-5), title (`mt-1`), branch line (`mt-0.5`).
final class SidebarCardRowView: SidebarRowBase {
    private let surface = CALayer()
    private let monogram = ProjectMonogramView()
    private let project = LabelView()
    let pin = PinButton()
    private let statusIcon = StatusIconSlot()
    private let statusLabel = LabelView()
    private let duration = LabelView()
    private let title = LabelView()
    private let branchIcon = IconView(name: .folderGit2, size: 12)
    private let branch = LabelView()
    private let provider = ProviderGlyphView()
    /// A remote thread's machine (`size-3.5`, `text-sidebar-muted-foreground/70`, Sidebar.tsx:2196-2205).
    private let machine = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    let terminal = TerminalStatusGlyph()
    let prBadge = PullRequestBadgeView()
    let snoozeButton = RowActionButton(icon: .clock, size: 14, accessibility: "Snooze thread")
    let settleButton = RowActionButton(icon: .check, size: 14, title: "Settle", accessibility: "Settle thread")
    var actions = SidebarRowActions()
    /// Working duration ticks with the list's timer.
    var nowMs: Int64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "borderColor": NSNull()]
        surface.cornerRadius = 8
        layer?.addSublayer(surface)
        for v in [monogram, project, pin, statusIcon, statusLabel, duration, title, branchIcon, branch, provider, machine, terminal, prBadge] as [NSView] { addSubview(v) }
        prBadge.onClick = { [weak self] in if case .row(let r)? = self?.item { self?.actions.pullRequest(r.id) } }
        project.font = SB.font(12, .medium); project.lineHeight = 16
        statusLabel.font = SB.font(12, .medium); statusLabel.lineHeight = 16
        duration.font = SB.tabular(12, .medium); duration.lineHeight = 16
        title.lineHeight = 20
        branch.font = SB.font(12); branch.lineHeight = 16
        settleButton.padding = 6
        addSubview(snoozeButton)
        addSubview(settleButton)
        settleButton.action = { [weak self] in if case .row(let r)? = self?.item { self?.actions.settle(r.id) } }
        snoozeButton.action = { [weak self] in
            guard let self, case .row(let r)? = self.item else { return }
            self.actions.snooze(r.id, self.snoozeButton)
        }
        pin.action = { [weak self] in if case .row(let r)? = self?.item { self?.actions.unpin(r.id) } }
        onContextMenu = { [weak self] id, event in if let self { self.actions.contextMenu(id, event, self) } }
    }

    var row: SidebarRowModel? { if case .row(let r)? = item { r } else { nil } }

    override func refresh() {
        guard let r = row else { return }
        let hovered = state.hovered || isKeyboardFocused || snoozeButton.state.popupOpen
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // rowSurfaceClassName (Sidebar.tsx:1582-1605)
        surface.backgroundColor = r.isActive ? SB.c(\.sidebarRowActive).cgColor(in: self)
            : state.hovered ? SB.c(\.sidebarRowHover).cgColor(in: self) : nil
        surface.borderWidth = isKeyboardFocused ? 2 : 0
        surface.borderColor = SB.c(\.ring).cgColor(in: self)
        // Background work fades as a whole row (`opacity-70`, full on hover).
        alphaValue = r.recedes && r.status == .working && !hovered ? 0.7 : 1
        CATransaction.commit()

        monogram.projectTitle = r.projectTitle ?? r.projectLabel ?? ""
        monogram.source = r.projectIcon
        monogram.isHidden = r.projectTitle == nil && r.projectLabel == nil
        project.text = r.projectLabel ?? ""
        project.font = SB.font(12, r.recedes ? .regular : .medium)
        project.color = SB.c(\.secondaryLabel)
        pin.isHidden = !r.isPinned

        let showActions = hovered
        if let top = r.topStatus {
            let color = SB.status(top)
            statusLabel.text = r.statusLabel ?? ""
            statusLabel.color = color
            statusIcon.set(SB.statusIcon(top), color: color)
            duration.text = r.status == .working ? r.workingStartedMs.map {
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
        let woke = r.topStatus == .woke
        for v in [statusIcon, statusLabel, duration] as [NSView] { v.alphaValue = showActions && !woke ? 0 : 1 }
        snoozeButton.isHidden = !showActions || r.action != .settle || !r.canSnooze
        settleButton.isHidden = !showActions
        // Title (Sidebar.tsx:1658-1690), card variant.
        title.text = r.title
        title.font = SB.font(14, r.recedes ? .regular : .medium)
        title.color = r.recedes ? SB.c(\.secondaryLabel)
            : r.isUnread || r.isWoke || r.status == .input ? SB.c(\.foreground)
            : r.status == .failed ? SB.c(\.foreground, 0.95) : SB.c(\.foreground, 0.9)
        title.alphaValue = r.isRegeneratingTitle ? 0.55 : 1
        branch.text = r.branch ?? ""
        branch.color = SB.c(\.mutedForeground, 0.4)
        branchIcon.isHidden = !(r.branch != nil && r.hasWorktree)
        branchIcon.strokeColor = SB.c(\.mutedForeground, 0.4)
        provider.driver = r.providerIcon
        machine.kind = r.environmentMachine
        machine.isHidden = r.environmentMachine == nil
        machine.color = SB.c(\.sidebarMutedForeground, 0.7)
        terminal.count = r.terminalProcessCount
        prBadge.badge = r.pullRequestBadge
        setAccessibilityLabel([r.title, r.statusLabel, r.projectLabel].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = CGRect(x: 0, y: 2, width: w, height: 78)
        CATransaction.commit()
        let left: CGFloat = 10, right = w - 10, top: CGFloat = 10
        // Line 1: favicon, project, pin, status slot.
        var x = left
        if !monogram.isHidden { monogram.frame = NSRect(x: x, y: top + 2, width: 16, height: 16); x += 16 + 6 }
        var slotRight = right
        var slotLeft = right
        if !settleButton.isHidden {
            // `-mr-1` on Settle, buttons stretch to the 20px slot.
            let sw = settleButton.preferredWidth
            settleButton.frame = NSRect(x: right + 4 - sw, y: top, width: sw, height: 20)
            slotLeft = settleButton.frame.minX
            if !snoozeButton.isHidden {
                let zw = snoozeButton.preferredWidth
                snoozeButton.frame = NSRect(x: slotLeft - zw, y: top, width: zw, height: 20)
                slotLeft -= zw
            }
        }
        // Status label at rest (absolute and faded while actions show).
        var sx = slotRight
        if !duration.text.isEmpty {
            let dw = ceil(duration.textWidth)
            duration.frame = NSRect(x: sx - dw, y: top + 2, width: dw + 1, height: 16)
            sx -= dw + (statusLabel.text.isEmpty ? 0 : 4)
        }
        if !statusLabel.text.isEmpty {
            let lw = ceil(statusLabel.textWidth)
            statusLabel.frame = NSRect(x: sx - lw, y: top + 2, width: lw + 1, height: 16)
            sx -= lw
            if statusIcon.icon != nil { statusIcon.frame = NSRect(x: sx - 4 - 16, y: top + 2, width: 16, height: 16); sx -= 20 }
        }
        let restWidth = max(32, slotRight - sx) // `min-w-8`
        if settleButton.isHidden { slotLeft = slotRight - restWidth }
        slotRight = slotLeft
        if !pin.isHidden { pin.frame = NSRect(x: slotRight - 6 - 12, y: top + 4, width: 12, height: 12); slotRight -= 18 }
        project.frame = NSRect(x: x, y: top + 2, width: max(0, slotRight - 6 - x), height: 16)
        // Line 2: title, `mt-1`.
        title.frame = NSRect(x: left, y: top + 24, width: right - left, height: 20)
        // Line 3: branch and provider, `mt-0.5`, text-xs.
        let y3 = top + 46
        provider.frame = NSRect(x: right - 14, y: y3 + 1, width: 14, height: 14)
        // `ml-auto gap-1`: the machine sits 4pt left of the provider.
        var trailing = right - 14
        if !machine.isHidden { machine.frame = NSRect(x: trailing - 4 - 14, y: y3 + 1, width: 14, height: 14); trailing -= 18 }
        // The terminal glyph follows the branch, `gap-1.5` before the provider group.
        if !prBadge.isHidden {
            let pw = prBadge.preferredWidth
            prBadge.frame = NSRect(x: trailing - 6 - pw, y: y3, width: pw, height: 16); trailing -= pw + 6
        }
        if !terminal.isHidden { terminal.frame = NSRect(x: trailing - 6 - 14, y: y3 + 1, width: 14, height: 14); trailing -= 20 }
        var bx = left
        if !branchIcon.isHidden { branchIcon.frame = NSRect(x: bx, y: y3 + 2, width: 12, height: 12); bx += 18 }
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
    private var actionButton: RowActionButton?
    private var actionKind: SidebarRowModel.Action?
    var actions = SidebarRowActions()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "borderColor": NSNull()]
        surface.cornerRadius = 8
        layer?.addSublayer(surface)
        for v in [monogram, title, pin, terminal, prBadge, time] as [NSView] { addSubview(v) }
        prBadge.onClick = { [weak self] in if case .row(let r)? = self?.item { self?.actions.pullRequest(r.id) } }
        title.lineHeight = 20
        time.font = SB.tabular(12); time.lineHeight = 16
        pin.action = { [weak self] in if case .row(let r)? = self?.item { self?.actions.unpin(r.id) } }
        onContextMenu = { [weak self] id, event in if let self { self.actions.contextMenu(id, event, self) } }
    }

    var row: SidebarRowModel? { if case .row(let r)? = item { r } else { nil } }

    override func refresh() {
        guard let r = row else { return }
        let hovered = state.hovered || isKeyboardFocused
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.backgroundColor = r.isActive ? SB.c(\.sidebarRowActive).cgColor(in: self)
            : state.hovered ? SB.c(\.sidebarRowHover).cgColor(in: self) : nil
        surface.borderWidth = isKeyboardFocused ? 2 : 0
        surface.borderColor = SB.c(\.ring).cgColor(in: self)
        CATransaction.commit()
        let unsettle = r.action == .unsettle
        // Dimmed favicon at rest, restored on hover.
        let dim = (!r.isActive || unsettle) && !hovered
        monogram.projectTitle = r.projectTitle ?? r.projectLabel ?? ""
        monogram.source = r.projectIcon
        monogram.dimmed = dim
        monogram.alphaValue = dim ? 0.4 : 1
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
        pin.isHidden = !r.isPinned
        terminal.count = r.terminalProcessCount
        prBadge.badge = r.pullRequestBadge
        if let snooze = r.snoozeLabel {
            time.text = snooze
            time.color = SB.c(\.infoForeground)
        } else {
            time.text = r.timeLabel
            time.color = unsettle && !hovered ? SB.c(\.secondaryLabel, 0.7) : SB.c(\.secondaryLabel)
        }
        time.alphaValue = hovered && !r.isWoke ? 0 : 1
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
            actionButton = b
            actionKind = r.action
        }
        actionButton?.isHidden = !hovered
        setAccessibilityLabel(r.title)
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
        let slot = max(32, tw) // `min-w-8`
        let slotX = w - 10 - slot
        time.frame = NSRect(x: w - 10 - tw, y: (h - 16) / 2, width: tw + 1, height: 16)
        if let b = actionButton {
            let bw = b.preferredWidth
            b.frame = NSRect(x: w - 10 + 4 - bw, y: (h - 24) / 2, width: bw, height: 24) // `-mr-1`
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
    }
}

/// `SidebarSectionHeader` (Sidebar.tsx:789-830): `mx-0.5 h-8` around a CollapsibleSectionHeader.
final class SidebarShelfRowView: SidebarRowBase {
    let header = CollapsibleSectionHeaderView("")
    var onToggle: (@MainActor (SidebarShelf) -> Void)?

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
        header.tone = shelf == .snoozed ? .info : .muted
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
/// keyframe animation, so it runs in the render server without waking the app.
final class TerminalStatusGlyph: DSView {
    private let icon = IconView(name: .terminal, size: 14)

    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            isHidden = count == 0
            setAccessibilityLabel("\(count) terminal \(count == 1 ? "process" : "processes") running")
            updatePulse()
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
        updatePulse()
    }

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

    private func updatePulse() {
        let animate = count > 0 && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate, icon.layer?.animation(forKey: "pulse") == nil {
            icon.layer?.add(Self.pulse(), forKey: "pulse")
        } else if !animate {
            icon.layer?.removeAnimation(forKey: "pulse")
        }
    }
}
