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
    /// `SIDEBAR_COLLAPSE_DRAG_RATIO` (ui/sidebar.tsx:34 at 5258): a rail drag below a quarter of the minimum width hides
    /// the sidebar (#29546).
    public static let collapseDragRatio: CGFloat = 0.75
    /// `SidebarRestoreHandle` (ui/sidebar.tsx:485-570): a drag from the left edge opens the sidebar once it reaches 48px.
    public static let restoreDistance: CGFloat = 48
    /// The restore handle's zone: `fixed top-1/2 left-[8px] h-16 w-[16px] -translate-y-1/2`.
    public static let restoreHandle = NSRect(x: 8, y: 0, width: 16, height: 64)

    /// Whether a rail drag to `rawWidth` hides the sidebar on release (ui/sidebar.tsx:620-626).
    public static func collapses(rawWidth: CGFloat, minimum: CGFloat) -> Bool { rawWidth < minimum * (1 - collapseDragRatio) }
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
    /// A rail drag past the collapse threshold: the sidebar is already off to the left and the main panel full width,
    /// as T3 previews it (`data-sidebar-drag-state="collapsed"`, ui/sidebar.tsx:603-648).
    public private(set) var dragCollapsed = false { didSet { if dragCollapsed != oldValue { layoutNow() } } }
    /// A restore-handle drag past 48px: the sidebar shows at this width before it opens (ui/sidebar.tsx:503-516).
    public private(set) var restorePreviewWidth: CGFloat? { didSet { if restorePreviewWidth != oldValue { layoutNow() } } }
    /// The left-edge handle that drags a hidden sidebar back (`SidebarRestoreHandle`).
    public let restoreHandle = SidebarRestoreHandleView()
    /// The Dither theme's picture in the main panel, present only while it shows.
    private var ditherArt: DitherArtView?
    /// Dither's hairline down the panel's sidebar edge and round its bottom left corner, faded in below the band.
    private let panelRim = CAShapeLayer()
    private let panelRimMask = CAGradientLayer()
    /// Dither's tab strip in the window's top band, over the framed content panel; the app fills its tabs.
    public let tabStrip = DitherTabStripView()
    /// Redesign's inset panel (Settings > Redesign > Inset panel, after Capy): the page sits in one rounded card
    /// `Space.s` in from the sidebar and the window's edges, under the card's top row (`tabStrip`), and the window
    /// around it takes the sidebar's color. The art is the card's ground. The page reports the thread card's frame
    /// (`setInsetCard`), which ends where the right panel's or the terminal drawer's own card begins.
    private let cardRim = InsetCardRimView()
    private var reportedCard: NSRect?
    private weak var cardReporter: NSView?
    var insetActive: Bool { ThemeRuntime.insetPanel(dark: effectiveAppearance.isDark) }
    /// Dither's history buttons, after Capy's: in the titlebar row at the sidebar's right, whatever the sidebar shows.
    public let backButton = ButtonView(nil, icon: .chevronLeft, variant: .ghostMuted, size: .iconSm)
    public let forwardButton = ButtonView(nil, icon: .chevronRight, variant: .ghostMuted, size: .iconSm)
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
        get { main.subviews.first { !($0 is DitherArtView) && !($0 is ThemeBackgroundView) } }
        set {
            for view in main.subviews where view !== newValue && !(view is DitherArtView) && !(view is ThemeBackgroundView) { view.removeFromSuperview() }
            if let newValue, newValue.superview !== main { main.addSubview(newValue) }
            needsLayout = true
        }
    }

    public init(sidebarContent: NSView? = nil, mainContent: NSView? = nil, defaults: UserDefaults = .standard, viewport: CGFloat = 1100) {
        self.defaults = defaults
        sidebar = SidebarContainerView()
        main = GrainSurfaceView(fill: Themed.color(\.background))
        width = SidebarWidth.initial(stored: SidebarWidth.load(defaults), viewport: viewport)
        super.init(frame: .zero)
        addSubview(main)
        cardRim.isHidden = true
        addSubview(cardRim)
        addSubview(tabStrip)
        tabStrip.isHidden = true
        addSubview(sidebar)
        backButton.setAccessibilityLabel("Back")
        forwardButton.setAccessibilityLabel("Forward")
        for b in [backButton, forwardButton] { b.isHidden = true; addSubview(b) }
        addSubview(rail)
        addSubview(restoreHandle)
        restoreHandle.layoutView = self
        restoreHandle.isHidden = true
        addSubview(collapsedTrigger)
        collapsedTrigger.isHidden = true
        slide.onFrame = { [weak self] _ in self?.layoutNow() }
        slide.onEnd = { [weak self] in self?.slideEnded() }
        collapsedTrigger.action = { [weak self] in self?.toggle() }
        if let sidebarContent { sidebar.content = sidebarContent }
        if let mainContent { main.addSubview(mainContent) }
        ThemeBackgroundView.register(main)
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
    public func setOpen(_ open: Bool) { setOpen(open, slides: true) }

    /// `slides: false` lands at once: a drag that already moved the sidebar there must not restart the slide.
    func setOpen(_ open: Bool, slides: Bool) {
        guard open != isOpen else { return }
        let duration = SettingsPanelMotion.duration
        let animated = slides && duration > 0 && window != nil && bounds.width > 0
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
        updateArt()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateArt()
    }

    /// Adds Redesign's art while it shows, and drops it otherwise. The theme runtime calls
    /// `viewDidChangeEffectiveAppearance` on every view when the theme changes, so switching is instant.
    private func updateArt() {
        // Blur draws the picture behind the whole window, sidebar included; Dither only in the main panel.
        ditherArt = DitherArtView.sync(ditherArt, in: ThemeRuntime.ditherBlur ? self : main)
        needsLayout = true // Dither frames the main panel
    }

    /// `sidebar.toggle` (Mod+B by default; the app's shortcut dispatcher calls it).
    public func toggle() { setOpen(!isOpen) }


    // MARK: Width

    func beginDrag() -> CGFloat { effectiveWidth }

    func drag(to proposed: CGFloat, current: CGFloat) -> CGFloat {
        let next = widthRules.dragStep(current: current, proposed: proposed, viewport: bounds.width, wrapperWidth: bounds.width)
        if next != width { width = next; layoutNow() }
        if Haptics.crosses(from: current, to: next, [widthRules.minimum, widthRules.maximum(viewport: bounds.width)]) { Haptics.tap(.alignment) }
        return next
    }

    func endDrag() {
        SidebarWidth.save(width, defaults)
    }

    /// The rail drag crossed the collapse threshold one way or the other.
    func previewCollapse(_ collapsed: Bool) { dragCollapsed = collapsed }

    /// A rail drag ended: past the threshold the sidebar hides where it already is; `cancelled` (the window lost
    /// focus mid-drag, `cancelOnInterrupt`) keeps it open.
    func finishCollapse(commit: Bool) {
        let collapse = dragCollapsed && commit
        dragCollapsed = false
        if collapse { setOpen(false, slides: false) }
    }

    /// One restore-handle drag step to `proposed` from the left edge. Returns the width the sidebar would open at.
    @discardableResult
    func restoreDrag(to proposed: CGFloat) -> CGFloat {
        let next = widthRules.clamp(proposed, viewport: bounds.width)
        restorePreviewWidth = proposed >= SidebarMetrics.restoreDistance ? next : nil
        return next
    }

    /// The restore drag ended; past 48px the previewed width is saved and the sidebar opens in place.
    func finishRestore(commit: Bool) {
        let preview = restorePreviewWidth
        restorePreviewWidth = nil
        guard commit, let preview else { return }
        width = preview
        SidebarWidth.save(width, defaults)
        setOpen(true, slides: false)
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
        let w = restorePreviewWidth ?? effectiveWidth
        // Offcanvas: the container slides fully off screen to `left: -width`, the gap collapses to 0. Mid-slide
        // the gap is the open share of the width, on whole device pixels so the main panel's text stays sharp.
        // A drag preview shows the end state: hidden past the rail's threshold, open past the restore handle's.
        let sliding = slide.isRunning
        let scale = window?.backingScaleFactor ?? 2
        let shown = restorePreviewWidth != nil || isOpen && !dragCollapsed
        let gap = sliding ? (w * slide.value * scale).rounded() / scale : shown ? w : 0
        // While it slides the container keeps its open frame and only its layer moves: AppKit draws nothing
        // for a view whose frame lies outside the window (the art, the brand and every label went blank).
        sidebar.frame = NSRect(x: shown || sliding ? 0 : -w, y: 0, width: w, height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sidebar.layer?.setAffineTransform(sliding ? CGAffineTransform(translationX: gap - w, y: 0) : .identity)
        CATransaction.commit()
        // Dither (after Capy): the content is a rounded panel framed by the chrome, under a tab strip band.
        let dither = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        // The panel runs flush to the window's right, bottom and top edges, so the art and its top fade start at the
        // window's top and the tab strip sits on the art (the user: "start AT THE VERY TOP OF THE WINDOW"). The page
        // inside still starts below the band. The sidebar side rounds both corners and keeps a hairline.
        let inset = dither && insetActive
        let margin = RedesignTokens.Space.s
        let band: CGFloat = inset ? margin + CardTopRow.rowHeight : dither ? DitherChrome.band : 0
        main.frame = NSRect(x: gap, y: 0, width: max(0, bounds.width - gap), height: bounds.height)
        main.layer?.cornerRadius = dither && !inset ? DitherChrome.panelRadius : 0
        main.layer?.maskedCorners = dither ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        // Blur: the sidebar and the panel are transparent over one blurred picture, with no edge between them.
        let blur = dither && ThemeRuntime.ditherBlur
        layoutPanelRim(dither: dither && !blur && !inset)
        layer?.backgroundColor = dither ? DitherChrome.bandColor(in: self) : nil
        // The inset card's ground is the art; the margins around it show this view's sidebar color.
        if main.clearsFill != (blur || inset) { main.clearsFill = blur || inset }
        if sidebar.surface.clearsFill != blur { sidebar.surface.clearsFill = blur }
        if blur { ditherArt?.frame = bounds }
        sidebar.showsBorder = !dither
        // The band and frame around the panel are flat, so the sidebar drops its grain to match them.
        if sidebar.surface.showsGrain == dither { sidebar.surface.showsGrain = !dither }
        tabStrip.isHidden = !dither
        tabStrip.frame = inset ? NSRect(x: gap + margin, y: margin, width: max(0, bounds.width - gap - 2 * margin), height: CardTopRow.rowHeight)
            : NSRect(x: gap, y: 0, width: max(0, bounds.width - gap), height: band)
        // Over the sidebar's titlebar row, right-aligned, while the sidebar is open.
        for (i, b) in [backButton, forwardButton].enumerated() {
            b.isHidden = !dither || !isOpen || sliding
            b.frame = NSRect(x: gap - 8 - 28 * CGFloat(2 - i) - 2 * CGFloat(1 - i), y: (DitherChrome.band - 28) / 2, width: 28, height: 28)
        }
        for view in main.subviews {
            view.frame = view is DitherArtView || view is ThemeBackgroundView ? main.bounds
                : inset ? NSRect(x: margin, y: band, width: max(0, main.bounds.width - 2 * margin), height: max(0, main.bounds.height - band - margin))
                : NSRect(x: 0, y: band, width: main.bounds.width, height: max(0, main.bounds.height - band))
        }
        placeInsetCard()
        // The padding box ends at w - 1 (inside the 1px border); the rail is centred there.
        rail.frame = NSRect(x: gap - 1 - SidebarMetrics.railWidth / 2, y: 0, width: SidebarMetrics.railWidth, height: bounds.height)
        // The rail keeps its frame through a collapse drag, so it still gets the drag's events.
        rail.isHidden = !isOpen // collapsed offcanvas rail has `pointer-events: none`
        // ui/sidebar.tsx:429: the handle exists only while the left sidebar is hidden (`collapseOnResize`).
        restoreHandle.isHidden = isOpen && restorePreviewWidth == nil
        let zone = SidebarMetrics.restoreHandle
        restoreHandle.frame = NSRect(x: zone.minX, y: ((bounds.height - zone.height) / 2).rounded(), width: zone.width, height: zone.height)
        collapsedTrigger.frame = NSRect(x: SidebarMetrics.controlsLeft(windowedMac: true) + 1, y: (SidebarMetrics.topbarHeight - 28) / 2, width: 28, height: 28)
    }

    /// A page in the main column reports the thread card's frame in its own coordinates from its layout, or nil for the
    /// whole card. A page that never reports gets the whole card.
    public func setInsetCard(_ rect: NSRect?, from page: NSView) {
        guard rect != reportedCard || page !== cardReporter else { return }
        reportedCard = rect
        cardReporter = page
        placeInsetCard()
    }

    /// The thread card in `main`'s coordinates: the reported frame while its page shows, else all of the page's room.
    var insetCardFrame: NSRect {
        let margin = RedesignTokens.Space.s
        let whole = main.bounds.insetBy(dx: margin, dy: margin)
        guard let rect = reportedCard, let page = cardReporter, page.isDescendant(of: main), !page.isHiddenOrHasHiddenAncestor else {
            return whole
        }
        return main.convert(rect, from: page)
    }

    private func placeInsetCard() {
        let inset = ThemeRuntime.isDither(dark: effectiveAppearance.isDark) && insetActive
        let picture = inset && !ThemeRuntime.ditherBlur
        tabStrip.insetCard = inset
        cardRim.isHidden = !inset
        if let art = ditherArt {
            art.isInsetCard = picture && art.superview === main
            if !picture, art.superview === main { art.frame = main.bounds }
        }
        guard inset else { return }
        let card = insetCardFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cardRim.frame = convert(card, from: main)
        cardRim.isHidden = card.width < 1 || card.height < 1
        if picture, let art = ditherArt, art.superview === main, art.frame != card { art.frame = card }
        CATransaction.commit()
        tabStrip.contentEnd = max(0, cardRim.frame.maxX - tabStrip.frame.minX)
    }

    private func layoutPanelRim(dither: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard dither, let host = main.layer else { panelRim.removeFromSuperlayer(); return }
        if panelRim.superlayer !== host {
            host.addSublayer(panelRim)
            panelRim.zPosition = 10
            panelRim.fillColor = nil
            panelRim.lineWidth = 0.5
            panelRim.mask = panelRimMask
        }
        let r = DitherChrome.panelRadius, b = main.bounds
        panelRim.frame = b
        panelRim.strokeColor = Themed.color(\.contrastForeground, 0.08).cgColor(in: self)
        panelRim.path = SmoothCorners.path(b.insetBy(dx: 0.25, dy: 0.25), r, corners: [.topLeft, .bottomLeft], flipped: main.isFlipped)
        // Only the left edge and its two curves, which end 1.53 radii along the top and bottom edges.
        panelRimMask.frame = CGRect(x: 0, y: 0, width: ceil(r * SmoothCorners.reach) + 1, height: b.height)
        panelRimMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor]
        panelRimMask.locations = nil
    }
}

