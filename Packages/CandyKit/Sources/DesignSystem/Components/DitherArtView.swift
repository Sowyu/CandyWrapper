import Accelerate
import AppKit
import ImageIO
import os

/// The Dither theme's art (CandyWrapper's own, after Capy's desktop app). Picture: the chosen or desktop picture as a
/// two-ink Bayer dither on 3pt cells (`PictureInk`), thinning around the new thread's composer and behind a thread's
/// reading column so text keeps its floors, with no dim layer. Blur: the picture blurred behind the whole window.
/// Gradient: accent cells with no picture. Settings and other pages lay a heavy scrim of the background over it. It
/// renders once per size, picture, appearance, ink and page shape off the main thread and never moves in Picture
/// (the user, 2026-11-21: "no motion its horrid"). A live resize scales the cached image with the panel on the GPU and
/// renders once when the size settles.
public final class DitherArtView: NSView {
    private let art = CALayer()
    /// The background over the art, one share across the panel, plus a faint veil of it behind the chat column.
    private let scrim = CAGradientLayer()
    /// The band's color over the panel's top edge, a thin fade into the window's top.
    private let blend = CAGradientLayer()
    /// How far down the panel the band's color reaches: only the window's top edge, the same reach as the rows' fade
    /// there. It reached the band's whole 52 before, a grey slab under the title the user removed ("lets remove this
    /// early fade i only want the one up here", 2026-11-21).
    public static let topBlend: CGFloat = 20
    private var shown: DitherArt.Request?
    private var pending: DitherArt.Request?
    private var debounce: DispatchWorkItem?
    private var loggedScrim: CGFloat?
    /// macOS's Reduce Transparency, replaceable in tests.
    var systemReducesTransparency: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    /// Gradient: the accent color through the current frame's mask, one cell per mask pixel.
    private let gradientMask = CALayer()
    /// Gradient's loop, held only while the new-thread page shows (`DitherArt.gradientFrames`).
    private var gradientFrames: [CGImage] = []
    /// Whether the window is visible, unminiaturized, not covered and key; tests set it.
    var windowIsActiveOverride: Bool?
    /// Flower: the ink color through the current frame's mask (`LotusArt`), its own layer so it moves and scales
    /// without touching the art.
    let flower = CALayer()
    let flowerMask = CALayer()
    /// The frames on screen, filled in as they render: the open still, then the bloom, then the idle loop.
    var flowerSet: FlowerSet?
    /// A set rendering while another shows, until it can take over.
    var flowerIncoming: FlowerSet?
    /// The set being rendered, and the job rendering it.
    var flowerWanted: FlowerKey?
    var flowerJob: FlowerJob?
    /// Where the flower sits now, and on which page.
    var flowerSpot: LotusArt.Spot?
    var flowerKind: LotusArt.Kind?
    /// When the last geometry change came, to tell a drag from a single change, and the settle after a drag.
    var flowerMovedAt: CFTimeInterval = 0
    var flowerSettle: DispatchWorkItem?
    /// When a thread or the new-thread page last opened (`flowerOpened`), until the bloom plays or goes stale.
    var bloomRequestedAt: CFTimeInterval?
    /// Layer time the playing bloom ends at.
    var bloomEnds: CFTimeInterval = 0
    var flowerShownOnce = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        art.magnificationFilter = .nearest
        // One canvas pixel is exactly one dot: the layer is the canvas's size in dots (`placeArt`), so the stretch is
        // exactly `dot` and every dot is the same whole number of device pixels.
        art.contentsGravity = .resize
        art.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "mask": NSNull()]
        gradientMask.contentsGravity = .resize
        gradientMask.magnificationFilter = .nearest
        gradientMask.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        scrim.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
        scrim.startPoint = CGPoint(x: 0, y: 0.5)
        scrim.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.masksToBounds = true
        layer?.addSublayer(art)
        flower.mask = flowerMask
        flower.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        flowerMask.contentsGravity = .resize
        flowerMask.magnificationFilter = .nearest
        flowerMask.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        flower.isHidden = true
        layer?.addSublayer(flower)
        layer?.addSublayer(scrim)
        blend.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
        layer?.addSublayer(blend)
        Self.arts.add(self)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        // "Ignore Reduce Transparency" and the other theme settings take effect at once.
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeRuntime.didChange, object: nil)
        // macOS posts nothing when the desktop picture changes or rotates, so the art checks it again whenever the
        // desktop could have changed under it. A check costs nothing when the picture is the same.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(desktopMayHaveChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(desktopMayHaveChanged),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func desktopMayHaveChanged(_ note: Notification) { refresh() }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func displayOptionsChanged(_ note: Notification) { updateScrim() }
    /// The ink, the accent and the palette's ground feed Picture's render, so a theme change may render again.
    @objc private func themeChanged(_ note: Notification) { refresh() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var wantsUpdateLayer: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func isAccessibilityElement() -> Bool { false }

    /// Puts the art at the bottom of `view` while the Dither theme shows in its appearance and takes it out otherwise.
    @MainActor
    public static func sync(_ current: DitherArtView?, in view: NSView) -> DitherArtView? {
        let on = view.window != nil && ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark)
        if on, current == nil {
            let made = DitherArtView(frame: view.bounds)
            view.addSubview(made, positioned: .below, relativeTo: nil)
            return made
        }
        if !on, let current { current.removeFromSuperview(); return nil }
        // Blur sits behind the whole window and Dither in the main panel, so a switch moves the art.
        if let current, current.superview !== view {
            current.removeFromSuperview()
            current.frame = view.bounds
            view.addSubview(current, positioned: .below, relativeTo: nil)
        }
        current?.refresh()
        return current
    }

    /// How much of the art a page shows. `page` is the heavy scrim, for pages in the thread panel's place.
    public enum Emphasis: Sendable { case hero, thread, settings, page }

    /// A page calls this: while `source` is the frontmost registered page showing inside the art's panel, the art
    /// takes `emphasis`'s scrim. Pass nil when the source leaves. Pages that never call it get the heavy page scrim.
    @MainActor
    public static func setEmphasis(_ emphasis: Emphasis?, from source: NSView) {
        if let emphasis { sources.setObject(EmphasisBox(emphasis: emphasis), forKey: source) } else { sources.removeObject(forKey: source) }
        // Gradient renders only for the new-thread page and Picture's shape follows the page, so a page change may
        // render again.
        for art in arts.allObjects { art.refresh() }
    }

    /// A page joined or left the window, as the thread panel and a utility page trade places: every art takes the scrim
    /// of what shows now. Before, the last page's scrim stayed until something else redrew the art.
    @MainActor
    public static func pagesMoved() {
        for art in arts.allObjects { art.refresh() }
    }

    /// A thread page calls this from its layout with its chat column, in its own coordinates, so the art's veil sits
    /// behind it. Pass nil when there is no column.
    @MainActor
    public static func setColumn(_ column: NSRect?, from source: NSView) {
        guard columns.object(forKey: source)?.rectValue != column else { return }
        if let column { columns.setObject(NSValue(rect: column), forKey: source) } else { columns.removeObject(forKey: source) }
        art(behind: source)?.refresh()
    }

    /// The new-thread page calls this from its layout with its composer's frame, in its own coordinates, so Picture's
    /// dots thin around it. Pass nil when the composer isn't centred on the page.
    @MainActor
    public static func setComposer(_ composer: NSRect?, from source: NSView) {
        guard composers.object(forKey: source)?.rectValue != composer else { return }
        if let composer { composers.setObject(NSValue(rect: composer), forKey: source) } else { composers.removeObject(forKey: source) }
        art(behind: source)?.refresh()
    }

    /// A thread page calls this from its layout with where the Flower background may sit, in its own coordinates
    /// (`LotusArt.Stage`): its content area and what the flower keeps clear of. Pass nil when it shows no flower.
    @MainActor
    public static func setFlowerStage(kind: LotusArt.Kind, content: NSRect, keepOut: [NSRect], from source: NSView) {
        let box = FlowerStageBox(kind: kind, content: content, keepOut: keepOut)
        guard stages.object(forKey: source) != box else { return }
        stages.setObject(box, forKey: source)
        guard ThemeRuntime.ditherFlower else { return }
        art(behind: source)?.refresh()
    }

    @MainActor
    public static func clearFlowerStage(from source: NSView) {
        guard stages.object(forKey: source) != nil else { return }
        stages.removeObject(forKey: source)
        if ThemeRuntime.ditherFlower { art(behind: source)?.refresh() }
    }

    /// A thread opened in `source`, or the new-thread page appeared: the flower blooms once, from the bud. Switching
    /// threads and opening the new-thread page call it; a re-render, a stream update, scrolling and coming back to
    /// the window don't.
    @MainActor
    public static func flowerOpened(from source: NSView) {
        guard ThemeRuntime.ditherFlower, let art = art(behind: source) else { return }
        art.requestBloom()
    }

    /// The art showing behind `source`, if any.
    @MainActor
    static func art(behind source: NSView) -> DitherArtView? {
        arts.allObjects.first { art in
            art.superview.map { source.isDescendant(of: $0) } == true && (art.window == nil || art.window === source.window)
        }
    }

    /// Each registered page and its emphasis, weakly held.
    @MainActor private static let sources = NSMapTable<NSView, EmphasisBox>.weakToStrongObjects()
    @MainActor private static let arts = NSHashTable<DitherArtView>.weakObjects()
    /// Each thread page's chat column, weakly held.
    @MainActor private static let columns = NSMapTable<NSView, NSValue>.weakToStrongObjects()
    /// Each new-thread page's composer, weakly held.
    @MainActor private static let composers = NSMapTable<NSView, NSValue>.weakToStrongObjects()
    /// Each thread page's flower stage, weakly held.
    @MainActor static let stages = NSMapTable<NSView, FlowerStageBox>.weakToStrongObjects()

    public override func updateLayer() {
        updateScrim()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        placeArt()
        scrim.frame = artRect
        // This view isn't flipped: its top is maxY, and the gradient's unit space runs bottom to top.
        blend.frame = CGRect(x: 0, y: bounds.height - Self.topBlend, width: bounds.width, height: Self.topBlend)
        CATransaction.commit()
        refresh()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    /// A window moved to another screen shows that screen's desktop picture. A hidden window holds no art.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didBecomeKeyNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didResignKeyNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(desktopMayHaveChanged), name: NSWindow.didChangeScreenNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// A miniaturized or ordered-out window drops its art, which renders again when the window shows. A window only
    /// covered by others keeps it, so it never flashes empty.
    @objc private func visibilityChanged(_ note: Notification) {
        guard let window else { return }
        if !window.isVisible || window.isMiniaturized {
            guard shown != nil || pending != nil || flowerSet != nil || flowerWanted != nil else { return }
            debounce?.cancel()
            shown = nil; pending = nil
            art.contents = nil
            dropGradient()
            dropFlower()
            PictureInk.dropCache()
        } else if shown == nil {
            refresh()
        }
        syncMotion()
    }

    @objc private func keyChanged(_ note: Notification) { syncMotion() }

    /// Whether the window shows and has the user's attention: visible, not miniaturized or covered, and key.
    private var windowIsActive: Bool {
        if let windowIsActiveOverride { return windowIsActiveOverride }
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) && window.isKeyWindow
    }

    /// Gradient moves only while it can be seen and wanted: the new-thread page in Gradient with Animate on, the
    /// window active and Reduce Motion off. Anything else removes the animation, holding the frame it was on, so
    /// nothing runs while idle (the user, 2026-11-21: "capys plain dither isnt just static").
    func syncMotion() {
        syncFlowerMotion()
        let on = ThemeRuntime.ditherGradient && ThemeRuntime.ditherGradientAnimates && !Motion.reduced && windowIsActive
            && page == .hero && !art.isHidden && gradientFrames.count > 1 && art.mask === gradientMask
        let running = gradientMask.animation(forKey: "drift") != nil
        guard on != running else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if on {
            let drift = CAKeyframeAnimation(keyPath: "contents")
            drift.values = gradientFrames
            drift.calculationMode = .discrete
            drift.keyTimes = (0...gradientFrames.count).map { NSNumber(value: Double($0) / Double(gradientFrames.count)) }
            drift.duration = DitherArt.gradientPeriod
            drift.repeatCount = .infinity
            // Start from the frame it holds, so resuming never jumps.
            if let held = gradientMask.contents, let i = gradientFrames.firstIndex(where: { $0 === (held as AnyObject) }) {
                drift.timeOffset = DitherArt.gradientPeriod * Double(i) / Double(gradientFrames.count)
            }
            // Only `syncMotion` takes it off, never Core Animation (an offscreen window counts it finished at once).
            drift.isRemovedOnCompletion = false
            gradientMask.add(drift, forKey: "drift")
        } else {
            // Hold the frame on screen now.
            if let current = gradientMask.presentation()?.contents { gradientMask.contents = current }
            gradientMask.removeAnimation(forKey: "drift")
        }
        CATransaction.commit()
    }

    /// Gradient's frames go when its page or window does; they render again when it shows.
    private func dropGradient() {
        gradientMask.removeAnimation(forKey: "drift")
        gradientMask.contents = nil
        gradientFrames = []
    }

    var gradientAnimatingForTesting: Bool { gradientMask.animation(forKey: "drift") != nil }

    /// Moving between the main panel (Dither) and the window (Blur): the old art never shows at the new place.
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        art.contents = nil
        shown = nil
        pending = nil
    }

    /// A move between screens refreshes the art for the new backing scale.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    /// The whole panel: the thread's top fade blends it into the header.
    var artRect: CGRect { bounds }

    /// The shown canvas at one cell per pixel, its top left at the panel's top left, on the lattice Gradient and
    /// Picture share. While the panel's size differs from the canvas's (a live resize, a sidebar drag), the cached
    /// image scales to cover the panel, centred as the picture is, so no band of ground shows; the window server
    /// scales it, and the sharp render lands when the size settles (the user, 2026-11-21: "i need to release my mouse
    /// before it pops in").
    private func placeArt() {
        guard let shown else { return }
        let unit = shown.unit
        let w = CGFloat(shown.width) * unit, h = CGFloat(shown.height) * unit
        let target = canvasSize(for: shown)
        if target == (shown.width, shown.height) {
            art.frame = CGRect(x: 0, y: bounds.height - h, width: w, height: h)
        } else if shown.tint != nil {
            // Gradient covers the panel's width and the top of its height: stretch it there.
            let gh = bounds.height * DitherArt.gradientReach.height
            art.frame = CGRect(x: 0, y: bounds.height - gh, width: bounds.width, height: gh)
        } else {
            let k = max(bounds.width / w, bounds.height / h)
            art.frame = CGRect(x: (bounds.width - w * k) / 2, y: (bounds.height - h * k) / 2, width: w * k, height: h * k)
        }
        gradientMask.frame = art.bounds
    }

    /// The canvas size, in cells, a render for this panel's size would have in `request`'s mode.
    private func canvasSize(for request: DitherArt.Request) -> (width: Int, height: Int) {
        let reach = request.tint != nil ? DitherArt.gradientReach : CGSize(width: 1, height: 1)
        return (Int((artRect.width * reach.width / request.unit).rounded(.up)), Int((artRect.height * reach.height / request.unit).rounded(.up)))
    }

    /// How many renders reached the screen, for tests.
    private(set) var rendersForTesting = 0

    /// The drag or window resize ended: render the sharp art now instead of after the pause.
    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard let work = debounce, !work.isCancelled else { return }
        work.cancel()
        debounce = nil
        pending = nil
        refresh()
    }

    /// What the panel shows over the art: the frontmost registered page that's visible inside it decides, whatever
    /// order the pages registered in, and an unregistered page gets the heavy scrim.
    var page: DitherArt.Page { front.page }

    /// The frontmost registered page showing inside the panel and what it shows.
    private var front: (page: DitherArt.Page, view: NSView?) {
        guard let panel = superview, window != nil else { return (.page, nil) }
        let showing = (Self.sources.keyEnumerator().allObjects as? [NSView] ?? []).filter {
            $0.window === window && $0.isDescendant(of: panel) && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
        guard let front = showing.max(by: { Self.isInFront($1, of: $0) }), let emphasis = Self.sources.object(forKey: front)?.emphasis else {
            return (.page, nil)
        }
        switch emphasis {
        case .hero: return (.hero, front)
        case .thread: return (.thread, front)
        case .settings: return (.settings, front)
        case .page: return (.page, front)
        }
    }

    /// Whether `a` draws over `b`: under the nearest ancestor they share, the later subview is in front, and a view is
    /// in front of its own ancestors.
    static func isInFront(_ a: NSView, of b: NSView) -> Bool {
        func chain(_ v: NSView) -> [NSView] { sequence(first: v, next: \.superview).reversed() }
        let ca = chain(a), cb = chain(b)
        var i = 0
        while i < ca.count, i < cb.count, ca[i] === cb[i] { i += 1 }
        if i == cb.count { return i < ca.count }
        if i == ca.count || i == 0 { return false }
        let siblings = ca[i - 1].subviews
        return (siblings.firstIndex { $0 === ca[i] } ?? 0) > (siblings.firstIndex { $0 === cb[i] } ?? 0)
    }

    /// Main thread only, like every view method.
    func updateScrim() {
        let dark = effectiveAppearance.isDark
        let background = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.nsColor
        let display = (reduceTransparency: ThemeRuntime.reducesTransparency(system: systemReducesTransparency()),
                       increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let (page, front) = self.front
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        // Gradient: the dots show on a new thread only, with no scrim; every other page is the plain ground.
        // Flower: the lotus on a new thread and beside a thread's column, the plain ground everywhere else.
        let flowerOn = ThemeRuntime.ditherFlower
        let gradient = ThemeRuntime.ditherGradient
        let artHidden = (gradient && page != .hero) || flowerOn
        if art.isHidden != artHidden { art.isHidden = artHidden }
        let picture = !gradient && !flowerOn && !ThemeRuntime.ditherBlur
        let alpha = gradient || flowerOn ? 0 : DitherArt.scrim(page, display, light: !dark, picture: picture)
        if loggedScrim != alpha {
            DitherArt.log.notice("scrim \(alpha) on \(String(describing: page), privacy: .public): reduce transparency \(display.reduceTransparency), increase contrast \(display.increaseContrast), dark \(dark)")
        }
        loggedScrim = alpha
        scrim.backgroundColor = background.withAlphaComponent(alpha).cgColor
        CATransaction.commit()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The veil follows the column through a live resize, so it never animates.
        let veil = gradient || flowerOn || picture ? 0 : DitherArt.veil(page, reduceTransparency: display.reduceTransparency)
        if veil > 0, bounds.width >= 1, let front, let column = Self.columns.object(forKey: front)?.rectValue {
            let lane = convert(column, from: front)
            let xs = (0...64).map { bounds.width * CGFloat($0) / 64 }
            scrim.locations = xs.map { NSNumber(value: Double($0 / bounds.width)) }
            scrim.colors = xs.map { background.withAlphaComponent(veil * DitherArt.veilShare($0, lane: lane.minX...lane.maxX)).cgColor }
        } else {
            scrim.colors = nil
        }
        // Blur runs under the band too, so the band shows the picture and needs no blend.
        blend.isHidden = ThemeRuntime.ditherBlur
        let band = DitherChrome.bandColor(in: self)
        // Bottom (no band) to top (all band).
        let ts = (0...10).reversed().map { Double($0) / 10 }
        blend.locations = ts.map { NSNumber(value: 1 - $0) }
        blend.colors = ts.map { band.copy(alpha: DitherChrome.bandBlend($0))! }
        CATransaction.commit()
        syncMotion()
    }

    /// Asks for the art at the current size and appearance, after the size settles.
    func refresh() {
        updateScrim()
        let rect = artRect
        guard let window, rect.width >= 1, rect.height >= 1 else {
            if window != nil { DitherArt.log.notice("no art yet: the panel is \(Int(rect.width)) x \(Int(rect.height)) pt") }
            return
        }
        let dark = effectiveAppearance.isDark
        let palette = ThemeRuntime.palettes.palette(dark: dark, sidebar: false)
        let background = palette.background
        let scale = window.backingScaleFactor
        let blur = ThemeRuntime.ditherBlur
        art.magnificationFilter = blur ? .linear : .nearest
        if ThemeRuntime.ditherFlower {
            debounce?.cancel()
            shown = nil; pending = nil
            art.contents = nil; art.mask = nil
            dropGradient()
            refreshFlower(palette: palette, dark: dark)
            return
        }
        if flowerSet != nil || flowerWanted != nil || !flower.isHidden { flowerSpot = nil; dropFlower() }
        let request: DitherArt.Request
        if ThemeRuntime.ditherGradient {
            // Only the new-thread page shows it, so no other page holds its frames.
            guard page == .hero else {
                debounce?.cancel()
                shown = nil; pending = nil
                dropGradient()
                return
            }
            // No picture: the canvas covers the top of the panel, where the cells are; the ground shows below it.
            let accent = palette.primary
            request = DitherArt.Request(url: nil, width: Int((rect.width * DitherArt.gradientReach.width / DitherArt.gradientUnit).rounded(.up)),
                                        height: Int((rect.height * DitherArt.gradientReach.height / DitherArt.gradientUnit).rounded(.up)),
                                        background: [background.srgb.x, background.srgb.y, background.srgb.z], scale: scale,
                                        tint: [accent.srgb.x, accent.srgb.y, accent.srgb.z], dark: dark,
                                        frames: ThemeRuntime.ditherGradientAnimates ? Int(DitherArt.gradientPeriod * DitherArt.gradientFPS) : 1)
        } else {
            let url = ThemeRuntime.ditherPicture ?? DitherArt.desktopPicture(for: window.screen)
            let fallbacks = [DitherArt.desktopPicture(for: window.screen), DitherArt.defaultDesktop].compactMap { $0 }.filter { $0 != url }
            PictureTint.sync([url].compactMap { $0 } + fallbacks)
            // Picture's cell lands on whole device pixels at this window's scale (`DitherDotSize`).
            let unit = blur ? DitherArt.blurPixel : ThemeRuntime.ditherDotSize.points(scale: scale)
            var made = DitherArt.Request(url: url, width: Int((rect.width / unit).rounded(.up)),
                                         height: Int((rect.height / unit).rounded(.up)),
                                         background: [background.srgb.x, background.srgb.y, background.srgb.z], scale: scale,
                                         fallbacks: fallbacks,
                                         blur: blur, dark: dark)
            if !blur {
                made.ink = Self.ink(palette: palette)
                made.dot = unit
                made.shape = pictureShape(cell: unit)
                made.text = [palette.foreground.srgb, palette.mutedForeground.srgb].flatMap { [$0.x, $0.y, $0.z] }
            }
            request = made
        }
        guard request != shown, request != pending else { return }
        // Only a new size waits for the drag to pause; a page, ink or picture change renders at once.
        let resizing = shown.map { $0.width != request.width || $0.height != request.height } ?? false
        pending = request
        debounce?.cancel()
        // A live resize lands here every frame; the last size renders, the old art scales with the panel meanwhile.
        if rendersInlineForTesting {
            let (image, frames) = Self.render(request)
            show(request, image: image, frames: frames)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let (image, frames) = Self.render(request)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.show(request, image: image, frames: frames) }
                }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (resizing ? 0.15 : 0), execute: work)
    }

    /// Picture's inks from the "Ink" setting: Auto takes them from the picture, Accent from the accent, Custom from the
    /// user's color.
    private static func ink(palette: Palette) -> PictureInk.Choice {
        switch ThemeRuntime.ditherInk {
        case .auto: return .auto
        case .accent: let c = palette.primary.srgb; return .color(SIMD3(c.x, c.y, c.z))
        case let .custom(color): return .color(color)
        }
    }

    /// What the front page needs from Picture's dots, in points from the panel's top left, snapped to whole cells so
    /// a sub-point layout change renders nothing.
    private func pictureShape(cell: CGFloat) -> PictureInk.Shape {
        let (page, front) = self.front
        func cells(_ r: NSRect) -> [Double] {
            let local = convert(r, from: front)
            let snap = { (v: CGFloat) in Double((v / cell).rounded() * cell) }
            return [snap(local.minX), snap(bounds.height - local.maxY), snap(local.width), snap(local.height)]
        }
        switch page {
        case .hero: return .hero(composer: front.flatMap { Self.composers.object(forKey: $0)?.rectValue }.map(cells))
        case .thread: return .thread(column: front.flatMap { Self.columns.object(forKey: $0)?.rectValue }.map(cells))
        case .settings, .page: return .plain
        }
    }

    /// Tests render on the main thread, so they never wait with theme globals applied.
    var rendersInlineForTesting = false

    /// The picture's art, or Gradient's frames and the first of them. Runs on any thread.
    private nonisolated static func render(_ request: DitherArt.Request) -> (DitherArtImage, DitherArtFrames) {
        let frames = DitherArtFrames(images: request.tint == nil ? []
            : DitherArt.gradientFrames(width: request.width, height: request.height, frames: request.frames))
        return (DitherArtImage(image: request.tint == nil ? DitherArt.render(request) : frames.images.first), frames)
    }

    private func show(_ request: DitherArt.Request, image: DitherArtImage, frames: DitherArtFrames) {
        guard pending == request else { return }
        pending = nil
        rendersForTesting += 1
        // A render that failed isn't remembered, so the next refresh tries again.
        shown = image.image == nil ? nil : request
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dropGradient()
        if let tint = request.tint {
            art.contents = nil
            art.backgroundColor = DitherArt.gradientColor(tint: tint, background: request.background, dark: request.dark)
            gradientFrames = frames.images
            gradientMask.contents = image.image
            art.mask = gradientMask
        } else {
            art.mask = nil
            art.backgroundColor = nil
            art.contents = image.image
        }
        placeArt()
        CATransaction.commit()
        syncMotion()
    }

    var contentsForTesting: CGImage? { art.contents.map { $0 as! CGImage } }
    var requestForTesting: DitherArt.Request? { pending ?? shown }
    var scrimAlphaForTesting: CGFloat { scrim.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0 }
}

