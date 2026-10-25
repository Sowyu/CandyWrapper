import AppKit
import ImageIO

/// The Dither theme's art (CandyWrapper's own, after Capy's desktop app): the chosen picture, or the desktop picture,
/// filling the main panel in its own colors at 2pt ordered-dither dots of brightness, held within a reach of the
/// panel's background that keeps text readable anywhere on it. A new thread shows it fully, an open thread under a
/// light scrim of the background, and every other page under a heavy one. It renders once per size and appearance
/// off the main thread. Opening a new thread resolves the dots in, in Bayer order, for 0.75 s. While a thread works,
/// the dots breathe in a slow wave (`working`); otherwise it holds still and runs nothing.
public final class DitherArtView: NSView {
    private let art = CALayer()
    /// The background over the art, one share across the panel.
    private let scrim = CALayer()
    /// The band's color over the panel's top, so the art meets the tab strip band with no edge.
    private let blend = CAGradientLayer()
    /// How far down the panel the band's color reaches: the thread header's height. The blend eases out from the top
    /// edge (`DitherChrome.bandBlend`), so the art shows from the panel's top with no solid strip.
    public static let topBlend: CGFloat = DitherChrome.band
    private var shown: DitherArt.Request?
    private var pending: DitherArt.Request?
    private var debounce: DispatchWorkItem?
    /// A new thread opened before the art had rendered: the first render resolves in.
    private var revealsWhenShown = false
    /// The working wave, only while it shows or fades out.
    private var wave: (root: CALayer, grid: CALayer, band: CAGradientLayer)?
    /// What the wave was last laid out for, so an unchanged layout costs nothing.
    private var waveLayout: (frame: CGRect, scale: CGFloat, color: CGColor)?
    private var waveStopping = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        art.magnificationFilter = .nearest
        // One canvas pixel is exactly one dot: the layer is the canvas's size in dots (`placeArt`), so the stretch is
        // exactly `dot` and every dot is the same whole number of device pixels.
        art.contentsGravity = .resize
        art.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        scrim.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.masksToBounds = true
        layer?.addSublayer(art)
        layer?.addSublayer(scrim)
        blend.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
        layer?.addSublayer(blend)
        Self.arts.add(self)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func displayOptionsChanged(_ note: Notification) { updateScrim() }

    // MARK: Working wave

    /// Some thread is working, the sidebar's Working status. The app sets it on every shell change.
    @MainActor public static var working = false {
        didSet { if working != oldValue { for art in arts.allObjects { art.updateWave() } } }
    }

    /// Starts, moves or eases out the wave. Cheap when nothing changes, so every scrim update calls it.
    func updateWave() {
        var working = Self.working
        #if DEBUG
        // Debug-only, for measuring and recording without a real turn: `defaults write <bundle id> CandyDitherWave force|off`.
        switch UserDefaults.standard.string(forKey: "CandyDitherWave") {
        case "force": working = true
        case "off": working = false
        default: break
        }
        #endif
        let runs = DitherArt.waves(working: working, reduceMotion: Motion.reduced,
                                   reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                                   page: page, hasArt: shown != nil && window != nil)
        if runs {
            let made = wave ?? makeWave()
            if wave == nil || waveStopping { fadeWave(made.root, to: 1) }
            waveStopping = false
            wave = made
            placeWave()
        } else if let wave, !waveStopping {
            // Reduce Motion stops it at once; the rest ease out.
            if Motion.reduced { removeWave(); return }
            waveStopping = true
            fadeWave(wave.root) { [weak self] in if self?.waveStopping == true { self?.removeWave() } }
        }
    }

