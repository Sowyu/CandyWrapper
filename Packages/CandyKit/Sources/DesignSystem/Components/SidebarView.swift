import AppKit

/// T3's sidebar shell (`components/ui/sidebar.tsx` with the app wiring in AppSidebarLayout.tsx and
/// threadSidebarWidth.ts): side left, variant sidebar, collapsible offcanvas, resizable.
/// Spec: docs/research/recovered/ui-components-b.md 19.1-19.7.
public enum SidebarMetrics {
    /// `SIDEBAR_WIDTH`, 16rem.
    public static let defaultWidth: CGFloat = 256
    /// `THREAD_SIDEBAR_MIN_WIDTH`, 13rem.
    public static let minWidth: CGFloat = 208
    /// `THREAD_MAIN_CONTENT_MIN_WIDTH`, 40rem: the main panel never gets narrower while growing.
    public static let mainContentMinWidth: CGFloat = 640
    /// `THREAD_SIDEBAR_WIDTH_STORAGE_KEY`. T3 keeps it in localStorage as a JSON number.
    public static let storageKey = "chat_thread_sidebar_width"
    /// `--workspace-controls-left` on windowed macOS (`--desktop-window-controls-inset`, 90px); 12px otherwise.
    public static func controlsLeft(windowedMac: Bool) -> CGFloat { windowedMac ? 90 : 12 }
    /// `--workspace-titlebar-control-size` (28px at >= 640px).
    public static let titlebarControlSize: CGFloat = 28
    /// `--workspace-titlebar-control-gap`.
    public static let titlebarControlGap: CGFloat = 12
    /// `--workspace-topbar-height`.
    public static let topbarHeight: CGFloat = 52
    /// `--workspace-titlebar-content-left`: 130px next to the traffic lights, 52px otherwise.
    public static func titlebarContentLeft(windowedMac: Bool) -> CGFloat {
        controlsLeft(windowedMac: windowedMac) + titlebarControlSize + titlebarControlGap
    }
    /// The rail: 16px hit area centred on the border's inner edge, a 2px line on hover.
    public static let railWidth: CGFloat = 16
}

/// Width rules from threadSidebarWidth.ts and the rail's drag (useResizeDrag.ts), plus persistence.
public struct SidebarWidth {
    public var minimum: CGFloat = SidebarMetrics.minWidth

    public init(brandWidth: CGFloat = 0) {
        minimum = max(SidebarMetrics.minWidth, brandWidth.rounded(.up))
    }

    public func maximum(viewport: CGFloat) -> CGFloat {
        max(minimum, viewport.rounded(.down) - SidebarMetrics.mainContentMinWidth)
    }

    public func clamp(_ width: CGFloat, viewport: CGFloat) -> CGFloat {
        min(maximum(viewport: viewport), max(minimum, width))
    }

    /// `resolveInitialThreadSidebarWidth`: stored width raised to 208, capped at viewport - 640.
    public static func initial(stored: CGFloat?, viewport: CGFloat) -> CGFloat {
        let preferred = stored.map { max(SidebarMetrics.minWidth, $0) } ?? SidebarMetrics.defaultWidth
        return min(preferred, SidebarWidth().maximum(viewport: viewport))
    }

    /// One drag step: clamp, then `shouldAcceptWidth` (shrinking always, growing only while the main panel keeps 640px).
    public func dragStep(current: CGFloat, proposed: CGFloat, viewport: CGFloat, wrapperWidth: CGFloat) -> CGFloat {
        let next = clamp(proposed, viewport: viewport)
        return next <= current || wrapperWidth - next >= SidebarMetrics.mainContentMinWidth ? next : current
    }

    public static func load(_ defaults: UserDefaults = .standard) -> CGFloat? {
        guard let value = defaults.object(forKey: SidebarMetrics.storageKey) as? Double, value.isFinite else { return nil }
        return CGFloat(value)
    }

    public static func save(_ width: CGFloat, _ defaults: UserDefaults = .standard) {
        defaults.set(Double(width), forKey: SidebarMetrics.storageKey)
    }

    public static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: SidebarMetrics.storageKey)
    }
}

/// `SidebarProvider` + `Sidebar` + `SidebarInset`: the sidebar container on the left (1px right border,
/// `bg-sidebar surface-grain`), the main panel filling the rest, and the rail between them.
/// Show and hide are instant at T3's default `panelAnimationDurationMs` of 0 and slide otherwise (`setOpen`).
public final class SidebarLayoutView: DSView {
    public let sidebar: SidebarContainerView
    public let main: GrainSurfaceView
    public let rail = SidebarRailView()
    public let defaults: UserDefaults