// MARK: Flower

/// One flower frame set's identity: radius in cells, appearance, page (the new thread thins toward the composer), and
/// whether it moves (one still when Animate is off).
struct FlowerKey: Hashable, Sendable {
    var radius: Int
    var dark: Bool
    var kind: LotusArt.Kind
    var animates: Bool
}

/// A flower's frames as they arrive: the open still first, so the flower shows at once, then the 28 bloom masks,
/// then the idle loop.
struct FlowerSet: @unchecked Sendable {
    var key: FlowerKey
    var open: CGImage
    var bloom: [CGImage] = []
    var idle: [CGImage] = []
    var bytes: Int { ([open] + bloom + idle).reduce(0) { $0 + $1.bytesPerRow * $1.height } }
}

/// A render in flight, cancelled when a newer one starts.
final class FlowerJob: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true } }
}

final class FlowerStageBox: Equatable {
    let kind: LotusArt.Kind, content: NSRect, keepOut: [NSRect]
    init(kind: LotusArt.Kind, content: NSRect, keepOut: [NSRect]) { self.kind = kind; self.content = content; self.keepOut = keepOut }
    static func == (a: FlowerStageBox, b: FlowerStageBox) -> Bool { a.kind == b.kind && a.content == b.content && a.keepOut == b.keepOut }
}

