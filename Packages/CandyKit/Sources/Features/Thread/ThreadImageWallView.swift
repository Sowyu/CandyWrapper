import AppKit
import DesignSystem
import T3Protocol
import T3Store

private typealias Tokens = RedesignTokens

/// A masonry of gallery images, the document of a scroll view: the card's grid and the full gallery's wall.
///
/// Images take their place only once their natural size is known (from the signed URL or the first decode), and only
/// in order, so a placed image never moves when a later one measures or when its pixels arrive. Measuring is the first
/// load at the column's size, stored in the decode cache the tile then reads. Only tiles within half a viewport of the
/// visible rect exist; the rest hold nothing.
final class GalleryMasonryView: DSView {
    struct Metrics {
        var inset: NSEdgeInsets
        var gap: CGFloat
        var minColumn: CGFloat
        var radius: CGFloat
    }

    var metrics: Metrics { didSet { relayout() } }
    /// Newest first, as the gallery orders them.
    var images: [GalleryImage] = [] {
        didSet {
            guard images != oldValue else { return }
            let keys = Set(images.map(\.pixelKey))
            loaders = loaders.filter { keys.contains($0.key) }
            for (index, tile) in tiles { tile.removeFromSuperview(); tiles[index] = nil }
            relayout()
        }
    }
    /// Builds an image's loader; called once per image while it stays in `images`.
    var makeLoader: ((GalleryImage) -> AsyncImageView.Loader)?
    /// Prefixes the decode cache keys, so the full gallery can drop its own decodes on close.
    var cachePrefix = ""
    var onSelect: ((Int) -> Void)?
    /// The placed height or the measured estimate changed; the card resizes to fit.
    var onContentHeight: (() -> Void)?
    /// The tile drawn with the keyboard focus ring, by index.
    var focused: Int? { didSet { if focused != oldValue { for (i, t) in tiles { t.keyFocused = i == focused } } } }

    private(set) var frames: [CGRect] = []
    private(set) var tiles: [Int: GalleryTileView] = [:]
    private var loaders: [String: AsyncImageView.Loader] = [:]
    private var measuring: Set<String> = []
    private var failed: Set<String> = []
    /// Cache keys this view stored or its tiles read, so `releaseDecodes` can drop exactly those.
    private(set) var cacheKeys: Set<String> = []
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var lastWidth: CGFloat = 0