    /// The wave between the art and the scrim: a band of the background color, seen only through a grid one device
    /// pixel wide on each dot's edge, moving across the panel. Where it passes, each dot shrinks by a sliver and grows
    /// back. Core Animation moves the band, so the app does no work per frame.
    private func makeWave() -> (root: CALayer, grid: CALayer, band: CAGradientLayer) {
        let root = CALayer(), grid = CALayer(), band = CAGradientLayer()
        for l in [root, grid, band] as [CALayer] {
            l.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "contents": NSNull(),
                         "transform": NSNull(), "colors": NSNull(), "locations": NSNull()]
        }
        grid.magnificationFilter = .nearest
        grid.contentsGravity = .resize
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        root.addSublayer(band)
        root.mask = grid
        root.opacity = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.insertSublayer(root, above: art)
        CATransaction.commit()
        waveLayout = nil
        return (root, grid, band)
    }

    /// Lines the grid up with the art's dots and restarts the band when the size, scale or background changed.
    private func placeWave() {
        guard let wave, let window else { return }
        let frame = art.frame, scale = window.backingScaleFactor
        let color = ThemeRuntime.palettes.palette(dark: effectiveAppearance.isDark, sidebar: false).background.nsColor.cgColor
        if let last = waveLayout, last.frame == frame, last.scale == scale, last.color == color { return }
        waveLayout = (frame, scale, color)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let bounds = CGRect(origin: .zero, size: frame.size)
        wave.root.frame = frame
        wave.grid.frame = bounds
        let k = Int((DitherArt.dot * scale).rounded())
        wave.grid.contents = DitherArt.waveGrid(columns: Int(frame.width / DitherArt.dot), rows: Int(frame.height / DitherArt.dot),
                                                pixelsPerDot: k)
        // The band repeats every `wavePeriod`, so moving it one period and starting over has no seam.
        let period = DitherArt.wavePeriod, angle = DitherArt.waveAngle
        let diagonal = hypot(frame.width, frame.height)
        let cycles = Int(((diagonal + period) / period).rounded(.up))
        let profile = DitherArt.waveProfile(cycles: cycles, depth: DitherArt.waveDepth(pixelsPerDot: k))
        wave.band.bounds = CGRect(x: 0, y: 0, width: CGFloat(cycles) * period, height: diagonal)
        wave.band.colors = profile.map { color.copy(alpha: $0.alpha)! }
        wave.band.locations = profile.map { NSNumber(value: $0.at) }
        wave.band.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        let step = CGPoint(x: cos(angle) * period, y: sin(angle) * period)
        wave.band.position = CGPoint(x: bounds.midX - step.x / 2, y: bounds.midY - step.y / 2)
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: .zero)
        move.toValue = NSValue(point: step)
        move.isAdditive = true
        move.duration = DitherArt.waveDuration
        move.repeatCount = .infinity
        // The window server redraws the whole panel each frame of the band, so it moves at a few frames a second:
        // 30 cost about 17% of a core there, 10 about 5%. A soft band 900pt wide hides the steps.
        move.preferredFrameRateRange = DitherArt.waveFrameRate
        wave.band.add(move, forKey: "wave")
    }

    private func fadeWave(_ root: CALayer, to opacity: Float = 0, done: (() -> Void)? = nil) {
        let from = root.presentation()?.opacity ?? root.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        fade.duration = DitherArt.waveEase * Double(abs(opacity - from))
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.preferredFrameRateRange = Motion.loopFrameRate
        root.opacity = opacity
        root.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private func removeWave() {
        wave?.root.removeFromSuperlayer()
        wave = nil
        waveLayout = nil
        waveStopping = false
    }

    var waveShowsForTesting: Bool { wave != nil && !waveStopping }

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
        if !on, let current { current.removeWave(); current.removeFromSuperview(); return nil }
        current?.refresh()
        return current
    }

    /// How much of the art a page shows.
    public enum Emphasis: Sendable { case hero, thread, settings }

    /// The thread panel calls this: while `source` shows inside the art's panel, the art takes `emphasis`'s scrim.
    /// Pass nil when the source leaves. Pages that never call it get the heavy page scrim.
    @MainActor
    public static func setEmphasis(_ emphasis: Emphasis?, from source: NSView) {
        let wasHero = heroSources.contains(source)
        heroSources.remove(source); threadSources.remove(source); settingsSources.remove(source)
        switch emphasis {
        case .hero: heroSources.add(source)
        case .thread: threadSources.add(source)
        case .settings: settingsSources.add(source)
        case nil: break
        }
        // The full art goes up first, then opening a new thread resolves its dots in.
        for art in arts.allObjects { art.updateScrim() }
        if emphasis == .hero, !wasHero, let art = art(behind: source) { art.playReveal() }
    }

    /// A page joined or left the window, as the thread panel and a utility page trade places: every art takes the scrim
    /// of what shows now. Before, the last page's scrim stayed until something else redrew the art.
    @MainActor
    public static func pagesMoved() {
        for art in arts.allObjects { art.updateScrim() }
    }

    /// The art showing behind `source`, if any.
    @MainActor
    static func art(behind source: NSView) -> DitherArtView? {
        arts.allObjects.first { art in
            art.superview.map { source.isDescendant(of: $0) } == true && (art.window == nil || art.window === source.window)
        }
    }

    /// Dots resolve in, in Bayer order, over 0.75 s, and the last frame is the static art itself, so the art ends
    /// exactly as it rests. Core Animation flips the ten frames; they exist only while it plays.
    func playReveal() {
        guard !Motion.reduced else { return }
        guard let request = shown, let contents = art.contents else { revealsWhenShown = true; return }
        revealsWhenShown = false
        let final = DitherArtImage(image: (contents as! CGImage))
        // Hidden until the frames are ready, so the full art never flashes before resolving in.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.opacity = 0
        CATransaction.commit()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frames = DitherArtFrames(images: final.image.map {
                DitherArt.revealFrames($0, background: request.background, reveals: (1...9).map { Double($0) / 10 })
            } ?? [])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.art.opacity = 1
                    CATransaction.commit()
                    // A newer render replaced the art meanwhile: it shows as it is.
                    guard self.shown == request, !frames.images.isEmpty, let final = self.art.contents else { return }
                    let resolve = CAKeyframeAnimation(keyPath: "contents")
                    resolve.values = frames.images + [final]
                    resolve.calculationMode = .discrete
                    resolve.duration = 0.75
                    self.art.add(resolve, forKey: "reveal")
                }
            }
        }
    }
    @MainActor private static let heroSources = NSHashTable<NSView>.weakObjects()
    @MainActor private static let threadSources = NSHashTable<NSView>.weakObjects()
    @MainActor private static let settingsSources = NSHashTable<NSView>.weakObjects()
    @MainActor private static let arts = NSHashTable<DitherArtView>.weakObjects()

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

    /// A move between a 1x and a 2x screen redraws the wave's grid for the new device pixels.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    /// The whole panel: the thread's top fade blends it into the header.
    var artRect: CGRect { bounds }

    /// The shown canvas at one dot per pixel, its top left at the panel's top left. A live resize shows the old canvas
    /// cropped or short by a few dots until the new one renders.
    private func placeArt() {
        guard let shown else { return }
        let w = CGFloat(shown.width) * DitherArt.dot, h = CGFloat(shown.height) * DitherArt.dot
        art.frame = CGRect(x: 0, y: bounds.height - h, width: w, height: h)
    }

    /// What the panel shows over the art: the new thread, an open thread or any other page.
    var page: DitherArt.Page {
        guard let panel = superview, window != nil else { return .page }
        func shows(_ table: NSHashTable<NSView>) -> Bool {
            table.allObjects.contains { $0.window === window && $0.isDescendant(of: panel) && !$0.isHiddenOrHasHiddenAncestor }
        }
        if shows(Self.heroSources) { return .hero }
        if shows(Self.threadSources) { return .thread }
        if shows(Self.settingsSources) { return .settings }
        return .page
    }

    /// Main thread only, like every view method.
    func updateScrim() {
        let dark = effectiveAppearance.isDark
        let background = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.nsColor
        let display = (reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                       increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let page = self.page
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        scrim.backgroundColor = background.withAlphaComponent(DitherArt.scrim(page, display)).cgColor
        CATransaction.commit()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let band = DitherChrome.bandColor(in: self)
        // Bottom (no band) to top (all band).
        let ts = (0...10).reversed().map { Double($0) / 10 }
        blend.locations = ts.map { NSNumber(value: 1 - $0) }
        blend.colors = ts.map { band.copy(alpha: DitherChrome.bandBlend($0))! }
        CATransaction.commit()
        updateWave()
    }

    /// Asks for the art at the current size and appearance, after the size settles.
    func refresh() {
        updateScrim()
        let rect = artRect
        guard let window, rect.width >= 1, rect.height >= 1 else { return }
        let dark = effectiveAppearance.isDark
        guard let url = ThemeRuntime.ditherPicture ?? DitherArt.desktopPicture(for: window.screen) else {
            art.contents = nil; shown = nil; return
        }
        let background = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background
        let scale = window.backingScaleFactor
        let request = DitherArt.Request(url: url, width: Int((rect.width / DitherArt.dot).rounded(.up)),
                                        height: Int((rect.height / DitherArt.dot).rounded(.up)),
                                        background: [background.srgb.x, background.srgb.y, background.srgb.z], scale: scale)
        guard request != shown, request != pending else { return }
        pending = request
        debounce?.cancel()
        // A live resize lands here every frame; the last size renders, the old art stretches meanwhile.
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let image = DitherArtImage(image: DitherArt.render(request))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.pending == request else { return }
                        self.pending = nil
                        self.shown = request
                        self.art.contents = image.image
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        self.placeArt()
                        CATransaction.commit()
                        self.updateWave()
                        if self.revealsWhenShown { self.playReveal() }
                    }
                }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (shown == nil ? 0 : 0.15), execute: work)
    }

    var contentsForTesting: CGImage? { art.contents.map { $0 as! CGImage } }
    var scrimAlphaForTesting: CGFloat { scrim.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0 }
}

