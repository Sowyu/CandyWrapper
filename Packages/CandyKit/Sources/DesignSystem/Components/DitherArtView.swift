import AppKit
import os

/// Redesign's background, Gradient (the user, 2026-11-27: "lets just only do the gradient theme"), after Capy's
/// new-thread page: binary cells in the accent on a fixed 3pt grid across the top of the new-thread page, fading to
/// plain ground well above the composer group. A thread and every other page show the plain ground, with no art, scrim
/// or dim. The loop renders once per size, accent and appearance on a worker; a discrete keyframe animation on the
/// layer's mask flips its frames, so the app does no work per frame, and it moves only while it can be seen.
public final class DitherArtView: NSView {
    /// The accent color through the current frame's mask, one cell per mask pixel.
    private let art = CALayer()
    private let gradientMask = CALayer()
    /// The loop, held only while the new-thread page shows (`DitherArt.gradientFrames`).
    private var gradientFrames: [CGImage] = []
    /// The band's color over the panel's top edge, a thin fade into the window's top.
    private let blend = CAGradientLayer()
    /// How far down the panel the band's color reaches: only the window's top edge, the same reach as the rows' fade
    /// there. It reached the band's whole 52 before, a grey slab under the title the user removed ("lets remove this
    /// early fade i only want the one up here", 2026-11-21).
    public static let topBlend: CGFloat = 20
    private var shown: DitherArt.Request?
    private var pending: DitherArt.Request?
    private var debounce: DispatchWorkItem?
    /// Whether the window is visible, unminiaturized, not covered and key; tests set it.
    var windowIsActiveOverride: Bool?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        art.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "mask": NSNull(),
                       "hidden": NSNull()]
        gradientMask.contentsGravity = .resize
        gradientMask.magnificationFilter = .nearest
        gradientMask.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.masksToBounds = true
        layer?.addSublayer(art)
        blend.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
        layer?.addSublayer(blend)
        Self.arts.add(self)
        // Reduce Motion stops the loop at once.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        // The accent, the appearance's ground and Animate background feed the render.
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeRuntime.didChange, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func displayOptionsChanged(_ note: Notification) { syncMotion() }
    @objc private func themeChanged(_ note: Notification) { refresh() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Redesign's inset panel: the art is the thread card's ground, top row included, from the sidebar's margin to the
    /// right panel's. `SidebarLayoutView` sets it and the frame.
    public var isInsetCard = false { didSet { if isInsetCard != oldValue { updateGround() } } }

    public override var wantsUpdateLayer: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func isAccessibilityElement() -> Bool { false }

    /// Puts the art at the bottom of `view` while Redesign shows in its appearance and takes it out otherwise.
    @MainActor
    public static func sync(_ current: DitherArtView?, in view: NSView) -> DitherArtView? {
        let on = view.window != nil && ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark)
        if on, current == nil {
            let made = DitherArtView(frame: view.bounds)
            view.addSubview(made, positioned: .below, relativeTo: nil)
            return made
        }
        if !on, let current { current.removeFromSuperview(); return nil }
        current?.refresh()
        return current
    }

    /// Which page shows in the panel. Only `hero`, the new-thread page, shows the cells.
    public enum Emphasis: Sendable { case hero, thread, settings, page }

    /// A page calls this: while `source` is the frontmost registered page showing inside the art's panel, the art
    /// shows what `emphasis` shows. Pass nil when the source leaves. Pages that never call it show the plain ground.
    @MainActor
    public static func setEmphasis(_ emphasis: Emphasis?, from source: NSView) {
        if let emphasis { sources.setObject(EmphasisBox(emphasis: emphasis), forKey: source) } else { sources.removeObject(forKey: source) }
        for art in arts.allObjects { art.refresh() }
    }

    /// A page laid over the thread panel (no active thread, an unavailable or linked thread) calls this when it joins or
    /// leaves a window or changes appearance, so a new-thread page under it stops showing its cells.
    @MainActor
    public static func syncOverlayPage(_ source: NSView) {
        setEmphasis(source.window != nil && ThemeRuntime.isDither(dark: source.effectiveAppearance.isDark) ? .page : nil, from: source)
    }

    /// A page joined or left the window, as the thread panel and a utility page trade places: every art follows what
    /// shows now.
    @MainActor
    public static func pagesMoved() {
        for art in arts.allObjects { art.refresh() }
    }

    /// The new-thread page calls this from its layout with its composer group's frame (the context row and the
    /// composer), in its own coordinates, so the field ends above it. Pass nil when there is none.
    @MainActor
    public static func setComposer(_ composer: NSRect?, from source: NSView) {
        guard composers.object(forKey: source)?.rectValue != composer else { return }
        if let composer { composers.setObject(NSValue(rect: composer), forKey: source) } else { composers.removeObject(forKey: source) }
        art(behind: source)?.refresh()
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
    /// Each new-thread page's composer group, weakly held.
    @MainActor private static let composers = NSMapTable<NSView, NSValue>.weakToStrongObjects()

    public override func updateLayer() {
        updateGround()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        placeArt()
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

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: window)
            }
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didBecomeKeyNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didResignKeyNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// A miniaturized or ordered-out window drops its frames, which render again when the window shows. A window only
    /// covered by others keeps them, so it never flashes empty.
    @objc private func visibilityChanged(_ note: Notification) {
        guard let window else { return }
        if !window.isVisible || window.isMiniaturized {
            debounce?.cancel()
            shown = nil; pending = nil
            dropGradient()
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

    /// The cells move only while they can be seen and wanted: the new-thread page with Animate background on, the
    /// window active and Reduce Motion off. Anything else removes the animation, holding the frame it was on, so
    /// nothing runs while idle (the user, 2026-11-21: "capys plain dither isnt just static").
    func syncMotion() {
        let on = ThemeRuntime.ditherGradientAnimates && !Motion.reduced && windowIsActive && !isHiddenOrHasHiddenAncestor
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

    /// The frames go when their page or window does; they render again when it shows.
    private func dropGradient() {
        gradientMask.removeAnimation(forKey: "drift")
        gradientMask.contents = nil
        gradientFrames = []
        art.mask = nil
        art.backgroundColor = nil
    }

    var gradientAnimatingForTesting: Bool { gradientMask.animation(forKey: "drift") != nil }
    var gradientFrameCountForTesting: Int { gradientFrames.count }
    /// Whether the cells show at all.
    var showsCellsForTesting: Bool { !art.isHidden && art.mask === gradientMask && gradientMask.contents != nil }

    /// A move between screens refreshes the art for the new backing scale.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    /// The shown canvas at one cell per mask pixel, its top left at the panel's top left. While the panel's size
    /// differs from the canvas's (a live resize, a sidebar drag), the cached mask stretches over the new canvas's
    /// place; the window server scales it, and the sharp render lands when the size settles (the user, 2026-11-21: "i
    /// need to release my mouse before it pops in").
    private func placeArt() {
        guard let shown else { return }
        let unit = DitherArt.gradientUnit
        let target = gradientCanvas()
        let w = CGFloat(target == (shown.width, shown.height) ? shown.width : target.width) * unit
        let h = CGFloat(target == (shown.width, shown.height) ? shown.height : target.height) * unit
        art.frame = CGRect(x: 0, y: bounds.height - h, width: target == (shown.width, shown.height) ? w : bounds.width, height: h)
        gradientMask.frame = art.bounds
    }

    /// The canvas in cells: the panel's width, and from its top down `DitherArt.gradientHeight`, which stops short of the
    /// new thread's composer group so the field has faded to plain ground well above it.
    private func gradientCanvas() -> (width: Int, height: Int) {
        let (_, front) = self.front
        let groupTop = front.flatMap { Self.composers.object(forKey: $0)?.rectValue }.map { bounds.height - convert($0, from: front).maxY }
        let unit = DitherArt.gradientUnit
        return (Int((bounds.width / unit).rounded(.up)), Int((DitherArt.gradientHeight(panel: bounds.height, groupTop: groupTop) / unit).rounded()))
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

    /// What the panel shows: the frontmost registered page that's visible inside it decides, whatever order the pages
    /// registered in, and an unregistered page shows the plain ground.
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

    /// The cells on the new-thread page only, the inset card's ground and corners, and the band's fade at the window's
    /// top. Main thread only, like every view method.
    func updateGround() {
        let dark = effectiveAppearance.isDark
        let background = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.nsColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let hidden = page != .hero
        if art.isHidden != hidden { art.isHidden = hidden }
        // The inset card's top is its own row, under the window's margin, not the band.
        blend.isHidden = isInsetCard
        // The inset card's ground, clipped to its corners.
        layer?.cornerRadius = isInsetCard ? RedesignTokens.Radius.panel : 0
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = isInsetCard ? background.cgColor : nil
        let band = DitherChrome.bandColor(in: self)
        // Bottom (no band) to top (all band).
        let ts = (0...10).reversed().map { Double($0) / 10 }
        blend.locations = ts.map { NSNumber(value: 1 - $0) }
        blend.colors = ts.map { band.copy(alpha: DitherChrome.bandBlend($0))! }
        CATransaction.commit()
        syncMotion()
    }

    /// Asks for the cells at the current size, accent and appearance, after the size settles.
    func refresh() {
        updateGround()
        guard let window, bounds.width >= 1, bounds.height >= 1 else { return }
        let dark = effectiveAppearance.isDark
        let palette = ThemeRuntime.palettes.palette(dark: dark, sidebar: false)
        // Only the new-thread page shows them, so no other page holds the frames.
        let canvas = gradientCanvas()
        guard page == .hero, canvas.width > 0, canvas.height > 0 else {
            debounce?.cancel()
            shown = nil; pending = nil
            dropGradient()
            return
        }
        let ground = palette.background.srgb, accent = palette.primary.srgb
        let request = DitherArt.Request(width: canvas.width, height: canvas.height, background: [ground.x, ground.y, ground.z],
                                        tint: [accent.x, accent.y, accent.z], dark: dark, scale: window.backingScaleFactor,
                                        frames: ThemeRuntime.ditherGradientAnimates ? Int(DitherArt.gradientPeriod * DitherArt.gradientFPS) : 1)
        guard request != shown, request != pending else { return }
        // Only a new size waits for the drag to pause; an accent or appearance change renders at once.
        let resizing = shown.map { $0.width != request.width || $0.height != request.height } ?? false
        pending = request
        debounce?.cancel()
        if rendersInlineForTesting {
            show(request, frames: Self.render(request))
            return
        }
        // A live resize lands here every frame; the last size renders, the old frames stretch over the panel meanwhile.
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let frames = Self.render(request)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.show(request, frames: frames) }
                }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (resizing ? 0.15 : 0), execute: work)
    }

    /// Tests render on the main thread, so they never wait with theme globals applied.
    var rendersInlineForTesting = false

    /// The loop's frames. Runs on any thread.
    private nonisolated static func render(_ request: DitherArt.Request) -> DitherArtFrames {
        DitherArtFrames(images: DitherArt.gradientFrames(width: request.width, height: request.height, frames: request.frames))
    }

    private func show(_ request: DitherArt.Request, frames: DitherArtFrames) {
        guard pending == request else { return }
        pending = nil
        rendersForTesting += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dropGradient()
        // A render that failed isn't remembered, so the next refresh tries again.
        shown = frames.images.isEmpty ? nil : request
        if let first = frames.images.first {
            art.backgroundColor = DitherArt.gradientColor(tint: request.tint, background: request.background, dark: request.dark)
            gradientFrames = frames.images
            gradientMask.contents = first
            art.mask = gradientMask
        }
        placeArt()
        CATransaction.commit()
        syncMotion()
    }

    /// Renders what the panel shows now on this thread, dropping a render that was waiting, for offscreen pictures.
    func renderNowForTesting() {
        debounce?.cancel(); debounce = nil
        pending = nil; shown = nil
        rendersInlineForTesting = true
        refresh()
    }

    var requestForTesting: DitherArt.Request? { pending ?? shown }
}

