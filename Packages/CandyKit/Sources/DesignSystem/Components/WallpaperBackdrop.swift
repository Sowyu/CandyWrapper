import AppKit
import ImageIO

/// Classic Glass's base layer (docs/design.md "Glass"): the desktop picture, laid out as the Desktop lays it out,
/// blurred once off the main thread at an eighth of the screen's size and shown in an opaque layer lined up with
/// the real desktop. The window looks see-through, but the window server has no live blur to run, and moving the
/// window only moves a layer. Anything this can't reproduce falls back to the real blur.
public enum WallpaperBlur {
    nonisolated static let downscale: CGFloat = 8
    /// Points, before the downscale.
    nonisolated static let radius: CGFloat = 30
    /// The system backdrop's own `colorSaturate` amount (2.2 light, 2.4 dark, read from its filters on macOS 27). Classic
    /// Glass hides the material's tint layers, so no tint goes on top: the measured match needs none.
    // ponytail: copied from the macOS 27 backdrop; read the filters again (docs/design.md "Glass") if a macOS update
    // changes the frost.
    nonisolated static func saturation(dark: Bool) -> CGFloat { dark ? 2.4 : 2.2 }

    /// How the Desktop places its picture. NSWorkspace reports scaling and clipping only, so `.tile` is reachable
    /// only through the debug override.
    public enum Placement: String, Sendable, Hashable { case fill, fit, stretch, center, tile }

    /// The placement NSWorkspace's options describe. A missing clipping key means fill, which is what the Desktop
    /// shows for the default picture.
    nonisolated static func placement(scaling: UInt?, clip: Bool?) -> Placement {
        switch scaling.flatMap(NSImageScaling.init(rawValue:)) ?? .scaleProportionallyUpOrDown {
        case .scaleAxesIndependently: return .stretch
        case .scaleNone: return .center
        default: return clip ?? true ? .fill : .fit
        }
    }