/// The inset card's rim, over the page so rows never cover it: Redesign's hairline on the card's continuous corners.
final class InsetCardRimView: DSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateLayer() {
        layer?.cornerRadius = RedesignTokens.Radius.panel
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = RedesignTokens.Surface.rim(dark: effectiveAppearance.isDark).cgColor
    }
}

/// The fixed container plus inner: `bg-sidebar surface-grain` and `border-r` in the sidebar's `--contrast-border`.
public final class SidebarContainerView: DSView {
    public let surface = GrainSurfaceView(fill: Themed.color(\.sidebar, sidebar: true))
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

    /// Dither hides the border: the sidebar and the window frame are one color there.
    public var showsBorder = true { didSet { border.isHidden = !showsBorder } }

    public override func layout() {
        super.layout()
        // Inner fills the padding box; the border sits on the right 1px.
        let box = NSRect(x: 0, y: 0, width: bounds.width - 1, height: bounds.height)
        surface.frame = box
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
    private var resignObserver: NSObjectProtocol?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(line)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize Sidebar")
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
        // `cancelOnInterrupt`: losing the window mid-drag keeps the sidebar open.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endDrag(commit: false) }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let layoutView else { return }
        let delta = event.locationInWindow.x - start.x
        if abs(delta) > 2 { moved = true }
        let raw = start.width + delta
        let current = layoutView.drag(to: raw, current: start.current)
        dragStart?.current = current
        layoutView.previewCollapse(SidebarMetrics.collapses(rawWidth: raw, minimum: layoutView.widthRules.minimum))
    }

