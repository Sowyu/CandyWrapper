import AppKit
import ImageIO

/// The Dither theme's art (CandyWrapper's own, after Capy's desktop app): the chosen picture, or the desktop picture,
/// filling the main panel in its own colors at 2pt ordered-dither dots of brightness, held within a reach of the
/// panel's background that keeps text readable anywhere on it. A new thread shows it fully, an open thread under a
/// light scrim of the background, and every other page under a heavy one. It renders once per size and appearance
/// off the main thread. It moves only in answer to something: dots resolve in when a new thread opens, the art drifts
/// a little as a thread scrolls back, and edge dots
/// shimmer while an agent works. Nothing runs while idle.
public final class DitherArtView: NSView {
    private let art = CALayer()
    private let scrim = CALayer()
    private var shown: DitherArt.Request?
    /// The prepared picture, kept while a motion needs frames from it.
    private var field: DitherArt.Field?
    /// How far the art has drifted down while scrolling back through a thread, in points.
    private var parallax: CGFloat = 0
    private var looping = false

    /// Dots of picture above the panel's top, for the parallax to reveal.
    static let margin = 12
    private var pending: DitherArt.Request?
    private var debounce: DispatchWorkItem?

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
    }

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
        if emphasis == .hero, !wasHero, let art = art(behind: source), let field = art.field {
            art.playResolve(field, final: art.art.contents.map { $0 as! CGImage })
        }
        for art in arts.allObjects { art.updateScrim() }
    }
    @MainActor private static let heroSources = NSHashTable<NSView>.weakObjects()
    @MainActor private static let workingSources = NSHashTable<NSView>.weakObjects()

    /// The art showing behind `source`, if any.
    @MainActor
    static func art(behind source: NSView) -> DitherArtView? {
        arts.allObjects.first { art in art.window != nil && art.window === source.window && art.superview.map { source.isDescendant(of: $0) } == true }
    }

    /// A shimmering "Working" label calls this as it starts and stops.
    @MainActor
    public static func setWorking(_ working: Bool, from source: NSView) {
        if working { workingSources.add(source) } else { workingSources.remove(source) }
        for art in arts.allObjects { art.updateLoop() }
    }

    /// The timeline calls this as it scrolls: `distance` is how far it sits above its end, in points.
    @MainActor
    public static func scrolled(_ distance: CGFloat, from source: NSView) {
        guard let art = art(behind: source) else { return }
        let next = min(CGFloat(margin) * DitherArt.dot, max(0, distance) * 0.03).rounded()
        guard next != art.parallax else { return }
        art.parallax = next
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.placeArt()
        CATransaction.commit()
    }

    /// Starts or stops the shimmer: while an agent works in this window, the dots on an edge twinkle. Its six frames
    /// exist only while it runs; Core Animation flips them, so the app itself does nothing per frame.
    func updateLoop() {
        let working = Self.workingSources.allObjects.contains { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
        let want = window != nil && field != nil && working
        guard want != looping else { return }
        looping = want
        art.removeAnimation(forKey: "loop")
        guard want, let field else { return }
        let patterns = (0..<6).map { DitherArt.Pattern(jitter: ($0 + 1, 0.4)) }
        let frameTime = 0.16
        let target = Handoff(value: self)
        DispatchQueue.global(qos: .utility).async {
            let frames = Handoff(value: patterns.compactMap { DitherArt.image(field, $0) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let frames = frames.value, view = target.value
                    guard view.looping == want, !frames.isEmpty else { return }
                    let loop = CAKeyframeAnimation(keyPath: "contents")
                    loop.values = frames
                    loop.calculationMode = .discrete
                    loop.duration = frameTime * Double(frames.count)
                    loop.repeatCount = .infinity
                    view.art.add(loop, forKey: "loop")
                }
            }
        }
    }

    /// Dots resolve in, in Bayer order, when a picture first shows.
    private func playResolve(_ field: DitherArt.Field, final: CGImage?) {
        let target = Handoff(value: self), last = Handoff(value: final)
        DispatchQueue.global(qos: .userInitiated).async {
            let frames = Handoff(value: (1...10).compactMap { DitherArt.image(field, .init(reveal: Double($0) / 10)) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let frames = frames.value, view = target.value, final = last.value
                    guard !frames.isEmpty else { return }
                    let resolve = CAKeyframeAnimation(keyPath: "contents")
                    resolve.values = frames + [final as Any]
                    resolve.calculationMode = .discrete
                    resolve.duration = 0.75
                    view.art.add(resolve, forKey: "resolve")
                }
            }
        }
    }
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
        updateLoop()
    }

    /// The whole panel: the thread's top fade blends it into the header.
    var artRect: CGRect { bounds }

    /// The shown canvas at one dot per pixel, its top left at the panel's top left. A live resize shows the old canvas
    /// cropped or short by a few dots until the new one renders.
    private func placeArt() {
        guard let shown else { return }
        let w = CGFloat(shown.width) * DitherArt.dot, h = CGFloat(shown.height) * DitherArt.dot
        // The margin's dots sit above the panel's top until the parallax brings them down.
        let top = -CGFloat(Self.margin) * DitherArt.dot + parallax
        art.frame = CGRect(x: 0, y: bounds.height - top - h, width: w, height: h)
    }

    var scrimAlpha: CGFloat {
        guard let panel = superview, window != nil else { return DitherArt.pageScrim }
        func shows(_ table: NSHashTable<NSView>) -> Bool {
            table.allObjects.contains { $0.window === window && $0.isDescendant(of: panel) && !$0.isHiddenOrHasHiddenAncestor }
        }
        if shows(Self.heroSources) { return 0 }
        if shows(Self.threadSources) { return DitherArt.threadScrim }
        return DitherArt.pageScrim
    }

    /// Main thread only, like every view method.
    func updateScrim() {
        let dark = effectiveAppearance.isDark
        let background = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.nsColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
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
                                        height: Int((rect.height / DitherArt.dot).rounded(.up)) + Self.margin,
                                        background: [background.srgb.x, background.srgb.y, background.srgb.z], scale: scale)
        guard request != shown, request != pending else { return }
        pending = request
        debounce?.cancel()
        // A live resize lands here every frame; the last size renders, the old art stretches meanwhile.
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let field = DitherArt.field(request)
                let image = DitherArtImage(image: field.flatMap { DitherArt.image($0, .init()) })
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.pending == request else { return }
                        let firstShow = self.shown?.url != request.url
                        self.pending = nil
                        self.shown = request
                        self.field = field
                        self.art.contents = image.image
                        self.looping = false
                        self.updateLoop()
                        if firstShow, let field { self.playResolve(field, final: image.image) }
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        self.placeArt()
                        CATransaction.commit()
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
/// Hands a value to the main queue from a render; it is only read there.
private struct Handoff<T>: @unchecked Sendable { let value: T }

