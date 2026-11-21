import AppKit
import DesignSystem
import T3Protocol
import T3Store

private typealias Tokens = RedesignTokens

/// A masonry of gallery images, the document of a scroll view: the card's grid and the full gallery's wall.
///
/// Images take their place only once their natural size is known (from the signed URL or the first decode), and only
/// in order, so a placed image never moves when a later one measures or when its pixels arrive. Measuring is the first
/// load at the column's size, which the tile then shows. Only tiles within half a viewport of the visible rect exist;
/// the rest hold nothing.
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
            // A tile follows its picture to its new place and keeps its pixels: downloads, hashes and counts change
            // the list many times while pictures load. Only pictures that left the list lose their tile.
            let keys = Set(images.map(\.pixelKey))
            loaders = loaders.filter { keys.contains($0.key) }
            let gone = tileViews.keys.filter { !keys.contains($0) }
            for key in gone { tileViews.removeValue(forKey: key)?.removeFromSuperview() }
            for image in oldValue where !keys.contains(image.pixelKey) {
                MediaPriority.forget(image.key)
                image.stored.map { MediaPriority.forget($0.key) }
            }
            ImageTiming.mark("wall-list", "\(images.count) images, \(gone.count) tiles removed, \(tileViews.count) kept")
            relayout()
        }
    }
    /// Builds an image's loader; called once per image while it stays in `images`.
    var makeLoader: ((GalleryImage) -> AsyncImageView.Loader)?
    /// The card shares the decode cache with the timeline, so a reopened card shows its pictures at once. The full
    /// gallery keeps its pixels in its tiles only, so closing it frees them all: a decode already in flight when a
    /// shared request is cancelled can still land in the cache after the views are gone.
    var sharedCache = true
    var onSelect: ((Int) -> Void)?
    /// The placed height or the measured estimate changed; the card resizes to fit.
    var onContentHeight: (() -> Void)?
    /// The tile drawn with the keyboard focus ring, by index.
    var focused: Int? { didSet { if focused != oldValue { for (i, t) in tiles { t.keyFocused = i == focused } } } }

    private(set) var frames: [CGRect] = []
    /// The live tiles by pixel key, so a list change moves a tile instead of building a new one.
    private var tileViews: [String: GalleryTileView] = [:]
    /// The live tiles by index in `images`.
    var tiles: [Int: GalleryTileView] {
        var out: [Int: GalleryTileView] = [:]
        for (index, image) in images.enumerated() { if let tile = tileViews[image.pixelKey] { out[index] = tile } }
        return out
    }
    private var loaders: [String: AsyncImageView.Loader] = [:]
    private var measuring: Set<String> = []
    private var failed: Set<String> = []
    /// First loads of pictures not tiled yet, handed to their tile as its first pixels. Without the shared cache only.
    private var measured: [String: CGImage] = [:]
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var lastWidth: CGFloat = 0

    init(metrics: Metrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// The columns the width fits at `minColumn`: the most the wall shows.
    var maxColumns: Int { GalleryLayout.columns(width: contentWidth, minColumn: metrics.minColumn, gap: metrics.gap) }

    /// A density the user chose on the wall, clamped to what the width fits; nil follows the width.
    var fixedColumns: Int? { didSet { if fixedColumns != oldValue { relayout() } } }

    var columnCount: Int { fixedColumns.map { min(maxColumns, max(2, $0)) } ?? maxColumns }

    /// Pinches over the tiles, which the wall turns into density.
    var onMagnify: ((NSEvent) -> Void)?
    override func magnify(with event: NSEvent) { if let onMagnify { onMagnify(event) } else { super.magnify(with: event) } }

    /// Changes the density keeping the tile under `point` (document coordinates) at the same height in the viewport.
    func setColumns(_ columns: Int?, keeping point: CGPoint) {
        guard let clip = enclosingScrollView?.contentView else { fixedColumns = columns; return }
        let index = frames.firstIndex { $0.contains(point) }
            ?? frames.indices.min { abs(frames[$0].midY - point.y) < abs(frames[$1].midY - point.y) }
        let inView = point.y - clip.bounds.minY
        let share = index.map { (point.y - frames[$0].minY) / max(1, frames[$0].height) }
        fixedColumns = columns
        guard let index, let share, frames.indices.contains(index) else { return }
        let target = frames[index].minY + share * frames[index].height - inView
        let y = min(max(0, bounds.height - clip.bounds.height), max(0, target))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
        tile()
    }

    /// The width to lay out for before the scroll view has one, like the card's own width while it is measured.
    var widthHint: CGFloat = 0

    private var outerWidth: CGFloat {
        let clip = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        return clip > 1 ? clip : widthHint
    }

    private var contentWidth: CGFloat { max(1, outerWidth - metrics.inset.left - metrics.inset.right) }

    /// Re-flows when the scroll view's width changed since the last layout, and otherwise makes the tiles the visible
    /// rect now needs: with every size known up front nothing else would tile once the scroll view gets its frame.
    /// The host calls it from its own layout.
    func fitWidth() { if outerWidth != lastWidth { relayout() } else { tile(); measure() } }

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
        var wanted: [String: Int] = [:]
        for index in frames.indices where frames[index].intersects(live) { wanted[images[index].pixelKey] = wanted[images[index].pixelKey] ?? index }
        for key in tileViews.keys where wanted[key] == nil {
            tileViews.removeValue(forKey: key)?.removeFromSuperview()
            if let image = images.first(where: { $0.pixelKey == key }) { rank(image, visible: false) }
        }
        let visible = visibleRect
        for (key, index) in wanted.sorted(by: { $0.value < $1.value }) {
            let image = images[index]
            rank(image, visible: frames[index].intersects(visible))
            let tile = tileViews[key] ?? {
                let tile = GalleryTileView(radius: metrics.radius)
                addSubview(tile)
                tileViews[key] = tile
                return tile
            }()
            // The index moves when pictures before this one come or go.
            tile.action = { [weak self] in self?.onSelect?(index) }
            tile.frame = frames[index]
            tile.keyFocused = index == focused
            tile.thumb.cacheable = sharedCache
            tile.show(image, key: image.pixelKey, loader: failed.contains(image.pixelKey) ? { @Sendable _ in nil } : loader(image),
                      preview: measured.removeValue(forKey: image.pixelKey))
        }
    }

    /// The download order `MediaFetchQueue` reads: pictures on screen first, then smaller ones first, pixel area
    /// standing in for bytes, so a small picture never waits behind two large sheets. Unmeasured ones go last.
    // ponytail: pixel area as the size, the queue never sees bytes; rank by the signed Content-Length if the server sends one
    private func rank(_ image: GalleryImage, visible: Bool) {
        let size = image.naturalSize ?? .zero
        let order = size.width > 0 ? -Double(size.width * size.height) : -Double.greatestFiniteMagnitude
        for key in [image.key] + (image.stored.map { [$0.key] } ?? []) { MediaPriority.set(key, visible: visible, recency: order) }
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
        for image in images[frames.count...].prefix(12) where measuring.count < 6 {
            guard aspect(image) == nil, !measuring.contains(image.pixelKey) else { continue }
            measuring.insert(image.pixelKey)
            rank(image, visible: false)
            let load = loader(image), side = measureSide
            Task { [weak self] in
                // The loader itself, not the cache's shared request: a cache clear (Force Reload) cancels those, and a
                // cancelled measure must not read as a failed picture.
                let pixels = await load(side)
                self?.measured(image, pixels, side: side)
            }
        }
    }

    private var measureSide: Int { Int((columnWidth * (window?.backingScaleFactor ?? 2)).rounded(.up)) }

    /// A first load came back: keep its pixels for the tile, take its proportions if nothing measured them on the way,
    /// or mark it failed, then place what is now known.
    private func measured(_ image: GalleryImage, _ pixels: CGImage?, side: Int) {
        measuring.remove(image.pixelKey)
        if let pixels {
            if sharedCache { ImageDecodeCache.store(pixels, side: side, key: "\(image.pixelKey)|cover") } else { measured[image.pixelKey] = pixels }
            if image.naturalSize == nil { MarkdownImages.record(CGSize(width: pixels.width, height: pixels.height), for: image.key) }
        } else {
            failed.insert(image.pixelKey)
        }
        relayout()
    }

    /// Measures every picture not measured yet, in order, one at a time, and returns once all are placed. Tests use it
    /// to wait on the measuring itself rather than on the main actor's turn.
    func measureAll() async {
        for image in images where aspect(image) == nil {
            measured(image, await loader(image)(measureSide), side: measureSide)
        }
    }

    /// The pictures that failed while this view showed them.
    var failedImages: [GalleryImage] { images.filter { failed.contains($0.pixelKey) } }

    /// Lets go of the loaders (and their downloaded files) and any first loads not tiled yet. The full gallery calls
    /// it on close, after its tiles are gone.
    func releaseDecodes() {
        measured = [:]
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
    /// Whether the hover strip shows: the pointer moved onto the tile or the keyboard focus is on it.
    var showsCaption: Bool { state.hovered && Self.stillPointer == nil || keyFocused || state.focusVisible }
    /// Where the pointer rested when the gallery opened, until it moves. A tile that opens under a still pointer gets
    /// a mouseEntered without any motion; its caption waits for the pointer to move, so no tile shows one at rest.
    static var stillPointer: NSPoint?
    static var pointer: () -> NSPoint = { NSEvent.mouseLocation }
    private var moveArea: NSTrackingArea?

    init(radius: CGFloat) {
        super.init(frame: .zero)
        scalesWhenPressed = false
        thumb.cacheable = true
        thumb.skeleton = true
        thumb.layer?.cornerRadius = radius
        thumb.layer?.cornerCurve = .continuous
        addSubview(thumb)
        // The strip lives inside the picture's clip, so it takes the picture's corners.
        shade.colors = [Themed.black(0).cgColor, Themed.black(Double(Tokens.Surface.shade)).cgColor]
        shade.opacity = 0
        thumb.layer?.addSublayer(shade)
        caption.alphaValue = 0
        caption.lineHeight = 16
        caption.truncation = .middle
        addSubview(caption)
        ring.cornerRadius = radius + 2
        ring.cornerCurve = .continuous
        ring.borderWidth = 0
        layer?.addSublayer(ring)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ image: GalleryImage, key: String, loader: @escaping AsyncImageView.Loader, preview: CGImage? = nil) {
        thumb.set(key: key, fallbackText: "Image unavailable", loader: loader, preview: preview, loadingText: "")
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

    /// Moves are tracked only inside a tile, and only matter while the gallery waits for the pointer's first move.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveArea { removeTrackingArea(moveArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        moveArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        Self.notePointer()
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard Self.stillPointer != nil else { return }
        Self.notePointer()
        if Self.stillPointer == nil { restyle(animated: true) }
    }

    private static func notePointer() {
        if let still = stillPointer, pointer() != still { stillPointer = nil }
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
        // A zero width, not a nil color: a layer with a width and no color still draws its default black border.
        let ringOn = keyFocused || state.focusVisible
        ring.borderWidth = ringOn ? 2 : 0
        ring.borderColor = ringOn ? Themed.color(\.ring).cgColor(in: self) : nil
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

/// One picture large inside the gallery's card, over the wall: back to the wall, the count, previous and next, its source,
/// "Open in thread" and the card's close. A click on the ground returns to the wall.
final class GalleryViewerView: DSView {
    var images: [GalleryImage] = [] { didSet { if images != oldValue { show() } } }
    var index = 0 { didSet { if index != oldValue { show() } } }
    /// The tile's pixels, shown while the large decode is on its way.
    var preview: ((Int) -> CGImage?)?
    var makeLoader: ((GalleryImage) -> AsyncImageView.Loader)?
    var onClose: (() -> Void)?
    /// The close button: the whole gallery, as the wall's own close does.
    var onCloseGallery: (() -> Void)?
    var onOpenInThread: ((GalleryImage) -> Void)?

    let picture = AsyncImageView()
    let count = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    let detail = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let back = ButtonView(nil, icon: .arrowLeft, variant: .ghost, size: .iconSm)
    let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconSm)
    let previous = ButtonView(nil, icon: .chevronLeft, variant: .ghost, size: .iconSm)
    let next = ButtonView(nil, icon: .chevronRight, variant: .ghost, size: .iconSm)
    let openInThread = ButtonView("Open in thread", icon: .arrowUpRight, variant: .ghost, size: .xs)
    private(set) lazy var zoom = ZoomableImageView(picture: picture)
    static let bar = ThreadImageWallView.header
    let hint = ThreadImageWallView.hintLabel("Pinch or ⌘+ and ⌘− to zoom, ⌘0 to fit, double-click for 100%")
    /// Horizontal two-finger travel at fit in the current gesture, and whether it already changed the picture.
    private var swipe: (dx: CGFloat, dy: CGFloat, done: Bool, at: TimeInterval) = (0, 0, false, 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picture.cover = false
        picture.skeleton = true
        picture.layer?.cornerRadius = Tokens.Radius.card
        picture.layer?.cornerCurve = .continuous
        detail.truncation = .middle
        zoom.naturalSize = { [weak self] in self?.shown?.naturalSize }
        zoom.fit = { natural, area, backing in GalleryLayout.fit(natural, in: area, scale: backing) }
        zoom.onBackgroundClick = { [weak self] in self?.onClose?() }
        zoom.onFitScroll = { [weak self] event in self?.swipe(event) }
        for view in [zoom, back, count, hint, detail, close, previous, next, openInThread] as [NSView] { addSubview(view) }
        back.setTooltip("Back to all images", shortcut: "Esc"); back.setAccessibilityLabel("Back to all images")
        close.setTooltip("Close", shortcut: "Esc"); close.setAccessibilityLabel("Close")
        previous.setTooltip("Previous image"); previous.setAccessibilityLabel("Previous image")
        next.setTooltip("Next image"); next.setAccessibilityLabel("Next image")
        back.action = { [weak self] in self?.onClose?() }
        close.action = { [weak self] in self?.onCloseGallery?() }
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
        zoom.reset()
        guard let image = shown else { picture.set(key: nil, fallbackText: "", loader: nil); return }
        let loader = makeLoader?(image) ?? ThreadImageGalleryView.loader(image)
        picture.set(key: image.pixelKey, fallbackText: "Image unavailable", loader: loader, preview: preview?(index), loadingText: "")
        count.text = "\(index + 1) of \(images.count)"
        detail.text = ThreadImageGalleryView.caption(image, long: true) + " · " + ThreadImageGalleryView.name(image)
        picture.setAccessibilityLabel(ThreadImageGalleryView.name(image) + ", " + ThreadImageGalleryView.caption(image))
        previous.isHidden = images.count < 2
        next.isHidden = images.count < 2
        needsLayout = true
    }

    /// The area the picture fits and zooms in: below the top bar, above the footer, clear of the side arrows.
    var pictureArea: CGRect {
        let side = Tokens.Space.xl + 32 + Tokens.Space.s
        return CGRect(x: side, y: Self.bar, width: max(1, bounds.width - 2 * side), height: max(1, bounds.height - 2 * Self.bar))
    }

    /// At fit, a two-finger swipe sideways changes the picture once per gesture; momentum and vertical travel do nothing.
    private func swipe(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        // A device without gesture phases starts a new swipe after a pause.
        if event.phase.contains(.began) || (event.phase.isEmpty && event.timestamp - swipe.at > 0.3) { swipe = (0, 0, false, 0) }
        swipe.at = event.timestamp
        swipe.dx += event.scrollingDeltaX
        swipe.dy += event.scrollingDeltaY
        guard !swipe.done, abs(swipe.dx) > 60, abs(swipe.dx) > 2 * abs(swipe.dy) else { return }
        swipe.done = true
        // Content follows the fingers: dragging it left brings in the next picture.
        step(swipe.dx < 0 ? 1 : -1)
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.xl, w = bounds.width, h = bounds.height
        ThreadImageWallView.placeBar(back: back, labels: [count], hint: hint, close: close, width: w)
        let middle = (h / 2 - 16).rounded()
        previous.frame = NSRect(x: pad, y: middle, width: 32, height: 32)
        next.frame = NSRect(x: w - pad - 32, y: middle, width: 32, height: 32)
        zoom.frame = pictureArea
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
        // Opaque: a see-through veil let the wall's header read through the count.
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
    }

    /// The veil returns to the wall; the picture zooms, and a click beside it inside its area returns too.
    override func mouseDown(with event: NSEvent) { onClose?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // The labels are not controls: their clicks land on the veil's own handler.
        if hit === count || hit === detail || hit === hint { return self }
        return hit
    }

    /// Pinches between the bars zoom the picture too.
    override func magnify(with event: NSEvent) { zoom.magnify(with: event) }
}

/// The full gallery: every agent image of the thread as a masonry wall, the content of a route modal like Settings'.
/// Escape or the close button closes it. A click opens one picture large inside the same card.
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

    /// Settings' route-modal bar height (`SettingsHeaderView.barHeight`).
    static let header: CGFloat = 48
    /// The wall's density for the rest of the session, once a pinch or ⌘+ / ⌘- chose one.
    // ponytail: session only, one number; persist it if the user wants it across launches
    static var sessionColumns: Int?
    /// The pinch in progress: the columns it started from and how far it has zoomed.
    private var pinch: (columns: Int, zoom: CGFloat)?

    let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconSm)
    let title = LabelView("Agent images", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    let count = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.mutedForeground))
    /// How to change the picture size, as quiet text in the bar instead of a tooltip over the pictures.
    let hint = ThreadImageWallView.hintLabel("Pinch or ⌘+ and ⌘− to resize, ⌘0 to fit")
    private let rule = DSView()
    let masonry = GalleryMasonryView(metrics: .init(inset: NSEdgeInsets(top: Tokens.Space.s, left: Tokens.Space.xl, bottom: Tokens.Space.xl, right: Tokens.Space.xl),
                                                    gap: Tokens.Space.l, minColumn: 160, radius: Tokens.Radius.card))
    private lazy var scroll = ScrollAreaView(documentView: masonry, scrollFade: true)
    private(set) var viewer: GalleryViewerView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [title, count, hint, close, rule, scroll] as [NSView] { addSubview(view) }
        scroll.scrollsHorizontally = false
        close.setTooltip("Close", shortcut: "Esc")
        close.setAccessibilityLabel("Close")
        close.action = { [weak self] in self?.onClose?() }
        masonry.sharedCache = false
        masonry.makeLoader = { [weak self] image in
            ThreadImageGalleryView.loader(image, onHash: { hash in self?.onHash?(image, hash) })
        }
        masonry.onSelect = { [weak self] index in self?.openViewer(at: index) }
        masonry.fixedColumns = Self.sessionColumns
        masonry.onMagnify = { [weak self] event in self?.magnify(with: event) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent images")
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        GalleryTileView.stillPointer = window == nil ? nil : GalleryTileView.pointer()
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        Self.placeBar(back: nil, labels: [title, count], hint: hint, close: close, width: w)
        rule.frame = NSRect(x: 0, y: Self.header - 1, width: w, height: 1)
        let top = Self.header
        scroll.frame = NSRect(x: 0, y: top, width: w, height: max(0, bounds.height - top))
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
        rule.layer?.backgroundColor = Themed.color(\.border).cgColor(in: self)
    }

    /// Settings' route-modal bar (`SettingsHeaderView.layout`): the title 20pt in, the close a 28pt square 8pt from the
    /// right edge, both centred in `header`. A back button takes the title's inset and the title follows it.
    static func placeBar(back: NSView?, labels: [LabelView], hint: LabelView? = nil, close: NSView, width: CGFloat) {
        let mid = header / 2
        var x: CGFloat = 20
        if let back {
            back.frame = NSRect(x: 8, y: mid - 14, width: 28, height: 28)
            x = back.frame.maxX + 4
        }
        for label in labels {
            label.lineHeight = 20
            let w = ceil(label.textWidth) + 1
            label.frame = NSRect(x: x, y: mid - 10, width: max(0, min(w, width - 44 - x)), height: 20)
            x += w + 8
        }
        close.frame = NSRect(x: width - 8 - 28, y: mid - 14, width: 28, height: 28)
        // The hint sits right of the labels and ends 12pt before the close; it hides where it would crowd them.
        if let hint {
            let w = ceil(hint.textWidth) + 1
            let left = close.frame.minX - 12 - w
            hint.isHidden = left < x + 16
            hint.frame = NSRect(x: left, y: mid - 8, width: w, height: 16)
        }
    }

    static func hintLabel(_ text: String) -> LabelView {
        let label = LabelView(text, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        label.lineHeight = 16
        label.setAccessibilityElement(false)
        return label
    }

    /// One picture large, over the wall.
    public func openViewer(at index: Int) {
        guard images.indices.contains(index) else { return }
        if let viewer { viewer.index = index; return }
        let viewer = GalleryViewerView(frame: bounds)
        viewer.preview = { [weak self] index in self?.masonry.tiles[index]?.thumb.image }
        viewer.makeLoader = { [weak self] image in
            ThreadImageGalleryView.loader(image, onHash: { hash in self?.onHash?(image, hash) })
        }
        viewer.images = images
        viewer.index = index
        viewer.onClose = { [weak self] in self?.closeViewer() }
        viewer.onCloseGallery = { [weak self] in self?.onClose?() }
        viewer.onOpenInThread = { [weak self] image in self?.onOpenInThread?(image) }
        addSubview(viewer)
        self.viewer = viewer
        Self.fade(viewer, in: true) {}
        window?.makeFirstResponder(self)
    }

    public func closeViewer() {
        guard let viewer else { return }
        self.viewer = nil
        let index = viewer.index
        masonry.reveal(index)
        Self.fade(viewer, in: false) { viewer.removeFromSuperview() }
    }

    /// Pinching over the wall changes its density in whole columns as the fingers move: apart for fewer, larger
    /// pictures, together for more, smaller ones, keeping the picture under the pointer in place.
    // ponytail: whole-column steps during the pinch; scale the document between steps if the steps read as jumpy
    public override func magnify(with event: NSEvent) {
        if let viewer { viewer.magnify(with: event); return }
        if event.phase.contains(.began) || pinch == nil { pinch = (masonry.columnCount, 1) }
        guard var pinch else { return }
        pinch.zoom *= 1 + event.magnification
        self.pinch = event.phase.contains(.ended) || event.phase.contains(.cancelled) ? nil : pinch
        let columns = GalleryLayout.density(from: pinch.columns, zoom: pinch.zoom, max: masonry.maxColumns)
        setColumns(columns, keeping: masonry.convert(event.locationInWindow, from: nil))
    }

    /// ⌘+ and ⌘- step the wall's density by a column, ⌘0 follows the width again; the large picture takes them while open.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard viewer == nil, window != nil, let direction = ImageZoom.command(event) else { return super.performKeyEquivalent(with: event) }
        let visible = masonry.visibleRect
        let middle = CGPoint(x: visible.midX, y: visible.midY)
        if direction == 0 { setColumns(nil, keeping: middle); return true }
        setColumns(min(masonry.maxColumns, max(2, masonry.columnCount - direction)), keeping: middle)
        return true
    }

    private func setColumns(_ columns: Int?, keeping point: CGPoint) {
        // The width's own count is no choice: a wider window shows more again.
        let chosen = columns == masonry.maxColumns ? nil : columns
        Self.sessionColumns = chosen
        guard chosen != masonry.fixedColumns else { return }
        let before = masonry.columnCount
        masonry.setColumns(chosen, keeping: point)
        if masonry.columnCount != before { Haptics.tap(.alignment) }
        setAccessibilityValue("\(masonry.columnCount) columns")
    }

    /// Escape closes the large picture, then the gallery (inside the route modal its key monitor asks
    /// `takeRouteModalEscape` first). Arrows step the large picture, or move the focus ring over
    /// the wall, where Return opens the focused picture.
    public override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let key = Self.key(event) else { return false }
        if let viewer {
            switch key {
            // The ring follows only when the keyboard put it on the wall; a click leaves no ring behind.
            case .left: viewer.step(-1); if masonry.focused != nil { masonry.focused = viewer.index }
            case .right: viewer.step(1); if masonry.focused != nil { masonry.focused = viewer.index }
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

    /// The large view's short fade in and out over the wall; it ends on the resting pixels.
    static func fade(_ view: NSView, in appearing: Bool, done: @escaping @MainActor () -> Void) {
        guard let layer = view.layer else { done(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : 1
        fade.toValue = appearing ? 1 : 0
        fade.duration = Tokens.Motion.quick
        fade.timingFunction = Tokens.Motion.curve
        layer.opacity = appearing ? 1 : 0
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

extension ThreadImageWallView: RouteModalEscapeHandler {
    /// Escape inside the route modal: the large view goes back to the wall; on the wall the modal closes.
    func takeRouteModalEscape() -> Bool {
        guard viewer != nil else { return false }
        closeViewer()
        return true
    }
}
