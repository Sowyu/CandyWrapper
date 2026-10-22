import AppKit
import ImageIO

/// The Dither theme's art (CandyWrapper's own, after Capy's desktop app): the chosen picture, or the desktop picture,
/// filling the main panel in its own colors at 2pt ordered-dither dots of brightness, held within a reach of the
/// panel's background that keeps text readable anywhere on it. A new thread shows it fully, an open thread under a
/// light scrim of the background, and every other page under a heavy one. It renders once per size and appearance
/// off the main thread. Opening a new thread resolves the dots in, in Bayer order, for 0.75 s; otherwise it holds
/// still and runs nothing.
public final class DitherArtView: NSView {
    private let art = CALayer()
    private let scrim = CALayer()
    private var shown: DitherArt.Request?
    private var pending: DitherArt.Request?
    private var debounce: DispatchWorkItem?
    /// A new thread opened before the art had rendered: the first render resolves in.
    private var revealsWhenShown = false

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
        scrim.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        layer?.masksToBounds = true
        layer?.addSublayer(art)
        layer?.addSublayer(scrim)
        Self.arts.add(self)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func displayOptionsChanged(_ note: Notification) { updateScrim() }

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
        current?.refresh()
        return current
    }

    /// Switching threads resolves the dots in again, like opening a new thread.
    @MainActor
    public static func replayReveal(behind source: NSView) { art(behind: source)?.playReveal() }

    /// How much of the art a page shows.
    public enum Emphasis: Sendable { case hero, thread }

    /// The thread panel calls this: while `source` shows inside the art's panel, the art takes `emphasis`'s scrim.
    /// Pass nil when the source leaves. Pages that never call it get the heavy page scrim.
    @MainActor
    public static func setEmphasis(_ emphasis: Emphasis?, from source: NSView) {
        let wasHero = heroSources.contains(source)
        heroSources.remove(source); threadSources.remove(source)
        if emphasis == .hero { heroSources.add(source) } else if emphasis == .thread { threadSources.add(source) }
        // Opening a new thread resolves the dots in.
        if emphasis == .hero, !wasHero, let art = art(behind: source) { art.playReveal() }
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
    @MainActor private static let arts = NSHashTable<DitherArtView>.weakObjects()

    public override func updateLayer() {
        updateScrim()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        placeArt()
        scrim.frame = artRect
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

    /// The whole panel: the thread's top fade blends it into the header.
    var artRect: CGRect { bounds }

    /// The shown canvas at one dot per pixel, its top left at the panel's top left. A live resize shows the old canvas
    /// cropped or short by a few dots until the new one renders.
    private func placeArt() {
        guard let shown else { return }
        let w = CGFloat(shown.width) * DitherArt.dot, h = CGFloat(shown.height) * DitherArt.dot
        art.frame = CGRect(x: 0, y: bounds.height - h, width: w, height: h)
    }

    var scrimAlpha: CGFloat {
        let display = (reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                       increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        guard let panel = superview, window != nil else { return DitherArt.scrim(.page, display) }
        func shows(_ table: NSHashTable<NSView>) -> Bool {
            table.allObjects.contains { $0.window === window && $0.isDescendant(of: panel) && !$0.isHiddenOrHasHiddenAncestor }
        }
        if shows(Self.heroSources) { return DitherArt.scrim(.hero, display) }
        if shows(Self.threadSources) { return DitherArt.scrim(.thread, display) }
        return DitherArt.scrim(.page, display)
    }

    /// Main thread only, like every view method.
    func updateScrim() {
        let dark = effectiveAppearance.isDark
        let background = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.nsColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2)
        scrim.backgroundColor = background.withAlphaComponent(scrimAlpha).cgColor
        CATransaction.commit()
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
                        if self.revealsWhenShown { self.playReveal() }
                    }
                }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (shown == nil ? 0 : 0.15), execute: work)
    }

    var contentsForTesting: CGImage? { art.contents.map { $0 as! CGImage } }
}

private struct DitherArtImage: @unchecked Sendable { let image: CGImage? }
private struct DitherArtFrames: @unchecked Sendable { let images: [CGImage] }

/// The art's rendering. Touches no AppKit view, so it runs on any thread.
public enum DitherArt {
    /// Dot size in points.
    public nonisolated static let dot: CGFloat = 2
    /// The background's share over an open thread: the cap already keeps text readable, this calms it under messages.
    nonisolated static let threadScrim: CGFloat = 0.2
    /// The background's share over Settings and every other page, whose cards and lists aren't frosted.
    nonisolated static let pageScrim: CGFloat = 0.92

    enum Page: Sendable { case hero, thread, page }

    /// The scrim for `page` under the system display options. Reduce Transparency covers the art with the solid
    /// background, so the frosted panes over it read as solid surfaces. Increase Contrast keeps the art as a faint
    /// texture: text on the hero and in a thread then sits on about the background itself.
    nonisolated static func scrim(_ page: Page, _ display: (reduceTransparency: Bool, increaseContrast: Bool)) -> CGFloat {
        if display.reduceTransparency { return 1 }
        switch page {
        case .hero: return display.increaseContrast ? 0.6 : 0
        case .thread: return display.increaseContrast ? 0.75 : threadScrim
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