    init(metrics: Metrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var columnCount: Int {
        GalleryLayout.columns(width: contentWidth, minColumn: metrics.minColumn, gap: metrics.gap)
    }

    /// The width to lay out for before the scroll view has one, like the card's own width while it is measured.
    var widthHint: CGFloat = 0

    private var outerWidth: CGFloat {
        let clip = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        return clip > 1 ? clip : widthHint
    }

    private var contentWidth: CGFloat { max(1, outerWidth - metrics.inset.left - metrics.inset.right) }

    /// Re-flows when the scroll view's width changed since the last layout; the host calls it from its own layout.
    func fitWidth() { if outerWidth != lastWidth { relayout() } }

    private var columnWidth: CGFloat {
        let n = CGFloat(columnCount)
        return ((contentWidth - (n - 1) * metrics.gap) / n).rounded(.down)
    }

    /// Height over width, or nil while it isn't known. A picture that failed takes 3:4 and shows the failed label.
    func aspect(_ image: GalleryImage) -> CGFloat? {
        if failed.contains(image.pixelKey) { return 0.75 }
        guard let size = image.naturalSize, size.width > 0 else { return nil }
        return size.height / size.width
    }

    /// The document's height for every image, with 4:3 standing in for the ones not measured yet.
    var estimatedHeight: CGFloat {
        let aspects = images.map { aspect($0) ?? 0.75 }
        let h = GalleryLayout.masonry(aspects: aspects, width: contentWidth, columns: columnCount, gap: metrics.gap).height
        return metrics.inset.top + h + metrics.inset.bottom
    }

    func frame(of index: Int) -> CGRect? { frames.indices.contains(index) ? frames[index] : nil }

    /// Places the measured prefix, grows the document, then makes the near tiles and measures what comes next.
    func relayout() {
        var aspects: [CGFloat] = []
        for image in images { guard let a = aspect(image) else { break }; aspects.append(a) }
        let laid = GalleryLayout.masonry(aspects: aspects, width: contentWidth, columns: columnCount, gap: metrics.gap)
        frames = laid.frames.map { $0.offsetBy(dx: metrics.inset.left, dy: metrics.inset.top) }
        let clipHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let content = frames.isEmpty ? 0 : metrics.inset.top + laid.height + metrics.inset.bottom
        let size = NSSize(width: outerWidth, height: max(clipHeight, content))
        if frame.size != size { setFrameSize(size) }
        lastWidth = size.width
        tile()
        measure()
        onContentHeight?()
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A width change re-flows the columns; a scroll only brings tiles in and out.
                if clip.bounds.width != self.lastWidth { self.relayout() } else { self.tile(); self.measure() }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { relayout() }
    }

    /// The rect tiles live in: the visible rect and half a viewport either side.
    private var liveRect: CGRect {
        let visible = visibleRect
        return visible.insetBy(dx: 0, dy: -max(visible.height, 200) / 2)
    }

    /// Tiles for the placed images near the viewport; the rest go, with their pixels.
    func tile() {
        let live = liveRect
        let wanted = Set(frames.indices.filter { frames[$0].intersects(live) })
        for (index, tile) in tiles where !wanted.contains(index) { tile.removeFromSuperview(); tiles[index] = nil }
        for index in wanted.sorted() {
            let image = images[index]
            let tile = tiles[index] ?? {
                let tile = GalleryTileView(radius: metrics.radius)
                tile.action = { [weak self] in self?.onSelect?(index) }
                addSubview(tile)
                tiles[index] = tile
                return tile
            }()
            tile.frame = frames[index]
            tile.keyFocused = index == focused
            let key = cachePrefix + image.pixelKey
            cacheKeys.insert(key)
            tile.show(image, key: key, loader: failed.contains(image.pixelKey) ? { @Sendable _ in nil } : loader(image))
        }
    }

    private func loader(_ image: GalleryImage) -> AsyncImageView.Loader {
        if let loader = loaders[image.pixelKey] { return loader }
        let loader = makeLoader?(image) ?? ThreadImageGalleryView.loader(image)
        loaders[image.pixelKey] = loader
        return loader
    }

    /// Up to six first loads at a time for the unmeasured images just past the placed ones, while the placed column
    /// bottoms are within a viewport of the visible rect.
    private func measure() {
        guard window != nil, frames.count < images.count, measuring.count < 6 else { return }
        let placedBottom = frames.map(\.maxY).min() ?? 0
        guard frames.isEmpty || placedBottom < visibleRect.maxY + max(visibleRect.height, 400) else { return }
        let scale = window?.backingScaleFactor ?? 2
        let side = Int((columnWidth * scale).rounded(.up))
        for image in images[frames.count...].prefix(12) where measuring.count < 6 {
            guard aspect(image) == nil, !measuring.contains(image.pixelKey) else { continue }
            let pixelKey = image.pixelKey, key = image.key
            let memoryKey = "\(cachePrefix)\(pixelKey)|cover"
            cacheKeys.insert(cachePrefix + pixelKey)
            measuring.insert(pixelKey)
            let load = loader(image)
            Task { [weak self] in
                let result = await ImageDecodeCache.load(key: memoryKey, side: side, loader: load)
                guard let self else { return }
                self.measuring.remove(pixelKey)
                if let result {
                    // A loader that measured nothing on the way (a kept copy) still gives the proportions.
                    if self.images.first(where: { $0.pixelKey == pixelKey })?.naturalSize == nil {
                        MarkdownImages.record(CGSize(width: result.image.width, height: result.image.height), for: key)
                    }
                } else {
                    self.failed.insert(pixelKey)
                }
                self.relayout()
            }
        }
    }

    /// The pictures that failed while this view showed them.
    var failedImages: [GalleryImage] { images.filter { failed.contains($0.pixelKey) } }

    /// Drops every decode this view put in the shared cache. The full gallery calls it on close.
    func releaseDecodes() {
        for key in cacheKeys {
            ImageDecodeCache.memory.removeObject(forKey: "\(key)|cover" as NSString)
            ImageDecodeCache.memory.removeObject(forKey: "\(key)|fit" as NSString)
        }
        cacheKeys = []
        loaders = [:]
    }

    /// Scrolls a placed tile into view.
    func reveal(_ index: Int) {
        guard let rect = frame(of: index) else { return }
        scrollToVisible(rect.insetBy(dx: 0, dy: -metrics.gap))
        tile()
    }
}

/// One picture of the masonry: its pixels at its own proportions, and on hover a quiet strip at the bottom edge with
/// the source thread and the time.
final class GalleryTileView: ControlView {
    let thumb = AsyncImageView()
    let shade = CAGradientLayer()
    let caption = LabelView("", font: DSFont.ui(12), color: Themed.white(1))
    private let ring = CALayer()
    var keyFocused = false { didSet { if keyFocused != oldValue { restyle(animated: false) } } }
    /// Whether the hover strip shows: the pointer is over the tile or the keyboard focus is on it.
    var showsCaption: Bool { state.hovered || keyFocused || state.focusVisible }