    /// Where the picture lands on a screen of `screen` pixels, y up. `image` is its natural size in screen pixels.
    /// For `.tile`, the first tile, at the top left.
    nonisolated static func imageRect(image: CGSize, screen: CGSize, placement: Placement) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        func centered(_ size: CGSize) -> CGRect {
            CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width, height: size.height)
        }
        let sx = screen.width / image.width, sy = screen.height / image.height
        switch placement {
        case .fill: return centered(CGSize(width: image.width * max(sx, sy), height: image.height * max(sx, sy)))
        case .fit: return centered(CGSize(width: image.width * min(sx, sy), height: image.height * min(sx, sy)))
        case .stretch: return CGRect(origin: .zero, size: screen)
        case .center: return centered(image)
        case .tile: return CGRect(x: 0, y: screen.height - image.height, width: image.width, height: image.height)
        }
    }

    // MARK: Guarded folders

    /// Folders macOS asks the user about before an app reads them, relative to the home folder.
    nonisolated static let guardedInHome = ["Desktop", "Documents", "Downloads", ".Trash", "Library/Mobile Documents",
                                            "Library/CloudStorage", "Library/Containers", "Library/Group Containers"]

    /// Whether reading `path` could make macOS ask for permission: the guarded home folders, removable and network
    /// volumes, and photo libraries.
    nonisolated static func isGuarded(_ path: String, home: String) -> Bool {
        let path = (path as NSString).standardizingPath
        func under(_ dir: String) -> Bool { path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") }
        if under("/Volumes") || under("/System/Volumes/Data/Volumes") { return true }
        if path.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) { return true }
        for home in Set([home, "/System/Volumes/Data" + home]) where guardedInHome.contains(where: { under(home + "/" + $0) }) {
            return true
        }
        return false
    }

    /// `path` with its symbolic links resolved one component at a time, or nil if it is guarded or passes through
    /// a guarded folder. It never looks inside a guarded folder, so it can't cause a prompt either.
    nonisolated static func unguardedPath(_ path: String, home: String) -> String? {
        // The home folder can itself be a link, so both spellings count.
        let homes = [home, URL(filePath: home).resolvingSymlinksInPath().path]
        func guarded(_ p: String) -> Bool { homes.contains { isGuarded(p, home: $0) } }
        // Lexical, because `standardizingPath` turns /private/var back into /var, the link it came from.
        func parts(_ p: String) -> [String] {
            p.split(separator: "/").reduce(into: [String]()) { out, c in
                if c == ".." { _ = out.popLast() } else if c != "." { out.append(String(c)) }
            }
        }
        var pending = parts(path)
        var current = "/", hops = 0
        while !pending.isEmpty {
            let candidate = (current as NSString).appendingPathComponent(pending.removeFirst())
            if guarded(candidate) { return nil }
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                if hops > 32 { return nil }
                let absolute = target.hasPrefix("/") ? target : (current as NSString).appendingPathComponent(target)
                pending = parts(absolute) + pending
                current = "/"
            } else {
                current = candidate
            }
        }
        return guarded(current) ? nil : current
    }

    // MARK: Dynamic pictures

    /// Which image of a picture the Desktop shows. Dynamic pictures that follow light and dark mode pick by
    /// appearance. Ones that follow the time or the sun change while the app sits idle, so they keep the real blur.
    enum Variant: Equatable { case still(Int), byAppearance(light: Int, dark: Int), byTime }

    nonisolated static func variant(of source: CGImageSource) -> Variant {
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        guard CGImageSourceGetCount(source) > 1, let metadata = CGImageSourceCopyMetadataAtIndex(source, primary, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else {
            return .still(primary)
        }
        for tag in tags {
            guard CGImageMetadataTagCopyPrefix(tag) as String? == "apple_desktop",
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            if name == "h24" || name == "solar" { return .byTime }
            if name == "apr", let value = CGImageMetadataTagCopyValue(tag) as? String, let pair = appearanceIndices(value) {
                return .byAppearance(light: pair.light, dark: pair.dark)
            }
        }
        return .still(primary)
    }

    /// The light and dark image indices from an `apple_desktop:apr` tag: a base64 property list with `l` and `d`.
    nonisolated static func appearanceIndices(_ base64: String) -> (light: Int, dark: Int)? {
        guard let data = Data(base64Encoded: base64),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let light = plist["l"] as? Int, let dark = plist["d"] as? Int else { return nil }
        return (light, dark)
    }

    // MARK: Rendering

    /// Everything one blurred picture depends on. A screen whose request hasn't changed keeps its image.
    struct Request: Hashable, Sendable {
        var url: URL
        var placement: Placement
        /// The Desktop's fill color around a picture that doesn't cover the screen, sRGB.
        var fill: [CGFloat]
        /// The screen's size in pixels.
        var pixels: CGSize
        var scale: CGFloat
        var dark: Bool
        /// The Dither theme: 2pt dots in two grays instead of the blur.
        var dither = false
    }

    /// Dither dots, in points.
    nonisolated static let ditherDot: CGFloat = 2
    /// The two grays, sRGB. They stay inside the desktop range `WindowGlass.frostWorstBackground` assumes
    /// (10% gray in light, 85% in dark), so text on the panes keeps its contrast.
    nonisolated static func ditherTones(dark: Bool) -> (low: UInt8, high: UInt8) { dark ? (8, 190) : (64, 255) }

    /// The 8 x 8 Bayer matrix, thresholds 0..<64.
    nonisolated static let bayer: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// Ordered dither of RGBX pixels in place, each pixel to one of `ditherTones` by its luminance.
    nonisolated static func dither(_ data: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int, dark: Bool) {
        let (low, high) = ditherTones(dark: dark)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let l = 0.2126 * Float(data[i]) + 0.7152 * Float(data[i + 1]) + 0.0722 * Float(data[i + 2])
                let threshold = (Float(bayer[(y & 7) * 8 + (x & 7)]) + 0.5) * 4
                let v = l > threshold ? high : low
                data[i] = v; data[i + 1] = v; data[i + 2] = v
            }
        }
    }

    /// The blurred picture for `request`, or nil if it can't be read, is guarded or changes on its own. Touches no
    /// AppKit object, so it runs on any thread.
    nonisolated static func render(_ request: Request, home: String = NSHomeDirectory()) -> CGImage? {
        guard request.url.isFileURL, !request.url.path.contains("/com.apple.wallpaper/aerials/"),
              let path = unguardedPath(request.url.path, home: home),
              // An aerial moves, so no still matches it.
              !path.contains("/com.apple.wallpaper/aerials/"),
              let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil) else { return nil }
        let index: Int
        switch variant(of: source) {
        case .still(let i): index = i
        case .byAppearance(let light, let dark): index = request.dark ? dark : light
        case .byTime: return nil
        }
        guard index < CGImageSourceGetCount(source),
              let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return nil }
        var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        if ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5 { swap(&width, &height) }
        guard width >= 1, height >= 1, request.pixels.width >= 1, request.pixels.height >= 1 else { return nil }
        // Natural size: the picture's points at the screen's scale, as the Desktop centers and tiles it.
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let natural = 72 / (dpi > 0 ? dpi : 72) * request.scale
        let rect = imageRect(image: CGSize(width: width * natural, height: height * natural), screen: request.pixels,
                             placement: request.placement)

        let shrink = request.dither ? ditherDot * request.scale : downscale
        let canvas = CGRect(x: 0, y: 0, width: ceil(request.pixels.width / shrink), height: ceil(request.pixels.height / shrink))
        let toCanvas = canvas.width / request.pixels.width
        let target = CGSize(width: rect.width * toCanvas, height: rect.height * toCanvas)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(1, ceil(max(target.width, target.height)))]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }

        // Core Graphics and plain loops, not Core Image: Core Image cost 5 MB that stayed and 30 MB at its peak.
        let w = Int(canvas.width), h = Int(canvas.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let fill = request.fill.count == 3 ? request.fill : [0, 0, 0]
        ctx.setFillColor(red: fill[0], green: fill[1], blue: fill[2], alpha: 1)
        ctx.fill(canvas)
        ctx.interpolationQuality = .medium
        let placed = CGRect(x: rect.minX * toCanvas, y: rect.minY * toCanvas, width: target.width, height: target.height)
        if request.placement == .tile { ctx.draw(thumbnail, in: placed, byTiling: true) } else { ctx.draw(thumbnail, in: placed) }
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        if request.dither {
            dither(data, width: w, height: h, dark: request.dark)
            return ctx.makeImage()
        }

        // The window server blurs and saturates gamma-encoded sRGB, not linear light, so this does too.
        var plane = (0..<w * h * 3).map { Float(data[$0 / 3 * 4 + $0 % 3]) }
        blur(&plane, width: w, height: h, sigma: Float(radius * request.scale * toCanvas))
        let s = Float(saturation(dark: request.dark))
        for i in 0..<w * h {
            let r = plane[i * 3], g = plane[i * 3 + 1], b = plane[i * 3 + 2]
            let l = 0.2125 * r + 0.7154 * g + 0.0721 * b
            for (c, v) in [r, g, b].enumerated() { data[i * 4 + c] = UInt8(min(max(l + s * (v - l), 0), 255).rounded()) }
        }
        return ctx.makeImage()
    }

    /// A Gaussian blur of an interleaved RGB plane, one pass per axis, edges extended.
    nonisolated static func blur(_ plane: inout [Float], width w: Int, height h: Int, sigma: Float) {
        guard sigma > 0.1 else { return }
        let r = Int((sigma * 3).rounded(.up))
        var kernel = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        var out = [Float](repeating: 0, count: plane.count)
        for horizontal in [true, false] {
            let n = horizontal ? w : h, lines = horizontal ? h : w
            func at(_ line: Int, _ i: Int) -> Int { (horizontal ? line * w + i : i * w + line) * 3 }
            for line in 0..<lines {
                for i in 0..<n {
                    var acc: (Float, Float, Float) = (0, 0, 0)
                    for k in -r...r {
                        let j = min(max(i + k, 0), n - 1)
                        let p = at(line, j)
                        let weight = kernel[k + r]
                        acc.0 += plane[p] * weight; acc.1 += plane[p + 1] * weight; acc.2 += plane[p + 2] * weight
                    }
                    let o = at(line, i)
                    out[o] = acc.0; out[o + 1] = acc.1; out[o + 2] = acc.2
                }
            }
            swap(&plane, &out)
        }
    }

    #if DEBUG
    /// Debug-only: a test picture and placement instead of the real desktop, so checks never touch the user's
    /// settings. `CANDY_WALLPAPER=/path/to/image` and optionally `CANDY_WALLPAPER_PLACEMENT=fill|fit|stretch|center|tile`.
    nonisolated static let override: (url: URL, placement: Placement?)? = {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CANDY_WALLPAPER"], !path.isEmpty else { return nil }
        return (URL(filePath: path), env["CANDY_WALLPAPER_PLACEMENT"].flatMap(Placement.init(rawValue:)))
    }()
    #endif

    /// The request for `screen` in the given appearance, or nil when the Desktop shows no file.
    @MainActor
    static func request(for screen: NSScreen, dark: Bool) -> Request? {
        let workspace = NSWorkspace.shared
        guard var url = workspace.desktopImageURL(for: screen) ?? ThemeRuntime.ditherPicture, url.isFileURL else { return nil }
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        var placement = placement(scaling: (options[.imageScaling] as? NSNumber)?.uintValue,
                                  clip: (options[.allowClipping] as? NSNumber)?.boolValue)
        #if DEBUG
        if let override { url = override.url; placement = override.placement ?? placement }
        #endif
        var fill: [CGFloat] = [0, 0, 0]
        if let c = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) { fill = [c.redComponent, c.greenComponent, c.blueComponent] }
        let dither = ThemeRuntime.isDither(dark: dark)
        if dither, let picture = ThemeRuntime.ditherPicture { url = picture; placement = .fill; fill = [0, 0, 0] }
        let scale = screen.backingScaleFactor
        return Request(url: url, placement: placement, fill: fill,
                       pixels: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale), scale: scale, dark: dark,
                       dither: dither)
    }
}

