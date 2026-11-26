import Accelerate
import AppKit
import ImageIO
import os

/// The Dither theme's art (CandyWrapper's own, after Capy's desktop app). Picture: the chosen or desktop picture as a
/// two-ink Bayer dither on 3pt cells (`PictureInk`), thinning around the new thread's composer and behind a thread's
/// reading column so text keeps its floors, with no dim layer. Blur: the picture blurred behind the whole window.
/// Flower: a lotus over a field of accent cells, with no picture (`LotusArt`). Settings and other pages lay a heavy
/// scrim of the background over the picture. It renders once per size, picture, appearance, ink and page shape off the main thread and never moves in Picture
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
    /// Whether the window is visible, unminiaturized, not covered and key; tests set it.
    var windowIsActiveOverride: Bool?
    /// Flower: the ink color through the current frame's mask (`LotusArt`), inside `flowerHost`, which carries the
    /// reading column's still mask in a thread and light's faintness, and moves and scales without touching the art.
    let flowerHost = CALayer()
    let flower = CALayer()
    let flowerMask = CALayer()
    /// The column's mask on `flowerHost`, and what it was built from.
    let columnLayer = CALayer()
    var columnKey: ColumnKey?
    /// The flower blurred, for the surfaces that float over it (`FlowerGlassView`), and what it was built from.
    var glowImage: CGImage?
    /// The glow's brightest pixel, 0...1, so the surfaces can cap it for their text.
    var glowPeak: Float = 0
    var glowKey: ColumnKey?
    /// The frames on screen: the open still, the bloom while it plays, and the new thread's packed idle loop.
    var flowerSet: FlowerSet?
    /// The set being rendered, and the job rendering it.
    var flowerWanted: FlowerKey?
    var flowerJob: FlowerJob?
    /// The content area the flower fills, in the art's top-left space, and the page.
    var flowerContent: CGRect?
    var flowerKind: LotusArt.Kind?
    /// When the last geometry change came, to tell a drag from a single change, and the settle after a drag.
    var flowerMovedAt: CFTimeInterval = 0
    var flowerSettle: DispatchWorkItem?
    /// When a thread or the new-thread page last opened (`flowerOpened`), until the bloom plays or goes stale.
    var bloomRequestedAt: CFTimeInterval?
    /// Layer time the playing bloom ends at, and the work that drops its frames after.
    var bloomEnds: CFTimeInterval = 0
    var bloomDone: DispatchWorkItem?
    var flowerShownOnce = false
    /// The new thread's turn: a timer at `LotusArt.idleFPS` that expands one packed frame at a time, only while it
    /// turns. `turnStart` is the time frame 0 showed.
    var turnTimer: Timer?
    var turnStart: CFTimeInterval = 0
    var turnIndex = 0
    /// The field shows alone while an opening waits for its frames.
    var fieldOnly = false
    /// Where the field's loop stands, 0...1, on `DitherArt.gradientFPS` steps; it moves only with the turn.
    var fieldT: Double = 0
    var fieldStart: CFTimeInterval = 0
    /// The top of what floats over the new thread's flower, in this view's top-left space.
    var flowerFloorTop: CGFloat?
    /// The new thread's opening for the current area (`LotusArt.opening`), whether it is playing, and the move's start.
    var flowerOpening: LotusArt.Opening?
    var openingPlaying = false
    var openingFly: DispatchWorkItem?
    var openingLand: DispatchWorkItem?
    /// When the new-thread page last stopped showing the flower, so a quick return shows it at rest.
    var heroLeftAt: CFTimeInterval?
    /// The opening the running job renders frames for.
    var flowerJobOpening: LotusArt.Opening?
    /// The canvas the current area wants, and the frames the running job makes.
    var flowerTarget: FlowerKey?
    var flowerJobParts: FlowerParts = []
    /// A resize or drag is in progress: the shown frame scales and nothing renders until it settles.
    var flowerResizing = false
    /// The frames' cell codes, newest key first (`flowerCodes(for:)`). They stay while the window shows, across pages
    /// and returns, and go with the window or the Flower.
    var flowerCodeSets: [FlowerCodes] = []

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
        scrim.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
        scrim.startPoint = CGPoint(x: 0, y: 0.5)
        scrim.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.masksToBounds = true
        layer?.addSublayer(art)
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "opacity": NSNull(),
                                         "hidden": NSNull(), "contents": NSNull(), "path": NSNull(), "fillColor": NSNull(), "mask": NSNull()]
        flower.mask = flowerMask
        for l in [flowerHost, flower, flowerMask, columnLayer] { l.actions = still }
        for l in [flowerMask, columnLayer] { l.contentsGravity = .resize; l.magnificationFilter = .nearest }
        flowerHost.addSublayer(flower)
        flowerHost.isHidden = true
        layer?.addSublayer(flowerHost)
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

    @objc private func desktopMayHaveChanged(_ note: Notification) { desktopAnswer = nil; refresh() }

    /// The desktop picture for one screen, kept so a refresh reads no disk: a live resize refreshes every layout step,
    /// and a lookup took 2.5 to 3.3 ms on the main thread (2026-11-21). Dropped on every event that can change the
    /// answer (a Space or screen change, the app becoming active, a theme or setting change, a new window or backing
    /// scale) and whenever the window hides.
    private var desktopAnswer: (screen: NSScreen?, url: URL?)?
    private(set) var desktopLookupsForTesting = 0

    private func desktopPicture(for screen: NSScreen?) -> URL? {
        if let desktopAnswer, desktopAnswer.screen === screen { return desktopAnswer.url }
        desktopLookupsForTesting += 1
        let url = DitherArt.desktopPicture(for: screen)
        desktopAnswer = (screen, url)
        return url
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func displayOptionsChanged(_ note: Notification) { updateScrim() }
    /// The ink, the accent and the palette's ground feed Picture's render, so a theme change may render again.
    @objc private func themeChanged(_ note: Notification) { desktopAnswer = nil; refresh() }

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
        // The Flower and Picture's shape follow the page, so a page change may render again.
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

    /// A thread page calls this from its layout with where the Flower background sits, in its own coordinates: its
    /// content area, which the flower fills (`LotusArt.spot(in:)`), and the top of what floats over the new thread's
    /// flower (the composer and the chips above it), which the opening bloom sits above.
    @MainActor
    public static func setFlowerStage(kind: LotusArt.Kind, content: NSRect, floorTop: CGFloat? = nil, from source: NSView) {
        let box = FlowerStageBox(kind: kind, content: content, floorTop: floorTop)
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
        desktopAnswer = nil
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
            shown = nil; pending = nil; desktopAnswer = nil
            art.contents = nil
            dropFlower()
            flowerCodeSets = []
            PictureInk.dropCache()
        } else if shown == nil {
            refresh()
        }
        syncMotion()
    }

    @objc private func keyChanged(_ note: Notification) { syncMotion() }

    /// The art or a view above it hidden: nothing moves.
    public override func viewDidHide() { super.viewDidHide(); syncMotion() }
    public override func viewDidUnhide() { super.viewDidUnhide(); syncMotion() }

    static let launchedInBackground = CommandLine.arguments.contains("--background")

    /// Whether the window shows and has the user's attention: visible, not miniaturized or covered, and key.
    private var windowIsActive: Bool {
        if let windowIsActiveOverride { return windowIsActiveOverride }
        guard let window else { return false }
        // A test app launched behind the other windows (`scripts/run-app --background`) never becomes key or uncovered;
        // it counts as active so agents can record the motion from behind.
        if Self.launchedInBackground { return window.isVisible && !window.isMiniaturized }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) && window.isKeyWindow
    }

    /// The Flower moves only while it can be seen and wanted (`syncFlowerMotion`); nothing else here moves.
    func syncMotion() {
        syncFlowerMotion()
    }

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
        desktopAnswer = nil
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
        } else {
            let k = max(bounds.width / w, bounds.height / h)
            art.frame = CGRect(x: (bounds.width - w * k) / 2, y: (bounds.height - h * k) / 2, width: w * k, height: h * k)
        }
    }

    /// The canvas size, in cells, a render for this panel's size would have in `request`'s mode.
    private func canvasSize(for request: DitherArt.Request) -> (width: Int, height: Int) {
        (Int((artRect.width / request.unit).rounded(.up)), Int((artRect.height / request.unit).rounded(.up)))
    }

    /// How many renders reached the screen, for tests.
    private(set) var rendersForTesting = 0

    /// The drag or window resize ended: render the sharp art now instead of after the pause.
    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if flowerResizing { settleFlower() }
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
        // Flower: the lotus on a new thread and beside a thread's column, the plain ground everywhere else.
        let flowerOn = ThemeRuntime.ditherFlower
        let artHidden = flowerOn
        if art.isHidden != artHidden { art.isHidden = artHidden }
        let picture = !flowerOn && !ThemeRuntime.ditherBlur
        let alpha = flowerOn ? 0 : DitherArt.scrim(page, display, light: !dark, picture: picture)
        if loggedScrim != alpha {
            DitherArt.log.notice("scrim \(alpha) on \(String(describing: page), privacy: .public): reduce transparency \(display.reduceTransparency), increase contrast \(display.increaseContrast), dark \(dark)")
        }
        loggedScrim = alpha
        scrim.backgroundColor = background.withAlphaComponent(alpha).cgColor
        CATransaction.commit()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The veil follows the column through a live resize, so it never animates.
        let veil = flowerOn || picture ? 0 : DitherArt.veil(page, reduceTransparency: display.reduceTransparency)
        if veil > 0, bounds.width >= 1, let front, let column = Self.columns.object(forKey: front)?.rectValue {
            let lane = convert(column, from: front)
            let xs = (0...64).map { bounds.width * CGFloat($0) / 64 }
            scrim.locations = xs.map { NSNumber(value: Double($0 / bounds.width)) }
            scrim.colors = xs.map { background.withAlphaComponent(veil * DitherArt.veilShare($0, lane: lane.minX...lane.maxX)).cgColor }
        } else {
            scrim.colors = nil
        }
        // Blur runs under the band too, so the band shows the picture and needs no blend; Flower's dots run to the top.
        blend.isHidden = ThemeRuntime.ditherBlur || ThemeRuntime.ditherFlower
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
            shown = nil; pending = nil; desktopAnswer = nil
            art.contents = nil; art.mask = nil
            refreshFlower(palette: palette, dark: dark)
            return
        }
        if flowerSet != nil || flowerWanted != nil || !flowerHost.isHidden { flowerContent = nil; dropFlower() }
        flowerCodeSets = []
        let request: DitherArt.Request
        do {
            let desktop = desktopPicture(for: window.screen)
            let url = ThemeRuntime.ditherPicture ?? desktop
            let fallbacks = [desktop, DitherArt.defaultDesktop].compactMap { $0 }.filter { $0 != url }
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
                made.textDim = ThemeRuntime.ditherTextDim
            }
            request = made
        }
        guard request != shown, request != pending else { return }
        // Only a new size waits for the drag to pause; a page, ink or picture change renders at once.
        let resizing = shown.map { $0.width != request.width || $0.height != request.height } ?? false
        // A "Dim behind text" drag only re-thresholds the cached tone, but lands every tick: the last value renders.
        var dimOnly = (pending ?? shown).map { $0.textDim != request.textDim } ?? false
        if dimOnly, var same = pending ?? shown { same.textDim = request.textDim; dimOnly = same == request }
        pending = request
        debounce?.cancel()
        // A live resize lands here every frame; the last size renders, the old art scales with the panel meanwhile.
        if rendersInlineForTesting {
            show(request, image: Self.render(request))
            return
        }
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let image = Self.render(request)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.show(request, image: image) }
                }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (resizing ? 0.15 : dimOnly ? 0.06 : 0), execute: work)
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
    /// Flower render jobs started and cancelled before they finished, and, while `holdsFlowerJobsForTesting`, the
    /// inline jobs waiting for the test to run them, so a test sees what a slow render overlaps.
    var flowerJobsForTesting = 0
    var flowerCancelsForTesting = 0
    var holdsFlowerJobsForTesting = false
    var heldFlowerJobsForTesting: [() -> Void] = []

    /// The picture's art. Runs on any thread.
    private nonisolated static func render(_ request: DitherArt.Request) -> DitherArtImage {
        DitherArtImage(image: DitherArt.render(request))
    }

    private func show(_ request: DitherArt.Request, image: DitherArtImage) {
        guard pending == request else { return }
        pending = nil
        rendersForTesting += 1
        // A render that failed isn't remembered, so the next refresh tries again.
        shown = image.image == nil ? nil : request
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.mask = nil
        art.backgroundColor = nil
        art.contents = image.image
        placeArt()
        CATransaction.commit()
        syncMotion()
    }

    var contentsForTesting: CGImage? { art.contents.map { $0 as! CGImage } }
    var requestForTesting: DitherArt.Request? { pending ?? shown }
    var scrimAlphaForTesting: CGFloat { scrim.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0 }
}

