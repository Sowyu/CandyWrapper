import AppKit
import ImageIO
import os

/// The Dither theme's art (CandyWrapper's own, after Capy's desktop app): the chosen picture, or the desktop picture,
/// filling the main panel in its own colors at 2pt ordered-dither dots of brightness, held within a reach of the
/// panel's background that keeps text readable anywhere on it. A new thread shows it fully, an open thread under a
/// light scrim of the background, and every other page under a heavy one. It renders once per size and appearance
/// off the main thread. Opening a new thread resolves the dots in, in Bayer order, for 0.75 s. Thread activity
/// leaves the art still.
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
    private var loggedScrim: CGFloat?
    /// macOS's Reduce Transparency, replaceable in tests.
    var systemReducesTransparency: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

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
        // "Ignore Reduce Transparency" and the other theme settings take effect at once.
        NotificationCenter.default.addObserver(self, selector: #selector(displayOptionsChanged), name: ThemeRuntime.didChange, object: nil)
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

    /// How much of the art a page shows. `page` is the heavy scrim, for the Orchestrator's pane and like pages.
    public enum Emphasis: Sendable { case hero, thread, settings, page }

    /// A page calls this: while `source` is the frontmost registered page showing inside the art's panel, the art
    /// takes `emphasis`'s scrim. Pass nil when the source leaves. Pages that never call it get the heavy page scrim.
    @MainActor
    public static func setEmphasis(_ emphasis: Emphasis?, from source: NSView) {
        let wasHero = sources.object(forKey: source)?.emphasis == .hero
        if let emphasis { sources.setObject(EmphasisBox(emphasis: emphasis), forKey: source) } else { sources.removeObject(forKey: source) }
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
    /// Each registered page and its emphasis, weakly held.
    @MainActor private static let sources = NSMapTable<NSView, EmphasisBox>.weakToStrongObjects()
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

    /// A window moved to another screen shows that screen's desktop picture.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window { NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: window) }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(desktopMayHaveChanged), name: NSWindow.didChangeScreenNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// A move between screens refreshes the art for the new backing scale.
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

    /// What the panel shows over the art: the frontmost registered page that's visible inside it decides, whatever
    /// order the pages registered in, and an unregistered page gets the heavy scrim.
    var page: DitherArt.Page {
        guard let panel = superview, window != nil else { return .page }
        let showing = (Self.sources.keyEnumerator().allObjects as? [NSView] ?? []).filter {
            $0.window === window && $0.isDescendant(of: panel) && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
        guard let front = showing.max(by: { Self.isInFront($1, of: $0) }), let emphasis = Self.sources.object(forKey: front)?.emphasis else {
            return .page
        }
        switch emphasis {
        case .hero: return .hero
        case .thread: return .thread
        case .settings: return .settings
        case .page: return .page
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
        let page = self.page
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        let alpha = DitherArt.scrim(page, display, light: !dark)
        if loggedScrim != alpha {
            DitherArt.log.notice("scrim \(alpha) on \(String(describing: page), privacy: .public): reduce transparency \(display.reduceTransparency), increase contrast \(display.increaseContrast), dark \(dark)")
        }
        loggedScrim = alpha
        scrim.backgroundColor = background.withAlphaComponent(alpha).cgColor
        CATransaction.commit()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let band = DitherChrome.bandColor(in: self)
        // Bottom (no band) to top (all band).
        let ts = (0...10).reversed().map { Double($0) / 10 }
        blend.locations = ts.map { NSNumber(value: 1 - $0) }
        blend.colors = ts.map { band.copy(alpha: DitherChrome.bandBlend($0))! }
        CATransaction.commit()
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
        let url = ThemeRuntime.ditherPicture ?? DitherArt.desktopPicture(for: window.screen)
        let background = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background
        let scale = window.backingScaleFactor
        let request = DitherArt.Request(url: url, width: Int((rect.width / DitherArt.dot).rounded(.up)),
                                        height: Int((rect.height / DitherArt.dot).rounded(.up)),
                                        background: [background.srgb.x, background.srgb.y, background.srgb.z], scale: scale,
                                        fallbacks: [DitherArt.desktopPicture(for: window.screen), DitherArt.defaultDesktop].compactMap { $0 }.filter { $0 != url })
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
                        // A render that failed isn't remembered, so the next refresh tries again.
                        self.shown = image.image == nil ? nil : request
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
    var scrimAlphaForTesting: CGFloat { scrim.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0 }
}

private struct DitherArtImage: @unchecked Sendable { let image: CGImage? }
private final class EmphasisBox { let emphasis: DitherArtView.Emphasis; init(emphasis: DitherArtView.Emphasis) { self.emphasis = emphasis } }
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

    /// The scrim for `page` under the system display options. Increase Contrast keeps the art as a faint texture: text
    /// on the hero and in a thread then sits on about the background itself. Reduce Transparency takes at least those
    /// scrims but never covers the art: full cover made Redesign a plain panel with any picture and no sign why (the
    /// user's MacBook, 2026-10-28). "Ignore Reduce Transparency" turns it off here (`ThemeRuntime.reducesTransparency`).
    nonisolated static func scrim(_ page: Page, _ display: (reduceTransparency: Bool, increaseContrast: Bool),
                                  light: Bool = false) -> CGFloat {
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
    nonisolated static func lightScrim(_ page: Page) -> CGFloat {
        switch page {
        case .hero: 0.65
        case .thread: 0.65 + 0.35 * threadScrim
        case .settings: 0.88
        case .page: pageScrim
        }
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
        for url in [request.url].compactMap({ $0 }) + request.fallbacks {
            let t0 = Date()
            guard let picture = picture(url, maxPixels: max(w, h) * 2) else { continue }
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

    /// `picture` covering the canvas, centered, faded into the background and dithered.
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
