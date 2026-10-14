import AppKit
import DesignSystem

/// The floating theme editor (ThemeEditorPanel.tsx:1118-1312): `dialog-glass fixed bottom-4 right-4 w-[min(26rem,100vw-2rem)]
/// max-h-[min(42rem,100dvh-6rem)] rounded-xl border`, a draggable header, the scrolling form, the footer and a
/// corner resize grip.
final class ThemeEditorPanelView: DSView {
    let controller: ThemeEditorController
    private let decoration = BoxDecorationLayer()
    private let header = ThemeEditorHeaderView()
    let body = ThemeEditorBodyView()
    private lazy var scroll = ScrollAreaView(documentView: body, scrollbars: .native) // ThemeEditorPanel.tsx:1251
    private let footer = ThemeEditorFooterView()
    private let grip = ThemeEditorResizeGripView()
    private var lines: [CALayer] = [CALayer(), CALayer()]
    /// A dragged spot (top-left, in the host's top-down coordinates) and a grip size; nil keeps the defaults.
    private var position: CGPoint?
    private var size: CGSize?
    private var dragOffset: CGPoint?
    private var resizeStart: (pointer: CGPoint, size: CGSize, origin: CGPoint)?
    private var inspectMonitor: Any?
    private var frameObserver: NSObjectProtocol?
    /// Off for a panel drawn on its own (the fidelity test); on, it keeps itself in the window's corner.
    var placesInHost = true