private struct DitherArtFrames: @unchecked Sendable { let images: [CGImage] }
private final class EmphasisBox { let emphasis: DitherArtView.Emphasis; init(emphasis: DitherArtView.Emphasis) { self.emphasis = emphasis } }

/// Gradient's rendering. Touches no AppKit view, so it runs on any thread.
public enum DitherArt {
    enum Page: Sendable { case hero, thread, settings, page }

    struct Request: Hashable, Sendable {
        /// The canvas in cells.
        var width: Int, height: Int
        /// The panel's ground and the accent, sRGB 0...1.
        var background: [Double]
        var tint: [Double]
        var dark: Bool
        var scale: CGFloat
        /// The loop's frame count, or 1 when Animate background is off.
        var frames: Int
    }

    /// The cell, in points: Capy's binary dither cells measured 6px at 2x in the user's recording.
    public nonisolated static let gradientUnit: CGFloat = 3
    /// The share of the panel's height the canvas covers from the top.
    nonisolated static let gradientReach: CGFloat = 0.5
    /// Plain ground between the canvas's foot and the composer group's top, in points. The field has thinned to
    /// nothing a little before the foot (`gradientFloor`), so the ground runs further still.
    nonisolated static let gradientClearance: CGFloat = 24
    /// The loop: 12 s at 8 frames a second. Capy's field moves at about 12 cells a second at its fastest, so a cell
    /// flips at most once a frame or so.
    nonisolated static let gradientPeriod: Double = 12
    nonisolated static let gradientFPS: Double = 8