extension DitherArtView {
    /// How long an opening waits for its bloom frames before it gives up and shows the open flower.
    static let bloomPatience: CFTimeInterval = 4
    /// A geometry change this soon after the last one is part of a drag: it follows at once, scaled, and the sharp
    /// set renders after `settleDelay` of quiet.
    static let dragGap: CFTimeInterval = 0.25
    static let settleDelay: CFTimeInterval = 0.15

    func requestBloom() {
        bloomRequestedAt = CACurrentMediaTime()
        // The open flower that was showing goes at once; the bloom fades the bud in.
        if flowerMotionAllowed, flowerSpot != nil {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            flowerMask.removeAnimation(forKey: "bloom"); flowerMask.removeAnimation(forKey: "idle")
            flower.removeAnimation(forKey: "fade")
            flower.opacity = 0
            CATransaction.commit()
        }
        syncFlowerMotion()
        // If the bloom's frames never land, the open flower shows when the wait runs out.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bloomPatience + 0.05) { [weak self] in self?.syncFlowerMotion() }
    }

    /// The flower's ink: the accent in dark, its hue at a deep lightness in light so the dots read on the off-white
    /// ground. Deep cells show it at `LotusArt.deepAlpha` over the ground, the second ink.
    static func flowerInk(_ palette: Palette, dark: Bool) -> CGColor {
        let a = palette.primary.srgb
        guard !dark else { return CGColor(srgbRed: a.x, green: a.y, blue: a.z, alpha: 1) }
        let o = PictureInk.oklch(srgb: SIMD3(a.x, a.y, a.z))
        let c = PictureInk.srgb(oklch: LotusArt.lightInk.l, min(o.c, LotusArt.lightInk.c), o.h)
        return CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
    }