    public private(set) var isOpen = true
    /// The Glass theme's frost under everything, present only while it shows.
    private var glassBackdrop: WallpaperBackdropView?
    /// The Dither theme's picture in the main panel, present only while it shows.
    private var ditherArt: DitherArtView?
    /// Preferred width; the drawn width is this clamped to the window (`effectiveWidth`).
    public private(set) var width: CGFloat
    public var widthRules = SidebarWidth() { didSet { needsLayout = true } }
    public final var onOpenChange: (@MainActor (Bool) -> Void)?
    /// T3's fixed `SidebarTrigger` (AppSidebarLayout.tsx:137-163) while the sidebar is collapsed: the sidebar's own
    /// trigger slides away with it, so this one takes the same spot over the main area. It stays up through the
    /// open animation, until the sidebar's trigger is back underneath it.
    public let collapsedTrigger = SidebarTriggerView()

    public var effectiveWidth: CGFloat { widthRules.clamp(width, viewport: bounds.width) }

    /// The main column's page: the thread panel, Settings or a utility page. Setting it takes the others out.
    public var mainContent: NSView? {
        get { main.subviews.first { !($0 is DitherArtView) } }
        set {
            for view in main.subviews where view !== newValue && !(view is DitherArtView) { view.removeFromSuperview() }
            if let newValue, newValue.superview !== main { main.addSubview(newValue) }
            needsLayout = true
        }
    }

    public init(sidebarContent: NSView? = nil, mainContent: NSView? = nil, defaults: UserDefaults = .standard, viewport: CGFloat = 1100) {
        self.defaults = defaults
        sidebar = SidebarContainerView()
        main = GrainSurfaceView(fill: WindowGlass.mainSurface)
        width = SidebarWidth.initial(stored: SidebarWidth.load(defaults), viewport: viewport)
        super.init(frame: .zero)
        addSubview(main)
        addSubview(sidebar)
        addSubview(rail)
        addSubview(collapsedTrigger)
        collapsedTrigger.isHidden = true
        slide.onFrame = { [weak self] _ in self?.layoutNow() }
        slide.onEnd = { [weak self] in self?.slideEnded() }
        collapsedTrigger.action = { [weak self] in self?.toggle() }
        if let sidebarContent { sidebar.content = sidebarContent }
        if let mainContent { main.addSubview(mainContent) }
        rail.layoutView = self
        setAccessibilityRole(.group)
    }

    /// How far open the sidebar shows, 0 to 1. The sidebar sits `width * (1 - value)` left of its place and
    /// the main panel starts at its right edge; at rest it is 1 open and 0 closed.
    public let slide = PanelSlide(value: 1)