/// The blurred pictures, one per display, shared by every window. Main thread only.
@MainActor
final class WallpaperStore {
    static let shared = WallpaperStore()
    /// Posted when a picture finishes, so backdrops waiting for it pick it up.
    static let ready = Notification.Name("CandyWallpaperReady")

    enum Lookup { case ready(CGImage), pending, unavailable }

    private struct Entry {
        var request: WallpaperBlur.Request
        var image: CGImage?
        var pending: Bool
    }
    private var entries: [CGDirectDisplayID: Entry] = [:]
    private let render: @Sendable (WallpaperBlur.Request) -> CGImage?
    /// How many pictures it has started, for tests.
    private(set) var renders = 0

    init(render: @escaping @Sendable (WallpaperBlur.Request) -> CGImage? = { WallpaperBlur.render($0) }) {
        self.render = render
    }

    /// The picture for `display`, starting a render when `request` differs from the last one.
    func lookup(_ display: CGDirectDisplayID, _ request: WallpaperBlur.Request?) -> Lookup {
        guard let request else { entries[display] = nil; return .unavailable }
        if let entry = entries[display], entry.request == request {
            if let image = entry.image { return .ready(image) }
            return entry.pending ? .pending : .unavailable
        }
        entries[display] = Entry(request: request, image: nil, pending: true)
        renders += 1
        let render = render
        DispatchQueue.global(qos: .utility).async {
            let image = SendableImage(image: render(request))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WallpaperStore.finish(self, display, request, image.image) }
            }
        }
        return .pending
    }

    private static func finish(_ store: WallpaperStore, _ display: CGDirectDisplayID, _ request: WallpaperBlur.Request, _ image: CGImage?) {
        guard store.entries[display]?.request == request else { return }
        store.entries[display] = Entry(request: request, image: image, pending: false)
        NotificationCenter.default.post(name: ready, object: store)
    }

    func isPending(_ display: CGDirectDisplayID) -> Bool { entries[display]?.pending ?? false }

    /// Drops the pictures of displays that are gone.
    func keep(_ displays: Set<CGDirectDisplayID>) {
        entries = entries.filter { displays.contains($0.key) }
    }
}