    /// The front page's stage in this view's top-left space, if it reported one.
    private func flowerStage(_ page: DitherArt.Page, _ front: NSView?) -> LotusArt.Stage? {
        guard page == .hero || page == .thread, let front, let box = Self.stages.object(forKey: front) else { return nil }
        func topLeft(_ r: NSRect) -> CGRect {
            let l = convert(r, from: front)
            return CGRect(x: l.minX, y: bounds.height - l.maxY, width: l.width, height: l.height)
        }
        return LotusArt.Stage(kind: box.kind, content: topLeft(box.content), keepOut: box.keepOut.map(topLeft))
    }

    func refreshFlower(palette: Palette, dark: Bool) {
        let (page, front) = self.front
        guard let stage = flowerStage(page, front), let spot = LotusArt.spot(for: stage) else {
            flowerSpot = nil
            dropFlower()
            return
        }
        if !flowerShownOnce { flowerShownOnce = true; bloomRequestedAt = bloomRequestedAt ?? CACurrentMediaTime() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flower.backgroundColor = Self.flowerInk(palette, dark: dark)
        CATransaction.commit()
        let key = FlowerKey(radius: LotusArt.bucket(spot.radius, cell: DitherArt.gradientUnit), dark: dark, kind: stage.kind,
                            animates: ThemeRuntime.ditherGradientAnimates)
        let now = CACurrentMediaTime()
        let moved = spot != flowerSpot || stage.kind != flowerKind
        // A page change (new thread to thread) or a single change moves with the motion tokens; a drag follows at once.
        let drag = moved && flowerKind == stage.kind && flowerSpot != nil && now - flowerMovedAt < Self.dragGap
        let pageChanged = flowerKind != nil && flowerKind != stage.kind
        if moved { flowerMovedAt = now }
        let wasHidden = flower.isHidden
        flowerSpot = spot
        flowerKind = stage.kind
        if wasHidden {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            flower.isHidden = false
            CATransaction.commit()
        }
        if drag {
            placeFlower(settled: false, animated: false)
            flowerSettle?.cancel()
            let settle = DispatchWorkItem { [weak self] in self?.settleFlower() }
            flowerSettle = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: settle)
        } else if moved || wasHidden {
            placeFlower(settled: true, animated: !wasHidden && (pageChanged || flowerSet != nil) && !Motion.reduced)
        }
        if !drag, flowerSet?.key != key, flowerWanted != key { renderFlower(key) }
    }

    /// The drag ended: the flower eases to its bucket's radius and that set renders if it isn't the one showing.
    private func settleFlower() {
        flowerSettle = nil
        guard ThemeRuntime.ditherFlower, flowerSpot != nil else { return }
        refresh()
        placeFlower(settled: true, animated: !Motion.reduced)
        if let spot = flowerSpot, let kind = flowerKind {
            let key = FlowerKey(radius: LotusArt.bucket(spot.radius, cell: DitherArt.gradientUnit), dark: effectiveAppearance.isDark, kind: kind,
                                animates: ThemeRuntime.ditherGradientAnimates)
            if flowerSet?.key != key, flowerWanted != key { renderFlower(key) }
        }
    }