    init(controller: ThemeEditorController) {
        self.controller = controller
        super.init(frame: .zero)
        decoration.host = self
        decoration.outset = 96
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        for l in lines { layer?.addSublayer(l) }
        addSubview(scroll)
        addSubview(header)
        addSubview(footer)
        addSubview(grip)
        setAccessibilityRole(.group)
        header.close.action = { [weak controller] in controller?.close() }
        header.minimize.action = { [weak self] in
            guard let self else { return }
            self.controller.isMinimized.toggle()
            self.update(structure: false)
        }
        header.inspect.action = { [weak controller] in
            guard let controller else { return }
            controller.setInspecting(!controller.isInspecting)
        }
        footer.cancel.action = { [weak controller] in controller?.close() }
        footer.submit.action = { [weak controller] in controller?.submit() }
        body.controller = controller
        restyle()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        guard let superview else { return }
        superview.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: superview, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        place()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        // ponytail: `dialog-glass` blurs what is behind at --glass-opacity; drawn as solid --background like DialogView
        var box = BoxStyle()
        box.radius = 12
        box.fill = WindowGlass.paneFill
        box.border = Themed.pick(light: Themed.color(\.contrastForeground, 0.1), dark: Themed.white(0.08))
        box.shadows = [
            BoxShadow(y: 1, color: Themed.pick(light: .clear, dark: Themed.white(0.04)), inset: true),
            BoxShadow(y: 24, blur: 64, spread: -24, color: Themed.pick(light: Themed.black(0.65), dark: .clear)),
            BoxShadow(y: 24, blur: 72, spread: -20, color: Themed.pick(light: .clear, dark: Themed.black(0.9))),
        ]
        decoration.boxStyle = box
        for l in lines { l.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self) }
    }

    // MARK: State

    /// Re-reads the draft. `structure` rebuilds the color fields (appearance, Advanced, filter); otherwise the
    /// fields update in place so typing keeps focus.
    func update(structure: Bool) {
        let c = controller
        header.title = c.editing == nil ? "Create theme" : "Edit theme"
        header.subtitle.text = c.isMinimized ? "" : c.isInspecting ? "Select an element · Esc to cancel"
            : c.selectedRole.map { r in c.isAdvanced ? (ThemeEditorFamily.of(r)?.label ?? ThemeEditorFamily.roleLabel(r)) : ThemeEditorFamily.roleLabel(r) }
            ?? "Select a color below"
        header.setInspecting(c.isInspecting)
        header.minimize.icon = c.isMinimized ? .chevronUp : .chevronDown
        header.minimize.setAccessibilityLabel(c.isMinimized ? "Expand the theme editor" : "Minimize the theme editor")
        setAccessibilityLabel(c.editing == nil ? "Create theme" : "Edit theme")
        let s = c.submitTitle
        footer.submit.title = s.title
        footer.submit.icon = s.icon
        footer.submit.isEnabled = !c.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        footer.needsLayout = true
        body.update(structure: structure)
        updateInspector()
        place()
    }

    func focusName() { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self?.body.name) } }
    func reveal(_ role: ThemeColorRole) {
        layoutSubtreeIfNeeded()
        if let f = body.field(for: role) { scroll.scroll(to: NSPoint(x: 0, y: max(0, f.frame.minY - 8))) }
    }
    func closePopups() { body.closePicker() }

    // MARK: Geometry

    private var hostSize: CGSize { superview?.bounds.size ?? .zero }

    private func contentHeight(width: CGFloat) -> CGFloat {
        1 + 41 + (controller.isMinimized ? 0 : body.height(forWidth: width - 2 - 18) + 45) + 1
    }

    /// Clamps like ThemeEditorPanel.tsx:350-381 and positions the panel.
    func place() {
        guard placesInHost, let host = superview else { return }
        let H = hostSize
        let margin: CGFloat = 8
        var w = min(416, H.width - 32)
        var maxH = min(672, H.height - 96)
        if let s = size {
            w = max(280, min(s.width, H.width - margin * 2))
            maxH = H.height - 16
        }
        var h = min(contentHeight(width: w), maxH)
        if let s = size, !controller.isMinimized { h = max(220, min(s.height, H.height - margin * 2)) }
        var origin: CGPoint
        if let p = position {
            origin = CGPoint(x: min(max(p.x, margin), max(margin, H.width - w - margin)),
                             y: min(max(p.y, margin), max(margin, H.height - h - margin)))
        } else {
            origin = CGPoint(x: H.width - w - 16, y: H.height - h - 16)
        }
        let y = host.isFlipped ? origin.y : H.height - origin.y - h
        frame = NSRect(x: origin.x, y: y, width: w, height: h).integral
        needsLayout = true
    }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let w = bounds.width
        header.frame = NSRect(x: 1, y: 1, width: w - 2, height: 40)
        lines[0].frame = NSRect(x: 1, y: 41, width: w - 2, height: 1)
        let minimized = controller.isMinimized
        scroll.isHidden = minimized
        footer.isHidden = minimized
        grip.isHidden = minimized
        lines[1].isHidden = minimized
        guard !minimized else { return }
        let footerY = bounds.height - 1 - 45
        footer.frame = NSRect(x: 1, y: footerY + 1, width: w - 2, height: 44)
        lines[1].frame = NSRect(x: 1, y: footerY, width: w - 2, height: 1)
        scroll.frame = NSRect(x: 1, y: 42, width: w - 2, height: footerY - 42)
        body.frame = NSRect(x: 0, y: 0, width: w - 2, height: body.height(forWidth: w - 2 - 18))
        grip.frame = NSRect(x: w - 20, y: bounds.height - 20, width: 20, height: 20)
    }

    // MARK: Dragging and resizing

    private func hostPoint(_ event: NSEvent) -> CGPoint {
        guard let host = superview else { return .zero }
        let p = host.convert(event.locationInWindow, from: nil)
        return host.isFlipped ? p : CGPoint(x: p.x, y: host.bounds.height - p.y)
    }

    private var topLeft: CGPoint {
        guard let host = superview else { return .zero }
        return CGPoint(x: frame.minX, y: host.isFlipped ? frame.minY : host.bounds.height - frame.maxY)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let p = hostPoint(event)
        if grip.frame.contains(local), !grip.isHidden {
            position = topLeft
            resizeStart = (p, frame.size, topLeft)
        } else if local.y <= 41 {
            dragOffset = CGPoint(x: p.x - topLeft.x, y: p.y - topLeft.y)
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = hostPoint(event)
        if let o = dragOffset {
            position = CGPoint(x: p.x - o.x, y: p.y - o.y)
            place()
        } else if let r = resizeStart {
            let margin: CGFloat = 8
            let maxW = max(280, hostSize.width - margin - r.origin.x), maxH = max(220, hostSize.height - margin - r.origin.y)
            size = CGSize(width: min(max(r.size.width + p.x - r.pointer.x, 280), maxW), height: min(max(r.size.height + p.y - r.pointer.y, 220), maxH))
            place()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragOffset != nil { NSCursor.pop() }
        dragOffset = nil
        resizeStart = nil
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: 41), cursor: .openHand)
        if !grip.isHidden { addCursorRect(grip.frame, cursor: .crosshair) }
    }

    // MARK: Inspect

    /// While inspecting, a click elsewhere in the window picks the color under the pointer; Escape cancels.
    private func updateInspector() {
        if controller.isInspecting, inspectMonitor == nil {
            inspectMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                let used = MainActor.assumeIsolated { self?.inspectEvent(event) ?? false }
                return used ? nil : event
            }
        } else if !controller.isInspecting, let m = inspectMonitor {
            NSEvent.removeMonitor(m)
            inspectMonitor = nil
        }
    }

    /// True when the event was used.
    private func inspectEvent(_ event: NSEvent) -> Bool {
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false }
            controller.setInspecting(false)
            return true
        }
        guard event.window === window, let content = window?.contentView else { return false }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { return false }
        let p = content.convert(event.locationInWindow, from: nil)
        let rect = NSRect(x: floor(p.x), y: floor(p.y), width: 1, height: 1)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return true }
        content.cacheDisplay(in: rect, to: rep)
        if let color = rep.colorAt(x: 0, y: 0) { controller.inspect(color: color) }
        return true
    }

    override func removeFromSuperview() {
        if let m = inspectMonitor { NSEvent.removeMonitor(m); inspectMonitor = nil }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        super.removeFromSuperview()
    }
}

