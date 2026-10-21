import AppKit
import ImageIO

/// The Dither theme's art (CandyWrapper's own, after Capy's desktop app): the chosen picture, or the desktop picture,
/// filling the main panel in its own colors at 2pt ordered-dither dots of brightness, held within a reach of the
/// panel's background that keeps text readable anywhere on it. A new thread shows it
/// fully; anywhere else a scrim of the background covers most of it, so messages and settings read as on the stock
/// theme. It renders once per size and appearance off the main thread and runs nothing while idle.
public final class DitherArtView: NSView {
    private let art = CALayer()
    private let scrim = CALayer()
    private var shown: DitherArt.Request?
    private var pending: DitherArt.Request?
    private var debounce: DispatchWorkItem?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        art.magnificationFilter = .nearest
        art.contentsGravity = .resize
        art.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        scrim.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
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

    /// The new-thread screen calls this: while `source` shows inside the art's panel, the art shows unscrimmed.
    @MainActor
    public static func setVivid(_ vivid: Bool, from source: NSView) {
        if vivid { vividSources.add(source) } else { vividSources.remove(source) }
        for art in arts.allObjects { art.updateScrim() }
    }
    @MainActor private static let vividSources = NSHashTable<NSView>.weakObjects()
    @MainActor private static let arts = NSHashTable<DitherArtView>.weakObjects()

    public override func updateLayer() {
        updateScrim()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.frame = artRect
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

    var isVivid: Bool {
        guard let panel = superview, window != nil else { return false }
        return Self.vividSources.allObjects.contains { $0.window === window && $0.isDescendant(of: panel) && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// Main thread only, like every view method.
    func updateScrim() {
        let dark = effectiveAppearance.isDark
        let background = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.nsColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        scrim.backgroundColor = background.withAlphaComponent(DitherArt.scrim).cgColor
        scrim.opacity = isVivid ? 0 : 1
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

/// The art's rendering. Touches no AppKit view, so it runs on any thread.
public enum DitherArt {
    /// Dot size in points.
    public nonisolated static let dot: CGFloat = 2
    /// Brightness levels a dot steps between, from the background to the picture's brightest.
    nonisolated static let levels = 9
    /// The background's share where text can sit: messages, settings and every page but a new thread.
    nonisolated static let scrim: CGFloat = 0.9

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
        let step = 255 / Double(levels - 1)
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
}