// MARK: Flower

/// One flower frame set's identity: its canvas (the content area's cells and the flower on them) and the appearance.
struct FlowerKey: Hashable, Sendable {
    /// The flower's resting canvas, and the content area's whole canvas, which the field covers and the layer shows.
    var placement: LotusArt.Placement
    var full: LotusArt.Placement
    var dark: Bool
}

/// What the column mask and the glow were built from.
struct ColumnKey: Equatable {
    var placement: LotusArt.Placement
    var column: ClosedRange<CGFloat>?
    var cap: Float
    var dark: Bool
    /// "Dim behind text" (`TextDim`).
    var dim = TextDim.standard
}

/// Which frames a render makes.
struct FlowerParts: OptionSet, Sendable {
    let rawValue: Int
    static let open = FlowerParts(rawValue: 1), bloom = FlowerParts(rawValue: 2), idle = FlowerParts(rawValue: 4)
    static let opening = FlowerParts(rawValue: 8), flight = FlowerParts(rawValue: 16)
}

/// A flower's frames. Only `open` stays while the flower rests: the bloom renders for an opening and goes once it has
/// played, and the new thread's idle loop is held packed, two bits a cell, one frame expanded at a time.
struct FlowerSet: @unchecked Sendable {
    var key: FlowerKey
    /// The open flower over the field, as shown (the whole canvas), and the flower alone as codes.
    var open: CGImage
    var openCodes: [UInt8] = []
    var bloom: [CGImage] = []
    var idle: [[UInt8]] = []
    /// The new thread's opening: its bloom above the composer and the move down, on the content area's full canvas,
    /// held only from the opening until the flower lands.
    var opening: LotusArt.Opening?
    var openingBloom: [CGImage] = []
    var flight: [CGImage] = []
    var bytes: Int {
        (([open] + bloom + openingBloom + flight).reduce(0) { $0 + $1.bytesPerRow * $1.height }) + idle.reduce(0) { $0 + $1.count }
            + openCodes.count
    }
}