/// The header: title, subtitle, Inspect, minimize and close (ThemeEditorPanel.tsx:1144-1212).
final class ThemeEditorHeaderView: DSView {
    private let titleLabel = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.popoverForeground))
    let subtitle = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let inspect = ButtonView("Inspect", icon: .mousePointer2, variant: .ghost, size: .xs)
    let minimize = ButtonView(nil, icon: .chevronDown, variant: .ghost, size: .iconXs)
    let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    private let inspectTip: TooltipController

    var title: String {
        get { titleLabel.text }
        set { titleLabel.text = newValue; needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        inspectTip = TooltipController.attach(to: inspect, text: "Pick a color from the app")
        super.init(frame: frameRect)
        titleLabel.lineHeight = 20
        subtitle.lineHeight = 16
        for v in [titleLabel, subtitle, inspect, minimize, close] as [NSView] { addSubview(v) }
        close.setAccessibilityLabel("Close the theme editor")
        inspect.setAccessibilityLabel("Inspect app colors")
    }

    func setInspecting(_ on: Bool) {
        inspect.title = on ? "Cancel" : "Inspect"
        inspect.variant = on ? .secondary : .ghost
        inspect.setAccessibilityLabel(on ? "Cancel inspecting app colors" : "Inspect app colors")
        inspectTip.text = on ? "Cancel and clear the selection" : "Pick a color from the app"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // `px-3 py-2`, buttons `gap-1` at the end.
        var x = bounds.width - 12
        for b in [close, minimize, inspect] {
            let w = b.intrinsicContentSize.width
            x -= w
            b.frame = NSRect(x: x, y: 8, width: w, height: 24)
            x -= 4
        }
        let titleWidth = min(ceil(titleLabel.textWidth) + 1, x - 12)
        titleLabel.frame = NSRect(x: 12, y: 10, width: titleWidth, height: 20)
        // `items-baseline`: the 12px line sits 2.7px lower than the 14px one.
        let subX = 12 + titleWidth + 8
        subtitle.frame = NSRect(x: subX, y: 12.5, width: max(0, x + 4 - 4 - subX), height: 16)
    }
}

/// The footer (`flex justify-end gap-2 border-t px-3 py-2`): Cancel and the submit button.
final class ThemeEditorFooterView: DSView {
    let cancel = ButtonView("Cancel", variant: .ghost, size: .sm)
    let submit = ButtonView("Create theme", icon: .paintbrush, variant: .default, size: .sm)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(cancel)
        addSubview(submit)
    }
    override func layout() {
        super.layout()
        let s = submit.intrinsicContentSize.width, c = cancel.intrinsicContentSize.width
        submit.frame = NSRect(x: bounds.width - 12 - s, y: 8, width: s, height: 28)
        cancel.frame = NSRect(x: submit.frame.minX - 8 - c, y: 8, width: c, height: 28)
    }
}

/// The corner grip (`size-5 p-1 text-muted-foreground/70`, an 8x8 two-stroke glyph at `size-2.5`).
final class ThemeEditorResizeGripView: DSView {
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let s: CGFloat = 10 / 8
        let o = CGPoint(x: bounds.width - 4 - 10, y: bounds.height - 4 - 10)
        let p = NSBezierPath()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        p.move(to: pt(7, 1)); p.line(to: pt(1, 7))
        p.move(to: pt(7, 4.5)); p.line(to: pt(4.5, 7))
        p.lineWidth = 1.2 * s
        p.lineCapStyle = .round
        Themed.color(\.mutedForeground, 0.7).setStroke()
        p.stroke()
    }
}