    /// Opens or closes at once; with `panelAnimationDurationMs` above 0 the panels then slide there.
    ///
    /// T3 transitions the container's `left` and the gap's `width` with `ease-out` over the setting's duration
    /// (ui/sidebar.tsx:287, :299; AppSidebarLayout.tsx:264). The main panel (`SidebarInset`, `flex-1` beside
    /// the gap, ui/sidebar.tsx:550-556) takes the rest of the row, so it narrows or widens and reflows on every
    /// frame of the slide; here `PanelSlide` steps the same curve on the display link and lays out each step.
    /// A toggle mid-slide starts from where the panels are, and a reversal takes the share of the duration it
    /// has left to travel, like a reversed CSS transition.
    public func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        let duration = SettingsPanelMotion.duration
        let animated = duration > 0 && window != nil && bounds.width > 0
        isOpen = open
        rail.isOpen = open
        collapsedTrigger.isSidebarOpen = open
        // The fixed trigger stays up through an open slide, until the sidebar's own trigger is back under it.
        collapsedTrigger.isHidden = open && !animated
        onOpenChange?(open)
        if animated {
            slide.run(to: open ? 1 : 0, duration: duration, in: self)
            // The rail hides, and an opening sidebar takes its frame (drawn, still off to the left), at once.
            layoutNow()
        } else {
            slide.jump(to: open ? 1 : 0)
        }
        HoverSync.setNeedsSync(window)
    }

    private func slideEnded() {
        if isOpen { collapsedTrigger.isHidden = true }
        layoutNow()
        HoverSync.setNeedsSync(window)
    }

    /// A sidebar leaving its window mid-slide lands where it was going; the display link stops with it.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, slide.isRunning { slide.jump(to: slide.target) }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let wasGlass = glassBackdrop != nil
        updateGlass()
        // Behind a frosted window AppKit leaves box decorations with the old appearance's colors (the
        // translucent theme cards stayed light in dark mode), so they redraw here.
        if wasGlass || glassBackdrop != nil { ThemeRuntime.redrawDecorations(in: self) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlass()
    }

    /// Adds the frost under the surfaces while the Glass theme shows, and drops it otherwise. The theme runtime
    /// calls `viewDidChangeEffectiveAppearance` on every view when the theme changes, so switching is instant.
    private func updateGlass() {
        glassBackdrop = WindowGlass.syncBackdrop(glassBackdrop, in: self)
        ditherArt = DitherArtView.sync(ditherArt, in: main)
    }

    /// `sidebar.toggle` (Mod+B by default; the app's shortcut dispatcher calls it).
    public func toggle() { setOpen(!isOpen) }


    // MARK: Width

    func beginDrag() -> CGFloat { effectiveWidth }

    func drag(to proposed: CGFloat, current: CGFloat) -> CGFloat {
        let next = widthRules.dragStep(current: current, proposed: proposed, viewport: bounds.width, wrapperWidth: bounds.width)
        if next != width { width = next; layoutNow() }
        return next
    }

    func endDrag() {
        SidebarWidth.save(width, defaults)
    }

    /// Double-clicking the rail forgets the stored width and returns to the default.
    public func resetWidth() {
        SidebarWidth.reset(defaults)
        width = SidebarWidth.initial(stored: nil, viewport: bounds.width)
        layoutNow()
    }

    /// Sets the width as a finished drag would, persisting it (tests and restores).
    public func setWidth(_ value: CGFloat) {
        width = widthRules.clamp(value, viewport: bounds.width)
        SidebarWidth.save(width, defaults)
        layoutNow()
    }

    private func layoutNow() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        // The main page may have changed, say from a new thread to Settings.
        ditherArt?.updateScrim()
        let w = effectiveWidth
        // Offcanvas: the container slides fully off screen to `left: -width`, the gap collapses to 0. Mid-slide
        // the gap is the open share of the width, on whole device pixels so the main panel's text stays sharp.
        let sliding = slide.isRunning
        let scale = window?.backingScaleFactor ?? 2
        let gap = sliding ? (w * slide.value * scale).rounded() / scale : isOpen ? w : 0
        // While it slides the container keeps its open frame and only its layer moves: AppKit draws nothing
        // for a view whose frame lies outside the window (the art, the brand and every label went blank).
        sidebar.frame = NSRect(x: isOpen || sliding ? 0 : -w, y: 0, width: w, height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sidebar.layer?.setAffineTransform(sliding ? CGAffineTransform(translationX: gap - w, y: 0) : .identity)
        CATransaction.commit()
        main.frame = NSRect(x: gap, y: 0, width: max(0, bounds.width - gap), height: bounds.height)
        for view in main.subviews { view.frame = main.bounds }
        // The padding box ends at w - 1 (inside the 1px border); the rail is centred there.
        rail.frame = NSRect(x: gap - 1 - SidebarMetrics.railWidth / 2, y: 0, width: SidebarMetrics.railWidth, height: bounds.height)
        rail.isHidden = !isOpen // collapsed offcanvas rail has `pointer-events: none`
        collapsedTrigger.frame = NSRect(x: SidebarMetrics.controlsLeft(windowedMac: true) + 1, y: (SidebarMetrics.topbarHeight - 28) / 2, width: 28, height: 28)
    }
}