/// A render in flight, cancelled when a newer one starts.
final class FlowerJob: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true } }
}

/// The flower's frames for one `FlowerKey` as packed cell codes, two bits a cell: what the model renders, before the
/// field is laid under it. They depend on nothing else (the ink, the accent and the backing scale only color or scale
/// the layer), so a return to the page, a thread's bloom and a replayed opening compose them over the field again
/// instead of rendering. Render jobs read and fill it from any thread.
final class FlowerCodes: @unchecked Sendable {
    enum Slot: Hashable { case open, bloom, idle, opening(LotusArt.Opening), flight(LotusArt.Opening) }
    let key: FlowerKey
    private let lock = NSLock()
    private var slots: [Slot: [[UInt8]]] = [:]
    private var renders = 0
    init(key: FlowerKey) { self.key = key }

    subscript(slot: Slot) -> [[UInt8]]? { lock.withLock { slots[slot] } }

    /// The slot's frames, rendered by `make` and kept the first time. Only the latest opening's frames stay: the
    /// composer moved for any other.
    func frames(_ slot: Slot, make: () -> [[UInt8]]?) -> [[UInt8]]? {
        if let hit = self[slot] { return hit }
        guard let made = make() else { return nil }
        lock.withLock {
            switch slot {
            case let .opening(o), let .flight(o):
                for old in slots.keys {
                    switch old { case let .opening(p) where p != o, let .flight(p) where p != o: slots[old] = nil; default: break }
                }
            default: break
            }
            slots[slot] = made
            renders += made.count
        }
        return made
    }

    /// Frames rendered from the model so far.
    var rendered: Int { lock.withLock { renders } }
    var bytes: Int { lock.withLock { slots.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } } }
    /// Keeps the open still only, for Animate off and Reduce Motion.
    func dropMotion() { lock.withLock { slots = slots.filter { $0.key == .open } } }
}

final class FlowerStageBox: Equatable {
    let kind: LotusArt.Kind, content: NSRect, floorTop: CGFloat?
    init(kind: LotusArt.Kind, content: NSRect, floorTop: CGFloat?) { self.kind = kind; self.content = content; self.floorTop = floorTop }
    static func == (a: FlowerStageBox, b: FlowerStageBox) -> Bool { a.kind == b.kind && a.content == b.content && a.floorTop == b.floorTop }
}

extension DitherArtView {
    /// How long an opening waits for its bloom frames before it gives up and shows the open flower.
    /// Tests on a loaded machine raise it, since a debug render can take that long.
    /// An unoptimized build renders about 50 times slower, so its first opening's frames take 10 s or more: it waits
    /// longer, so a walk on a test app still sees the bloom above the composer.
    nonisolated(unsafe) static var bloomPatience: CFTimeInterval = _isDebugAssertConfiguration() ? 20 : 4
    /// A geometry change this soon after the last one is part of a drag: the shown frame scales with it, and the new
    /// set renders after `settleDelay` of quiet. A live window resize renders when it ends.
    static let dragGap: CFTimeInterval = 0.25
    static let settleDelay: CFTimeInterval = 0.15
    /// Light's flower: much fainter, so it reads as a texture on the pale ground and the column's falloff shows no
    /// shape (the mock at full strength looked cut out around a pale blob).
    static func flowerOpacity(dark: Bool) -> Float { dark ? 1 : 0.4 }

    func requestBloom() {
        // Back on the new-thread page soon after leaving it: the flower shows at rest, no replay.
        if page == .hero, let left = heroLeftAt, CACurrentMediaTime() - left < LotusArt.replayInterval {
            bloomRequestedAt = nil
            syncFlowerMotion()
            return
        }
        bloomRequestedAt = CACurrentMediaTime()
        // The open flower that was showing goes at once; the field stays while the bud's frames render.
        if flowerMotionAllowed, flowerSet != nil {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            flowerMask.removeAnimation(forKey: "bloom")
            CATransaction.commit()
            stopTurn()
            showFieldOnly()
        }
        syncFlowerMotion()
        // If the bloom's frames never land, the open flower shows when the wait runs out.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bloomPatience + 0.05) { [weak self] in self?.syncFlowerMotion() }
    }

    /// The flower's ink as sRGB: the accent in dark, its hue at a deep lightness in light so the dots read on the
    /// off-white ground. Deep cells show it at `LotusArt.deepAlpha` over the ground, the second ink.
    static func flowerInkRGB(_ palette: Palette, dark: Bool) -> SIMD3<Double> {
        let a = palette.primary.srgb
        guard !dark else { return SIMD3(a.x, a.y, a.z) }
        let o = PictureInk.oklch(srgb: SIMD3(a.x, a.y, a.z))
        return PictureInk.srgb(oklch: LotusArt.lightInk.l, min(o.c, LotusArt.lightInk.c), o.h)
    }

    static func flowerInk(_ palette: Palette, dark: Bool) -> CGColor {
        let c = flowerInkRGB(palette, dark: dark)
        return CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
    }

    /// The front page's stage: its content area, and the floor's top, in this view's top-left space.
    private func flowerStage(_ page: DitherArt.Page, _ front: NSView?) -> (kind: LotusArt.Kind, content: CGRect, floorTop: CGFloat?)? {
        guard page == .hero || page == .thread, let front, let box = Self.stages.object(forKey: front) else { return nil }
        let l = convert(box.content, from: front)
        let floor = box.floorTop.map { bounds.height - convert(NSPoint(x: 0, y: $0), from: front).y }
        // The page starts under the window's band, but the panel, and the art, run to the window's top: the flower and
        // its field fill the panel from there (the user, 2026-11-21: "it should fully commit even at the top").
        return (box.kind, CGRect(x: l.minX, y: 0, width: l.width, height: bounds.height - l.minY), floor)
    }