/// The scrolling form (`space-y-3 py-3 pl-3 pr-1.5`): name, error, appearance, the colors header and fields.
final class ThemeEditorBodyView: DSView {
    weak var controller: ThemeEditorController?
    let name = InputView(placeholder: "e.g. Aurora", size: .sm)
    private let nameLabel = LabelView("Theme name", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.popoverForeground))
    private let error = TextBlockView()
    private let appearanceLabel = LabelView("Appearance", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.popoverForeground))
    private let appearanceToggle = ToggleGroupView(variant: .segmented, items: [("Light", nil), ("Dark", nil)], selected: 0)
    private let colorsTitle = LabelView("Colors", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.popoverForeground))
    private let colorsNote = TextBlockView()
    private let filter = InputView(placeholder: "Filter colors", size: .sm)
    private let advancedLabel = LabelView("Advanced", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.popoverForeground))
    private let advanced = SwitchView(isOn: false)
    private var groupTitles: [LabelView] = []
    private var fields: [ThemeColorFieldView] = []
    private let noMatches = LabelView("No matches.", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private var appearanceTips: [TooltipController] = []
    private var structureKey = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [nameLabel, appearanceLabel, colorsTitle, advancedLabel] { l.lineHeight = 20 }
        colorsNote.text = "Two colors, rest derived"
        colorsNote.font = DSFont.ui(12)
        colorsNote.lineHeight = 16
        colorsNote.color = Themed.color(\.mutedForeground)
        noMatches.lineHeight = 16
        error.font = DSFont.ui(14)
        error.lineHeight = 20
        error.color = Themed.color(\.destructive)
        for v in [nameLabel, name, error, appearanceLabel, appearanceToggle, colorsTitle, colorsNote, filter, advancedLabel, advanced, noMatches] as [NSView] {
            addSubview(v)
        }
        name.setAccessibilityLabel("Theme name")
        filter.setAccessibilityLabel("Filter colors")
        advanced.setAccessibilityLabel("Use advanced theme colors")
        appearanceToggle.setAccessibilityLabel("Theme appearance")
        // Only typing counts: setting `text` from the draft also reports a change.
        name.onChange = { [weak self] t in if self?.name.state.focused == true { self?.controller?.setName(t) } }
        name.onSubmit = { [weak self] in self?.controller?.submit() }
        filter.onChange = { [weak self] t in if self?.filter.state.focused == true { self?.controller?.setQuery(t) } }
        advanced.onChange = { [weak self] on in self?.controller?.setAdvanced(on) }
        appearanceToggle.onChange = { [weak self] i in
            guard let self, let c = self.controller else { return }
            let a: ThemeAppearance = i == 1 ? .dark : .light
            if let i, c.lockReason(a) == nil { c.setAppearance(i == 1 ? .dark : .light) }
            self.appearanceToggle.selectedIndex = c.active == .dark ? 1 : 0
        }
        for (i, item) in appearanceToggle.items.enumerated() {
            appearanceTips.append(TooltipController.attach(to: item, text: ""))
            _ = i
        }
    }

    /// The fields on screen for the draft (`renderColorFields`).
    private func visibleFamilies(_ c: ThemeEditorController) -> [(title: String?, families: [ThemeEditorFamily])] {
        guard c.isAdvanced else {
            return [(nil, [ThemeEditorFamily(id: "canvas", label: "Background", role: .canvas, roles: [.canvas]),
                           ThemeEditorFamily(id: "accent", label: "Accent", role: .accent, roles: [.accent])])]
        }
        let q = c.roleQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return ThemeEditorFamily.groups.compactMap { g in
            let f = g.families.filter { q.isEmpty || ([$0.label] + $0.roles.map(ThemeEditorFamily.roleLabel)).joined(separator: " ").lowercased().contains(q) }
            return f.isEmpty ? nil : (g.title, f)
        }
    }

    func update(structure: Bool) {
        guard let c = controller else { return }
        if !name.state.focused || name.text != c.name { if name.text != c.name { name.text = c.name } }
        error.text = c.error ?? ""
        error.isHidden = c.error == nil
        appearanceToggle.selectedIndex = c.active == .dark ? 1 : 0
        for (i, a) in [ThemeAppearance.light, .dark].enumerated() {
            let reason = c.lockReason(a)
            appearanceToggle.items[i].alphaValue = reason == nil ? 1 : 0.64
            appearanceTips[i].text = reason ?? ""
        }
        advanced.isOn = c.isAdvanced
        colorsNote.isHidden = c.isAdvanced
        filter.isHidden = !c.isAdvanced
        if filter.text != c.roleQuery { filter.text = c.roleQuery }
        let visible = visibleFamilies(c)
        let key = "\(c.isAdvanced)|\(c.active)|" + visible.map { ($0.title ?? "") + ":" + $0.families.map(\.id).joined(separator: ",") }.joined(separator: ";")
        if key != structureKey {
            structureKey = key
            closePicker()
            fields.forEach { $0.removeFromSuperview() }
            groupTitles.forEach { $0.removeFromSuperview() }
            fields = []
            groupTitles = []
            for g in visible {
                if let title = g.title {
                    let l = LabelView(title, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
                    l.lineHeight = 20
                    groupTitles.append(l)
                    addSubview(l)
                }
                for f in g.families {
                    let field = ThemeColorFieldView(role: f.role, label: f.label)
                    field.onChange = { [weak c] role, value in c?.updateColor(role, value) }
                    field.onSelect = { [weak c] role in c?.selectRole(role) }
                    field.onToggle = { [weak c] role in c?.toggleRole(role) }
                    fields.append(field)
                    addSubview(field)
                }
            }
            noMatches.isHidden = !(c.isAdvanced && visible.isEmpty)
            needsLayout = true
        }
        for f in fields {
            f.value = c.colors[c.active]?[f.role] ?? ""
            f.isSelected = c.selectedRole == f.role
        }
    }

    func field(for role: ThemeColorRole) -> NSView? { fields.first { $0.role == role } }
    func closePicker() { fields.forEach { $0.closePicker() } }

    // Layout: `pl-3 pr-1.5`, two-column rows `grid-cols-[minmax(0,1fr)_minmax(0,2fr)] gap-3`.
    func height(forWidth width: CGFloat) -> CGFloat { layoutRows(width: width + 18, apply: false) }

    override func layout() {
        super.layout()
        _ = layoutRows(width: bounds.width, apply: true)
    }

    private func layoutRows(width: CGFloat, apply: Bool) -> CGFloat {
        guard let c = controller else { return 0 }
        let x0: CGFloat = 12, inner = width - 12 - 6
        let col = (inner - 12) / 3
        var y: CGFloat = 12
        func place(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        place(nameLabel, NSRect(x: x0, y: y + 4, width: col, height: 20))
        place(name, NSRect(x: x0 + col + 12, y: y, width: inner - col - 12, height: 28))
        y += 28 + 12
        if c.error != nil {
            let h = error.height(forWidth: inner)
            place(error, NSRect(x: x0, y: y, width: inner, height: h))
            y += h + 12
        }
        place(appearanceLabel, NSRect(x: x0, y: y + 4, width: col, height: 20))
        let seg = appearanceToggle.intrinsicContentSize
        place(appearanceToggle, NSRect(x: x0 + col + 12, y: y, width: seg.width, height: seg.height))
        y += 28 + 12
        // Colors header (`items-start`): the title block left, the filter and Advanced switch right.
        place(colorsTitle, NSRect(x: x0, y: y, width: col, height: 20))
        // The note wraps in its column (`text-xs`, no truncation).
        let noteHeight = c.isAdvanced ? 0 : colorsNote.height(forWidth: col)
        place(colorsNote, NSRect(x: x0, y: y + 20, width: col, height: noteHeight))
        let sw = advanced.intrinsicContentSize
        let advWidth = ceil(advancedLabel.textWidth) + 1 + 8 + sw.width
        let right = x0 + inner
        place(advancedLabel, NSRect(x: right - advWidth, y: y + 2, width: ceil(advancedLabel.textWidth) + 1, height: 20))
        place(advanced, NSRect(x: right - sw.width, y: y + 2 + (20 - sw.height) / 2, width: sw.width, height: sw.height))
        if c.isAdvanced {
            place(filter, NSRect(x: x0 + col + 12, y: y, width: max(0, right - advWidth - 12 - (x0 + col + 12)), height: 28))
        }
        y += max(c.isAdvanced ? 28 : 0, 20 + noteHeight) + 12
        if c.isAdvanced {
            var fi = 0, gi = 0
            let visible = visibleFamilies(c)
            for (n, g) in visible.enumerated() {
                if n > 0 { y += 20 }
                if gi < groupTitles.count { place(groupTitles[gi], NSRect(x: x0, y: y, width: inner, height: 20)) }
                gi += 1
                y += 20 + 8
                for (k, _) in g.families.enumerated() {
                    if k > 0 { y += 4 }
                    if fi < fields.count { place(fields[fi], NSRect(x: x0, y: y, width: inner, height: 44)) }
                    fi += 1
                    y += 44
                }
            }
            if visible.isEmpty { place(noMatches, NSRect(x: x0, y: y, width: inner, height: 16)); y += 16 }
        } else {
            for (k, f) in fields.enumerated() {
                if k > 0 { y += 4 }
                place(f, NSRect(x: x0, y: y, width: inner, height: 44))
                y += 44
            }
        }
        return y + 12
    }
}

/// `ThemeColorField` (ThemeColorPicker.tsx:290-368): the label (a toggle for the role's highlight), the swatch
/// that opens the picker, and the hex input.
final class ThemeColorFieldView: DSView {
    let role: ThemeColorRole
    let label: String
    var onChange: ((ThemeColorRole, String) -> Void)?
    var onSelect: ((ThemeColorRole) -> Void)?
    var onToggle: ((ThemeColorRole) -> Void)?
    var value = "" { didSet { if value != oldValue { show() } } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private let title = ThemeFieldLabelButton()
    private let swatch = ThemeSwatchButton()
    private let input = InputView(placeholder: "", size: .compact, font: .mono)
    private var picker: OpenPopup?
    private var pickerPanel: ThemeColorPickerPanelView?

    init(role: ThemeColorRole, label: String) {
        self.role = role
        self.label = label
        super.init(frame: .zero)
        title.text = label
        title.action = { [weak self] in guard let self else { return }; self.onToggle?(self.role) }
        swatch.action = { [weak self] in self?.openPicker() }
        swatch.setAccessibilityLabel("Choose \(label) color")
        TooltipController.attach(to: swatch, text: "Choose \(label) color", placement: PopupPlacement(side: .top))
        input.setAccessibilityLabel("\(label) hex value")
        input.onChange = { [weak self] t in guard let self, self.input.state.focused else { return }; self.onChange?(self.role, t) }
        input.onStateChange = { [weak self] s in guard let self, s.focused else { return }; self.onSelect?(self.role) }
        addSubview(title)
        addSubview(swatch)
        addSubview(input)
    }

    override var wantsUpdateLayer: Bool { false }

    /// `bg-accent/60 inset-ring inset-ring-ring` when selected.
    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        let p = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        Themed.color(\.accent, 0.6).setFill()
        p.fill()
        Themed.color(\.ring).setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
        ring.lineWidth = 1
        ring.stroke()
    }

    private func show() {
        let valid = ThemePalette.isThemeColor(value)
        swatch.color = valid ? ThemeCSSColor.nsColor(value) ?? .black : .black
        input.isInvalid = !valid
        // An oklch value shows as hex in the field (`editorValue`).
        let shown = value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("oklch(") ? (ThemePalette.hex(value) ?? value) : value
        if !input.state.focused, input.text != shown { input.text = shown }
        pickerPanel?.setValue(valid ? value : "#000000")
    }

    override func layout() {
        super.layout()
        // `px-2 py-1.5 gap-2`: the input `w-28`, the swatch `size-6` before it.
        let iw: CGFloat = 112
        input.frame = NSRect(x: bounds.width - 8 - iw, y: (bounds.height - 30) / 2, width: iw, height: 30)
        swatch.frame = NSRect(x: input.frame.minX - 8 - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
        title.frame = NSRect(x: 8, y: (bounds.height - 20) / 2, width: min(title.intrinsicContentSize.width, swatch.frame.minX - 8 - 8), height: 20)
    }

    private func openPicker() {
        onSelect?(role)
        if picker != nil { closePicker(); return }
        let panel = ThemeColorPickerPanelView(label: label)
        panel.setValue(ThemePalette.isThemeColor(value) ? value : "#000000")
        panel.onChange = { [weak self] v in guard let self else { return }; self.onChange?(self.role, v) }
        pickerPanel = panel
        let pop = PopoverView(content: panel, padding: .none, width: .auto)
        picker = pop.show(from: swatch, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 10))
        picker?.onClose = { [weak self] in self?.picker = nil; self?.pickerPanel = nil }
    }

    func closePicker() {
        if let picker, let window = swatch.window { PopupHost.host(for: window).close(picker, returnFocus: false) }
        picker = nil
        pickerPanel = nil
    }
}

/// The field's label button (`flex-1 truncate text-sm text-muted-foreground hover:text-foreground`).
final class ThemeFieldLabelButton: ControlView {
    private let label = LabelView("", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    var text: String { get { label.text } set { label.text = newValue } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 20
        addSubview(label)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1, height: 20) }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        label.color = state.hovered ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
    }
    override func layout() { super.layout(); label.frame = bounds }
}