/// The fixed container plus inner: `bg-sidebar surface-grain` and `border-r` in the sidebar's `--contrast-border`.
public final class SidebarContainerView: DSView {
    public let surface = GrainSurfaceView(fill: WindowGlass.sidebarSurface)
    private let border = DSView()
    public var content: NSView? {
        didSet { oldValue?.removeFromSuperview(); if let content { addSubview(content) }; needsLayout = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(surface)
        addSubview(border)
        // The content names itself, "Threads" or "Settings" (AppSidebarLayout.tsx:322); this box stays transparent.
    }

    public override func layout() {
        super.layout()
        // Inner fills the padding box; the border sits on the right 1px. Under Glass the frost runs under the border
        // too, or that column showed the bare, saturated wallpaper as a bright line.
        let box = NSRect(x: 0, y: 0, width: bounds.width - 1, height: bounds.height)
        surface.frame = WindowGlass.isActive(for: self) ? bounds : box
        border.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        content?.frame = box
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    public override func updateLayer() {
        border.layer?.backgroundColor = Themed.color(\.contrastBorder, sidebar: true).cgColor(in: self)
    }
}

/// `SidebarRail`: drag to resize, double-click to reset, a 2px `--contrast-sidebar-border` line on hover.
/// Cursor `w-resize` while open; `col-resize` while dragging.
public final class SidebarRailView: DSView {
    weak var layoutView: SidebarLayoutView?
    var isOpen = true { didSet { window?.invalidateCursorRects(for: self) } }
    public private(set) var isHovered = false { didSet { needsDisplay = true } }
    private let line = CALayer()
    private var dragStart: (x: CGFloat, width: CGFloat, current: CGFloat)?
    private var moved = false
    private var trackingArea: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(line)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize Sidebar")
        toolTip = "Drag to resize sidebar"
    }

    /// For tests and the gallery.
    public func previewHover(_ hovered: Bool) { isHovered = hovered }

    public override func layout() {
        super.layout()
        // `after:left-1/2 after:w-[2px]`
        line.frame = CGRect(x: bounds.width / 2, y: 0, width: 2, height: bounds.height)
    }

    public override func updateLayer() {
        line.backgroundColor = isHovered || dragStart != nil
            ? Themed.color(\.contrastSidebarBorder, sidebar: true).cgColor(in: self) : nil
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: isOpen ? .resizeLeft : .resizeRight)
    }

    public override func mouseDown(with event: NSEvent) {
        guard let layoutView else { return }
        if event.clickCount == 2 { layoutView.resetWidth(); return }
        let width = layoutView.beginDrag()
        dragStart = (event.locationInWindow.x, width, width)
        moved = false
        NSCursor.resizeLeftRight.push() // body `cursor: col-resize` while dragging
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let layoutView else { return }
        let delta = event.locationInWindow.x - start.x
        if abs(delta) > 2 { moved = true }
        let current = layoutView.drag(to: start.width + delta, current: start.current)
        dragStart?.current = current
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        NSCursor.pop()
        needsDisplay = true
        // A click without movement on an open resizable sidebar is a no-op; a drag commits the width.
        if moved { layoutView?.endDrag() }
    }
}

/// `SidebarTrigger`: a 28px ghost icon button whose icon is lucide `PanelLeftClose` while open
/// and `PanelLeft` while closed. Placed at `--workspace-controls-left` + 1px, centred in the 52px top bar.
// ponytail: the icon swaps instead of the spring path morph (MorphIcon); add the morph if the user notices
public final class SidebarTriggerView: ControlView {
    public var isSidebarOpen = true { didSet { updateIcon(); setAccessibilityValue(isSidebarOpen) } }
    /// T3's `media-navigation` variant over header art (`text-white/90`, hover `bg-white/10` and full
    /// text), in this color instead of white. Nil is the ghost button.
    public var mediaTint: NSColor? { didSet { needsDisplay = true } }
    private let decoration = BoxDecorationLayer()
    private let icon = CAShapeLayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        layer?.addSublayer(decoration)
        icon.fillColor = nil
        icon.lineCap = .round
        icon.lineJoin = .round
        icon.actions = ["path": NSNull(), "strokeColor": NSNull()]
        layer?.addSublayer(icon)
        setAccessibilityLabel("Toggle Sidebar")
        toolTip = "Toggle main sidebar"
        updateIcon()
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }


    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        updateIcon()
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    public override func updateLayer() {
        var look = ButtonStyles.look(variant: .ghost, state: state, radius: 8)
        if let mediaTint {
            let hover = state.hoverOrPressed
            look.box.fill = hover ? mediaTint.withAlphaComponent(0.1) : nil
            look.icon = mediaTint.withAlphaComponent(hover ? 1 : 0.9)
        }
        decoration.boxStyle = look.box
        icon.strokeColor = look.icon.cgColor(in: self)
    }

    private func updateIcon() {
        // 24-unit viewBox drawn at 16px, centred; the view is flipped, so the layer is too.
        let s: CGFloat = 16 / 24
        var t = CGAffineTransform(translationX: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2).scaledBy(x: s, y: s)
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerWidth: 2, cornerHeight: 2)
        p.move(to: CGPoint(x: 9, y: 3)); p.addLine(to: CGPoint(x: 9, y: 21))
        if isSidebarOpen {
            p.move(to: CGPoint(x: 16, y: 15)); p.addLine(to: CGPoint(x: 13, y: 12)); p.addLine(to: CGPoint(x: 16, y: 9))
        }
        icon.frame = bounds
        icon.lineWidth = 2 * s
        icon.path = p.copy(using: &t)
    }
}