    /// The flower layer's frame for the spot, in this view's (unflipped) space. Settled, the flower shows at its
    /// bucket's radius with every dot exactly one cell, its centre on the cell lattice; mid-drag at the spot's own
    /// radius, the shown set scaled on the GPU.
    func flowerFrame(settled: Bool) -> CGRect? {
        guard let spot = flowerSpot else { return nil }
        let cell = DitherArt.gradientUnit
        let target = LotusArt.bucket(spot.radius, cell: cell)
        let radius = flowerSet?.key.radius ?? flowerWanted?.radius ?? target
        let canvas = LotusArt.canvas(radius: radius)
        let shownRadius = settled ? CGFloat(target) * cell : spot.radius
        let k = shownRadius / (CGFloat(radius) * cell)
        var cx = spot.centre.x, cy = spot.centre.y
        if settled { cx = (cx / cell).rounded() * cell; cy = (cy / cell).rounded() * cell }
        let w = CGFloat(canvas.width) * cell * k, h = CGFloat(canvas.height) * cell * k
        let x = cx - CGFloat(canvas.centreX) * cell * k, y = cy - CGFloat(canvas.centreY) * cell * k
        return CGRect(x: x, y: bounds.height - y - h, width: w, height: h)
    }

    func placeFlower(settled: Bool, animated: Bool) {
        guard let frame = flowerFrame(settled: settled) else { return }
        let from = flower.presentation() ?? flower
        let old = (position: from.position, bounds: from.bounds)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flower.removeAnimation(forKey: "position"); flower.removeAnimation(forKey: "bounds")
        flower.frame = frame
        flowerMask.frame = flower.bounds
        flowerMask.removeAnimation(forKey: "bounds"); flowerMask.removeAnimation(forKey: "position")
        if animated, old.bounds.width > 0 {
            for (key, value, layer) in [("position", NSValue(point: old.position), flower),
                                        ("bounds", NSValue(rect: old.bounds), flower),
                                        ("bounds", NSValue(rect: CGRect(origin: .zero, size: old.bounds.size)), flowerMask),
                                        ("position", NSValue(point: CGPoint(x: old.bounds.width / 2, y: old.bounds.height / 2)), flowerMask)] {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = value
                a.duration = RedesignTokens.Motion.large
                a.timingFunction = RedesignTokens.Motion.curve
                layer.add(a, forKey: key)
            }
        }
        CATransaction.commit()
    }

    /// Renders `key`'s frames off the main thread, across the cores: the open still, then the bloom, then the idle loop,
    /// each handed over as it lands.
    private func renderFlower(_ key: FlowerKey) {
        flowerJob?.cancel()
        flowerIncoming = nil
        let job = FlowerJob()
        flowerJob = job
        flowerWanted = key
        let deliver: @Sendable (FlowerPhase) -> Void = { [weak self] phase in
            if self == nil { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveFlower(phase, key: key, job: job) } }
        }
        if rendersInlineForTesting {
            for phase in Self.flowerPhases(key, job: job) { receiveFlower(phase, key: key, job: job) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var phases = Self.flowerPhasesLazy(key, job: job)
            while let phase = phases.next() { deliver(phase) }
        }
    }

    enum FlowerPhase: @unchecked Sendable { case open(CGImage), bloom([CGImage]), idle([CGImage]) }

    nonisolated static func flowerPhases(_ key: FlowerKey, job: FlowerJob) -> [FlowerPhase] {
        var out: [FlowerPhase] = []
        var phases = flowerPhasesLazy(key, job: job)
        while let p = phases.next() { out.append(p) }
        return out
    }

    /// The phases one at a time, so each reaches the screen before the next renders.
    /// Samples a cell side, 2; tests that render inline take 1, since a debug build renders about 60 times slower.
    @TaskLocal static var flowerSamples = 2

    nonisolated static func flowerPhasesLazy(_ key: FlowerKey, job: FlowerJob) -> AnyIterator<FlowerPhase> {
        let p = LotusArt.canvas(radius: key.radius)
        let samples = flowerSamples
        let density = key.kind == .hero ? LotusArt.heroDensity(p) : nil
        func masks(_ poses: [LotusArt.Pose]) -> [CGImage]? {
            job.cancelled ? nil : LotusArt.masks(poses, placement: p, dark: key.dark, inks: 2, density: density, samples: samples)
        }
        var step = 0
        return AnyIterator {
            defer { step += 1 }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let phase: FlowerPhase?
            switch step {
            case 0: phase = masks([LotusArt.openPose]).flatMap(\.first).map(FlowerPhase.open)
            case 1 where key.animates: phase = masks(LotusArt.bloomPoses()).map(FlowerPhase.bloom)
            case 2 where key.animates: phase = masks(LotusArt.idlePoses()).map(FlowerPhase.idle)
            default: return nil
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            DitherArt.log.notice("flower \(key.radius) cells, phase \(step): \(p.width) x \(p.height) in \(ms, format: .fixed(precision: 1)) ms")
            return phase
        }
    }

    private func receiveFlower(_ phase: FlowerPhase, key: FlowerKey, job: FlowerJob) {
        guard flowerJob === job, !job.cancelled, ThemeRuntime.ditherFlower else { return }
        rendersForTesting += 1
        switch phase {
        case let .open(image): flowerIncoming = FlowerSet(key: key, open: image)
        case let .bloom(images): flowerIncoming?.bloom = images
        case let .idle(images): flowerIncoming?.idle = images
        }
        guard let incoming = flowerIncoming else { return }
        let done = !key.animates || !incoming.idle.isEmpty
        if done { flowerWanted = nil; flowerJob = nil; flowerIncoming = nil }
        // A set already turning keeps turning until the new idle loop is ready, then hands over on the same frame, so
        // a settled resize never jumps the flower's turn. A first set, an opening and a still show at once.
        let turning = flowerSet != nil && flowerMask.animation(forKey: "idle") != nil
        guard flowerSet?.key != key else {
            flowerSet = incoming
            syncFlowerMotion()
            return
        }
        // A bloom in progress carries over to the new set's frames at the same moment, once they are here.
        let now = flowerMask.convertTime(CACurrentMediaTime(), from: nil)
        let midBloom = flowerMask.animation(forKey: "bloom") != nil && now < bloomEnds
        // The other appearance's masks read wrong under the new ink, so they hand over at once too.
        let appearance = flowerSet?.key.dark != key.dark
        guard done || !turning || bloomPending || appearance || (midBloom && !incoming.bloom.isEmpty) else { return }
        let index = flowerSet.flatMap { old in
            flowerMask.presentation()?.contents.flatMap { held in old.idle.firstIndex { $0 === (held as AnyObject) } }
        }
        flowerSet = incoming
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flowerMask.removeAnimation(forKey: "bloom"); flowerMask.removeAnimation(forKey: "idle")
        flowerMask.contents = index.flatMap { incoming.idle.indices.contains($0) ? incoming.idle[$0] : nil } ?? incoming.open
        if midBloom, !incoming.bloom.isEmpty { addBloom(incoming, ends: bloomEnds) }
        CATransaction.commit()
        // The new canvas differs in size: the frame follows, at the same size on screen.
        placeFlower(settled: flowerSettle == nil, animated: false)
        if !bloomPending { showOpenFlower() }
        if done { DitherArt.log.notice("flower set \(key.radius) cells: \(incoming.bytes / 1024) KB") }
        syncFlowerMotion()
    }

    /// Whether a fresh opening still waits for its bloom: while its frames render, or for `bloomPatience` after.
    var bloomPending: Bool {
        guard let at = bloomRequestedAt else { return false }
        return flowerJob != nil || CACurrentMediaTime() - at < Self.bloomPatience
    }

    var flowerMotionAllowed: Bool {
        ThemeRuntime.ditherFlower && ThemeRuntime.ditherGradientAnimates && !Motion.reduced && windowIsActive
            && flowerSpot != nil && !flower.isHidden
    }

    private func showOpenFlower() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flower.removeAnimation(forKey: "fade")
        flower.opacity = 1
        if let open = flowerSet?.open, flowerMask.animationKeys()?.isEmpty ?? true { flowerMask.contents = open }
        CATransaction.commit()
    }