    public override func mouseUp(with event: NSEvent) { endDrag(commit: true) }

    private func endDrag(commit: Bool) {
        guard dragStart != nil else { return }
        dragStart = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        NSCursor.pop()
        needsDisplay = true
        // A click without movement on an open resizable sidebar is a no-op; a drag commits the width.
        if moved { layoutView?.endDrag() }
        layoutView?.finishCollapse(commit: commit && moved)
    }
}

/// `SidebarRestoreHandle` (ui/sidebar.tsx:485-570 at 5258, #29546): an invisible 16x64 zone 8pt from the window's
/// left edge while the sidebar is hidden. The pointer in the zone shows a bar in its left half (`before:w-1/2
/// before:rounded-md before:bg-sidebar-border`); dragging it right 48pt or more opens the sidebar at the dragged width,
/// and a plain click opens it. Redesign draws the bar as a capsule in its card rim color.
public final class SidebarRestoreHandleView: DSView {
    weak var layoutView: SidebarLayoutView?
    public private(set) var isNear = false { didSet { if isNear != oldValue { needsDisplay = true } } }
    private let bar = CALayer()
    private var dragStartX: CGFloat?
    private var moved = false
    private var trackingArea: NSTrackingArea?
    private var resignObserver: NSObjectProtocol?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
        layer?.addSublayer(bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show sidebar")
    }