/// The art's rendering. Touches no AppKit view, so it runs on any thread.
public enum DitherArt {
    /// Dot size in points.
    public nonisolated static let dot: CGFloat = 2
    /// The background's share over an open thread: the cap already keeps text readable, this calms it under messages.
    nonisolated static let threadScrim: CGFloat = 0.2
    /// The background's share over Settings and every other page, whose cards and lists aren't frosted.
    nonisolated static let pageScrim: CGFloat = 0.92

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

    /// The picture prepared once per size: covered, faded and held to the reach, as each dot's distance from the
    /// background. Every frame of the art quantizes this, so motion costs a cheap pass, not a decode.
    struct Field: Sendable {
        var width: Int, height: Int
        var background: [Double]
        /// Three channels per dot.
        var deviation: [Float]
    }

    /// How one frame quantizes the field.
    struct Pattern: Sendable {
        /// Shifts the Bayer matrix, which moves the dots.
        var offsetX = 0, offsetY = 0
        /// Dots whose threshold is above this stay background: 0 shows nothing, 1 everything.
        var reveal = 1.0
        /// Multiplies each dot's strength.
        var gain = 1.0
        /// Nudges each threshold by a hash of the position and this seed, so dots on an edge flicker.
        var jitter: (seed: Int, amount: Double)?
    }

    /// The picture covering the canvas, centered, faded into the background and dithered, or nil if it can't be read.
    nonisolated static func render(_ request: Request) -> CGImage? {
        field(request).flatMap { image($0, Pattern()) }
    }

    nonisolated static func field(_ request: Request) -> Field? {
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
        var deviation = [Float](repeating: 0, count: w * h * 3)
        // Row 0 of the buffer is the top of the picture.
        for y in 0..<h {
            let keep = 1 - fade((Double(y) + 0.5) / Double(h))
            for x in 0..<w {
                let i = (y * w + x) * 4
                var d = (0..<3).map { (Double(data[i + $0]) - bg[$0]) * keep }
                let m = d.map(abs).max() ?? 0
                if m > reach { d = d.map { $0 * reach / m } }
                for c in 0..<3 { deviation[(y * w + x) * 3 + c] = Float(d[c]) }
            }
        }
        return Field(width: w, height: h, background: bg, deviation: deviation)
    }

    /// One frame. Each dot is the picture's own color at a dithered strength over the background, so the dots keep its
    /// hue instead of scattering red, green and blue, and a faded area is exactly the background. Three strengths per
    /// hue (none, half the reach, the full reach) make a clean halftone, not a mush of shades.
    nonisolated static func image(_ field: Field, _ pattern: Pattern) -> CGImage? {
        let w = field.width, h = field.height, bg = field.background
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        let step = reach / 2
        let base = (0..<3).map { UInt8(min(max(bg[$0], 0), 255).rounded()) }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4, f = (y * w + x) * 3
                var threshold = (Double(bayer[((y + pattern.offsetY) & 7) * 8 + ((x + pattern.offsetX) & 7)]) + 0.5) / 64
                data[i] = base[0]; data[i + 1] = base[1]; data[i + 2] = base[2]
                guard threshold <= pattern.reveal else { continue }
                if let jitter = pattern.jitter {
                    var hash = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663 ^ jitter.seed &* 83492791)
                    hash ^= hash >> 13; hash = hash &* 0x5bd1e995; hash ^= hash >> 15
                    threshold += (Double(hash & 1023) / 1023 - 0.5) * jitter.amount
                }
                let gain = pattern.gain
                let d0 = Double(field.deviation[f]) * gain, d1 = Double(field.deviation[f + 1]) * gain
                let d2 = Double(field.deviation[f + 2]) * gain
                let m = max(abs(d0), abs(d1), abs(d2))
                guard m > 0.5 else { continue }
                let scaled = m / step, low = scaled.rounded(.down)
                let q = (scaled - low > threshold ? low + 1 : low) * step / m
                data[i] = UInt8(min(max(bg[0] + d0 * q, 0), 255).rounded())
                data[i + 1] = UInt8(min(max(bg[1] + d1 * q, 0), 255).rounded())
                data[i + 2] = UInt8(min(max(bg[2] + d2 * q, 0), 255).rounded())
            }
        }
        return ctx.makeImage()
    }
}