    init(radius: CGFloat) {
        super.init(frame: .zero)
        scalesWhenPressed = false
        thumb.cacheable = true
        thumb.skeleton = true
        thumb.layer?.cornerRadius = radius
        thumb.layer?.cornerCurve = .continuous
        addSubview(thumb)
        // The strip lives inside the picture's clip, so it takes the picture's corners.
        shade.colors = [Themed.black(0).cgColor, Themed.black(Double(Tokens.Surface.resting)).cgColor]
        shade.opacity = 0
        thumb.layer?.addSublayer(shade)
        caption.alphaValue = 0
        caption.lineHeight = 16
        caption.truncation = .middle
        addSubview(caption)
        ring.cornerRadius = radius + 2
        ring.cornerCurve = .continuous
        ring.borderWidth = 2
        layer?.addSublayer(ring)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ image: GalleryImage, key: String, loader: @escaping AsyncImageView.Loader) {
        thumb.set(key: key, fallbackText: "Image unavailable", loader: loader, loadingText: "")
        caption.text = ThreadImageGalleryView.caption(image)
        setAccessibilityLabel(ThreadImageGalleryView.name(image) + ", " + caption.text)
    }

    override func layout() {
        super.layout()
        thumb.frame = bounds
        let strip: CGFloat = min(bounds.height, 40)
        caption.frame = NSRect(x: Tokens.Space.s + 2, y: bounds.height - 16 - Tokens.Space.s, width: max(0, bounds.width - 2 * (Tokens.Space.s + 2)), height: 16)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shade.frame = CGRect(x: 0, y: bounds.height - strip, width: bounds.width, height: strip)
        ring.frame = bounds.insetBy(dx: -2, dy: -2)
        CATransaction.commit()
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle(animated: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle(animated: false)
    }

    private func restyle(animated: Bool) {
        let on = showsCaption
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Motion.reduced)
        CATransaction.setAnimationDuration(Tokens.Motion.quick)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.curve)
        shade.opacity = on ? 1 : 0
        ring.borderColor = keyFocused || state.focusVisible ? Themed.color(\.ring).cgColor(in: self) : nil
        CATransaction.commit()
        if animated, !Motion.reduced {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Tokens.Motion.quick
                caption.animator().alphaValue = on ? 1 : 0
            }
        } else {
            caption.alphaValue = on ? 1 : 0
        }
    }
}

/// One picture large inside the full gallery, over a veil of the page: previous and next, the count, its source and
/// "Open in thread". A click on the veil returns to the wall.
final class GalleryViewerView: DSView {
    var images: [GalleryImage] = [] { didSet { if images != oldValue { show() } } }
    var index = 0 { didSet { if index != oldValue { show() } } }
    var cachePrefix = ""
    var makeLoader: ((GalleryImage) -> AsyncImageView.Loader)?
    var onClose: (() -> Void)?
    var onOpenInThread: ((GalleryImage) -> Void)?