/// The swatch (`size-6 rounded-full border border-foreground/30`, the color `inset-0 shadow-sm`, `hover:scale-105`).
final class ThemeSwatchButton: ControlView {
    var color: NSColor = .black { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); scalesWhenPressed = false }
    override var wantsUpdateLayer: Bool { false }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let s: CGFloat = state.hovered ? 1.05 : 1
        let r = NSRect(x: bounds.midX - 12 * s, y: bounds.midY - 12 * s, width: 24 * s, height: 24 * s)
        Themed.color(\.foreground, 0.3).setStroke()
        NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.05)
        shadow.set()
        color.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// `ThemeColorPickerPanel` (ThemeColorPicker.tsx:83-232): saturation and value plane, hue slider, hex and RGB
/// fields. The picker is an sRGB hex adapter; alpha is kept and re-attached.
final class ThemeColorPickerPanelView: DSView {
    var onChange: ((String) -> Void)?
    private let title: LabelView
    private let subtitle = LabelView("Choose a color", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private let current = ThemeSwatchDot(size: 28)
    private let plane = ColorSaturationValuePlaneView()
    private let hue = ColorHueSliderView()
    private let hexLabel = TrackedCaption("HEX"), rgbLabel = TrackedCaption("RGB")
    private let hexBox = ThemeMonoFieldBox(dot: true), rgbBox = ThemeMonoFieldBox(dot: false)
    private var hsv = (h: 0.0, s: 0.0, v: 0.0)
    private var alphaSuffix = ""
    private let headerLine = CALayer()

    init(label: String) {
        title = LabelView(label, font: DSFont.ui(12, weight: .semibold), color: Themed.color(\.foreground))
        super.init(frame: NSRect(x: 0, y: 0, width: 288, height: 0))
        title.lineHeight = 16
        subtitle.lineHeight = 16
        layer?.addSublayer(headerLine)
        for v in [title, subtitle, current, plane, hue, hexLabel, rgbLabel, hexBox, rgbBox] as [NSView] { addSubview(v) }
        plane.setAccessibilityLabel(label)
        hue.setAccessibilityLabel("\(label) hue")
        hexBox.input.setAccessibilityLabel("\(label) picker hex value")
        rgbBox.input.setAccessibilityLabel("\(label) picker RGB value")
        plane.onChange = { [weak self] s, v in guard let self else { return }; self.commit((self.hsv.h, s, v)) }
        hue.onChange = { [weak self] h in guard let self else { return }; self.commit((h, self.hsv.s, self.hsv.v)) }
        hexBox.input.onChange = { [weak self] t in if self?.hexBox.input.state.focused == true { self?.typedHex(t) } }
        rgbBox.input.onChange = { [weak self] t in if self?.rgbBox.input.state.focused == true { self?.typedRGB(t) } }
        for box in [hexBox, rgbBox] {
            box.input.onStateChange = { [weak self] s in if !s.focused { self?.syncFields(force: true) } }
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 288, height: Self.height) }
    override var fittingSize: NSSize { intrinsicContentSize }
    /// Header `py-3` (16px lines) plus a border, body `pt-3 pb-3 gap-3`: plane 128, hue 24, the field column.
    static let height: CGFloat = (12 + 32 + 12 + 1) + 12 + 128 + 12 + 24 + 12 + (14 + 4 + 34) + 12

    private var currentHex: String { Self.hsvToHex(hsv.h, hsv.s, hsv.v) }

    /// The incoming value; keeps hue and saturation when it is our own change echoed back.
    func setValue(_ value: String) {
        let hex = String((ThemePalette.hex(value) ?? "#000000").prefix(7))
        let full = ThemePalette.hex(value) ?? ""
        alphaSuffix = full.count == 9 && !full.hasSuffix("ff") ? String(full.suffix(2)) : ""
        if currentHex != hex { hsv = Self.hexToHsv(hex) }
        apply()
        syncFields(force: false)
    }

    private func commit(_ next: (h: Double, s: Double, v: Double)) {
        hsv = next
        apply()
        syncFields(force: true)
        onChange?(currentHex + alphaSuffix)
    }

    private func typedHex(_ t: String) {
        guard t.wholeMatch(of: #/#[0-9a-fA-F]{6}/#) != nil else { return }
        hsv = Self.hexToHsv(t.lowercased())
        apply()
        rgbBox.input.text = Self.rgb(t)
        onChange?(t.lowercased())
    }

    private func typedRGB(_ t: String) {
        let parts = t.trimmingCharacters(in: .whitespaces).replacing(#/(?i)^rgb\(\s*/#, with: "").replacing(#/\s*\)$/#, with: "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { return }
        let hex = "#" + parts.map { String(format: "%02x", $0) }.joined()
        hsv = Self.hexToHsv(hex)
        apply()
        hexBox.input.text = hex
        onChange?(hex + alphaSuffix)
    }

    private func apply() {
        plane.hue = hsv.h
        plane.saturation = hsv.s
        plane.value = hsv.v
        hue.hue = hsv.h
        let c = ThemeCSSColor.nsColor(currentHex) ?? .black
        current.color = c
        hexBox.dot.color = c
    }

    private func syncFields(force: Bool) {
        if force || !hexBox.input.state.focused { hexBox.input.text = currentHex }
        if force || !rgbBox.input.state.focused { rgbBox.input.text = Self.rgb(currentHex) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        headerLine.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
    }

    override func layout() {
        super.layout()
        headerLine.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
        let w = bounds.width
        title.frame = NSRect(x: 16, y: 12 + 0, width: w - 32 - 28 - 8, height: 16)
        subtitle.frame = NSRect(x: 16, y: 12 + 16, width: w - 32 - 28 - 8, height: 16)
        current.frame = NSRect(x: w - 16 - 28, y: 12 + 2, width: 28, height: 28)
        headerLine.frame = NSRect(x: 0, y: 56, width: w, height: 1)
        var y: CGFloat = 57 + 12
        plane.frame = NSRect(x: 12, y: y, width: w - 24, height: 128)
        y += 128 + 12
        hue.frame = NSRect(x: 12, y: y, width: w - 24, height: 24)
        y += 24 + 12
        // `grid-cols-[1fr_1.2fr] gap-2`.
        let col1 = (w - 24 - 8) / 2.2
        hexLabel.frame = NSRect(x: 12 + 4, y: y, width: col1 - 4, height: 14)
        rgbLabel.frame = NSRect(x: 12 + col1 + 8 + 4, y: y, width: col1 * 1.2 - 4, height: 14)
        hexBox.frame = NSRect(x: 12, y: y + 18, width: col1, height: 34)
        rgbBox.frame = NSRect(x: 12 + col1 + 8, y: y + 18, width: w - 24 - col1 - 8, height: 34)
    }

    static func rgb(_ hex: String) -> String {
        guard let n = Int(hex.dropFirst(), radix: 16) else { return "0, 0, 0" }
        return "\(n >> 16 & 255), \(n >> 8 & 255), \(n & 255)"
    }

    /// `hexToHsv` (lib/color.ts).
    static func hexToHsv(_ hex: String) -> (h: Double, s: Double, v: Double) {
        let n = Int(hex.dropFirst(), radix: 16) ?? 0
        let r = Double(n >> 16 & 255) / 255, g = Double(n >> 8 & 255) / 255, b = Double(n & 255) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d != 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    /// `hsvToHex` (lib/color.ts).
    static func hsvToHex(_ hue: Double, _ s: Double, _ v: Double) -> String {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double) = h < 60 ? (c, x, 0) : h < 120 ? (x, c, 0) : h < 180 ? (0, c, x) : h < 240 ? (0, x, c) : h < 300 ? (x, 0, c) : (c, 0, x)
        return "#" + [r, g, b].map { String(format: "%02x", Int(((($0 + m) * 255)).rounded(.toNearestOrAwayFromZero))) }.joined()
    }
}

/// A filled circle (`rounded-full shadow-sm`).
final class ThemeSwatchDot: DSView {
    var color: NSColor = .black { didSet { needsDisplay = true } }
    let diameter: CGFloat
    init(size: CGFloat) { diameter = size; super.init(frame: .zero) }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        if diameter > 14 {
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 2
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.05)
            shadow.set()
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// `px-1 text-3xs font-semibold uppercase tracking-widest text-muted-foreground`.
final class TrackedCaption: DSView {
    private let label: LabelView
    init(_ text: String) {
        label = LabelView(text, font: DSFont.ui(10, weight: .semibold), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        label.lineHeight = 14
        label.tracking = 1
        addSubview(label)
    }
    override func layout() { super.layout(); label.frame = bounds }
}

/// The picker's text field: `rounded-lg border border-input bg-background px-2` around an unstyled `h-8 font-mono
/// text-xs` input, with a `size-3.5` dot before the hex.
final class ThemeMonoFieldBox: DSView {
    let input = InputView(placeholder: "", size: .compact, font: .mono)
    let dot = ThemeSwatchDot(size: 14)
    private let decoration = BoxDecorationLayer()
    private let hasDot: Bool
    init(dot: Bool) {
        hasDot = dot
        super.init(frame: .zero)
        decoration.host = self
        layer?.addSublayer(decoration)
        input.unstyled = true
        input.fontWeight = .regular
        if dot { addSubview(self.dot) }
        addSubview(input)
        restyle()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    private func restyle() {
        var box = BoxStyle()
        box.radius = 8
        box.fill = WindowGlass.paneFill
        box.border = Themed.color(\.input)
        decoration.boxStyle = box
    }
    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        var x: CGFloat = 1 + 8
        if hasDot {
            dot.frame = NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14)
            x += 14 + 8
        }
        input.paddingOverride = (0, 0)
        input.frame = NSRect(x: x, y: 1, width: bounds.width - x - 9, height: 32)
    }
}