    func refreshFlower(palette: Palette, dark: Bool) {
        let (page, front) = self.front
        guard let stage = flowerStage(page, front),
              let target = LotusArt.canvas(content: stage.content, cell: DitherArt.gradientUnit) else {
            flowerContent = nil
            dropFlower()
            return
        }
        if !flowerShownOnce { flowerShownOnce = true; bloomRequestedAt = bloomRequestedAt ?? CACurrentMediaTime() }
        let now = CACurrentMediaTime()
        if flowerKind == .hero, stage.kind != .hero { heroLeftAt = now }
        let moved = flowerContent != nil && stage.content != flowerContent
        // While the area changes size the shown frame scales with it; the sharp set renders when it settles.
        let resizing = moved && flowerSet?.key.dark == dark && (window?.inLiveResize == true || now - flowerMovedAt < Self.dragGap)
        if moved { flowerMovedAt = now }
        // A resize or the page turning into a thread mid-opening jumps to the flower at rest.
        if openingPlaying, moved || stage.kind != .hero { cancelOpening() }
        flowerContent = stage.content
        flowerKind = stage.kind
        flowerOpening = stage.kind == .hero ? stage.floorTop.flatMap { LotusArt.opening(content: stage.content, floorTop: $0, cell: DitherArt.gradientUnit) } : nil
        guard let full = LotusArt.fullCanvas(content: stage.content, cell: DitherArt.gradientUnit) else { dropFlower(); return }
        flowerTarget = FlowerKey(placement: target, full: full, dark: dark)
        flowerFloorTop = stage.floorTop
        flowerResizing = resizing
        // A drag's first step started a render for an area the drag has already left: it stops, and the set for where
        // the drag ends renders when it settles.
        if resizing, let job = flowerJob, flowerWanted != flowerTarget {
            if !job.cancelled { flowerCancelsForTesting += 1 }
            job.cancel()
            flowerJob = nil; flowerWanted = nil; flowerJobParts = []; flowerJobOpening = nil
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flower.backgroundColor = Self.flowerInk(palette, dark: dark)
        flowerHost.opacity = Self.flowerOpacity(dark: dark)
        flowerHost.isHidden = false
        CATransaction.commit()
        if resizing, window?.inLiveResize != true {
            flowerSettle?.cancel()
            let settle = DispatchWorkItem { [weak self] in self?.settleFlower() }
            flowerSettle = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: settle)
        }
        placeFlower()
        updateFlowerOverlays(palette: palette, dark: dark)
        ensureFlowerFrames()
        syncFlowerMotion()
    }

    /// The drag or resize ended: the set for the new area renders.
    func settleFlower() {
        flowerSettle?.cancel()
        flowerSettle = nil
        guard flowerResizing else { return }
        flowerResizing = false
        flowerMovedAt = 0
        refresh()
    }

    /// The flower's frame in this view's (unflipped) space. With the set for the current area, every dot is exactly one
    /// cell on the art's lattice; while another area's set shows (a resize in progress), it scales to the flower's new
    /// centre and radius.
    func flowerFrame() -> CGRect? {
        guard let set = flowerSet else { return nil }
        // A resize in progress stretches the shown canvas over the new area until its own set lands.
        let p = flowerTarget?.full ?? set.key.full, cell = DitherArt.gradientUnit
        return CGRect(x: CGFloat(p.originX) * cell, y: bounds.height - CGFloat(p.originY + p.height) * cell,
                      width: CGFloat(p.width) * cell, height: CGFloat(p.height) * cell)
    }