    let picture = AsyncImageView()
    let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let detail = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconSm)
    let previous = ButtonView(nil, icon: .chevronLeft, variant: .ghost, size: .iconSm)
    let next = ButtonView(nil, icon: .chevronRight, variant: .ghost, size: .iconSm)
    let openInThread = ButtonView("Open in thread", icon: .arrowUpRight, variant: .ghost, size: .xs)
    static let bar: CGFloat = 52

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picture.cover = false
        picture.cacheable = true
        picture.skeleton = true
        picture.layer?.cornerRadius = Tokens.Radius.card
        picture.layer?.cornerCurve = .continuous
        detail.truncation = .middle
        for view in [picture, count, detail, close, previous, next, openInThread] as [NSView] { addSubview(view) }
        close.toolTip = "Back to all images"; close.setAccessibilityLabel("Back to all images")
        previous.toolTip = "Previous image"; previous.setAccessibilityLabel("Previous image")
        next.toolTip = "Next image"; next.setAccessibilityLabel("Next image")
        close.action = { [weak self] in self?.onClose?() }
        previous.action = { [weak self] in self?.step(-1) }
        next.action = { [weak self] in self?.step(1) }
        openInThread.action = { [weak self] in self?.shown.map { self?.onOpenInThread?($0) } }
        picture.onLoad = { [weak self] in self?.needsLayout = true }
        setAccessibilityRole(.group)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    var shown: GalleryImage? { images.indices.contains(index) ? images[index] : nil }

    func step(_ delta: Int) {
        guard !images.isEmpty else { return }
        index = (index + delta + images.count) % images.count
    }

    private func show() {
        guard let image = shown else { picture.set(key: nil, fallbackText: "", loader: nil); return }
        let loader = makeLoader?(image) ?? ThreadImageGalleryView.loader(image)
        picture.set(key: cachePrefix + image.pixelKey, fallbackText: "Image unavailable", loader: loader,
                    preview: ImageDecodeCache.preview(for: cachePrefix + image.pixelKey), loadingText: "")
        count.text = "\(index + 1) of \(images.count)"
        detail.text = ThreadImageGalleryView.caption(image, long: true) + " · " + ThreadImageGalleryView.name(image)
        picture.setAccessibilityLabel(ThreadImageGalleryView.name(image) + ", " + ThreadImageGalleryView.caption(image))
        previous.isHidden = images.count < 2
        next.isHidden = images.count < 2
        needsLayout = true
    }

    /// The area the picture fits in: below the top bar, above the footer, clear of the side arrows.
    var pictureArea: CGRect {
        let side = Tokens.Space.xl + 32 + Tokens.Space.s
        return CGRect(x: side, y: Self.bar, width: max(1, bounds.width - 2 * side), height: max(1, bounds.height - 2 * Self.bar))
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.xl, w = bounds.width, h = bounds.height
        let mid = (Self.bar / 2).rounded()
        count.frame = NSRect(x: pad, y: mid - 9, width: 160, height: 18)
        close.frame = NSRect(x: w - pad - 32, y: mid - 16, width: 32, height: 32)
        previous.frame = NSRect(x: pad, y: (h / 2 - 16).rounded(), width: 32, height: 32)
        next.frame = NSRect(x: w - pad - 32, y: (h / 2 - 16).rounded(), width: 32, height: 32)
        let area = pictureArea
        let scale = window?.backingScaleFactor ?? 2
        let size = shown?.naturalSize.map { GalleryLayout.fit($0, in: area.size, scale: scale) } ?? area.size
        picture.frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        picture.requestedSide = Int((max(size.width, size.height) * scale).rounded(.up))
        let bw = openInThread.intrinsicContentSize.width
        let footerY = h - Self.bar + (Self.bar - 24) / 2
        openInThread.frame = NSRect(x: w - pad - bw, y: footerY, width: bw, height: 24)
        detail.frame = NSRect(x: pad, y: footerY + 3, width: max(0, w - 2 * pad - bw - Tokens.Space.m), height: 18)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = Themed.color(\.background, Double(Tokens.Surface.floating)).cgColor(in: self)
    }

    /// The veil returns to the wall; the picture and the controls keep their clicks.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !picture.frame.contains(point) { onClose?() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // The picture and the labels are not controls: their clicks land on the veil's own handler.
        if hit === picture || hit === count || hit === detail || hit?.isDescendant(of: picture) == true { return self }
        return hit
    }
}

/// The full gallery: every agent image of the thread as a masonry wall over the main panel, on Redesign's background.
/// Escape or the back button returns to the thread. A click opens one picture large.
public final class ThreadImageWallView: DSView {
    public var images: [GalleryImage] = [] {
        didSet {
            guard images != oldValue else { return }
            masonry.images = images
            viewer?.images = images
            count.text = "\(images.count)"
            setAccessibilityLabel("Agent images, \(images.count)")
        }
    }
    public var onClose: (() -> Void)?
    public var onOpenInThread: ((GalleryImage) -> Void)?
    /// Every source of these pictures failed while the gallery showed them.
    public var onFailed: (([GalleryImage]) -> Void)?
    public var onHash: ((GalleryImage, String) -> Void)?

    static let header: CGFloat = 52
    static let prefix = "wall:"