private struct SendableImage: @unchecked Sendable { let image: CGImage? }

/// One screen as the backdrop sees it.
struct WallpaperScreen {
    var display: CGDirectDisplayID
    /// In screen coordinates.
    var frame: CGRect
    var request: WallpaperBlur.Request?

    @MainActor
    static func current(dark: Bool) -> [WallpaperScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return WallpaperScreen(display: id, frame: screen.frame, request: WallpaperBlur.request(for: screen, dark: dark))
        }
    }
}

/// Classic Glass's base: the pre-blurred desktop picture, one opaque layer per screen placed where that screen sits
/// relative to the window, over the real blur it falls back to. Inactive windows and Reduce Transparency show the
/// real material, which is a plain color then, as are pictures that can't be read.
public final class WallpaperBackdropView: NSView {
    /// The real blur: the fallback, and the plain color of inactive windows.
    let material: WindowGlassBackdropView
    /// Each screen's picture and that screen's frame in screen coordinates.
    private var plates: [CGDirectDisplayID: (layer: CALayer, screen: CGRect)] = [:]
    private var showsPicture = false
    var store = WallpaperStore.shared
    var screens: @MainActor (Bool) -> [WallpaperScreen] = WallpaperScreen.current
    /// How many times it asked for the screens' pictures, for tests.
    private(set) var refreshes = 0