    /// The flower moves only while it can be seen and wanted, as Gradient does: Flower with Animate on, the window
    /// active, Reduce Motion off, the flower on its page. An opening plays the bloom once, bud to open, and the idle
    /// loop follows from the open flower, the bloom's last frame. Anything else removes the animations and holds the
    /// open flower (not the bud), so nothing runs while idle.
    func syncFlowerMotion() {
        guard let set = flowerSet else { return }
        let now = flowerMask.convertTime(CACurrentMediaTime(), from: nil)
        let blooming = flowerMask.animation(forKey: "bloom") != nil && now < bloomEnds
        let idling = flowerMask.animation(forKey: "idle") != nil
        guard flowerMotionAllowed else {
            bloomRequestedAt = nil
            guard blooming || idling || flower.opacity < 1 || flowerMask.animation(forKey: "bloom") != nil else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // Hold what shows: the idle frame on screen, or the open flower over a bloom cut short.
            let held = !blooming && idling ? flowerMask.presentation()?.contents : nil
            flowerMask.removeAnimation(forKey: "bloom"); flowerMask.removeAnimation(forKey: "idle")
            flowerMask.contents = held ?? set.open
            flower.removeAnimation(forKey: "fade")
            flower.opacity = 1
            CATransaction.commit()
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if bloomPending, !set.bloom.isEmpty {
            bloomRequestedAt = nil
            flowerMask.removeAnimation(forKey: "idle")
            flowerMask.contents = set.open
            addBloom(set, ends: now + Self.bloomDuration(set))
            // The bud's first frames are a few scattered dots: they fade in rather than pop.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = LotusArt.bloomFadeIn
            fade.beginTime = flower.convertTime(CACurrentMediaTime(), from: nil)
            fade.fillMode = .backwards
            flower.opacity = 1
            flower.add(fade, forKey: "fade")
        } else if bloomPending {
            // Waiting for the bloom's frames: the flower stays out until they land, or the wait runs out.
            if !blooming, flower.opacity != 0 { flower.opacity = 0 }
            return
        } else if flower.opacity < 1, !blooming {
            flower.opacity = 1
        }
        guard flowerMask.animation(forKey: "idle") == nil, set.idle.count > 1 else { return }
        let idle = CAKeyframeAnimation(keyPath: "contents")
        idle.values = set.idle
        idle.calculationMode = .discrete
        idle.keyTimes = (0...set.idle.count).map { NSNumber(value: Double($0) / Double(set.idle.count)) }
        idle.duration = LotusArt.idlePeriod
        idle.repeatCount = .infinity
        idle.isRemovedOnCompletion = false
        if flowerMask.animation(forKey: "bloom") != nil, now < bloomEnds {
            // Straight after the bloom, from the open flower it ends on.
            idle.beginTime = bloomEnds
        } else {
            flowerMask.removeAnimation(forKey: "bloom")
            idle.beginTime = now
            // Resume from the frame it holds, so starting again never jumps.
            if let held = flowerMask.contents, let i = set.idle.firstIndex(where: { $0 === (held as AnyObject) }) {
                idle.timeOffset = LotusArt.idlePeriod * Double(i) / Double(set.idle.count)
            }
        }
        flowerMask.add(idle, forKey: "idle")
    }

    static func bloomDuration(_ set: FlowerSet) -> CFTimeInterval { Double(set.bloom.count + 1) / LotusArt.bloomFPS }

    /// The bloom's frames then the open flower, held, ending at `ends` in the mask's time.
    private func addBloom(_ set: FlowerSet, ends: CFTimeInterval) {
        let values = set.bloom + [set.open]
        let bloom = CAKeyframeAnimation(keyPath: "contents")
        bloom.values = values
        bloom.calculationMode = .discrete
        bloom.keyTimes = (0...values.count).map { NSNumber(value: Double($0) / Double(values.count)) }
        bloom.duration = Self.bloomDuration(set)
        bloom.beginTime = ends - bloom.duration
        bloom.fillMode = .forwards
        bloom.isRemovedOnCompletion = false
        flowerMask.add(bloom, forKey: "bloom")
        bloomEnds = ends
    }

    /// The flower's frames go when its page, its spot or the window does; they render again when it shows.
    func dropFlower() {
        flowerJob?.cancel()
        flowerJob = nil
        flowerWanted = nil
        flowerIncoming = nil
        flowerSettle?.cancel()
        flowerSettle = nil
        flowerSet = nil
        flowerKind = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flowerMask.removeAllAnimations()
        flower.removeAllAnimations()
        flowerMask.contents = nil
        flower.opacity = 1
        flower.isHidden = true
        CATransaction.commit()
    }

    var flowerBloomingForTesting: Bool { flowerMask.animation(forKey: "bloom") != nil }
    var flowerIdlingForTesting: Bool { flowerMask.animation(forKey: "idle") != nil }
    var flowerContentsForTesting: CGImage? { flowerMask.contents.map { $0 as! CGImage } }
}

private struct DitherArtImage: @unchecked Sendable { let image: CGImage? }
private final class EmphasisBox { let emphasis: DitherArtView.Emphasis; init(emphasis: DitherArtView.Emphasis) { self.emphasis = emphasis } }
private struct DitherArtFrames: @unchecked Sendable { let images: [CGImage] }

/// The art's rendering. Touches no AppKit view, so it runs on any thread.
public enum DitherArt {
    /// Blur's pixel size in points. The blurred picture has no detail finer than its radius, so the layer scales a
    /// canvas a quarter of the dots' on each side up smoothly, at a sixteenth of the memory.
    public nonisolated static let blurPixel: CGFloat = 8
    /// Blur's Gaussian sigma in points (radius about 3 sigma, 96 pt): text-sized and icon-sized detail in the picture
    /// is gone, while its colors and the shapes a quarter of a window wide still read.
    public nonisolated static let blurSigma: CGFloat = 32
    /// The background's share over an open thread: the user's "Background dim" (35% by default), so the art keeps its
    /// colors and text reads over it without halos (the user, 2026-10-22).
    nonisolated static var threadScrim: CGFloat { ThemeRuntime.ditherDim }
    /// "Background dim"'s default, which Picture's palette and marks keep since it lays no dim.
    nonisolated static let defaultDim: Double = 0.35
    /// The background's share over Settings and every other page, whose cards and lists aren't frosted.
    nonisolated static let pageScrim: CGFloat = 0.92

    /// Settings (after Capy's): its translucent cards sit over the art, which shows dimmer than in a thread.
    nonisolated static let settingsScrim: CGFloat = 0.8

    enum Page: Sendable { case hero, thread, settings, page }

    /// The scrim for `page` under the system display options. Increase Contrast keeps the art as a faint texture: text
    /// on the hero and in a thread then sits on about the background itself. Reduce Transparency takes at least those
    /// scrims but never covers the art: full cover made Redesign a plain panel with any picture and no sign why (the
    /// user's MacBook, 2026-10-28). "Ignore Reduce Transparency" turns it off here (`ThemeRuntime.reducesTransparency`).
    /// Picture lays no scrim on a new thread or a thread: its render thins the dots where text sits instead (the user,
    /// 2026-11-21, about the grey dim: "so non premium"). Reduce Transparency and Increase Contrast still take theirs.
    nonisolated static func scrim(_ page: Page, _ display: (reduceTransparency: Bool, increaseContrast: Bool),
                                  light: Bool = false, picture: Bool = false) -> CGFloat {
        if picture, !display.reduceTransparency, !display.increaseContrast, page == .hero || page == .thread { return 0 }
        if display.reduceTransparency {
            let standard = scrim(page, (false, display.increaseContrast), light: light), strong = scrim(page, (false, true), light: light)
            return min(max(standard, strong), pageScrim)
        }
        let scrim: CGFloat = switch page {
        case .hero: display.increaseContrast ? 0.6 : 0
        case .thread: display.increaseContrast ? 0.75 : threadScrim
        case .settings: display.increaseContrast ? 1 : settingsScrim
        case .page: display.increaseContrast ? 1 : pageScrim
        }
        return light ? max(scrim, lightScrim(page)) : scrim
    }