private struct DitherArtImage: @unchecked Sendable { let image: CGImage? }
private struct DitherArtFrames: @unchecked Sendable { let images: [CGImage] }

/// The art's rendering. Touches no AppKit view, so it runs on any thread.
public enum DitherArt {
    /// Dot size in points.
    public nonisolated static let dot: CGFloat = 2
    /// The background's share over an open thread: the user's "Background dim" (35% by default), so the art keeps its
    /// colors and text reads over it without halos (the user, 2026-10-22).
    nonisolated static var threadScrim: CGFloat { ThemeRuntime.ditherDim }
    /// The background's share over Settings and every other page, whose cards and lists aren't frosted.
    nonisolated static let pageScrim: CGFloat = 0.92

    /// Settings (after Capy's): its translucent cards sit over the art, which shows dimmer than in a thread.
    nonisolated static let settingsScrim: CGFloat = 0.8

    enum Page: Sendable { case hero, thread, settings, page }

    /// The working wave: how much of a dot's brightness a crest takes, how far apart crests are in points, how long
    /// one takes to move that far, its angle off horizontal and how long it takes to ease in or out.
    nonisolated static let waveStrength: Double = 0.24
    nonisolated static let wavePeriod: CGFloat = 900
    nonisolated static let waveDuration: CFTimeInterval = 4.5
    nonisolated static let waveAngle: CGFloat = -0.3
    nonisolated static let waveEase: CFTimeInterval = 1.5
    /// How often the band moves.
    nonisolated static let waveFrameRate = CAFrameRateRange(minimum: 8, maximum: 10, preferred: 10)