    /// How far down the panel the canvas reaches, in points: half the panel, as Capy's field fades out by about 45%
    /// down, and never closer than `gradientClearance` to the top of the new thread's composer group, so the field is
    /// plain ground well above the composer however short the window is.
    nonisolated static func gradientHeight(panel: CGFloat, groupTop: CGFloat?) -> CGFloat {
        let half = panel * gradientReach
        guard let groupTop else { return half }
        return max(0, min(half, groupTop - gradientClearance))
    }

    /// One soft lobe of the field along the top: its centre and strength swing around a rest value, each on a whole
    /// number of turns per loop, so the loop is seamless.
    struct Lobe { var centre: Double, travel: Double, phase: Double, width: Double, strength: Double, swell: Double, turns: Double, swellPhase: Double }
    /// After Capy's recording: a lobe at the left that swells and fades, one that drifts right across the middle,
    /// and one at the right that grows from nothing. Frame 0 is brightest at the top left, the static look.
    nonisolated static let lobes: [Lobe] = [
        Lobe(centre: 0.06, travel: 0.06, phase: 0, width: 0.22, strength: 0.75, swell: 0.25, turns: 1, swellPhase: 1),
        Lobe(centre: 0.4, travel: 0.16, phase: 2, width: 0.18, strength: 0.55, swell: 0.45, turns: 2, swellPhase: 0.5),
        Lobe(centre: 0.84, travel: 0.1, phase: 4, width: 0.2, strength: 0.4, swell: 0.5, turns: 1, swellPhase: 3.5),
    ]