    /// For tests and the gallery.
    public func previewNear(_ near: Bool) { isNear = near }

    private var redesign: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }

    public override func layout() {
        super.layout()
        let w = bounds.width / 2
        bar.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        bar.cornerRadius = redesign ? RedesignTokens.Radius.capsule(w) : 6
    }

    public override func updateLayer() {
        bar.backgroundColor = isNear || dragStartX != nil
            ? (redesign ? RedesignTokens.Card.border.cgColor(in: self) : Themed.color(\.sidebarBorder, sidebar: true).cgColor(in: self)) : nil
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isNear = true }
    public override func mouseExited(with event: NSEvent) { isNear = false }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeRight) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        moved = false
        needsDisplay = true
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endDrag(commit: false) }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartX else { return }
        let delta = event.locationInWindow.x - start
        if abs(delta) > 2 { moved = true }
        layoutView?.restoreDrag(to: max(0, delta))
    }

    public override func mouseUp(with event: NSEvent) { endDrag(commit: true) }

    private func endDrag(commit: Bool) {
        guard dragStartX != nil else { return }
        dragStartX = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        needsDisplay = true
        if moved { layoutView?.finishRestore(commit: commit) } else if commit { layoutView?.setOpen(true) }
    }

    public override func accessibilityPerformPress() -> Bool {
        layoutView?.setOpen(true)
        return true
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
        setTooltip("Toggle main sidebar")
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