    /// Whether the wave runs: a thread works and the art shows on the new thread or an open one, which barely cover
    /// it. Reduce Motion and Reduce Transparency, whose solid scrim hides the art, keep it still.
    nonisolated static func waves(working: Bool, reduceMotion: Bool, reduceTransparency: Bool, page: Page, hasArt: Bool) -> Bool {
        working && !reduceMotion && !reduceTransparency && hasArt && (page == .hero || page == .thread)
    }

    /// The wave's mask, one pixel per device pixel: opaque on each dot's right and bottom edge, clear inside.
    /// Alpha only, so it holds one byte a pixel.
    nonisolated static func waveGrid(columns: Int, rows: Int, pixelsPerDot k: Int) -> CGImage? {
        let w = columns * k, h = rows * k
        guard w > 0, h > 0, k > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return nil }
        // Row 0 of the buffer is the top, so a dot's bottom edge is its last row.
        for y in 0..<h {
            if y % k == k - 1 { (data + y * w).update(repeating: 255, count: w); continue }
            for x in stride(from: k - 1, to: w, by: k) { data[y * w + x] = 255 }
        }
        return ctx.makeImage()
    }

    /// The band's alpha at a crest. The grid covers (2k - 1) / k² of a dot k device pixels wide, 3/4 at 1x and 7/16 at
    /// 2x, so the band grows denser with the scale and a crest takes `waveStrength` of every dot on any screen.
    nonisolated static func waveDepth(pixelsPerDot k: Int) -> Double {
        min(1, waveStrength * Double(k * k) / Double(max(2 * k - 1, 1)))
    }

    /// The band's stops across `cycles` periods: a crest of `depth` in the middle of each, nothing between.
    nonisolated static func waveProfile(cycles: Int, depth: Double) -> [(at: Double, alpha: Double)] {
        let perCycle = 12, n = max(cycles, 1) * perCycle
        return (0...n).map { i in
            let phase = Double(i % perCycle) / Double(perCycle)
            return (Double(i) / Double(n), depth * (0.5 - 0.5 * cos(2 * .pi * phase)))
        }
    }

    /// The scrim for `page` under the system display options. Reduce Transparency covers the art with the solid
    /// background, so the frosted panes over it read as solid surfaces. Increase Contrast keeps the art as a faint
    /// texture: text on the hero and in a thread then sits on about the background itself.
    nonisolated static func scrim(_ page: Page, _ display: (reduceTransparency: Bool, increaseContrast: Bool)) -> CGFloat {
        if display.reduceTransparency { return 1 }
        switch page {
        case .hero: return display.increaseContrast ? 0.6 : 0
        case .thread: return display.increaseContrast ? 0.75 : threadScrim
        case .settings: return display.increaseContrast ? 1 : settingsScrim
        case .page: return display.increaseContrast ? 1 : pageScrim
        }
    }

    struct Request: Hashable, Sendable {
        var url: URL
        /// Canvas size in dots.
        var width: Int, height: Int
        /// The panel's background, sRGB 0...1.
        var background: [Double]
        var scale: CGFloat
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
        guard let screen = screen ?? NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL,
              let path = WallpaperBlur.unguardedPath(url.path, home: NSHomeDirectory()) else { return nil }
        return URL(filePath: path)
    }

    /// The picture covering the canvas, centered, faded into the background and dithered, or nil if it can't be read.
    nonisolated static func render(_ request: Request) -> CGImage? {
        let w = request.width, h = request.height
        guard w > 0, h > 0, let source = CGImageSourceCreateWithURL(request.url as CFURL, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(w, h) * 2]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              picture.width > 0, picture.height > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        let cover = max(Double(w) / Double(picture.width), Double(h) / Double(picture.height))
        let pw = Double(picture.width) * cover, ph = Double(picture.height) * cover
        ctx.interpolationQuality = .high
        ctx.draw(picture, in: CGRect(x: (Double(w) - pw) / 2, y: (Double(h) - ph) / 2, width: pw, height: ph))
        let bg = request.background.count == 3 ? request.background.map { $0 * 255 } : [0, 0, 0]
        // Three strengths per hue (none, half the reach, the full reach): a clean halftone, not a mush of shades.
        let step = reach / 2
        // Row 0 of the buffer is the top of the picture.
        for y in 0..<h {
            let keep = 1 - fade((Double(y) + 0.5) / Double(h))
            for x in 0..<w {
                let i = (y * w + x) * 4
                let threshold = (Double(bayer[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
                // Each dot is the picture's own color at a dithered strength over the background, so the dots keep
                // its hue instead of scattering red, green and blue, and a faded area is exactly the background.
                var d = (0..<3).map { (Double(data[i + $0]) - bg[$0]) * keep }
                var m = d.map(abs).max() ?? 0
                if m > reach { d = d.map { $0 * reach / m }; m = reach }
                guard m > 0.5 else { for c in 0..<3 { data[i + c] = UInt8(bg[c].rounded()) }; continue }
                let scaled = m / step, low = scaled.rounded(.down)
                let q = (scaled - low > threshold ? low + 1 : low) * step / m
                for c in 0..<3 { data[i + c] = UInt8(min(max(bg[c] + d[c] * q, 0), 255).rounded()) }
            }
        }
        return ctx.makeImage()
    }

    /// The art partly resolved, one frame per reveal: a dot whose Bayer threshold is above the reveal shows the
    /// background, so a reveal of 1 is `art` itself. Works from the rendered art, so it costs no decode.
    nonisolated static func revealFrames(_ art: CGImage, background: [Double], reveals: [Double]) -> [CGImage] {
        let w = art.width, h = art.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt32.self, capacity: w * h) else { return [] }
        ctx.draw(art, in: CGRect(x: 0, y: 0, width: w, height: h))
        let full = Array(UnsafeBufferPointer(start: data, count: w * h))
        // One whole pixel in the context's byte order: red, green, blue, then the skipped byte.
        let rgb = (0..<3).map { UInt32(min(max(background.count == 3 ? background[$0] * 255 : 0, 0), 255).rounded()) }
        let base = UInt32(littleEndian: rgb[0] | rgb[1] << 8 | rgb[2] << 16 | 255 << 24)
        return reveals.compactMap { reveal in
            // A dot shows once its Bayer threshold, (b + 0.5) / 64, is within the reveal.
            let cut = Int((reveal * 64 - 0.5).rounded(.down))
            // Row 0 of the buffer is the top of the picture, as in `render`.
            for y in 0..<h {
                let row = y * w, b = (y & 7) * 8
                for x in 0..<w { data[row + x] = Int(bayer[b + (x & 7)]) <= cut ? full[row + x] : base }
            }
            return ctx.makeImage()
        }
    }
}