    /// Light's floor. Dark text loses more to a dot than light text does, so the art stays within 35% of its reach of
    /// the background: muted text keeps 4.5:1 over the darkest dot. "Background dim" spends the rest in a thread.
    /// Settings and the other pages cover the art in light: at 0.88 and 0.92 the dots showed as grey speckle between
    /// white cards, which reads as dirt on a light ground (docs/research/redesign-light-audit-2026-11-21.md).
    nonisolated static func lightScrim(_ page: Page) -> CGFloat {
        switch page {
        case .hero: 0.65
        case .thread: 0.65 + 0.35 * threadScrim
        case .settings, .page: 1
        }
    }

    /// The veil behind an open thread's chat column: a little more background over the art there, so muted text keeps
    /// its contrast, and so faint the column never shows as a shape (the user, 2026-10-29). Reduce Transparency's
    /// heavier scrim already covers it.
    nonisolated static let veilAlpha: CGFloat = 0.12
    /// How far beside the column the veil fades out, in points.
    nonisolated static let veilFeather: CGFloat = 360

    nonisolated static func veil(_ page: Page, reduceTransparency: Bool) -> CGFloat {
        page == .thread && !reduceTransparency ? veilAlpha : 0
    }

    /// The veil's strength at `x`: full over the lane, easing to nothing `veilFeather` beside it.
    nonisolated static func veilShare(_ x: CGFloat, lane: ClosedRange<CGFloat>) -> CGFloat {
        let distance = x < lane.lowerBound ? lane.lowerBound - x : x > lane.upperBound ? x - lane.upperBound : 0
        return CGFloat(smoothstep(0, 1, 1 - Double(distance / veilFeather)))
    }

    /// The brightest (dark) or darkest (light) art dot behind the chat column, as an sRGB gray, for a "Background dim"
    /// of `dim`: the background moved by the full reach, under the thread's scrim and the veil. Muted text keeps 4.5:1
    /// over it (`ThemeRuntime.resolve`).
    nonisolated static let readableMembers: Set<String> = ["--muted-foreground", "--contrast-muted-foreground",
                                                           "--secondary-label", "--contrast-secondary-label"]
    /// Blur: the sidebar's own text and icon colors, which sit on the picture there, plus the muted ones above.
    nonisolated static let readableSidebarMembers: Set<String> = readableMembers.union([
        "--sidebar-foreground", "--contrast-sidebar-foreground", "--sidebar-muted-foreground",
        "--contrast-sidebar-muted-foreground", "--sidebar-icon-color"])

    nonisolated static func worstBackground(_ background: TokenColor, dark: Bool, dim: Double, veiled: Bool = true) -> Double {
        let scrim = dark ? dim : max(dim, 0.65 + 0.35 * dim)
        let cover = veiled ? scrim + Double(veilAlpha) * (1 - scrim) : scrim
        let bg = (background.srgb.x + background.srgb.y + background.srgb.z) / 3
        let shift = reach / 255 * (1 - cover)
        return min(max(dark ? bg + shift : bg - shift, 0), 1)
    }

    struct Request: Hashable, Sendable {
        /// The chosen or desktop picture, nil when neither is available.
        var url: URL?
        /// Canvas size in dots.
        var width: Int, height: Int
        /// The panel's background, sRGB 0...1.
        var background: [Double]
        var scale: CGFloat
        /// Tried in order when `url` won't render.
        var fallbacks: [URL] = []
        /// Blurred and smooth instead of dithered (`ThemeRuntime.ditherBlur`); the canvas is in `blurPixel`s.
        var blur = false
        /// Gradient (`ThemeRuntime.ditherGradient`): no picture, halftone dots in this sRGB accent over the top left;
        /// the canvas is in `gradientUnit`s and covers `gradientReach` of the panel.
        var tint: [Double]?
        var dark = true
        /// Gradient's frame count: the loop, or 1 when Animate is off.
        var frames = 1
        /// Picture: where the two inks come from, the page's shape over the dots, and the body and muted text colors
        /// (sRGB, six values) whose floors hold behind a thread's column.
        var ink = PictureInk.Choice.auto
        var shape = PictureInk.Shape.plain
        var text: [Double] = []
        /// Picture's cell in points, from the "Dot size" setting at the window's scale.
        var dot: CGFloat = DitherDotSize.medium.points(scale: 2)

        /// Points per canvas pixel.
        var unit: CGFloat { tint != nil ? DitherArt.gradientUnit : blur ? DitherArt.blurPixel : dot }
    }

    /// Gradient's cell, in points: Capy's binary dither cells measured 6px at 2x in the user's recording.
    public nonisolated static let gradientUnit: CGFloat = 3
    /// How much of the panel Gradient's canvas covers from the top: its full width and the top half, where Capy's
    /// field moves (the user's recording, 2026-11-21).
    nonisolated static let gradientReach = CGSize(width: 1, height: 0.5)
    /// The loop: 12 s at 8 frames a second. Capy's field moves at about 12 cells a second at its fastest, so a cell
    /// flips at most once a frame or so.
    nonisolated static let gradientPeriod: Double = 12
    nonisolated static let gradientFPS: Double = 8

    /// One soft lobe of Gradient's field along the top: its centre and strength swing around a rest value, each on a
    /// whole number of turns per loop, so the loop is seamless.
    struct Lobe { var centre: Double, travel: Double, phase: Double, width: Double, strength: Double, swell: Double, turns: Double, swellPhase: Double }
    /// After Capy's recording: a lobe at the left that swells and fades, one that drifts right across the middle,
    /// and one at the right that grows from nothing. Frame 0 is brightest at the top left, the static look.
    nonisolated static let lobes: [Lobe] = [
        Lobe(centre: 0.06, travel: 0.06, phase: 0, width: 0.22, strength: 0.75, swell: 0.25, turns: 1, swellPhase: 1),
        Lobe(centre: 0.4, travel: 0.16, phase: 2, width: 0.18, strength: 0.55, swell: 0.45, turns: 2, swellPhase: 0.5),
        Lobe(centre: 0.84, travel: 0.1, phase: 4, width: 0.2, strength: 0.5, swell: 0.5, turns: 1, swellPhase: 3.5),
    ]

    /// Gradient's field at `u` across the canvas (0 left, 1 right) and loop time `t` (0...1), 0 to 1.
    nonisolated static func gradientField(_ u: Double, _ t: Double) -> Double {
        var f = 0.0
        for l in lobes {
            let c = l.centre + l.travel * sin(2 * .pi * t + l.phase)
            let a = l.strength + l.swell * sin(2 * .pi * t * l.turns + l.swellPhase)
            let d = (u - c) / l.width
            f += a * exp(-d * d)
        }
        return min(1, f)
    }

    /// Gradient's frames: one alpha mask per frame, a cell per pixel, on where the field beats the cell's Bayer
    /// threshold, the way Capy's cells switch on and off on a fixed grid. One frame when `frames` is 1. The field is a
    /// row profile times a linear falloff down the canvas, so a frame costs one multiply per cell.
    nonisolated static func gradientFrames(width w: Int, height h: Int, frames: Int) -> [CGImage] {
        guard w > 0, h > 0, frames > 0 else { return [] }
        let fall = (0..<h).map { y -> Double in 1 - (Double(y) + 0.5) / Double(h) }
        var out: [CGImage] = []
        out.reserveCapacity(frames)
        var row = [Double](repeating: 0, count: w)
        for i in 0..<frames {
            let t = Double(i) / Double(frames)
            for x in 0..<w { row[x] = gradientField((Double(x) + 0.5) / Double(w), t) }
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
                  let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return [] }
            // Row 0 of the buffer is the top of the canvas.
            for y in 0..<h {
                let b = (y & 7) * 8, f = fall[y]
                for x in 0..<w {
                    data[y * w + x] = row[x] * f > (Double(bayer[b + (x & 7)]) + 0.5) / 64 ? 255 : 0
                }
            }
            guard let image = ctx.makeImage() else { return [] }
            out.append(image)
        }
        return out
    }