    func placeFlower() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let frame = flowerFrame() {
            flowerHost.frame = frame
            for l in [flower, flowerMask, columnLayer] { l.frame = flowerHost.bounds }
        }
        syncGlow()
    }

    /// The column's still mask over the flower in a thread, and the blurred flower under the floating surfaces, from
    /// the open frame. Both build on the main thread in about a millisecond, and only when what they show changed.
    func updateFlowerOverlays(palette: Palette, dark: Bool) {
        guard let set = flowerSet else { return }
        let p = set.key.full, cell = DitherArt.gradientUnit
        var column: ClosedRange<CGFloat>?
        if flowerKind == .thread, let front = front.view, let lane = Self.columns.object(forKey: front)?.rectValue {
            let l = convert(lane, from: front)
            column = (l.minX / cell).rounded() * cell...(l.maxX / cell).rounded() * cell
        }
        let text = palette.foreground.srgb, muted = palette.mutedForeground.srgb, ground = palette.background.srgb
        let cap = column == nil ? 1 : LotusArt.columnCap(ground: SIMD3(ground.x, ground.y, ground.z), ink: Self.flowerInkRGB(palette, dark: dark),
                                                         text: SIMD3(text.x, text.y, text.z), muted: SIMD3(muted.x, muted.y, muted.z),
                                                         opacity: Double(Self.flowerOpacity(dark: dark)), dark: dark)
        // "Dim behind text" scales the mask's depth; at 0 the flower runs at full strength behind the column.
        let dim = ThemeRuntime.ditherTextDim
        if dim <= 0 { column = nil }
        let key = ColumnKey(placement: p, column: column, cap: cap, dark: dark, dim: dim)
        let glass = RedesignTokens.FlowerGlass.isOn(dark: dark)
        guard key != columnKey || (glass && glowKey != key) || (!glass && glowKey != nil) else { return }
        let mask = column.map { LotusArt.columnMask(p, column: $0, cap: Self.flowerShare(cap, dim: dim), keep: Self.flowerShare(LotusArt.columnKeep, dim: dim),
                                                    dark: dark, cell: cell) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if key != columnKey {
            columnKey = key
            columnLayer.contents = mask.flatMap { LotusArt.image($0, width: p.width, height: p.height) }
            flowerHost.mask = mask == nil ? nil : columnLayer
        }
        if glass {
            glowKey = key
            // A quarter-size copy: the blur is wide, so the detail lost costs nothing, and it builds in about a millisecond.
            let g = LotusArt.glow(Self.bytes(set.open, width: p.width, height: p.height), over: mask, placement: p,
                                  radius: RedesignTokens.FlowerGlass.blur, scale: LotusArt.glowScale, cell: cell)
            glowImage = LotusArt.image(g.pixels, width: g.width, height: g.height)
            glowPeak = Float(g.pixels.max() ?? 0) / 255
        } else {
            glowKey = nil
            glowImage = nil
        }
        syncGlow()
    }

    /// The flower mask's `share` of ink or dots over the column at "Dim behind text" `dim` (`TextDim.share`).
    nonisolated static func flowerShare(_ share: Float, dim: Int) -> Float { Float(TextDim.share(Double(share), at: dim)) }

    /// Publishes the glow to the surfaces over the flower (`FlowerGlassView`): shown once the flower is open, not
    /// during a bloom, so the surfaces never show a full flower's glow over a bud.
    func syncGlow() {
        guard let window else { return }
        guard let image = glowImage, flowerSet != nil, !flowerHost.isHidden, let frame = flowerFrame() else {
            if FlowerGlassView.sources.object(forKey: window) != nil { FlowerGlassView.publish(nil, in: window) }
            return
        }
        let now = flowerMask.convertTime(CACurrentMediaTime(), from: nil)
        let blooming = (flowerMask.animation(forKey: "bloom") != nil && now < bloomEnds) || fieldOnly || openingPlaying
        let source = FlowerGlassView.Source(image: image, frame: convert(frame, to: nil), ink: flower.backgroundColor ?? .black,
                                            opacity: flowerHost.opacity, peak: glowPeak, shown: !blooming)
        if let old = FlowerGlassView.sources.object(forKey: window)?.source, old.image === source.image, old.frame == source.frame,
           old.shown == source.shown, old.opacity == source.opacity, old.ink == source.ink { return }
        FlowerGlassView.publish(source, in: window)
    }

    /// A one-byte-a-pixel image's rows, packed.
    static func bytes(_ image: CGImage, width w: Int, height h: Int) -> [UInt8] {
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data), image.bitsPerPixel == 8 else {
            return [UInt8](repeating: 0, count: w * h)
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = base[y * image.bytesPerRow + x] } }
        return out
    }

    /// What the flower needs now that it doesn't have: the open still for the current area, the bloom while an opening
    /// waits for it, and the new thread's idle loop while it may turn.
    func neededFlowerParts() -> FlowerParts {
        guard let target = flowerTarget, !flowerResizing else { return [] }
        let have = flowerSet?.key == target ? flowerSet : nil
        var need: FlowerParts = have == nil ? [.open] : []
        if flowerMotionAllowed {
            if bloomRequestedAt != nil, bloomPending, let o = flowerOpening {
                if have?.opening != o || have?.openingBloom.isEmpty ?? true { need.insert(.opening) }
                if have?.opening != o || have?.flight.isEmpty ?? true { need.insert(.flight) }
            } else if bloomRequestedAt != nil, bloomPending, !awaitingFloor, have?.bloom.isEmpty ?? true { need.insert(.bloom) }
            if flowerKind == .hero, have?.idle.isEmpty ?? true { need.insert(.idle) }
        }
        return need
    }

    func ensureFlowerFrames() {
        guard let target = flowerTarget else { return }
        let need = neededFlowerParts()
        guard !need.isEmpty else { return }
        if flowerWanted == target, flowerJobParts.isSuperset(of: need), flowerJobOpening == flowerOpening || !need.contains(.opening) { return }
        // Only what is missing now: a running job's finished parts are kept in `flowerCodes`, and a part it was making
        // that the page no longer wants (a plain bloom once the opening's geometry came) would render for nothing.
        renderFlower(target, need, opening: flowerOpening)
    }

    /// The cell codes for `key`, kept for the two keys used last: the new thread's and a thread's, when a right panel
    /// makes them differ. A resize settles on a new key and the oldest goes.
    func flowerCodes(for key: FlowerKey) -> FlowerCodes {
        if let i = flowerCodeSets.firstIndex(where: { $0.key == key }) {
            let hit = flowerCodeSets.remove(at: i)
            flowerCodeSets.insert(hit, at: 0)
            return hit
        }
        let made = FlowerCodes(key: key)
        flowerCodeSets = Array(([made] + flowerCodeSets).prefix(2))
        return made
    }

    /// Renders `parts` of `key` off the main thread, across the cores, each handed over as it lands.
    private func renderFlower(_ key: FlowerKey, _ parts: FlowerParts, opening: LotusArt.Opening? = nil) {
        if let old = flowerJob, !old.cancelled { flowerCancelsForTesting += 1 }
        flowerJob?.cancel()
        let job = FlowerJob()
        flowerJob = job
        flowerJobsForTesting += 1
        flowerWanted = key
        let parts = opening == nil ? parts.subtracting([.opening, .flight]) : parts
        flowerJobParts = parts
        flowerJobOpening = opening
        let codes = flowerCodes(for: key)
        if rendersInlineForTesting {
            let fieldT = fieldT
            let run = { [weak self] in
                var phases = Self.flowerPhases(key, parts, opening: opening, fieldT: fieldT, job: job, codes: codes)
                while let phase = phases.next() { self?.receiveFlower(phase, key: key, job: job) }
                self?.receiveFlower(.done, key: key, job: job)
            }
            if holdsFlowerJobsForTesting { heldFlowerJobsForTesting.append(run) } else { run() }
            return
        }
        let deliver: @Sendable (FlowerPhase) -> Void = { [weak self] phase in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveFlower(phase, key: key, job: job) } }
        }
        let fieldT = fieldT
        // What shows first (the open still, the opening, a bloom) renders at once; the new thread's loop, two thirds of
        // the work and wanted only once they have played, renders after them at utility, which can run on the
        // efficiency cores.
        DispatchQueue.global(qos: .userInitiated).async {
            var phases = Self.flowerPhases(key, parts.subtracting(.idle), opening: opening, fieldT: fieldT, job: job, codes: codes)
            while let phase = phases.next() { deliver(phase) }
            guard parts.contains(.idle), !job.cancelled else { deliver(.done); return }
            DispatchQueue.global(qos: .utility).async {
                var loop = Self.flowerPhases(key, .idle, opening: opening, fieldT: fieldT, job: job, codes: codes)
                while let phase = loop.next() { deliver(phase) }
                deliver(.done)
            }
        }
    }

    enum FlowerPhase: @unchecked Sendable {
        case open(CGImage, [UInt8]), bloom([CGImage]), idle([[UInt8]]), opening(LotusArt.Opening, [CGImage]), flight(LotusArt.Opening, [CGImage]), done
    }

    /// Samples a cell side, 2; tests that render inline take 1, since a debug build renders about 60 times slower.
    @TaskLocal static var flowerSamples = 2

    /// The phases one at a time, so each reaches the screen before the next renders. Frames `codes` holds compose
    /// over the field without rendering.
    nonisolated static func flowerPhases(_ key: FlowerKey, _ parts: FlowerParts, opening: LotusArt.Opening? = nil, fieldT: Double = 0,
                                         job: FlowerJob, codes: FlowerCodes) -> AnyIterator<FlowerPhase> {
        let p = key.placement, samples = flowerSamples, full = key.full, dark = key.dark
        // Every frame shows over the field as it stands when the job starts; the field holds still while they play.
        let stop: @Sendable () -> Bool = { job.cancelled }
        let images: ([[UInt8]], LotusArt.Placement) -> [CGImage]? = { packed, on in
            LotusArt.images(packed, flower: on, full: full, t: fieldT, dark: dark, stop: stop)
        }
        var step = 0
        return AnyIterator {
            // The open still first, then the opening's bloom and move (the bloom plays while the move renders), then
            // a thread's bloom, then the loop.
            let order = [0, 3, 4, 1, 2]
            while step < order.count {
                defer { step += 1 }
                guard !job.cancelled else { return nil }
                let t0 = DispatchTime.now().uptimeNanoseconds, before = codes.rendered, part = order[step]
                let phase: FlowerPhase?
                switch part {
                case 3 where parts.contains(.opening):
                    guard let o = opening else { continue }
                    let density = LotusArt.openingDensity(o, share: 1)
                    phase = codes.frames(.opening(o)) {
                        LotusArt.packedFrames(LotusArt.openingBloomPoses().map { ($0, o.bloom) }, dark: dark, density: { _ in density },
                                              samples: samples, stop: stop)
                    }.flatMap { images($0, o.bloom) }.map { FlowerPhase.opening(o, $0) }
                case 4 where parts.contains(.flight):
                    guard let o = opening else { continue }
                    phase = codes.frames(.flight(o)) {
                        let frames = LotusArt.flightFrames(o)
                        return LotusArt.packedFrames(frames.map { ($0.pose, $0.placement) }, dark: dark,
                                                     density: { LotusArt.openingDensity(o, share: frames[$0].thinning) }, samples: samples, stop: stop)
                    }.flatMap { images($0, o.canvas) }.map { FlowerPhase.flight(o, $0) }
                case 0 where parts.contains(.open):
                    phase = codes.frames(.open) {
                        LotusArt.withCells(LotusArt.openPose, placement: p, samples: samples) { light, cover in
                            [LotusArt.pack(LotusArt.codes(light: light, cover: cover, placement: p, dark: dark))]
                        }
                    }.flatMap { packed -> FlowerPhase? in
                        LotusArt.frame(packed: packed[0], flower: p, full: full, t: fieldT, dark: dark)
                            .map { FlowerPhase.open($0, LotusArt.unpack(packed[0], count: p.width * p.height)) }
                    }
                case 1 where parts.contains(.bloom):
                    phase = codes.frames(.bloom) {
                        LotusArt.packedFrames(LotusArt.bloomPoses().map { ($0, p) }, dark: dark, density: { _ in nil }, samples: samples, stop: stop)
                    }.flatMap { images($0, p) }.map(FlowerPhase.bloom)
                case 2 where parts.contains(.idle):
                    phase = codes.frames(.idle) {
                        LotusArt.packedMasks(LotusArt.idlePoses(), placement: p, dark: dark, samples: samples, stop: stop)
                    }.map(FlowerPhase.idle)
                default: continue
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6, rendered = codes.rendered - before
                DitherArt.log.notice("flower \(p.width) x \(p.height) cells on \(full.width) x \(full.height), part \(part): \(ms, format: .fixed(precision: 1)) ms, \(rendered) frames rendered")
                if let phase { return phase }
            }
            return nil
        }
    }

    private func receiveFlower(_ phase: FlowerPhase, key: FlowerKey, job: FlowerJob) {
        guard flowerJob === job, !job.cancelled, ThemeRuntime.ditherFlower else { return }
        switch phase {
        case let .open(image, codes):
            rendersForTesting += 1
            stopTurn()
            turnIndex = 0
            flowerSet = FlowerSet(key: key, open: image, openCodes: codes)
            columnKey = nil; glowKey = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            flowerMask.removeAnimation(forKey: "bloom")
            flowerMask.contents = image
            CATransaction.commit()
            placeFlower()
            let dark = effectiveAppearance.isDark
            updateFlowerOverlays(palette: ThemeRuntime.palettes.palette(dark: dark, sidebar: false), dark: dark)
        case let .bloom(images):
            rendersForTesting += 1
            // An opening that gave up waiting keeps no frames it won't play.
            if flowerSet?.key == key, bloomRequestedAt != nil { flowerSet?.bloom = images }
        case let .idle(frames):
            rendersForTesting += 1
            if flowerSet?.key == key, flowerKind == .hero { flowerSet?.idle = frames }
        case let .opening(o, frames):
            rendersForTesting += 1
            if flowerSet?.key == key, bloomRequestedAt != nil, o == flowerOpening {
                if flowerSet?.opening != o { flowerSet?.flight = [] }
                flowerSet?.opening = o
                flowerSet?.openingBloom = frames
            }
        case let .flight(o, frames):
            rendersForTesting += 1
            if flowerSet?.key == key, flowerSet?.opening == o, bloomRequestedAt != nil || openingPlaying { flowerSet?.flight = frames }
            if openingPlaying, openingFly == nil { fly() }
        case .done:
            flowerJob = nil; flowerWanted = nil; flowerJobParts = []; flowerJobOpening = nil
            if let set = flowerSet { DitherArt.log.notice("flower set \(set.key.placement.width) x \(set.key.placement.height) cells: \(set.bytes / 1024) KB") }
        }
        syncFlowerMotion()
    }

    /// The new thread whose composer's top hasn't come yet.
    var awaitingFloor: Bool { flowerKind == .hero && flowerFloorTop == nil }

    /// Whether a fresh opening still waits for its bloom.
    var bloomPending: Bool {
        guard let at = bloomRequestedAt else { return false }
        return CACurrentMediaTime() - at < Self.bloomPatience
    }

    var flowerMotionAllowed: Bool {
        ThemeRuntime.ditherFlower && ThemeRuntime.ditherGradientAnimates && !Motion.reduced && windowIsActive
            && flowerContent != nil && !flowerHost.isHidden && !isHiddenOrHasHiddenAncestor
    }

    /// Frames rendered from the model for the kept keys.
    var flowerFramesRendered: Int { flowerCodeSets.reduce(0) { $0 + $1.rendered } }

    /// The flower moves only while it can be seen and wanted: Flower with Animate on, the window active, Reduce Motion
    /// off. An opening plays the bloom once, bud to open; then a thread holds the open flower still (turning dots
    /// flicker behind text) and the new thread turns slowly. Anything else stops and holds the open flower or the turn's
    /// frame, so nothing runs while the flower rests.
    func syncFlowerMotion() {
        guard let set = flowerSet, flowerContent != nil else { stopTurn(); return }
        let now = flowerMask.convertTime(CACurrentMediaTime(), from: nil)
        let blooming = flowerMask.animation(forKey: "bloom") != nil && now < bloomEnds
        defer { syncGlow() }
        guard flowerMotionAllowed else {
            bloomRequestedAt = nil
            stopTurn()
            if openingPlaying || !set.openingBloom.isEmpty || !set.flight.isEmpty { cancelOpening() }
            if flowerMask.animation(forKey: "bloom") != nil || fieldOnly || !set.bloom.isEmpty { endBloom() }
            // Animate off and Reduce Motion show the open flower and hold no loop. A window in the background keeps
            // the turn's frame and the packed loop, so coming back resumes where it stopped.
            if !ThemeRuntime.ditherGradientAnimates || Motion.reduced { for codes in flowerCodeSets { codes.dropMotion() } }
            if !ThemeRuntime.ditherGradientAnimates || Motion.reduced || flowerKind != .hero {
                flowerSet?.idle = []
                turnIndex = 0
                if flowerMask.contents as AnyObject? !== flowerSet?.open {
                    recomposeOpen()
                    CATransaction.begin(); CATransaction.setDisableActions(true); flowerMask.contents = flowerSet?.open; CATransaction.commit()
                }
            }
            return
        }
        if bloomRequestedAt != nil, bloomPending, let o = flowerOpening, flowerKind == .hero {
            guard set.opening == o, !set.openingBloom.isEmpty else {
                if !openingPlaying { showFieldOnly() }
                ensureFlowerFrames()
                return
            }
            bloomRequestedAt = nil
            startOpening(set)
            ensureFlowerFrames()
            return
        } else if bloomRequestedAt != nil, bloomPending, awaitingFloor {
            // The new thread's stage came before its composer's top: the field alone until the opening knows where the
            // bloom goes. A plain bloom here would play at the resting spot and use up the opening.
            if !blooming { showFieldOnly() }
            return
        } else if bloomRequestedAt != nil, bloomPending {
            guard !set.bloom.isEmpty else {
                // Waiting for the bloom's frames: the field alone shows until they land, or the wait runs out.
                if !blooming { showFieldOnly() }
                ensureFlowerFrames()
                return
            }
            bloomRequestedAt = nil
            startBloom(set)
        } else if openingPlaying {
            return
        } else if bloomRequestedAt != nil || fieldOnly {
            // The wait ran out: the open flower.
            bloomRequestedAt = nil
            fieldOnly = false
            CATransaction.begin(); CATransaction.setDisableActions(true); flowerMask.contents = set.open; CATransaction.commit()
        }
        guard flowerKind == .hero else {
            stopTurn()
            if !set.idle.isEmpty { flowerSet?.idle = [] }
            return
        }
        ensureFlowerFrames()
        guard !openingPlaying, let idle = flowerSet?.idle, idle.count > 1, turnTimer == nil else { return }
        let nowBloom = flowerMask.animation(forKey: "bloom") != nil && now < bloomEnds
        startTurn(after: nowBloom ? bloomEnds - now : 0, frames: idle.count)
    }

    static func bloomDuration(_ set: FlowerSet) -> CFTimeInterval { Double(set.bloom.count + 1) / LotusArt.bloomFPS }

    /// The bloom's frames then the open flower, held, fading the bud in; the frames go once it has played.
    private func startBloom(_ set: FlowerSet) {
        let now = flowerMask.convertTime(CACurrentMediaTime(), from: nil)
        let values = set.bloom + [set.open]
        let duration = Self.bloomDuration(set)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stopTurn()
        turnIndex = 0
        flowerMask.contents = set.open
        let bloom = CAKeyframeAnimation(keyPath: "contents")
        bloom.values = values
        bloom.calculationMode = .discrete
        bloom.keyTimes = (0...values.count).map { NSNumber(value: Double($0) / Double(values.count)) }
        bloom.duration = duration
        bloom.beginTime = now
        bloom.fillMode = .forwards
        bloom.isRemovedOnCompletion = false
        flowerMask.add(bloom, forKey: "bloom")
        bloomEnds = now + duration
        // The field stays put under the bud, so the layer never fades; the bud starts a little open instead.
        fieldOnly = false
        CATransaction.commit()
        bloomDone?.cancel()
        let done = DispatchWorkItem { [weak self] in self?.endBloom() }
        bloomDone = done
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05, execute: done)
    }

    /// The bloom is over or cut short: the open flower (or the turn's frame) shows and the bloom's frames go.
    func endBloom() {
        fieldOnly = false
        bloomDone?.cancel()
        bloomDone = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flowerMask.removeAnimation(forKey: "bloom")
        flower.removeAnimation(forKey: "fade")
        flower.opacity = 1
        if turnTimer == nil, let open = flowerSet?.open { flowerMask.contents = open }
        CATransaction.commit()
        flowerSet?.bloom = []
        syncGlow()
    }

    /// The opening's first beat: the bloom above the composer on the full canvas, the bud fading in. The move follows
    /// after `LotusArt.flight.hold`, or as soon as its frames land after that.
    private func startOpening(_ set: FlowerSet) {
        guard set.opening != nil else { return }
        openingPlaying = true
        stopTurn()
        turnIndex = 0
        let now = flowerMask.convertTime(CACurrentMediaTime(), from: nil)
        let values = set.openingBloom
        let duration = Double(values.count) / LotusArt.bloomFPS
        CATransaction.begin(); CATransaction.setDisableActions(true)
        placeFlower()
        flowerMask.removeAnimation(forKey: "flight")
        flowerMask.contents = values.last
        let bloom = CAKeyframeAnimation(keyPath: "contents")
        bloom.values = values
        bloom.calculationMode = .discrete
        bloom.keyTimes = (0...values.count).map { NSNumber(value: Double($0) / Double(values.count)) }
        bloom.duration = duration
        bloom.beginTime = now
        bloom.fillMode = .forwards
        bloom.isRemovedOnCompletion = false
        flowerMask.add(bloom, forKey: "bloom")
        bloomEnds = now + duration
        fieldOnly = false
        CATransaction.commit()
        openingFly?.cancel()
        let fly = DispatchWorkItem { [weak self] in self?.openingFly = nil; self?.fly() }
        openingFly = fly
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + LotusArt.flight.hold, execute: fly)
        syncGlow()
    }

    /// The second beat, once the hold is over and the move's frames are here; until then the open bloom holds.
    func fly() {
        guard openingPlaying, openingFly == nil, let set = flowerSet, !set.flight.isEmpty,
              flowerMask.convertTime(CACurrentMediaTime(), from: nil) >= bloomEnds + LotusArt.flight.hold - 0.02 else { return }
        let values = set.flight
        let duration = LotusArt.flight.duration
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let move = CAKeyframeAnimation(keyPath: "contents")
        // The frames sit between the bloom's last and the resting one, which the landing shows.
        move.values = values
        move.calculationMode = .discrete
        move.keyTimes = (0...values.count).map { NSNumber(value: Double($0) / Double(values.count)) }
        move.duration = duration
        move.beginTime = flowerMask.convertTime(CACurrentMediaTime(), from: nil)
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false
        flowerMask.removeAnimation(forKey: "bloom")
        flowerMask.add(move, forKey: "flight")
        flowerSet?.openingBloom = []
        CATransaction.commit()
        openingLand?.cancel()
        let land = DispatchWorkItem { [weak self] in self?.openingLand = nil; self?.land() }
        openingLand = land
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: land)
    }

    /// The move's end: the resting canvas and frame in one transaction (the move's last frame is the step before it),
    /// the opening's frames freed, the turn started.
    func land() {
        guard openingPlaying else { return }
        openingPlaying = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flowerMask.removeAnimation(forKey: "flight")
        flowerMask.removeAnimation(forKey: "bloom")
        if let open = flowerSet?.open { flowerMask.contents = open }
        flowerSet?.flight = []
        flowerSet?.openingBloom = []
        flowerSet?.opening = nil
        placeFlower()
        CATransaction.commit()
        if let set = flowerSet { DitherArt.log.notice("flower landed: \(set.bytes / 1024) KB held") }
        syncFlowerMotion()
    }

    /// The opening stops where it is and the flower shows at rest: a resize, the page leaving or turning into a thread,
    /// Reduce Motion or the window going.
    func cancelOpening() {
        fieldOnly = false
        openingFly?.cancel(); openingFly = nil
        openingLand?.cancel(); openingLand = nil
        let was = openingPlaying
        openingPlaying = false
        flowerSet?.flight = []
        flowerSet?.openingBloom = []
        flowerSet?.opening = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flowerMask.removeAnimation(forKey: "flight")
        flowerMask.removeAnimation(forKey: "bloom")
        flower.removeAnimation(forKey: "fade")
        flower.opacity = 1
        if was, let open = flowerSet?.open { flowerMask.contents = open }
        CATransaction.commit()
        if was { placeFlower() }
    }

    /// The field with no flower, while an opening waits for its bud: the ground is already there when the bloom starts.
    func showFieldOnly() {
        guard let set = flowerSet, !fieldOnly else { return }
        let full = set.key.full
        let shown = LotusArt.compose(codes: nil, flower: set.key.placement, full: full, field: LotusArt.field(full, t: fieldT, dark: set.key.dark),
                                     fieldAlpha: LotusArt.fieldAlpha(dark: set.key.dark))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flowerMask.contents = LotusArt.image(shown, width: full.width, height: full.height)
        flower.opacity = 1
        CATransaction.commit()
        fieldOnly = true
    }

    /// Turns from the frame it holds, `delay` seconds from now.
    private func startTurn(after delay: CFTimeInterval, frames n: Int) {
        let step = LotusArt.idlePeriod / Double(n)
        turnStart = CACurrentMediaTime() + delay - Double(turnIndex) * step
        fieldStart = CACurrentMediaTime() + delay - fieldT * DitherArt.gradientPeriod
        let timer = Timer(fire: Date(timeIntervalSinceNow: delay), interval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.turnTick() }
        }
        timer.tolerance = step / 10
        RunLoop.main.add(timer, forMode: .common)
        turnTimer = timer
    }

    /// One step of the new thread's motion: the flower's turn and the field's drift, composed into one frame, only when
    /// either moved on a step.
    private func turnTick() {
        guard let set = flowerSet, !set.idle.isEmpty else { stopTurn(); return }
        let n = set.idle.count, now = CACurrentMediaTime()
        let i = (Int(((now - turnStart) / LotusArt.idlePeriod * Double(n)).rounded(.down)) % n + n) % n
        let steps = DitherArt.gradientPeriod * DitherArt.gradientFPS
        let ft = ((((now - fieldStart) / DitherArt.gradientPeriod * steps).rounded(.down)).truncatingRemainder(dividingBy: steps) + steps)
            .truncatingRemainder(dividingBy: steps) / steps
        let animates = ThemeRuntime.ditherGradientAnimates
        guard i != turnIndex || ft != fieldT || flowerMask.animation(forKey: "bloom") != nil else { return }
        turnIndex = i
        if animates { fieldT = ft }
        guard let image = LotusArt.frame(packed: set.idle[i], flower: set.key.placement, full: set.key.full, t: fieldT, dark: set.key.dark)
        else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flowerMask.removeAnimation(forKey: "bloom")
        flowerMask.contents = image
        CATransaction.commit()
    }

    /// The open flower over the field where it stands now, as `open`.
    func recomposeOpen() {
        guard let set = flowerSet, !set.openCodes.isEmpty else { return }
        let full = set.key.full
        let shown = LotusArt.compose(codes: set.openCodes, flower: set.key.placement, full: full, field: LotusArt.field(full, t: fieldT, dark: set.key.dark),
                                     fieldAlpha: LotusArt.fieldAlpha(dark: set.key.dark))
        if let image = LotusArt.image(shown, width: full.width, height: full.height) { flowerSet?.open = image }
    }

    func stopTurn() {
        turnTimer?.invalidate()
        turnTimer = nil
    }

    /// The flower's frames go when its page or the window does; they render again when it shows.
    func dropFlower() {
        fieldOnly = false
        if flowerKind == .hero { heroLeftAt = CACurrentMediaTime() }
        openingFly?.cancel(); openingFly = nil
        openingLand?.cancel(); openingLand = nil
        openingPlaying = false
        flowerJob?.cancel()
        flowerJob = nil
        flowerWanted = nil
        flowerJobParts = []
        flowerSettle?.cancel()
        flowerSettle = nil
        bloomDone?.cancel()
        bloomDone = nil
        stopTurn()
        flowerSet = nil
        flowerKind = nil
        flowerTarget = nil
        flowerResizing = false
        columnKey = nil
        glowKey = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flowerMask.removeAllAnimations()
        flower.removeAllAnimations()
        flowerMask.contents = nil
        columnLayer.contents = nil
        glowImage = nil
        flowerHost.mask = nil
        flower.opacity = 1
        flowerHost.isHidden = true
        CATransaction.commit()
        if let window { FlowerGlassView.publish(nil, in: window) }
    }

    var flowerBloomingForTesting: Bool { flowerMask.animation(forKey: "bloom") != nil }
    var flowerIdlingForTesting: Bool { turnTimer != nil }
    var flowerContentsForTesting: CGImage? { flowerMask.contents.map { $0 as! CGImage } }
}

private struct DitherArtImage: @unchecked Sendable { let image: CGImage? }
private final class EmphasisBox { let emphasis: DitherArtView.Emphasis; init(emphasis: DitherArtView.Emphasis) { self.emphasis = emphasis } }

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
        var dark = true
        /// Picture: where the two inks come from, the page's shape over the dots, and the body and muted text colors
        /// (sRGB, six values) whose floors hold behind a thread's column.
        var ink = PictureInk.Choice.auto
        var shape = PictureInk.Shape.plain
        var text: [Double] = []
        /// Picture's "Dim behind text" (`TextDim`).
        var textDim = TextDim.standard
        /// Picture's cell in points, from the "Dot size" setting at the window's scale.
        var dot: CGFloat = DitherDotSize.medium.points(scale: 2)

        /// Points per canvas pixel.
        var unit: CGFloat { blur ? DitherArt.blurPixel : dot }
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
        let art = PictureInk.render(tone, inks: inks, ground: ground, dark: request.dark, shape: request.shape, text: text,
                                   dim: request.textDim)
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