    let back = ButtonView(nil, icon: .arrowLeft, variant: .ghost, size: .iconSm)
    let title = LabelView("Agent images", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let masonry = GalleryMasonryView(metrics: .init(inset: NSEdgeInsets(top: Tokens.Space.s, left: Tokens.Space.xl, bottom: Tokens.Space.xl, right: Tokens.Space.xl),
                                                    gap: Tokens.Space.l, minColumn: 160, radius: Tokens.Radius.card))
    private lazy var scroll = ScrollAreaView(documentView: masonry, scrollFade: true)
    private(set) var viewer: GalleryViewerView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        count.alignment = .right
        for view in [back, title, count, scroll] as [NSView] { addSubview(view) }
        scroll.scrollsHorizontally = false
        back.toolTip = "Back to thread"
        back.setAccessibilityLabel("Back to thread")
        back.action = { [weak self] in self?.onClose?() }
        masonry.cachePrefix = Self.prefix
        masonry.makeLoader = { [weak self] image in
            ThreadImageGalleryView.loader(image, onHash: { hash in self?.onHash?(image, hash) })
        }
        masonry.onSelect = { [weak self] index in self?.openViewer(at: index) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent images")
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func layout() {
        super.layout()
        let pad = Tokens.Space.xl, w = bounds.width
        let mid = (Self.header / 2).rounded()
        back.frame = NSRect(x: pad - 6, y: mid - 16, width: 32, height: 32)
        title.frame = NSRect(x: back.frame.maxX + Tokens.Space.xs, y: mid - 9, width: 200, height: 18)
        count.frame = NSRect(x: w - pad - 120, y: mid - 9, width: 120, height: 18)
        scroll.frame = NSRect(x: 0, y: Self.header, width: w, height: max(0, bounds.height - Self.header))
        scroll.layoutSubtreeIfNeeded()
        masonry.fitWidth()
        viewer?.frame = bounds
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
    }

    /// One picture large, over the wall.
    public func openViewer(at index: Int) {
        guard images.indices.contains(index) else { return }
        if let viewer { viewer.index = index; return }
        let viewer = GalleryViewerView(frame: bounds)
        viewer.cachePrefix = Self.prefix
        viewer.makeLoader = { [weak self] image in
            ThreadImageGalleryView.loader(image, onHash: { hash in self?.onHash?(image, hash) })
        }
        viewer.images = images
        viewer.index = index
        viewer.onClose = { [weak self] in self?.closeViewer() }
        viewer.onOpenInThread = { [weak self] image in self?.onOpenInThread?(image) }
        addSubview(viewer)
        self.viewer = viewer
        masonry.focused = index
        Self.fade(viewer, in: true, rise: false) {}
        window?.makeFirstResponder(self)
    }

    public func closeViewer() {
        guard let viewer else { return }
        self.viewer = nil
        let index = viewer.index
        masonry.reveal(index)
        Self.fade(viewer, in: false, rise: false) { viewer.removeFromSuperview() }
    }

    /// Escape closes the large picture, then the gallery. Arrows step the large picture, or move the focus ring over
    /// the wall, where Return opens the focused picture.
    public override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let key = Self.key(event) else { return false }
        if let viewer {
            switch key {
            case .left: viewer.step(-1); masonry.focused = viewer.index
            case .right: viewer.step(1); masonry.focused = viewer.index
            case .escape: closeViewer()
            default: return false
            }
            return true
        }
        let n = images.count
        guard n > 0 else { return key == .escape ? { onClose?(); return true }() : false }
        let current = masonry.focused
        func move(_ delta: Int) {
            let target = current.map { min(n - 1, max(0, $0 + delta)) } ?? 0
            masonry.focused = target
            masonry.reveal(target)
        }
        switch key {
        case .escape: onClose?()
        case .left: move(-1)
        case .right: move(1)
        case .up: move(-masonry.columnCount)
        case .down: move(masonry.columnCount)
        case .enter, .space: openViewer(at: current ?? 0)
        default: return false
        }
        return true
    }

    static func key(_ event: NSEvent) -> PopupKey? {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 53: return .escape
        case 36, 76: return .enter
        case 49: return .space
        default: return nil
        }
    }

    /// Drops the wall's tiles and decodes; called once the close transition ends.
    func releaseImages() {
        viewer?.removeFromSuperview()
        viewer = nil
        onFailed?(masonry.failedImages)
        masonry.images = []
        masonry.releaseDecodes()
    }

    /// One short fade, with a 4pt rise unless Reduce Motion is on; it ends on the resting pixels.
    static func fade(_ view: NSView, in appearing: Bool, rise: Bool, done: @escaping @MainActor () -> Void) {
        guard let layer = view.layer else { done(); return }
        let duration = rise ? Tokens.Motion.appear : Tokens.Motion.quick
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : 1
        fade.toValue = appearing ? 1 : 0
        fade.duration = duration
        fade.timingFunction = Tokens.Motion.curve
        layer.opacity = appearing ? 1 : 0
        layer.add(fade, forKey: "fade")
        if rise, !Motion.reduced {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            // Layers are unflipped: a positive y is up, so the wall rises from 4pt below its place.
            move.fromValue = appearing ? -Tokens.Motion.rise : 0
            move.toValue = appearing ? 0 : -Tokens.Motion.rise
            move.duration = duration
            move.timingFunction = Tokens.Motion.curve
            layer.add(move, forKey: "rise")
        }
        CATransaction.commit()
    }
}