    /// Gradient's one cell color: the accent mixed into the ground, dim like Capy's navy (#26314b at most). Light
    /// takes 0.32: at 0.22 teal on the off-white ground was #c3dedb, under 1.3:1, and the field barely showed. At
    /// 0.32 it is #abd3cf, 1.5:1, close to the 1.7:1 step that dark's 0.36 makes.
    nonisolated static func gradientColor(tint: [Double], background: [Double], dark: Bool) -> CGColor {
        let share = dark ? 0.36 : 0.32
        let c = (0..<3).map { background[$0] + (tint[$0] - background[$0]) * share }
        return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    nonisolated static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The share of the background mixed into the picture at `y`, 0 at the top to 1 at the bottom: a light veil that
    /// deepens a little toward the bottom. The thread's top fade blends the top into the header.
    nonisolated static func fade(_ y: Double) -> Double { 0.15 + 0.2 * smoothstep(0.6, 1, y) }

    /// How far, in 0...255 on any channel, the picture may stray from the background. Dark pictures pass untouched and
    /// bright parts are held down, so text on the art keeps about 4.5:1 (white on at most 42% gray in dark, near-black
    /// on at least 58% gray in light).
    nonisolated static let reach: Double = 98

    /// The 8 x 8 Bayer matrix, thresholds 0..<64.
    nonisolated static let bayer: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// The desktop picture of `screen`, when it is a still file outside the folders macOS guards.
    @MainActor
    static func desktopPicture(for screen: NSScreen?) -> URL? {
        #if DEBUG
        if let override = WallpaperBlur.override { return override.url }
        #endif
        guard let screen = screen ?? NSScreen.main, let desktop = NSWorkspace.shared.desktopImageURL(for: screen), desktop.isFileURL,
              case let url = resolved(desktop), let path = WallpaperBlur.unguardedPath(url.path, home: NSHomeDirectory()) else { return nil }
        return URL(filePath: path)
    }

    /// The picture covering the canvas, centered, faded into the background and dithered, or nil if it can't be read.
    /// Tries the request's picture, then each fallback, then the built-in picture, so the panel is never blank: a
    /// picture that won't decode, a nil desktop URL or a `.madesktop` macOS won't hand over all still show art.
    nonisolated static func render(_ request: Request) -> CGImage? {
        let w = request.width, h = request.height
        guard w > 0, h > 0 else { log.error("no art: the canvas is \(w) x \(h) dots"); return nil }
        if request.tint != nil { return gradientFrames(width: w, height: h, frames: 1).first }
        if request.url == nil { log.notice("no chosen or desktop picture") }
        if !request.blur { return renderInk(request) }
        for url in [request.url].compactMap({ $0 }) + request.fallbacks {
            let t0 = Date()
            guard let picture = picture(url, maxPixels: max(w, h)) else { continue }
            if let art = render(request, picture: picture) { return art }
            log.error("can't dither \(url.path, privacy: .private): \(picture.width) x \(picture.height), \(picture.bitsPerComponent) bits")
        }
        log.notice("showing the built-in art")
        guard let art = builtInPicture().flatMap({ render(request, picture: $0) }) else { log.fault("the built-in art failed"); return nil }
        return art
    }

    nonisolated static let log = Logger(subsystem: "CandyWrapper", category: "dither-art")

    /// The picture at `url`, decoded to at most `maxPixels` on its long side, or nil if it can't be read.
    nonisolated static func picture(_ url: URL, maxPixels: Int) -> CGImage? {
        let file = resolved(url)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else {
            log.error("can't open \(file.path, privacy: .private): \(FileManager.default.isReadableFile(atPath: file.path) ? "not an image" : "missing or unreadable")")
            return nil
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary),
              picture.width > 0, picture.height > 0 else {
            log.error("can't decode \(file.path, privacy: .private): \(CGImageSourceGetType(source) as String? ?? "unknown type"), status \(CGImageSourceGetStatus(source).rawValue)")
            return nil
        }
        return picture
    }

    /// A `.madesktop`, which macOS's own wallpapers are, is a small plist naming a still thumbnail of the picture.
    nonisolated static func resolved(_ url: URL) -> URL {
        guard url.pathExtension.lowercased() == "madesktop", let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let thumbnail = plist["thumbnailPath"] as? String else { return url }
        return URL(filePath: thumbnail)
    }

    /// macOS's default desktop picture, the fallback when neither the chosen nor the desktop picture renders.
    nonisolated static let defaultDesktop = URL(filePath: "/System/Library/CoreServices/DefaultDesktop.heic")

    /// The last resort when no file renders: a soft violet-to-teal wash, so Redesign always has art.
    nonisolated static func builtInPicture() -> CGImage? {
        let w = 64, h = 40
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
                  CGColor(srgbRed: 0.42, green: 0.32, blue: 0.86, alpha: 1), CGColor(srgbRed: 0.16, green: 0.58, blue: 0.55, alpha: 1),
              ] as CFArray, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        return ctx.makeImage()
    }

    /// Blur: `picture` covering the canvas, centered, blurred and faded into the background.
    nonisolated static func render(_ request: Request, picture: CGImage) -> CGImage? {
        let w = request.width, h = request.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        let cover = max(Double(w) / Double(picture.width), Double(h) / Double(picture.height))
        let pw = Double(picture.width) * cover, ph = Double(picture.height) * cover
        ctx.interpolationQuality = .high
        ctx.draw(picture, in: CGRect(x: (Double(w) - pw) / 2, y: (Double(h) - ph) / 2, width: pw, height: ph))
        blur(ctx, width: w, height: h)
        let bg = request.background.count == 3 ? request.background.map { $0 * 255 } : [0, 0, 0]
        // The same fade and reach the old dots had, so text keeps its contrast over Blur.
        for y in 0..<h {
            let keep = 1 - fade((Double(y) + 0.5) / Double(h))
            for x in 0..<w {
                let i = (y * w + x) * 4
                var d = (0..<3).map { (Double(data[i + $0]) - bg[$0]) * keep }
                let m = d.map(abs).max() ?? 0
                if m > reach { d = d.map { $0 * reach / m } }
                for c in 0..<3 { data[i + c] = UInt8(min(max(bg[c] + d[c], 0), 255).rounded()) }
            }
        }
        return ctx.makeImage()
    }

    /// Picture: the tone of the first picture that decodes (cached per picture and size), thresholded in the request's
    /// inks and shape (`PictureInk`). Logs the time and the cached bytes.
    nonisolated static func renderInk(_ request: Request) -> CGImage? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let urls = [request.url].compactMap { $0 } + request.fallbacks
        guard let tone = PictureInk.tone(urls, width: request.width, height: request.height, cell: Double(request.dot)) else { return nil }
        let inks = switch request.ink {
        case .auto: PictureInk.inks(hue: tone.hue)
        case let .color(c): PictureInk.inks(light: c)
        }
        let ground = request.background.count == 3 ? SIMD3(request.background[0], request.background[1], request.background[2]) : .zero
        let text = request.text.count == 6 ? [SIMD3(request.text[0], request.text[1], request.text[2]), SIMD3(request.text[3], request.text[4], request.text[5])] : []
        let art = PictureInk.render(tone, inks: inks, ground: ground, dark: request.dark, shape: request.shape, text: text)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        log.notice("picture \(request.width) x \(request.height) cells of \(request.dot, format: .fixed(precision: 1)) pt in \(ms, format: .fixed(precision: 1)) ms, \(request.width * request.height * 5) bytes")
        return art
    }

    /// Blurs `ctx`'s pixels in place by about `blurSigma`, the edges extended so no dark rim creeps in. Runs once per
    /// render. Two tent passes are four box passes, which match a Gaussian closely; vImage needs no GPU context.
    nonisolated static func blur(_ ctx: CGContext, width w: Int, height h: Int, sigma points: CGFloat = blurSigma) {
        guard let data = ctx.data else { return }
        let sigma = Double(points / blurPixel)
        // A box of width b has variance (b² - 1) / 12, and four of them make the Gaussian's σ². A tent of width 2b - 1 is
        // two such boxes.
        let box = Int((sqrt(12 * sigma * sigma / 4 + 1)).rounded()) | 1
        var buffer = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: ctx.bytesPerRow)
        guard let scratch = malloc(ctx.bytesPerRow * h) else { return }
        defer { free(scratch) }
        var temp = vImage_Buffer(data: scratch, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: ctx.bytesPerRow)
        let k = UInt32(2 * box - 1)
        vImageTentConvolve_ARGB8888(&buffer, &temp, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
        vImageTentConvolve_ARGB8888(&temp, &buffer, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
    }
}