    /// The field's strength down the canvas, `y` 0 at the top to 1 at the foot: dense under the top edge and thinning
    /// faster than linear, as Capy's does (capy-real-dark-new-thread.png).
    nonisolated static func gradientFall(_ y: Double) -> Double { pow(max(0, 1 - y), 1.5) }
    /// Taken off the field before the threshold, so its last rows are empty ground instead of a sparse, even row of
    /// cells that ends on a hard line at the canvas's foot.
    nonisolated static let gradientFloor: Double = 0.04

    /// The field at `u` across the canvas (0 left, 1 right) and loop time `t` (0...1), 0 to 1.
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

    /// The frames: one alpha mask per frame, a cell per pixel, on where the field beats the cell's Bayer threshold, the
    /// way Capy's cells switch on and off on a fixed grid. One frame when `frames` is 1. The field is a row profile
    /// times a falloff down the canvas (`gradientFall`), so a frame costs one multiply per cell.
    nonisolated static func gradientFrames(width w: Int, height h: Int, frames: Int) -> [CGImage] {
        guard w > 0, h > 0, frames > 0 else { return [] }
        let fall = (0..<h).map { y -> Double in gradientFall((Double(y) + 0.5) / Double(h)) }
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
                    data[y * w + x] = row[x] * f - gradientFloor > (Double(bayer[b + (x & 7)]) + 0.5) / 64 ? 255 : 0
                }
            }
            guard let image = ctx.makeImage() else { return [] }
            out.append(image)
        }
        return out
    }

    /// The one cell color: the accent mixed into the ground, dim like Capy's navy (#26314b at most). Light takes 0.24:
    /// at 0.32 (#abd3cf, 1.5:1) the field read as a loud teal slab over the off-white card, far heavier than dark's
    /// 0.36 on near-black; at 0.22 it barely showed.
    nonisolated static func gradientColor(tint: [Double], background: [Double], dark: Bool) -> CGColor {
        let share = dark ? 0.36 : 0.24
        let c = (0..<3).map { background[$0] + (tint[$0] - background[$0]) * share }
        return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    /// The 8 x 8 Bayer matrix, thresholds 0..<64.
    nonisolated static let bayer: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
    ]
}