    /// What makes the picture worth checking again: the screen set or scale, the Space, Reduce Transparency, and
    /// coming back to the app, which is when a wallpaper changed in System Settings shows up. Notifications only.
    static let appTriggers: [Notification.Name] = [NSApplication.didChangeScreenParametersNotification,
                                                   NSApplication.didBecomeActiveNotification, WallpaperStore.ready]
    static let workspaceTriggers: [Notification.Name] = [NSWorkspace.activeSpaceDidChangeNotification,
                                                         NSWorkspace.accessibilityDisplayOptionsDidChangeNotification]
    static let windowTriggers: [Notification.Name] = [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                                                      NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                                                      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]

    public override init(frame frameRect: NSRect) {
        material = WindowGlassBackdropView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        addSubview(material)
        for name in Self.appTriggers {
            NotificationCenter.default.addObserver(self, selector: #selector(triggered), name: name, object: nil)
        }
        for name in Self.workspaceTriggers {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(triggered), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var wantsUpdateLayer: Bool { true }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            for name in Self.windowTriggers + [NSWindow.didMoveNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: window)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in Self.windowTriggers {
            NotificationCenter.default.addObserver(self, selector: #selector(triggered), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved), name: NSWindow.didMoveNotification, object: window)
        refresh()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    public override func layout() {
        super.layout()
        place()
    }

    @objc private func triggered(_ note: Notification) { refresh() }
    @objc private func windowMoved(_ note: Notification) { place() }

    /// Asks the store for every screen's picture and shows them, or the real material.
    func refresh() {
        guard let window else { return }
        refreshes += 1
        let dark = effectiveAppearance.isDark
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // A dithered picture is the theme itself, so it stays on inactive windows; the blur gives way to the material.
        let flat = reduce || !(ThemeRuntime.isDither(dark: dark) || window.isMainWindow || window.isKeyWindow)
        let list = reduce ? [] : screens(dark)
        store.keep(Set(list.map(\.display)))
        var images: [CGDirectDisplayID: (CGImage, CGRect)] = [:]
        var pending = false, missing = list.isEmpty
        for screen in list {
            switch store.lookup(screen.display, screen.request) {
            case .ready(let image): images[screen.display] = (image, screen.frame)
            case .pending: pending = true
            case .unavailable: missing = true
            }
        }
        // While a picture renders, keep what shows now; the store posts `ready` when it's done.
        if pending && !missing { if !showsPicture { show(nil, flat: flat) }; return }
        show(missing ? nil : images, flat: flat)
    }

    private func show(_ images: [CGDirectDisplayID: (CGImage, CGRect)]?, flat: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let picture = images != nil && !flat
        for (id, plate) in plates where images?[id] == nil {
            plate.layer.removeFromSuperlayer()
            plates[id] = nil
        }
        for (id, (image, screen)) in images ?? [:] {
            let plate = plates[id]?.layer ?? makePlate()
            plates[id] = (plate, screen)
            if (plate.contents as! CGImage?) !== image { plate.contents = image }
            // Dither dots stay square; the blur scales smoothly.
            plate.magnificationFilter = ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? .nearest : .linear
            plate.isHidden = !picture
        }
        showsPicture = picture
        material.isHidden = picture
        layer?.backgroundColor = picture ? NSColor.windowBackgroundColor.cgColor(in: self) : nil
        CATransaction.commit()
        place()
    }

    private func makePlate() -> CALayer {
        let plate = CALayer()
        plate.isOpaque = true
        plate.contentsGravity = .resize
        plate.zPosition = -1
        plate.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(plate)
        return plate
    }

    /// Lines each screen's picture up with that screen. Moving or resizing the window lands here, and it only moves
    /// layers.
    func place() {
        guard let window, showsPicture else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for plate in plates.values { plate.layer.frame = convert(window.convertFromScreen(plate.screen), from: nil) }
        CATransaction.commit()
    }

    var showsPictureForTesting: Bool { showsPicture }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func isAccessibilityElement() -> Bool { false }
}
